pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/dispatch.mjs" as Dispatch
import "lib/workspacenames.mjs" as Names
import "lib/workspaces.mjs" as Ws

// The name prompt's requests (SPEC.md §6.5), one shown at a time by
// NamePrompt.qml, the rest waiting their turn (Names.promptQueued):
//   - a new window on home, as it's first focused, unless it's a dialog, a
//     status popup or one of home's apps (Names.promptWanted). One that
//     takes focus as it opens asks at once; one the focus guard left
//     waiting asks when you go to it;
//   - Super+Return, for the focused window (`qs -c tide ipc call prompt
//     move`);
//   - a launch from home, which `tide launch` asks about before starting
//     anything (`ipc call prompt launch JSON`), waiting for the answer on
//     a FIFO so it starts the app itself, in its caller's environment; and
//     the launcher's Ctrl+Enter, which the shell launches.
// A request that arrives while another is shown waits; one replacing
// another is never taken as the first one's Esc.
Singleton {
    id: root

    property var state: Names.NO_PROMPTS
    readonly property var current: root.state.queue.length > 0 ? root.state.queue[0] : null
    readonly property string home: WorkspacesData.home
    readonly property var inApps: WorkspacesData.settings.inApps
    // The title patterns, compiled; WorkspacesData only takes a list whose
    // every pattern compiles.
    readonly property var patterns: Names.checkPatterns(WorkspacesData.settings.namePatterns).patterns ?? []
    // Windows opened since the shell started that haven't been judged yet
    // (Names.windowOpened): the first focus asks Hyprland about one, and an
    // answer that comes after it closed is dropped (Names.windowAnswered).
    property var windows: Names.NO_WINDOWS

    function ask(request) {
        root.state = Names.promptQueued(root.state, request);
    }

    // A window's class, from Hyprland's client list or its app ID.
    function classOf(address) {
        const t = Hyprland.toplevels.values.find(w => Ws.normalizeAddress(w.address) === address);
        return t ? (t.lastIpcObject?.class || t.wayland?.appId || "") : "";
    }

    // Super+Return: the focused window, wherever it is.
    function askMove() {
        const address = Ws.normalizeAddress(Hyprland.activeToplevel?.address);
        if (address === null) {
            console.log("tide: Super+Return with no window focused; nothing to move");
            return;
        }
        root.ask({ kind: "move", address: address, allowHome: Names.isHomeApp(root.classOf(address), root.inApps) });
    }

    // The launcher's Ctrl+Enter: `argv` is what follows `tide launch`, run
    // in `cwd`, and `apps` the IDs it grants. It always asks, and home is
    // offered to one of home's apps.
    function askLaunch(argv, cwd, apps) {
        const homeApp = apps.some(id => Names.isHomeApp(id, root.inApps));
        root.ask({ kind: "launch", argv: argv, cwd: cwd, allowHome: homeApp });
    }

    // `tide launch` from home, waiting on the FIFO at `answer`, for an app
    // whose window may have any of the classes `apps` (resolved there past
    // wrappers and desktop entries). One of home's apps is answered home at
    // once, as SPEC.md §6.5 says.
    function askAnswer(answer, apps) {
        if (apps.some(id => Names.isHomeApp(id, root.inApps))) {
            root.reply(answer, `workspace ${root.home}`);
            return;
        }
        root.ask({ kind: "launch", answer: answer, allowHome: false });
    }

    // Tells a waiting `tide launch` its answer: "workspace NAME" or
    // "cancel". The FIFO is gone once it stopped waiting (it gives up after
    // an hour), and then nothing is written, so no file is left in its
    // place; the write gives up after 5 s too. Either is said in the log.
    function reply(answer, line) {
        replier.createObject(root, {
            command: ["timeout", "5", "sh", "-c", 'test -p "$2" && printf "%s\\n" "$1" > "$2"', "sh", line, answer]
        }).running = true;
    }

    function launch(name, argv, cwd) {
        Launcher.start(["tide", "launch", "--workspace", name].concat(argv), cwd);
    }

    // Enter: go to `name`, made if it's new.
    function answer(name) {
        const r = root.current;
        if (r === null) {
            return;
        }
        root.state = Names.promptDone(root.state, r.id);
        if (r.kind === "launch" && r.answer !== undefined) {
            root.reply(r.answer, `workspace ${name}`);
        } else if (r.kind === "launch") {
            root.launch(name, r.argv, r.cwd);
        } else {
            Hyprland.dispatch(Dispatch.moveWindowToWorkspace(r.address, name, Hyprland.usingLua));
        }
    }

    // Esc: a new window on home closes, politely, as Super+Backspace does;
    // a launch doesn't happen; Super+Return leaves the window where it is.
    function cancel() {
        const r = root.current;
        if (r === null) {
            return;
        }
        root.state = Names.promptDone(root.state, r.id);
        if (r.kind === "window") {
            Hyprland.dispatch(Dispatch.closeWindow(r.address, Hyprland.usingLua));
        } else if (r.kind === "launch" && r.answer !== undefined) {
            root.reply(r.answer, "cancel");
        }
    }

    IpcHandler {
        target: "prompt"

        // `request` is JSON: {"apps": [...], "answer": FIFO}, from `tide
        // launch`, which waits on the FIFO for "workspace NAME" or
        // "cancel". A malformed one is refused, so tide launch starts the
        // app where you are and says why.
        function launch(request: string): string {
            let r;
            try {
                r = JSON.parse(request);
            } catch (e) {
                return `refused: not JSON: ${e.message}`;
            }
            if (!r || typeof r.answer !== "string" || !r.answer.startsWith("/")
                || !Array.isArray(r.apps) || !r.apps.every(a => typeof a === "string")) {
                return "refused: expected {\"apps\": [IDs], \"answer\": \"/path/to/fifo\"}";
            }
            root.askAnswer(r.answer, r.apps);
            return "asked";
        }
        function move(): void {
            root.askMove();
        }
    }

    Component {
        id: replier

        Process {
            onExited: (code, status) => {
                if (code !== 0) {
                    console.warn(`tide: couldn't tell tide launch the name prompt's answer (exit ${code}): it had stopped waiting`);
                }
                destroy();
            }
        }
    }

    // Asks Hyprland about a window as it's first focused, by its address
    // in the client list: focus may have moved on by the time it answers.
    Component {
        id: lookup

        Process {
            id: run

            property string address: ""

            command: ["hyprctl", "clients", "-j"]
            stdout: StdioCollector {
                onStreamFinished: {
                    let clients = [];
                    try {
                        clients = JSON.parse(text);
                    } catch (e) {
                        console.warn(`tide: couldn't read hyprctl clients, so a new window on home may not ask for a workspace: ${e.message}`);
                    }
                    const answered = Names.windowAnswered(root.windows, run.address);
                    root.windows = answered.state;
                    // Closed while Hyprland answered: nothing to ask about.
                    const client = answered.live ? Names.clientAt(clients, run.address) : null;
                    if (Names.promptWanted(client, root.home, root.inApps)) {
                        root.ask({ kind: "window", address: run.address, allowHome: false });
                    }
                }
            }
            onExited: (code, status) => {
                if (code !== 0) {
                    console.warn(`tide: hyprctl clients exited ${code}, so a new window on home may not ask for a workspace`);
                }
                destroy();
            }
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            const data = String(event.data);
            if (event.name === "openwindow") {
                const address = Ws.normalizeAddress(data.split(",")[0]);
                if (address !== null) {
                    root.windows = Names.windowOpened(root.windows, address);
                }
            } else if (event.name === "closewindow") {
                const address = Ws.normalizeAddress(data);
                root.windows = Names.windowClosed(root.windows, address);
                root.state = Names.promptWindowGone(root.state, address);
            } else if (event.name === "activewindowv2") {
                const address = Ws.normalizeAddress(data);
                const focused = address === null ? null : Names.windowFocused(root.windows, address);
                if (focused && focused.lookup) {
                    root.windows = focused.state;
                    lookup.createObject(root, { address: address }).running = true;
                }
            }
        }
    }
}
