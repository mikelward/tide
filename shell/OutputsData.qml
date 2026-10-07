pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/launch.mjs" as Run
import "lib/outputs.mjs" as Outputs
import "lib/report.mjs" as Report
import "lib/writes.mjs" as Writes

// The Displays settings (SPEC.md §16), from outputs.json and
// outputs.local.json (§16.1): each monitor's scale and place, by its
// description. What's set is written to ~/.config/hypr/tide-outputs.lua,
// which conf's hyprland.lua reads, and `hyprctl eval conf_outputs.reload()`
// has it applied with hl.monitor. A bad file is a notification naming it,
// once, and changes nothing. So is a change that can't be saved; one that
// can't be written or applied is tried again until it is
// (shell/lib/writes.mjs). The files are read and written as they're
// needed, synchronously, as IdleData's are.
Singleton {
    id: root

    // What's set, as the last good files say: nothing until they're read.
    property var outputs: ({})
    // What outputs.local.json alone sets, which Reset clears.
    property var localSettings: ({})
    // The monitors connected, as [{name, description, scale}], as last
    // listed.
    property var connected: []
    // The errors and which have been reported (shell/lib/report.mjs).
    property var reports: Report.NOTHING
    // The settings files' errors, as the last load found them.
    property var fileErrors: []
    // Why the panel's last change couldn't be saved, or "".
    property string saveFailure: ""
    // The file conf's hyprland.lua reads, written and applied
    // (shell/lib/writes.mjs).
    property var target: Writes.TARGET

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    // Sets one of a monitor's settings, by its description, or clears it
    // (`value` undefined), in outputs.local.json: the settings panel writes
    // only the .local files (§16.1). Returns why it didn't, or "": a bad
    // setting, a file that doesn't parse, which is left as it is so a hand
    // edit gone wrong isn't lost, or one that can't be saved.
    function set(description, key, value) {
        // The files as they are now, as IdleData.
        const sharedText = root.readNow(shared);
        const localText = root.readNow(local);
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing ${description}'s ${key}`;
        }
        const result = Outputs.withOutputSetting(localText, description, key, value, sharedText);
        if (result.error) {
            return `${result.error}; not changing ${description}'s ${key}`;
        }
        return root.save(result.text);
    }

    // Clears every setting outputs.local.json has for a monitor, as the
    // page's Reset does; outputs.json's, if any, still apply. As set.
    function reset(description) {
        const sharedText = root.readNow(shared);
        const localText = root.readNow(local);
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not resetting ${description}`;
        }
        const result = Outputs.withoutMonitor(localText, description, sharedText);
        if (result.error) {
            return `${result.error}; not resetting ${description}`;
        }
        return root.save(result.text);
    }

    function save(text) {
        const error = root.writeNow(local, text);
        root.saveFailure = error === "" ? "" : `${error}; display setting not saved`;
        root.load();
        return root.saveFailure;
    }

    // Lists the monitors again, for the page to name, disabled ones too (a
    // closed lid's panel). A list that fails is logged, and the page names
    // only the monitors that have settings.
    function listMonitors() {
        lister.createObject(root).running = true;
    }

    // As IdleData's.
    function readNow(file) {
        file.reload();
        const text = file.text();
        return file.loaded && file.broken === "" ? text : null;
    }

    // As IdleData's, read back since a failed atomic commit only logs.
    function writeNow(file, text) {
        file.failure = "";
        file.setText(text);
        if (file.failure !== "") {
            return file.failure;
        }
        if (root.readNow(file) !== text) {
            return file.broken !== "" ? file.broken : `${file.path}: the write didn't take`;
        }
        return "";
    }

    function stepped(r) {
        root.target = r.state;
        if (r.action?.write !== undefined) {
            const error = root.writeNow(written, r.action.write);
            root.stepped(Writes.targetWritten(root.target, error === "" ? "" : `${error}; the monitors keep their settings`));
            return;
        }
        if (r.action?.apply) {
            applier.createObject(root).running = true;
        }
        root.report();
    }

    // Every error there is now: the files', a change that couldn't be
    // saved, and one that hasn't reached the monitors. Each is a
    // notification once; one that hasn't reached them is tried again until
    // it does.
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
            Launcher.run(Report.notifyCommand("Display settings not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    // Reads both settings files and the file conf reads, and writes and
    // applies the settings when they've changed, as IdleData.load.
    function load() {
        const sharedText = root.readNow(shared);
        const localText = root.readNow(local);
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Outputs.loadOutputs(sharedText, localText, root.outputs);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        // Only settings every file agrees on reach the monitors.
        if (root.fileErrors.length > 0) {
            root.report();
            return;
        }
        root.outputs = result.settings;
        root.localSettings = Outputs.localOutputs(localText);
        const writtenText = root.readNow(written);
        if (written.broken !== "") {
            // Unreadable, it isn't written over either; it's read again on
            // the retry.
            root.stepped(Writes.targetUnreadable(root.target, `${written.broken}; the monitors keep their settings`));
            return;
        }
        // Hyprland outlives the shell, so a shell start applies the file
        // even unchanged: a shell restarted with an apply still to retry
        // would leave it undone. It costs nothing, since Hyprland (0.56's
        // CMonitorRuleManager::ensureMonitorStatus) leaves a monitor whose
        // rule hasn't changed alone.
        root.target = Writes.readTarget(root.target, writtenText, null).state;
        root.stepped(Writes.wantTarget(root.target, Outputs.outputsLua(root.outputs)));
    }

    component SettingsFile: FileView {
        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Why the last write failed, or "".
        property string failure: ""

        preload: false
        blockAllReads: true
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onLoaded: broken = ""
        onLoadFailed: error => {
            // A missing file is nothing set, not an error.
            broken = error === FileViewError.FileNotFound ? "" : `${path}: ${FileViewError.toString(error)}`;
            if (broken !== "") {
                console.warn(`tide: ${broken}`);
            }
        }
        onSaveFailed: error => failure = `${path}: ${FileViewError.toString(error)}`
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/outputs.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/outputs.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // What conf's hyprland.lua reads. Written only when it would say
    // something else.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-outputs.lua`
    }

    // Has conf's hyprland.lua apply what was written: `hyprctl eval` answers
    // "ok", or why not, on stdout, so its reply is read, not just its exit.
    Component {
        id: applier

        Process {
            id: run

            property var state: Run.initial()
            // Its reply is on stdout, which ends apart from stderr: the run
            // counts stderr as in only once both are.
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
                // Why the monitors don't have the settings, for the
                // notification, which needs no "tide: ".
                let error = "";
                if (!state.started) {
                    console.warn(state.report.message);
                    error = state.report.message.replace(/^tide: /, "");
                } else if (state.code !== 0 || reply.trim() !== "ok") {
                    // A conf without conf_outputs.reload, say.
                    error = `couldn't apply the display settings: ${(reply + state.errors).trim()}`;
                    console.warn(`tide: ${error}`);
                } else if (state.report?.level === "log") {
                    // It worked, but said something on the way, as MarkData's.
                    console.log(state.report.message);
                }
                root.stepped(Writes.targetApplied(root.target, error));
                // The scales Hyprland chose for the settings now, for the
                // page: one Reset hands back to Hyprland shows its own.
                if (error === "") {
                    root.listMonitors();
                }
                destroy();
            }

            command: ["hyprctl", "eval", "conf_outputs.reload()"]
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

    // Lists the monitors: hyprctl monitors all -j, read once both its
    // streams end, as the applier's are.
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
                const r = Outputs.listedMonitors(state.report?.level === "warn", out);
                if (r.error !== "") {
                    console.warn(`tide: ${r.error}`);
                }
                root.connected = r.monitors;
                destroy();
            }

            command: ["hyprctl", "monitors", "all", "-j"]
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

    // A change that couldn't be written or applied, tried again: load reads
    // every file afresh and carries on from there.
    Timer {
        id: retry

        interval: 30 * 1000
        onTriggered: root.load()
    }

    // An error counts as reported only once notify-send delivers it; one
    // that fails (at login, before the notification server is up) is sent
    // again, for as long as it lasts.
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
