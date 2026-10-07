pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/appearance.mjs" as Appearance
import "lib/launch.mjs" as Run
import "lib/report.mjs" as Report
import "lib/writes.mjs" as Writes

// Light or dark (SPEC.md §15). The shell owns the schedule: it reads
// appearance.json and appearance.local.json (§16.1), works out which it is
// each minute, and when that changes tells apps through gsettings and the
// shell's own palette (Theme) in place. The launcher's flip
// (`flip`) lasts until the schedule's next change. The settings panel's
// Appearance page (§16) changes the settings through `set`, in
// appearance.local.json, read and written synchronously as IdleData's
// files. The inactive dim's strength reaches Hyprland as LayoutsData's
// settings do: written to ~/.config/hypr/tide-appearance.lua, which conf's
// hyprland.lua reads, and applied with `hyprctl eval
// conf_appearance.reload()`, tried again until it is (shell/lib/writes.mjs).
Singleton {
    id: root

    // The settings in effect: the last good ones.
    property var settings: Appearance.DEFAULTS
    property bool loaded: false
    readonly property var now: Appearance.themeAt(root.settings, clock.minute, flipped.override)
    readonly property bool dark: root.now.dark
    // When the next change is due as "HH:MM", or "" when the mode is fixed.
    readonly property string until: root.now.next === null ? "" : Appearance.clockTime(root.now.next)
    // The last scheme apps were told, or null before the first time.
    property var told: null
    property var reports: Report.NOTHING
    // Why the panel's last change couldn't be saved, or "".
    property string saveFailure: ""
    // The settings files' errors, as the last load found them.
    property var fileErrors: []
    // The inactive dim's strength in effect, for the page.
    readonly property real dimStrength: Appearance.dimStrength(root.settings)
    // The file hyprland.lua reads, written and applied (shell/lib/writes.mjs).
    property var target: Writes.TARGET

    // A config reload keeps a flip, so reloading the shell doesn't undo it.
    PersistentProperties {
        id: flipped

        reloadableId: "tide-appearance"

        property var override: null
    }

    function flip() {
        flipped.override = Appearance.flip(root.settings, Date.now(), flipped.override);
    }

    // A flip that has run out is dropped, so it can't come back if the
    // settings return to what it was made under.
    onNowChanged: {
        if (flipped.override !== null && root.now.override === null) {
            flipped.override = null;
        }
    }

    onDarkChanged: root.tell()
    onLoadedChanged: root.tell()

    // Tells apps (Appearance.schemeCommands), once the settings are read so
    // a login doesn't flash the defaults' scheme first, then runs the
    // user's hook (Appearance.hookCommand). The commands run one after
    // another, so the hook reads the scheme as set, and one run at a time
    // (Appearance.tellNext), so an older run can't finish last. A failure
    // is logged by Launcher, the rest still run, and it's tried again at
    // the next change.
    property var telling: Appearance.TELL_IDLE

    function tell() {
        if (!root.loaded || root.told === root.dark) {
            return;
        }
        root.told = root.dark;
        root.tellStep("change");
    }

    function tellStep(event) {
        const r = Appearance.tellNext(root.telling, event);
        root.telling = r.state;
        if (r.start) {
            root.runInOrder(Appearance.schemeCommands(root.dark).concat([Appearance.hookCommand(root.dir)]));
        }
    }

    function runInOrder(commands) {
        if (commands.length === 0) {
            root.tellStep("done");
            return;
        }
        Launcher.run(commands[0], () => root.runInOrder(commands.slice(1)));
    }

    // Anything else that sets the color scheme is put back at once, so apps
    // can't disagree with the shell until its next change. The shell's own writes come back
    // here too, and match.
    function heard(line) {
        const dark = Appearance.schemeIsDark(line);
        if (dark !== null && root.told !== null && dark !== root.dark) {
            console.log(`tide: color-scheme was set to ${dark ? "dark" : "light"} elsewhere; setting it back`);
            root.told = null;
            root.tell();
        }
    }

    Process {
        command: ["gsettings", "monitor", "org.gnome.desktop.interface", "color-scheme"]
        running: true
        stdout: SplitParser {
            onRead: data => root.heard(data)
        }
        onExited: (code, status) => {
            console.warn(`tide: gsettings monitor exited ${code}; a color scheme set elsewhere stays until the shell's next change`);
        }
    }

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    function textOf(file) {
        // A missing file is the defaults' cue, not an error.
        return file.loaded && file.broken === "" ? file.text() : null;
    }

    function load() {
        // Both files' first loads are in before anything is decided, so the
        // shared settings can't show before the local ones replace them.
        if (!shared.settled || !local.settled) {
            return;
        }
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Appearance.loadAppearance(shared.broken ? null : textOf(shared), local.broken ? null : textOf(local), root.settings);
        const errors = broken.concat(result.errors);
        for (const error of errors) {
            console.warn(`tide: ${error}`);
        }
        // A file that can't be read keeps the last good settings, rather
        // than being taken for missing.
        if (broken.length === 0) {
            root.settings = result.settings;
        }
        root.loaded = true;
        root.fileErrors = errors;
        // Only settings every file agrees on reach Hyprland.
        if (errors.length === 0) {
            root.writeDim();
        }
        root.report();
    }

    // Writes what Hyprland is to have and applies it, when it's changed.
    function writeDim() {
        const writtenText = root.readNow(written);
        if (written.broken !== "") {
            // Unreadable, it isn't written over either; it's read again on
            // the retry.
            root.stepped(Writes.targetUnreadable(root.target, `${written.broken}; the dim keeps its strength`));
            return;
        }
        // Applied as the shell starts even unchanged, as InputData's: a shell
        // that died with an apply still to retry would otherwise leave it
        // unapplied, and setting the same strength again changes nothing.
        root.target = Writes.readTarget(root.target, writtenText, null).state;
        root.stepped(Writes.wantTarget(root.target, Appearance.appearanceLua(root.settings)));
    }

    function stepped(r) {
        root.target = r.state;
        if (r.action?.write !== undefined) {
            const error = root.writeNow(written, r.action.write);
            root.stepped(Writes.targetWritten(root.target, error === "" ? "" : `${error}; the dim keeps its strength`));
            return;
        }
        if (r.action?.apply) {
            applier.createObject(root).running = true;
        }
        root.report();
    }

    // Every error there is now: the files', a change that couldn't be
    // saved, and a dim that hasn't reached Hyprland. Each is a
    // notification once; the dim is tried again until it does.
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

    // Sets one setting, in appearance.local.json: the settings panel writes
    // only the .local files (§16.1). The files as they are now, not as they
    // last loaded, so a hand edit made a moment ago is built on, and one
    // that doesn't parse is left as it is. Returns why it didn't, or "".
    function set(key, value) {
        const sharedText = root.readNow(sharedNow);
        const localText = root.readNow(localNow);
        const broken = [sharedNow.broken, localNow.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing ${key}`;
        }
        const result = Appearance.withSetting(localText, key, value, sharedText);
        if (result.error) {
            return `${result.error}; not changing ${key}`;
        }
        const error = root.writeNow(localNow, result.text);
        root.saveFailure = error === "" ? "" : `${error}; appearance setting not saved`;
        if (error !== "") {
            console.warn(`tide: ${root.saveFailure}`);
        }
        // The shell's reader, now rather than when its watch fires: its load
        // reports a save failure, or that it's gone.
        local.reload();
        return root.saveFailure;
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

    // A bad file is a notification naming it and the line (SPEC.md §16.1),
    // once; one that fails to send (at login, before the notification
    // server is up) is sent again by `resend`.
    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Theme not updated", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    FileView {
        id: shared

        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Whether its first load has finished, either way.
        property bool settled: false

        path: `${root.dir}/appearance.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            broken = "";
            settled = true;
            root.load();
        }
        onLoadFailed: error => {
            settled = true;
            broken = error === FileViewError.FileNotFound ? "" : `${path}: ${FileViewError.toString(error)}`;
            root.load();
        }
    }

    FileView {
        id: local

        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Whether its first load has finished, either way.
        property bool settled: false

        path: `${root.dir}/appearance.local.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            broken = "";
            settled = true;
            root.load();
        }
        onLoadFailed: error => {
            settled = true;
            broken = error === FileViewError.FileNotFound ? "" : `${path}: ${FileViewError.toString(error)}`;
            root.load();
        }
    }

    // The files again, for the Appearance page's changes, as IdleData's:
    // read and written as they're needed, synchronously, so a change builds
    // on the file as it is.
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
        id: sharedNow

        path: shared.path
    }

    SettingsFile {
        id: localNow

        path: local.path
    }

    // What hyprland.lua reads. Written only when it would say something
    // else.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-appearance.lua`
    }

    // Has hyprland.lua take what was written, as LayoutsData's applier:
    // `hyprctl eval` answers "ok", or why not, on stdout.
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
                    // A hyprland.lua from before conf_appearance, say.
                    error = `couldn't apply the dim strength: ${(reply + state.errors).trim()}`;
                    console.warn(`tide: ${error}`);
                } else if (state.report?.level === "log") {
                    console.log(state.report.message);
                }
                root.stepped(Writes.targetApplied(root.target, error));
                destroy();
            }

            command: ["hyprctl", "eval", "conf_appearance.reload()"]
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

    // A dim that couldn't be written or applied, tried again: load reads
    // the settings afresh and carries on from there.
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

    // Each minute, and at once after a suspend: the schedule is read
    // against the wall clock, so a change missed while asleep shows on
    // waking.
    SystemClock {
        id: clock

        readonly property real minute: date.getTime()

        precision: SystemClock.Minutes
    }
}
