pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/idle.mjs" as Idle
import "lib/report.mjs" as Report
import "lib/writes.mjs" as Writes

// The idle timeline's timings (SPEC.md §10, §16), from idle.json and
// idle.local.json (§16.1). They're written to ~/.config/hypr/tide-idle.conf,
// which conf's hypridle.conf sources, and hypridle restarts to read them:
// it reads its config only as it starts. A bad file is a notification
// naming it, once, and changes nothing. So is a change that can't be saved;
// one that can't be written or applied is tried again until it is
// (shell/lib/writes.mjs).
//
// The files are read and written as they're needed, synchronously
// (SettingsFile.qml): they're under 1 KB, and it means what the shell
// reads is the file, with no read or write in flight for a change to race.
Singleton {
    id: root

    // The timings in effect: the defaults until the files are read, then
    // the last good ones.
    property var idle: Idle.DEFAULT_IDLE
    // The errors and which have been reported (shell/lib/report.mjs).
    property var reports: Report.NOTHING
    // The settings files' errors, as the last load found them.
    property var fileErrors: []
    // Why the panel's last change couldn't be saved, or "".
    property string saveFailure: ""
    // Why tide idle-suspend's file couldn't be written, or "".
    property string suspendFailure: ""
    // hypridle's timings file, written and applied (shell/lib/writes.mjs).
    property var target: Writes.TARGET

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`
    // Where the record of what hypridle was last given lives: this
    // session's, so a new login starts without one.
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""

    // Sets one step's seconds, or a switch's true or false, in
    // idle.local.json: the settings panel writes only the .local files
    // (§16.1). Returns why it didn't, or "": an unknown setting, a bad
    // value, a local file that doesn't parse, which is left as it is so a
    // hand edit gone wrong isn't lost, or one that can't be saved.
    function set(key, value) {
        // The file as it is now, not as it last loaded, so a hand edit made
        // a moment ago is built on, not written over.
        const text = local.readNow();
        if (local.broken !== "") {
            return `${local.broken}; not changing ${key}`;
        }
        const result = Idle.withSetting(text, key, value);
        if (result.error) {
            return `${result.error}; not changing ${key}`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; idle setting not saved`;
        root.load();
        return root.saveFailure;
    }

    function stepped(r) {
        root.target = r.state;
        if (r.action?.write !== undefined) {
            const error = written.writeNow(r.action.write);
            root.stepped(Writes.targetWritten(root.target, error === "" ? "" : `${error}; hypridle keeps its timings`));
            return;
        }
        if (r.action?.apply) {
            // try-restart: only a hypridle that's running, which in the
            // tide session is its unit's (§5.3).
            Launcher.run(["systemctl", "--user", "try-restart", "hypridle.service"], (ok, errors) => {
                const applied = Writes.targetApplied(root.target, ok ? "" : `couldn't restart hypridle: ${errors.trim() || "systemctl failed"}`);
                if (ok) {
                    root.record(Writes.recordOf(applied.state.applied));
                }
                root.stepped(applied);
            });
        }
        root.report();
    }

    // Every error there is now: the files', a change that couldn't be
    // saved, and one that hasn't reached hypridle. Each is a notification
    // once; one that hasn't reached hypridle is tried again until it does.
    function report() {
        const failures = [root.target.failure, root.suspendFailure].filter(f => f !== "");
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
            Launcher.run(Report.notifyCommand("Idle settings not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    // Reads both settings files and hypridle's timings file, and writes and
    // applies the timings when they've changed. Run at the start, whenever
    // a settings file changes on disk, after the panel's changes, and on a
    // retry.
    function load() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Idle.loadIdle(sharedText, localText, root.idle);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        // Only timings every file agrees on reach hypridle: a typo isn't
        // the cue to put the defaults back over yesterday's settings.
        if (root.fileErrors.length > 0) {
            root.report();
            return;
        }
        root.idle = result.idle;
        root.writeSuspend();
        const writtenText = written.readNow();
        if (written.broken !== "") {
            // Unreadable, it isn't written over either; it's read again on
            // the retry.
            root.stepped(Writes.targetUnreadable(root.target, `${written.broken}; hypridle keeps its timings`));
            return;
        }
        root.target = Writes.readTarget(root.target, writtenText, root.target.known ? writtenText : root.firstApplied(writtenText)).state;
        root.stepped(Writes.wantTarget(root.target, Idle.hypridleConf(root.idle)));
    }

    // What hypridle has as this shell first reads its file: what the
    // session's record of the last restart says, else the file, which
    // hypridle read as it started, recorded now. A record that can't be
    // read or written says nothing, so hypridle is restarted to be sure:
    // a shell after this one would otherwise take the file for what it
    // has. Nor does a file that couldn't be read until now, which hypridle
    // couldn't either (Writes.readTarget).
    function firstApplied(writtenText) {
        if (root.target.failure !== "") {
            return null;
        }
        if (root.runtimeDir === "") {
            return writtenText;
        }
        const text = recorded.readNow();
        if (recorded.broken !== "") {
            console.warn(`tide: ${recorded.broken}; restarting hypridle to be sure it has its timings`);
            return null;
        }
        const first = Writes.firstApplied(writtenText, text);
        return Writes.afterRecord(first, first.record === null || root.record(first.record));
    }

    // Records what hypridle has now, returning whether it could. One that
    // can't be written is logged: after a restart, it only costs another
    // if this shell dies with an apply still to retry.
    function record(text) {
        if (root.runtimeDir === "") {
            return true;
        }
        const error = recorded.writeNow(text);
        if (error !== "") {
            console.warn(`tide: ${error}; hypridle may be restarted again to be sure it has its timings`);
            return false;
        }
        return true;
    }

    // Writes tide idle-suspend's file when it would say something else,
    // with no restart: hypridle doesn't read it. One that can't be written
    // is reported, and tried again with the rest.
    function writeSuspend() {
        const text = Idle.suspendConf(root.idle);
        if (suspended.readNow() === text) {
            root.suspendFailure = "";
            return;
        }
        const error = suspended.writeNow(text);
        root.suspendFailure = error === "" ? "" : `${error}; idle-suspend keeps its last Suspend on AC`;
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/idle.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/idle.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // What hypridle sources. Written only when it would say something
    // else, so a shell start with nothing changed leaves hypridle alone.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-idle.conf`
    }

    // This session's record of what hypridle was last given (firstApplied).
    SettingsFile {
        id: recorded

        path: root.runtimeDir === "" ? "" : `${root.runtimeDir}/tide-idle-applied`
    }

    // What tide idle-suspend reads, apart from hypridle's file
    // (Idle.suspendConf).
    SettingsFile {
        id: suspended

        path: `${root.configHome}/hypr/tide-idle-suspend.conf`
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
