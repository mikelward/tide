pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import Quickshell.Io
import "lib/dispatch.mjs" as Dispatch
import "lib/keys.mjs" as Keys
import "lib/launch.mjs" as Run
import "lib/writes.mjs" as Writes

// The key bindings Hyprland has now, for the settings panel's keyboard
// shortcuts (SPEC.md §16), from `hyprctl binds -j` (shell/lib/keys.mjs),
// or on tidewm (§5.3) its config file's, from `tide-msg --type
// get_bindings`: listed as the shell starts, and again as the Keyboard
// page shows them, since a config reload can change them.
//
// On Hyprland, conf names most bindings and lists them in tide-keys.json,
// and those can be given other keys: yours are kept in keys.json and
// keys.local.json (§16.1), written to ~/.config/hypr/tide-keys.lua, which
// conf reads, and `hyprctl eval conf_keys.reload()` has it bind them, as
// the shell starts too. On tidewm, conf names them with `bindsym --name`,
// tidewm's GET_NAMED_BINDINGS lists them, and yours are written to
// ~/.config/tidewm/tide-keys.conf as `rebind` lines, which conf's tidewm
// config includes, and `tide-msg reload` applies. One that can't be written
// or applied is tried again until it is (shell/lib/writes.mjs).
Singleton {
    id: root

    // The bindings as last listed, as [{keys, does, submap}].
    property var binds: []
    // conf's named bindings as last listed, [] when there are none to change
    // (a conf or tidewm from before them).
    property var catalog: []
    // Whether tidewm has answered GET_NAMED_BINDINGS, so it takes the
    // rebind lines your keys are written as (Keys.keysWritable).
    property bool named: false
    // Why the last listing has none, or "".
    property string error: ""
    // The page's rows: {named, fixed} (Keys.shortcutRows).
    readonly property var rows: Keys.shortcutRows(root.catalog, root.binds, root.yours)
    readonly property bool editable: root.catalog.length > 0

    // Your keys in effect, {preset, keys} (Keys.loadKeys), and why they
    // aren't saved or applied, or "".
    property var yours: Keys.NO_KEYS
    property var fileErrors: []
    property string saveFailure: ""
    property var target: Writes.TARGET
    readonly property string failure: root.fileErrors.concat(root.saveFailure !== "" ? [root.saveFailure] : [], root.target.failure !== "" ? [root.target.failure] : []).join("; ")

    // The binding whose keys are being recorded, or "".
    property string recording: ""
    // Keys recorded that another binding has: {name, keys, clash: {name,
    // does}} for the page to ask about swapping, or null.
    property var pending: null

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`
    readonly property string catalogPath: Keys.catalogPath(Quickshell.env("XDG_RUNTIME_DIR") || "", Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")

    function list() {
        lister.createObject(root).running = true;
    }

    // conf's list, read after each listing and apply.
    function readCatalog() {
        if (Compositor.tidewm) {
            catalogLister.createObject(root).running = true;
            return;
        }
        if (root.catalogPath === "") {
            root.catalog = [];
            return;
        }
        const text = catalogFile.readNow();
        if (text === null) {
            // A conf from before named bindings writes none: the list
            // stays read-only.
            root.catalog = [];
            return;
        }
        const r = Keys.parseCatalog(text);
        if (r.error) {
            console.warn(`tide: ${r.error}`);
            root.catalog = [];
            return;
        }
        root.catalog = r.binds;
    }

    // Reads your files and the file hyprland.lua reads, and writes and
    // applies your keys. Run at the start, whenever a file changes on disk,
    // and after the page's changes.
    function load() {
        if (!Keys.keysWritable(Compositor.tidewm, root.named)) {
            // Loaded again once tidewm says it has named bindings.
            return;
        }
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Keys.loadKeys(sharedText, localText, root.yours);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        if (root.fileErrors.length > 0) {
            return;
        }
        root.yours = result.state;
        const writtenText = written.readNow();
        if (written.broken !== "") {
            root.stepped(Writes.targetUnreadable(root.target, `${written.broken}; the shortcuts stay as they were`));
            return;
        }
        // With no keys of yours and no file, there's nothing to write, and
        // a conf from before named bindings is left alone.
        if (root.yours.preset === "tide" && Object.keys(root.yours.keys).length === 0 && writtenText === null) {
            return;
        }
        // Hyprland outlives the shell, so the first read applies what's
        // wanted, as FloatingData does: the same keys again change nothing.
        // tidewm's reload starts every output and device over, so a shell
        // start leaves tidewm with what this session's record says it read
        // (AppliedRecord), as InputData does.
        if (!Compositor.tidewm) {
            root.target = Writes.readTarget(root.target, writtenText, null).state;
            root.stepped(Writes.wantTarget(root.target, Keys.keysLua(root.yours)));
            return;
        }
        root.target = Writes.readTarget(root.target, writtenText, root.target.known ? writtenText : applied.firstApplied(writtenText, root.target.failure)).state;
        const conf = Keys.keysConf(root.yours);
        for (const error of conf.errors) {
            console.warn(`tide: ${error}`);
        }
        root.stepped(Writes.wantTarget(root.target, conf.text));
    }

    function stepped(r) {
        root.target = r.state;
        if (r.action?.write !== undefined) {
            const error = written.writeNow(r.action.write);
            root.stepped(Writes.targetWritten(root.target, error === "" ? "" : `${error}; the shortcuts stay as they were`));
            return;
        }
        if (r.action?.apply) {
            applier.createObject(root).running = true;
        }
        if (root.target.failure !== "" && !retry.running) {
            retry.start();
        }
    }

    // Changes your keys as `change` says, in keys.local.json: the panel
    // writes only the .local files (§16.1), building on them as they are
    // now. Returns why it didn't, or "". Keys another shortcut has wait in
    // `pending` for the page's swap.
    function edit(change, pendingIfClash) {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing the shortcuts`;
        }
        const result = Keys.editedKeys(sharedText, localText, change);
        if (result.clash) {
            root.pending = Object.assign({ clash: result.clash }, pendingIfClash);
            return "";
        }
        root.pending = null;
        if (result.error) {
            return `${result.error}; not changing the shortcuts`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; the shortcuts not saved`;
        root.load();
        return root.saveFailure;
    }

    // Starts recording `name`'s keys: Hyprland's other bindings are off
    // until it stops, so the page sees the keys.
    function record(name) {
        root.pending = null;
        root.recording = name;
        root.recordingKeys(true);
        stopRecording.restart();
    }

    function stop() {
        if (root.recording === "") {
            return;
        }
        root.recording = "";
        stopRecording.stop();
        root.recordingKeys(false);
    }

    function recordingKeys(on) {
        if (Compositor.tidewm) {
            I3.dispatch(Dispatch.tidewmRecordingKeys(on));
        } else {
            Hyprland.dispatch(Dispatch.recordingKeys(on, Hyprland.usingLua));
        }
    }

    // A key pressed while recording: "" once it's taken or still waiting
    // for the key itself, else why not. Keys another binding has wait in
    // `pending` for the page's swap.
    function pressed(key, modifiers) {
        const name = root.recording;
        if (name === "") {
            return "";
        }
        const r = Keys.recordedKeys(key, modifiers);
        if (r.wait) {
            return "";
        }
        if (r.error) {
            return r.error;
        }
        root.stop();
        return root.give(name, r.keys, false);
    }

    function give(name, keys, swap) {
        const fixedIds = root.rows.fixed.filter(b => b.submap === "").map(b => b.keys);
        return root.edit(state => Keys.withKeys(state, root.catalog, name, keys, swap, fixedIds), { name: name, keys: keys });
    }

    function swap() {
        const p = root.pending;
        return p === null ? "" : root.give(p.name, p.keys, true);
    }

    function reset(name) {
        return root.edit(state => Keys.withDefault(state, name, root.catalog));
    }

    function off(name) {
        return root.edit(state => Keys.withOff(state, name));
    }

    // Starts again from `preset`'s keys (lib/keymaps.mjs), dropping yours.
    function startFrom(preset) {
        root.stop();
        return root.edit(state => Keys.withPreset(state, preset));
    }

    // Leaving the submap any other way (Esc, conf's) ends the recording.
    Connections {
        target: Compositor.tidewm ? null : Hyprland

        function onRawEvent(event) {
            if (event.name === "submap" && event.data !== "tide-keys" && root.recording !== "") {
                root.recording = "";
                stopRecording.stop();
            }
        }
    }

    // On tidewm, leaving the mode any other way ends it too.
    I3IpcListener {
        subscriptions: Compositor.tidewm ? ["mode"] : []

        onIpcEvent: event => {
            if (event.type === "mode" && event.data?.change !== "tide-keys" && root.recording !== "") {
                root.recording = "";
                stopRecording.stop();
            }
        }
    }

    // A recording left running gives the keys back.
    Timer {
        id: stopRecording

        interval: 15 * 1000
        onTriggered: root.stop()
    }

    Timer {
        id: retry

        interval: 30 * 1000
        onTriggered: root.load()
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/keys.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/keys.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // What hyprland.lua reads, or on tidewm what its config includes.
    // Written only when it would say something else.
    SettingsFile {
        id: written

        path: Compositor.tidewm ? `${root.configHome}/tidewm/tide-keys.conf` : `${root.configHome}/hypr/tide-keys.lua`
    }

    // This session's record of what tidewm last read.
    AppliedRecord {
        id: applied

        name: "tide-keys-tidewm-applied"
        unsure: "reloading tidewm to be sure it has your shortcuts"
        again: "tidewm may be reloaded again to be sure it has your shortcuts"
    }

    SettingsFile {
        id: catalogFile

        path: root.catalogPath
    }

    // Has hyprland.lua bind what was written: `hyprctl eval` answers "ok",
    // or why not, on stdout. On tidewm, `tide-msg reload` exits 0, or says
    // why not, as tidewm's errors in its config, on stderr. Then the list
    // is read again.
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
                } else if (state.code !== 0 || (!Compositor.tidewm && reply.trim() !== "ok")) {
                    // A conf from before named bindings has no conf_keys.
                    error = `couldn't apply the shortcuts: ${(reply + state.errors).trim()}`;
                    console.warn(`tide: ${error}`);
                } else if (state.report?.level === "log") {
                    console.log(state.report.message);
                }
                const done = Writes.targetApplied(root.target, error);
                if (Compositor.tidewm && error === "") {
                    applied.record(Writes.recordOf(done.state.applied));
                }
                root.stepped(done);
                root.list();
                destroy();
            }

            command: Compositor.tidewm ? ["tide-msg", "reload"] : ["hyprctl", "eval", "conf_keys.reload()"]
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

    // hyprctl binds -j, or tidewm's, read once both its streams end, as
    // InputData's device list is.
    Component {
        id: lister

        Process {
            id: listing

            property var state: Run.initial()
            property string out: ""
            property bool outRead: false
            property string errors: ""
            property bool errorsRead: false

            function streamed() {
                if (outRead && errorsRead) {
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
                if (state.report?.level === "warn") {
                    console.warn(state.report.message);
                } else if (state.report?.level === "log") {
                    console.log(state.report.message);
                }
                const failed = state.report?.level === "warn";
                const r = Compositor.tidewm ? Keys.listedTidewmBinds(failed, out) : Keys.listedBinds(failed, out);
                if (r.error !== "") {
                    console.warn(`tide: ${r.error}`);
                }
                root.binds = r.binds;
                root.error = r.error;
                root.readCatalog();
                destroy();
            }

            command: Compositor.tidewm ? ["tide-msg", "--type", "get_bindings"] : ["hyprctl", "binds", "-j"]
            stdout: StdioCollector {
                onStreamFinished: {
                    listing.out = text;
                    listing.outRead = true;
                    listing.streamed();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    listing.errors = text;
                    listing.errorsRead = true;
                    listing.streamed();
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
    // tidewm's named bindings, `tide-msg --type get_named_bindings`, read
    // as the list is.
    Component {
        id: catalogLister

        Process {
            id: catalogListing

            property var state: Run.initial()
            property string out: ""
            property bool outRead: false
            property string errors: ""
            property bool errorsRead: false

            function streamed() {
                if (outRead && errorsRead) {
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
                if (state.report?.level === "warn") {
                    console.warn(state.report.message);
                } else if (state.report?.level === "log") {
                    console.log(state.report.message);
                }
                // A tidewm from before named bindings lists none: the list
                // stays read-only.
                const r = Keys.listedTidewmCatalog(state.report?.level === "warn", out);
                if (r.error !== "") {
                    console.warn(`tide: ${r.error}`);
                }
                root.catalog = r.binds;
                // The first answer has your keys written, as Hyprland's
                // are as the shell starts.
                if (r.error === "" && !root.named) {
                    root.named = true;
                    root.load();
                }
                destroy();
            }

            command: ["tide-msg", "--type", "get_named_bindings"]
            stdout: StdioCollector {
                onStreamFinished: {
                    catalogListing.out = text;
                    catalogListing.outRead = true;
                    catalogListing.streamed();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    catalogListing.errors = text;
                    catalogListing.errorsRead = true;
                    catalogListing.streamed();
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
}
