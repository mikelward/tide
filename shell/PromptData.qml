pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/report.mjs" as Report
import "lib/tidewm.mjs" as Tw
import "lib/workspacenames.mjs" as Names
import "lib/workspaces.mjs" as Ws

// The name prompt's requests (SPEC.md §6.5), one shown at a time by
// NamePrompt.qml, the rest waiting their turn (Names.promptQueued):
//   - a new window on a workspace whose askForName is on, home by default,
//     as it's first focused, unless it's a dialog, a status popup or one
//     of home's apps (Names.promptWanted). One that takes focus as it
//     opens asks at once; one the focus guard left waiting asks when you
//     go to it. One a launch sent to such a workspace opens there and
//     doesn't ask again (Ws.windowPrompt);
//   - Super+Return, for a workspace to go to, moving no window, so it
//     asks with no window focused too (`qs -c tide ipc call prompt go`);
//   - Super+Shift+Return, for the focused window (`qs -c tide ipc call
//     prompt move`);
//   - a launch from a workspace that asks, which `tide launch` asks about before starting
//     anything (`ipc call prompt launch JSON`), waiting for the answer on
//     a FIFO so it starts the app itself, in its caller's environment; and
//     the launcher's Ctrl+Enter, which the shell launches.
// Every one offers home: any window may go there, and any launch open
// there. A request that arrives while another is shown waits; one replacing
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
    // tidewm's focus event carries the window, so it's judged at once.
    property var windows: Names.NO_WINDOWS
    // Launches answered with a workspace that asks, home by default
    // (Ws.homeLaunched), so their windows, which open there, don't ask
    // again.
    property var homeLaunches: Ws.NO_HOME_LAUNCHES

    function ask(request) {
        root.state = Names.promptQueued(root.state, request);
    }

    // Super+Return: a workspace to go to, from wherever you are, an empty
    // one included.
    function askGo() {
        root.ask({ kind: "go" });
    }

    // Super+Shift+Return: the focused window, wherever it is, to any
    // workspace, home included. With none there's nothing to move, so it
    // only says so in the log.
    function askMove() {
        const address = Compositor.tidewm
            ? Compositor.tidewmActive?.address ?? null
            : Ws.normalizeAddress(Hyprland.activeToplevel?.address);
        if (address === null) {
            console.log("tide: Super+Shift+Return with no window focused; nothing to move");
            return;
        }
        root.ask({ kind: "move", address: address });
    }

    // The launcher's Ctrl+Enter: `argv` is what follows `tide launch`, run
    // in `cwd`, and `apps` the IDs it grants. It always asks.
    function askLaunch(argv, cwd, apps) {
        root.ask({ kind: "launch", argv: argv, cwd: cwd, apps: apps });
    }

    // `tide launch` from a workspace that asks, waiting on the FIFO at `answer`, for an app
    // whose window may have any of the classes `apps` (resolved there past
    // wrappers and desktop entries), granted to windows of `grants` (`*`
    // for any, as a terminal's). One of home's apps is answered home at
    // once, as SPEC.md §6.5 says.
    function askAnswer(answer, apps, grants) {
        if (apps.some(id => Names.isHomeApp(id, root.inApps, WorkspacesData.resolved))) {
            root.reply(answer, `workspace ${root.home}`);
            return;
        }
        root.ask({ kind: "launch", answer: answer, apps: apps, grants: grants });
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

    // Enter: go to `name`, made if it's new, as Names.promptAnswer says.
    function answer(name) {
        const r = root.current;
        if (r === null) {
            return;
        }
        root.state = Names.promptDone(root.state, r.id);
        if (r.kind === "launch" && Names.asksForName(WorkspacesData.settings, name)) {
            root.homeLaunches = Ws.homeLaunched(root.homeLaunches, r.grants ?? r.apps, Date.now() / 1000);
        }
        const a = Names.promptAnswer(r, name);
        if (a.reply !== undefined) {
            root.reply(a.answer, a.reply);
        } else if (a.launch !== undefined) {
            root.launch(a.name, a.launch, a.cwd);
        } else if (a.go !== undefined) {
            Compositor.goToWorkspace(a.go);
        } else {
            Compositor.moveWindowToNamed(a.move, a.name);
        }
    }

    // The workspace the window at `address` is pinned on (Names.pinnedOn),
    // or null.
    function pinnedOn(address) {
        const w = Compositor.windows.find(w => w.address === address);
        if (!w) {
            return null;
        }
        return Names.pinnedOn(w.app, w.workspaceName, WorkspacesData.settings, WorkspacesData.resolved);
    }

    // Esc, as Names.promptCancel says: a new window closes, politely, as
    // Super+Backspace does, unless it's pinned where it is, when a
    // notification says so; a launch doesn't happen; anything else stays
    // as it was.
    function cancel() {
        const r = root.current;
        if (r === null) {
            return;
        }
        root.state = Names.promptDone(root.state, r.id);
        const c = Names.promptCancel(r);
        const pinned = c.close !== undefined ? root.pinnedOn(c.close) : null;
        if (pinned !== null) {
            const notice = Names.pinnedNotice(pinned);
            console.log(`tide: not closing window ${c.close}: it's pinned on ${pinned}`);
            Launcher.run(Report.notifyCommand(notice.summary, notice.body), ok => {
                if (!ok) {
                    console.warn(`tide: couldn't say window ${c.close} is pinned on ${pinned}`);
                }
            });
        } else if (c.close !== undefined) {
            Compositor.closeWindow(c.close);
        } else if (c.reply !== undefined) {
            root.reply(c.answer, c.reply);
        }
    }

    IpcHandler {
        target: "prompt"

        // `request` is JSON: {"apps": [...], "grants": [...], "answer":
        // FIFO}, from `tide launch`, which waits on the FIFO for "workspace NAME" or
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
                || !Array.isArray(r.apps) || !r.apps.every(a => typeof a === "string")
                || (r.grants !== undefined && !(Array.isArray(r.grants) && r.grants.every(a => typeof a === "string")))) {
                return "refused: expected {\"apps\": [IDs], \"grants\": [IDs], \"answer\": \"/path/to/fifo\"}";
            }
            root.askAnswer(r.answer, r.apps, r.grants);
            return "asked";
        }
        function go(): void {
            root.askGo();
        }
        function move(): void {
            root.askMove();
        }
        // The kind of the prompt shown ("go", "move", "window" or
        // "launch"), or "" with none: for the integration test.
        function shown(): string {
            return root.current?.kind ?? "";
        }
    }

    // The window at `address`, just first focused, as the compositor
    // describes it (`client`, null once it's gone): it asks for a
    // workspace if Ws.windowPrompt says so. A launch you sent to a workspace that asks stays there,
    // without asking.
    function judge(address, client) {
        const judged = Ws.windowPrompt(client, {
            settings: WorkspacesData.settings,
            resolved: WorkspacesData.resolved,
            launches: root.homeLaunches,
            now: Date.now() / 1000
        });
        root.homeLaunches = judged.launches;
        if (judged.ask) {
            root.ask({ kind: "window", address: address });
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
                        console.warn(`tide: couldn't read hyprctl clients, so a new window may not ask for a workspace: ${e.message}`);
                    }
                    const answered = Names.windowAnswered(root.windows, run.address);
                    root.windows = answered.state;
                    // Closed while Hyprland answered: nothing to ask about.
                    root.judge(run.address, answered.live ? Names.clientAt(clients, run.address) : null);
                }
            }
            onExited: (code, status) => {
                if (code !== 0) {
                    console.warn(`tide: hyprctl clients exited ${code}, so a new window may not ask for a workspace`);
                }
                destroy();
            }
        }
    }

    Connections {
        target: Compositor.tidewm ? null : Hyprland

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

    // tidewm's window events (TidewmData.qml), as Hyprland's above.
    Connections {
        target: Compositor.tidewm ? TidewmData : null

        function onWindowHeard(data) {
            const e = Tw.promptEvent(data);
            if (e === null) {
                return;
            }
            if (e.change === "new") {
                root.windows = Names.windowOpened(root.windows, e.address);
            } else if (e.change === "close") {
                root.windows = Names.windowClosed(root.windows, e.address);
                root.state = Names.promptWindowGone(root.state, e.address);
            } else {
                const focused = Names.windowFocused(root.windows, e.address);
                if (focused.lookup) {
                    root.windows = Names.windowAnswered(focused.state, e.address).state;
                    root.judge(e.address, e.client);
                }
            }
        }
    }
}
