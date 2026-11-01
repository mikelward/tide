pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/dispatch.mjs" as Dispatch
import "lib/floating.mjs" as Rules
import "lib/launch.mjs" as Run
import "lib/report.mjs" as Report
import "lib/workspaces.mjs" as Ws
import "lib/writes.mjs" as Writes

// Which windows float (SPEC.md §6.4, §16), from floating.json and
// floating.local.json (§16.1): each rule a window class and, optionally, a
// title pattern. They're written to ~/.config/hypr/tide-floating.lua, which
// conf's hyprland.lua reads as it loads, and `hyprctl eval
// conf_floating.reload()` has it read again, as the shell starts too. Once
// Hyprland has new rules, the tiled windows they cover that the old ones
// didn't are floated, since a rule floats a window only as it opens. A bad
// file is a notification naming it, once, and the last good rules stay;
// one that can't be written or applied is tried again until it is
// (shell/lib/writes.mjs).
Singleton {
    id: root

    // The rules in effect, none until the files are read.
    property var rules: []
    property var reports: Report.NOTHING
    property var fileErrors: []
    property string saveFailure: ""
    property var target: Writes.TARGET
    // The rules last asked for, as text, and the rules themselves; and the
    // rules the open windows were last floated for, null until this shell
    // has swept them, when the record says (Rules.sweptRules): which
    // windows a new rule floats (Rules.newlyCovered).
    property var wanted: ({ text: null, rules: [] })
    property var appliedRules: null
    readonly property string sweptPath: Rules.sweptPath(Quickshell.env("XDG_RUNTIME_DIR") || "", Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")

    // The open windows, as Hyprland's client list gives them.
    readonly property var windows: Hyprland.toplevels.values.map(t => Rules.windowOf(t))
    // The page's Floating now: floating windows no rule covers.
    readonly property var unruled: Rules.floatingNow(root.windows, root.rules)

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    function stepped(r) {
        root.target = r.state;
        if (r.action?.write !== undefined) {
            const error = written.writeNow(r.action.write);
            root.stepped(Writes.targetWritten(root.target, error === "" ? "" : `${error}; the floating rules stay as they were`));
            return;
        }
        if (r.action?.apply) {
            applier.createObject(root).running = true;
        }
        root.report();
    }

    function report() {
        const failures = [root.target.failure].filter(f => f !== "");
        const errors = root.fileErrors.concat(root.saveFailure !== "" ? [root.saveFailure] : [], failures);
        const v = Report.verdict(root.reports, errors);
        root.reports = v.state;
        root.send(v.send);
        if (failures.length > 0 && !retry.running) {
            retry.start();
        }
    }

    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Floating rules not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    // Reads both files and the file hyprland.lua reads, and writes and
    // applies the rules. Run at the start, whenever a file changes on
    // disk, and after the page's changes.
    function load() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Rules.loadFloating(sharedText, localText, root.rules);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        if (root.fileErrors.length > 0) {
            root.report();
            return;
        }
        root.rules = result.rules;
        const writtenText = written.readNow();
        if (written.broken !== "") {
            root.stepped(Writes.targetUnreadable(root.target, `${written.broken}; the floating rules stay as they were`));
            return;
        }
        // Hyprland outlives the shell, and a shell that died with an apply
        // still to retry left it with the old rules, so the first read
        // applies what's wanted, as WorkspacesData does: the same rules
        // again change nothing.
        root.target = Writes.readTarget(root.target, writtenText, null).state;
        const text = Rules.floatingLua(root.rules);
        root.wanted = { text: text, rules: root.rules };
        root.stepped(Writes.wantTarget(root.target, text));
    }

    // Hyprland took `text`: if it's the rules last asked for, the tiled
    // windows they cover that nothing covered before are floated, and the
    // record says these rules were swept, so a shell that restarts before
    // sweeping one still does.
    function rulesApplied(text) {
        if (text !== root.wanted.text) {
            return;
        }
        let before = root.appliedRules;
        if (before === null) {
            const recorded = root.sweptPath === "" ? null : swept.readNow();
            if (swept.broken !== "") {
                console.warn(`tide: ${swept.broken}; taking the floating rules in effect as swept`);
            }
            const r = Rules.sweptRules(recorded, root.wanted.rules);
            if (r.warning !== "") {
                console.warn(`tide: ${r.warning}`);
            }
            before = r.rules;
        }
        for (const address of Rules.newlyCovered(root.windows, before, root.wanted.rules)) {
            if (address === null) {
                continue;
            }
            console.log(`tide: floating window ${address}, which a new floating rule covers`);
            Hyprland.dispatch(Dispatch.floatWindow(address, Hyprland.usingLua));
        }
        root.appliedRules = root.wanted.rules;
        if (root.sweptPath === "") {
            console.warn("tide: no XDG_RUNTIME_DIR or HYPRLAND_INSTANCE_SIGNATURE, so a shell restarted mid-change won't float the windows it left");
            return;
        }
        const error = swept.writeNow(Rules.sweptText(root.wanted.rules));
        if (error !== "") {
            // Costs only a second sweep, which skips windows floating already.
            console.warn(`tide: ${error}; a restarted shell may float these windows again`);
        }
    }

    // The page's changes (SPEC.md §16): add a rule, or move or take out
    // one, by its place and what it is (Rules.movedRule). Each returns why
    // it didn't, or "".
    function add(cls, title) {
        return root.edit(rules => Rules.withRule(rules, cls, title));
    }

    function move(index, rule, step) {
        return root.edit(rules => Rules.movedRule(rules, index, rule, step));
    }

    function remove(index, rule) {
        return root.edit(rules => Rules.withoutRule(rules, index, rule));
    }

    // What the page's fields are to be filled with, for you to trim and
    // add with Enter: {class, title, note, serial}, the serial telling one
    // fill from the next for the same window. Always float and Super+Alt+F
    // set it (Rules.prefilled); nothing is added until you add it.
    property var prefill: null
    // Whether the page shows More about this window open: closed at first,
    // and as you left it for as long as the shell runs.
    property bool detailsOpen: false

    // Fills the page's fields for `window` ({class, title}): "" or why not.
    function prefillFor(window) {
        const p = Rules.prefilled(root.rules, window);
        if (p.error) {
            return p.error;
        }
        root.prefill = { class: p.class, title: p.title, note: p.note, details: p.details, serial: (root.prefill?.serial ?? 0) + 1 };
        return "";
    }

    // Changes the rules as `change` says, in floating.local.json: the panel
    // writes only the .local files (§16.1). The files as they are now, so
    // a hand edit made a moment ago is built on, and one that doesn't parse
    // is left as it is.
    function edit(change) {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing the floating rules`;
        }
        const result = Rules.editedFloating(sharedText, localText, change);
        if (result.error) {
            return `${result.error}; not changing the floating rules`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; the floating rules not saved`;
        root.load();
        root.report();
        return root.saveFailure;
    }

    // Asking to always float a window floated by the keys (SPEC.md §6.4):
    // the classes asked about, and where the declined ones are kept for
    // the Hyprland session (Rules.askFloat).
    property var asks: Rules.NO_ASKS
    property bool asksRead: false
    readonly property string declinedPath: Rules.declinedPath(Quickshell.env("XDG_RUNTIME_DIR") || "", Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")

    // conf's float keys left the window at `address` floating: ask, unless
    // a rule covers it or its class was asked about this session.
    function floatedByKeys(address) {
        if (!root.asksRead) {
            root.asksRead = true;
            const text = root.declinedPath === "" ? null : declined.readNow();
            if (declined.broken !== "") {
                console.warn(`tide: ${declined.broken}; asking about every class again`);
            }
            const r = Rules.declinedRead(text);
            if (r.warning !== "") {
                console.warn(`tide: ${r.warning}`);
            }
            root.asks = Object.assign({}, root.asks, { declined: r.declined });
        }
        const toplevel = Hyprland.toplevels.values.find(t => Ws.normalizeAddress(t.address) === address);
        const r = Rules.askFloat(root.asks, root.rules, Rules.windowOf(toplevel));
        root.asks = r.state;
        if (r.ask !== null) {
            asker.createObject(root, { window: r.ask }).running = true;
        }
    }

    function askAnswered(window, outcome) {
        root.asks = Rules.askAnswered(root.asks, window.class, outcome);
        if (outcome === "always") {
            const error = root.add(window.class, "");
            if (error !== "") {
                Launcher.run(Report.notifyCommand(`${window.class} not added to the floating rules`, error), ok => {
                    if (!ok) {
                        console.warn(`tide: couldn't say why ${window.class} wasn't added to the floating rules: ${error}`);
                    }
                });
            }
        } else if (outcome === "edit") {
            const error = root.prefillFor(window);
            if (error === "") {
                SettingsData.open("floating");
            } else {
                console.warn(`tide: couldn't fill in a floating rule for ${window.class}: ${error}`);
            }
        } else if (outcome === "failed") {
            // The tracker has logged why; it can be asked again.
            return;
        }
        if (root.declinedPath === "") {
            console.warn("tide: no XDG_RUNTIME_DIR or HYPRLAND_INSTANCE_SIGNATURE, so a restarted shell may ask about floating again");
            return;
        }
        const error = declined.writeNow(Rules.declinedText(root.asks));
        if (error !== "") {
            // Costs only asking again after a shell restart.
            console.warn(`tide: ${error}; a restarted shell may ask about ${window.class} again`);
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            const address = Rules.floatedEvent(event.name, event.data);
            if (address !== null) {
                root.floatedByKeys(address);
            }
        }
    }

    // The classes not to ask about again this Hyprland session.
    SettingsFile {
        id: declined

        path: root.declinedPath
    }

    // The question, through notify-send --wait, tracked as every command the
    // shell runs is (shell/lib/launch.mjs), waiting for its stdout too.
    Component {
        id: asker

        Process {
            id: ask

            property var window
            property var tracker: null

            function handle(event) {
                if (tracker.on(event)) {
                    destroy();
                }
            }

            Component.onCompleted: tracker = Run.track(command, (ok, errors, output) => root.askAnswered(ask.window, ok ? Rules.askOutcome(true, 0, output) : "failed"), {
                warn: m => console.warn(m),
                log: m => console.log(m)
            }, true)
            command: Rules.askCommand(ask.window)
            stdout: StdioCollector {
                onStreamFinished: ask.handle({ type: "stdout", text: text })
            }
            stderr: StdioCollector {
                onStreamFinished: ask.handle({ type: "stderr", text: text })
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (exitCode, status) => handle({ type: "exited", code: exitCode })
        }
    }

    // `qs -c tide ipc call floating remember`, which conf binds to
    // Super+Alt+F: opens the Floating page with its fields filled for the
    // focused window. One that can't be named is a notification, since a
    // key has nowhere else to say so.
    IpcHandler {
        target: "floating"

        function remember(): string {
            const error = root.prefillFor(Rules.windowOf(Hyprland.activeToplevel));
            if (error !== "") {
                Launcher.run(Report.notifyCommand("No floating rule to fill in", error), ok => {
                    if (!ok) {
                        console.warn(`tide: couldn't say why there's no floating rule to fill in: ${error}`);
                    }
                });
                return error;
            }
            SettingsData.open("floating");
            return "";
        }
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/floating.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/floating.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // The rules the open windows were last floated for.
    SettingsFile {
        id: swept

        path: root.sweptPath
    }

    // What hyprland.lua reads. Written only when it would say something
    // else.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-floating.lua`
    }

    // Has hyprland.lua take what was written: `hyprctl eval` answers "ok",
    // or why not, on stdout.
    Component {
        id: applier

        Process {
            id: run

            property var state: Run.initial()
            property string reply: ""
            property bool replyRead: false
            property string errors: ""
            property bool errorsRead: false

            function streamed() {
                if (replyRead && errorsRead) {
                    handle({ type: "stderr", text: errors });
                }
            }

            function handle(event) {
                if (state.done) {
                    return;
                }
                state = Run.step(state, event, command);
                if (!state.done) {
                    return;
                }
                let error = "";
                if (!state.started) {
                    console.warn(state.report.message);
                    error = state.report.message.replace(/^tide: /, "");
                } else if (state.code !== 0 || reply.trim() !== "ok") {
                    // A conf from before floating rules has no
                    // conf_floating.
                    error = `couldn't apply the floating rules: ${(reply + state.errors).trim()}`;
                    console.warn(`tide: ${error}`);
                } else if (state.report?.level === "log") {
                    console.log(state.report.message);
                }
                const text = root.target.onDisk;
                root.stepped(Writes.targetApplied(root.target, error));
                if (error === "") {
                    root.rulesApplied(text);
                }
                destroy();
            }

            command: ["hyprctl", "eval", "conf_floating.reload()"]
            stdout: StdioCollector {
                onStreamFinished: {
                    run.reply = text;
                    run.replyRead = true;
                    run.streamed();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    run.errors = text;
                    run.errorsRead = true;
                    run.streamed();
                }
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (code, status) => handle({ type: "exited", code: code })
        }
    }

    Timer {
        id: retry

        interval: 30 * 1000
        onTriggered: root.load()
    }

    Timer {
        id: resend

        interval: 30 * 1000
        onTriggered: {
            const r = Report.retry(root.reports);
            root.reports = r.state;
            root.send(r.send);
        }
    }
}
