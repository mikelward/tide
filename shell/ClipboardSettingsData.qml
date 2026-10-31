pragma Singleton

import QtQuick
import Quickshell
import "lib/clipboard.mjs" as Clip
import "lib/report.mjs" as Report

// The Clipboard page's settings (SPEC.md §8.4, §16), from clipboard.json
// and clipboard.local.json (§16.1): whether the history keeps new copies,
// and how many. They're written to ~/.config/hypr/tide-clipboard.conf,
// which `tide clipboard store` reads at each copy, so nothing restarts. A
// bad file is a notification naming it, once, and the last good settings
// stay; a file that can't be written is too, and tried again every 30 s.
Singleton {
    id: root

    property var settings: Clip.DEFAULTS
    property var reports: Report.NOTHING
    property var fileErrors: []
    // Why the page's last change couldn't be saved, or "".
    property string saveFailure: ""
    // Why tide clipboard store's file couldn't be written, or "".
    property string writeFailure: ""
    // Clear history: "" before it's asked, "clearing", "cleared", or why it
    // failed.
    property string clearing: ""

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    // Sets one setting in clipboard.local.json, as the page does. Returns
    // why it didn't, or "".
    function set(key, value) {
        const localText = local.readNow();
        if (local.broken !== "") {
            return `${local.broken}; not changing ${key}`;
        }
        const result = Clip.withSetting(localText, key, value);
        if (result.error) {
            return `${result.error}; not changing ${key}`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; ${key} not saved`;
        root.load();
        return root.saveFailure;
    }

    // Removes the whole history, as the launcher's Clear clipboard history
    // does. The page shows how it went.
    function clear() {
        root.clearing = "clearing";
        Launcher.run(["tide", "clipboard", "wipe"], (ok, errors) => {
            root.clearing = ok ? "cleared" : `Couldn't clear the history: ${errors.trim() || "tide clipboard wipe failed"}`;
        });
    }

    function load() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Clip.loadClipboardSettings(sharedText, localText, root.settings);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        if (root.fileErrors.length === 0) {
            root.settings = result.settings;
            root.write();
        }
        root.report();
    }

    // Writes tide clipboard store's file when it would say something else.
    function write() {
        const text = Clip.storeConf(root.settings);
        if (written.readNow() === text) {
            root.writeFailure = "";
            return;
        }
        const error = written.writeNow(text);
        root.writeFailure = error === "" ? "" : `${error}; the clipboard history keeps its last settings`;
        if (root.writeFailure !== "" && !retry.running) {
            retry.start();
        }
    }

    function report() {
        const errors = root.fileErrors.concat(root.saveFailure !== "" ? [root.saveFailure] : [], root.writeFailure !== "" ? [root.writeFailure] : []);
        const v = Report.verdict(root.reports, errors);
        root.reports = v.state;
        root.send(v.send);
    }

    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Clipboard settings not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/clipboard.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/clipboard.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // What tide clipboard store reads.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-clipboard.conf`
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
