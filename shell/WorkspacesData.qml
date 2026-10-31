pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/dispatch.mjs" as Dispatch
import "lib/launch.mjs" as Run
import "lib/mute.mjs" as Mute
import "lib/report.mjs" as Report
import "lib/workspacenames.mjs" as Names
import "lib/workspacepage.mjs" as Page
import "lib/workspaces.mjs" as Ws
import "lib/writes.mjs" as Writes

// The Workspaces settings (SPEC.md §6.5, §16), from workspaces.json and
// workspaces.local.json (§16.1): the standing workspaces, the first of them
// home, and the apps that live on home. What conf's Hyprland config needs
// of them, home's name and the classes its window rules send there, is
// written to ~/.config/hypr/tide-workspaces.lua, which hyprland.lua reads
// as it loads, and `hyprctl eval conf_workspaces.reload()` has it read
// again, as the shell starts too. A bad file is a notification naming it,
// once, and the last good settings stay; one that can't be written or
// applied is tried again until it is (shell/lib/writes.mjs).
//
// It also keeps home's name: a rename from elsewhere (`hyprctl`) is
// undone as it's heard.
Singleton {
    id: root

    // The settings in effect, defaults until the files are read.
    property var settings: Names.DEFAULT_SETTINGS
    readonly property var standing: root.settings.standing
    readonly property string home: Names.homeName(root.settings)
    // Home's workspace ID while it exists, else null (Ws.homeIdAfter).
    // It's kept from the list Hyprland gives too, since a shell started
    // after home was made never hears it made; a rename leaves it, so the
    // rename can be undone.
    property var homeId: null
    readonly property var listedHome: Hyprland.workspaces.values.find(w => w.name === root.home)?.id ?? null

    onListedHomeChanged: {
        if (root.listedHome !== null) {
            root.homeId = root.listedHome;
        }
    }

    property var reports: Report.NOTHING
    property var fileErrors: []
    // Bad entries in `muted`, each dropped alone (Names.checkMuted), and
    // why the last mute couldn't be saved, or "".
    property var warnings: []
    property string saveFailure: ""
    readonly property var muted: root.settings.muted ?? []
    property var target: Writes.TARGET
    // The classes each program in inApps may have, as `tide app-classes`
    // finds them, its launch's grant's: google-calendar's are its Chrome
    // `--app` window's (Names.inAppPatterns). Looked up once a shell.
    property var resolved: ({})
    // The programs being looked up now.
    property var resolving: []
    // The rules last asked for, as text, and what they were made from,
    // and what the rules Hyprland last took were made from: which windows
    // they cover (Names.uncoveredOpened).
    property var wantedRules: ({ text: null, rules: { inApps: [], resolved: {} } })
    property var appliedRules: ({ inApps: [], resolved: {} })
    // The windows that opened while the applied rules didn't cover them,
    // to send home once rules that do are applied (Names.homeSweep).
    property var uncovered: Names.NO_UNCOVERED

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    function stepped(r) {
        root.target = r.state;
        if (r.action?.write !== undefined) {
            const error = written.writeNow(r.action.write);
            root.stepped(Writes.targetWritten(root.target, error === "" ? "" : `${error}; home and its apps' rules stay as they were`));
            return;
        }
        if (r.action?.apply) {
            applier.createObject(root).running = true;
        }
        root.report();
    }

    function report() {
        const failures = [root.target.failure].filter(f => f !== "");
        const errors = root.fileErrors.concat(root.warnings, root.saveFailure !== "" ? [root.saveFailure] : [], failures);
        const v = Report.verdict(root.reports, errors);
        root.reports = v.state;
        root.send(v.send);
        if (failures.length > 0 && !retry.running) {
            retry.start();
        }
    }

    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Workspace settings not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    // Reads both settings files and the file hyprland.lua reads, writes
    // and applies the settings when they've changed, and looks up home's
    // programs' classes.
    function load() {
        root.read();
        // However read() ends, home's programs are looked up.
        root.resolve();
    }

    // Asks for the rules the settings and lookups make now.
    function wantRules() {
        const text = Names.workspacesLua(root.settings, root.resolved);
        root.wantedRules = { text: text, rules: { inApps: root.settings.inApps ?? [], resolved: root.resolved } };
        root.stepped(Writes.wantTarget(root.target, text));
    }

    // Hyprland took `text`: if it's the rules last asked for, they say
    // which windows are covered now, and the noted windows they cover go
    // home (Names.homeSweep).
    function rulesApplied(text) {
        if (text !== root.wantedRules.text) {
            return;
        }
        root.appliedRules = root.wantedRules.rules;
        const windows = Hyprland.toplevels.values.map(t => ({
            address: Ws.normalizeAddress(t.address),
            app: t.lastIpcObject?.class || t.wayland?.appId || "",
            workspace: t.workspace?.name ?? ""
        }));
        const r = Names.homeSweep(root.uncovered, windows, root.home, root.appliedRules);
        root.uncovered = r.list;
        for (const address of r.move) {
            console.log(`tide: sending window ${address}, one of home's apps that opened before its rule, to ${root.home}`);
            Hyprland.dispatch(Dispatch.sendWindowTo(address, root.home, Hyprland.usingLua));
        }
    }

    function read() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Names.loadWorkspaceSettings(sharedText, localText, root.settings);
        for (const error of result.errors.concat(result.warnings)) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        root.warnings = result.warnings;
        if (root.fileErrors.length > 0) {
            root.report();
            return;
        }
        if (Names.homeName(result.settings) !== root.home) {
            // Another home: the old one's ID no longer says where it is.
            root.homeId = null;
        }
        root.settings = result.settings;
        if (root.listedHome !== null) {
            root.homeId = root.listedHome;
        }
        const writtenText = written.readNow();
        if (written.broken !== "") {
            root.stepped(Writes.targetUnreadable(root.target, `${written.broken}; home and its apps' rules stay as they were`));
            return;
        }
        // Hyprland outlives the shell, and a shell that died with an apply
        // still to retry left it with the old home and rules, so the first
        // read applies what's wanted, as InputData does: reloading the same
        // rules again changes nothing.
        root.target = Writes.readTarget(root.target, writtenText, null).state;
        root.wantRules();
    }

    // Looks up the classes of each program in inApps not looked up yet;
    // each answer rewrites the rules (Names.workspacesLua).
    function resolve() {
        for (const p of Names.homeAppPrograms(root.settings.inApps ?? [])) {
            if (root.resolved[p.app] !== undefined || root.resolving.includes(p.app)) {
                continue;
            }
            root.resolving = root.resolving.concat([p.app]);
            resolver.createObject(root, { app: p.app, word: p.word }).running = true;
        }
    }

    // `app`'s lookup ended with `classes` (one per line on stdout). A
    // failed one is logged, and the program matches by its name alone.
    function resolvedApp(app, ok, classes, errors) {
        root.resolving = root.resolving.filter(a => a !== app);
        // The tracker has logged why; this says what it costs.
        if (!ok) {
            console.warn(`tide: couldn't find the window classes of ${app}, one of home's apps, so only a window named ${app} goes home`);
        }
        const next = Object.assign({}, root.resolved);
        next[app] = ok ? classes.split("\n").map(c => c.trim()).filter(c => c !== "") : [];
        root.resolved = next;
        root.wantRules();
    }

    // Mutes or unmutes one app or site (SPEC.md §9, Muted apps): if
    // `isMuted(list)` already, every entry that mutes it goes, else `entry`
    // is added (Mute.toggledMuted). It reads both files first, so it builds
    // on a hand edit made a moment ago, and writes workspaces.local.json
    // atomically (SettingsFile): the shell writes only the .local files
    // (§16.1). Returns why it didn't, or "".
    function toggleMuted(isMuted, entry) {
        root.load();
        if (root.fileErrors.length > 0) {
            return `${root.fileErrors[0]}; not changing muted`;
        }
        const localText = local.readNow();
        const next = Mute.toggledMuted(root.muted, isMuted, entry);
        const result = Names.withMuted(localText, next.list);
        if (result.error) {
            root.saveFailure = `${result.error}; not changing muted`;
        } else {
            const error = local.writeNow(result.text);
            root.saveFailure = error === "" ? "" : `${error}; muted not saved`;
        }
        root.load();
        root.report();
        return root.saveFailure;
    }

    // The Notifications page's muted list (SPEC.md §16): adds an entry as
    // typed, or takes one out, by its place and text (Mute.withMuteAdded,
    // Mute.withMuteRemoved). Each returns why it didn't, or "".
    function addMuted(entry) {
        return root.editMuted(list => Mute.withMuteAdded(list, entry));
    }

    function removeMuted(index, entry) {
        return root.editMuted(list => Mute.withMuteRemoved(list, index, entry));
    }

    // The Workspaces page (SPEC.md §16): adds, moves or takes out an entry
    // of list `key` (standing, inApps or namePatterns), in
    // workspaces.local.json, as Page.editedList makes it. Each returns why
    // it didn't, or "".
    function addItem(key, item) {
        return root.editList(key, list => Page.withItem(list, item));
    }

    function moveItem(key, index, item, step) {
        return root.editList(key, list => Page.movedItem(list, index, item, step));
    }

    function removeItem(key, index, item) {
        return root.editList(key, list => Page.withoutItem(list, index, item));
    }

    function editList(key, change) {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing ${key}`;
        }
        const result = Page.editedList(sharedText, localText, key, change);
        if (result.error) {
            return `${result.error}; not changing ${key}`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; ${key} not saved`;
        root.load();
        root.report();
        return root.saveFailure;
    }

    // Writes the muted list `change` makes of the one in effect to
    // workspaces.local.json, as toggleMuted does.
    function editMuted(change) {
        root.load();
        if (root.fileErrors.length > 0) {
            return `${root.fileErrors[0]}; not changing muted`;
        }
        const next = change(root.muted);
        if (next.error) {
            return `${next.error}; not changing muted`;
        }
        const result = Names.withMuted(local.readNow(), next.list);
        if (result.error) {
            root.saveFailure = `${result.error}; not changing muted`;
        } else {
            const error = local.writeNow(result.text);
            root.saveFailure = error === "" ? "" : `${error}; muted not saved`;
        }
        root.load();
        root.report();
        return root.saveFailure;
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            // openwindow is ADDRESS,WORKSPACE,CLASS,TITLE; a title may
            // hold commas, a class none.
            if (event.name === "openwindow" || event.name === "closewindow") {
                const fields = String(event.data).split(",");
                const address = Ws.normalizeAddress(fields[0]);
                if (address !== null) {
                    root.uncovered = event.name === "openwindow"
                        ? Names.uncoveredOpened(root.uncovered, address, fields[2] ?? "", root.appliedRules)
                        : Names.uncoveredClosed(root.uncovered, address);
                }
                return;
            }
            const ws = Ws.workspaceEvent(event.name, event.data);
            if (ws === null) {
                return;
            }
            if (Ws.homeRenamed(root.homeId, ws, root.home)) {
                console.log(`tide: workspace ${root.home} was renamed ${ws.name}; naming it ${root.home} again`);
                Hyprland.dispatch(Dispatch.renameWorkspace(ws.id, root.home, Hyprland.usingLua));
            }
            root.homeId = Ws.homeIdAfter(root.homeId, ws, root.home);
        }
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/workspaces.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/workspaces.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // What hyprland.lua reads. Written only when it would say something
    // else.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-workspaces.lua`
    }

    // `tide app-classes -- APP`, for one of home's programs, tracked as
    // every command the shell runs is (shell/lib/launch.mjs), waiting for
    // its stdout too.
    Component {
        id: resolver

        Process {
            id: look

            // The key the classes are kept under, and the program as
            // written, which is what's looked up.
            property string app
            property string word
            property var tracker: null

            function handle(event) {
                if (tracker.on(event)) {
                    destroy();
                }
            }

            Component.onCompleted: tracker = Run.track(command, (ok, errors, output) => root.resolvedApp(look.app, ok, output, errors), {
                warn: m => console.warn(m),
                log: m => console.log(m)
            }, true)
            command: ["tide", "app-classes", "--", look.word]
            stdout: StdioCollector {
                onStreamFinished: look.handle({ type: "stdout", text: text })
            }
            stderr: StdioCollector {
                onStreamFinished: look.handle({ type: "stderr", text: text })
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
                    // A conf from before named workspaces has no
                    // conf_workspaces.
                    error = `couldn't apply the workspace settings: ${(reply + state.errors).trim()}`;
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

            command: ["hyprctl", "eval", "conf_workspaces.reload()"]
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
