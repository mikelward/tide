pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/power.mjs" as Power
import "lib/report.mjs" as Report

// The Power page's lid action (SPEC.md §16), from power.json and
// power.local.json (§16.1). It's written to ~/.config/hypr/tide-power.lua,
// which conf's hyprland.lua reads as the lid closes, and Lock and Do nothing
// hold logind's lid switch through tide-lid-inhibit.service, so logind
// doesn't suspend first. Both are put right as the shell starts, too: the
// unit outlives a shell that died with it the other way. A bad file, or a
// file or unit that can't be put right, is a notification once, and the
// last two are tried again every 30 s.
Singleton {
    id: root

    property var settings: Power.DEFAULTS
    property var reports: Report.NOTHING
    property var fileErrors: []
    property string saveFailure: ""
    // Why tide-power.lua couldn't be written, or the unit started or
    // stopped, or "".
    property string applyFailure: ""
    // Whether power-profiles-daemon is there, as last listed (null before).
    property var profilesDaemon: null

    // On tidewm and tidesway, a monitor coming on while the lid is shut
    // turns the laptop's panel off, as Hyprland's config does itself (`tide
    // lid-docked`, SPEC.md §16): their lid binding hears a lid shut at login
    // before any other monitor is on, and a shut laptop can be docked. As
    // the shell starts, and as the monitors change.
    readonly property int screenCount: Quickshell.screens.length
    onScreenCountChanged: root.lidDocked()

    function lidDocked() {
        if (!Compositor.tidewm) {
            return;
        }
        Launcher.run(["tide", "lid-docked"], (ok, errors) => {
            if (!ok) {
                console.warn(`tide: couldn't turn the laptop's panel off with the lid shut: ${errors.trim() || "tide lid-docked failed"}`);
            }
        });
    }

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    function set(key, value) {
        const localText = local.readNow();
        if (local.broken !== "") {
            return `${local.broken}; not changing ${key}`;
        }
        const result = Power.withSetting(localText, key, value);
        if (result.error) {
            return `${result.error}; not changing ${key}`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; ${key} not saved`;
        root.load();
        return root.saveFailure;
    }

    function load() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Power.loadPowerSettings(sharedText, localText, root.settings);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        if (root.fileErrors.length === 0) {
            root.settings = result.settings;
            root.apply();
        }
        root.report();
    }

    // Writes tide-power.lua when it would say something else, then has the
    // unit hold or let go of the lid as the settings say.
    function apply() {
        const text = Power.powerLua(root.settings);
        if (written.readNow() !== text) {
            const error = written.writeNow(text);
            if (error !== "") {
                root.failed(`${error}; closing the lid does what it did before`);
                return;
            }
        }
        const command = Power.inhibitCommand(root.settings);
        Launcher.run(command, (ok, errors) => {
            root.failed(ok ? "" : `couldn't ${command[2]} ${Power.INHIBIT_UNIT}: ${errors.trim() || "systemctl failed"}`);
        });
    }

    function failed(why) {
        root.applyFailure = why;
        if (why !== "" && !retry.running) {
            retry.start();
        }
        root.report();
    }

    // Lists the system bus's names, for whether power-profiles-daemon is
    // there, as the page shows.
    function listProfiles() {
        lister.running = true;
    }

    function report() {
        const errors = root.fileErrors.concat(root.saveFailure !== "" ? [root.saveFailure] : [], root.applyFailure !== "" ? [root.applyFailure] : []);
        const v = Report.verdict(root.reports, errors);
        root.reports = v.state;
        root.send(v.send);
    }

    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Power settings not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    Process {
        id: lister

        command: Power.PROFILES_COMMAND
        stdout: StdioCollector {
            onStreamFinished: root.profilesDaemon = Power.hasProfilesDaemon(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "") {
                    console.warn(`tide: busctl couldn't list the system bus: ${text.trim()}`);
                }
            }
        }
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/power.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/power.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // What conf's hyprland.lua reads as the lid closes.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-power.lua`
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
