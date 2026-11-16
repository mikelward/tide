import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "lib/power.mjs" as Power

// The power profile on AC power and on battery (SPEC.md §16), from
// power.json and power.local.json: as the shell starts, as the power
// source changes, and as either file does, power-profiles-daemon is asked
// for the profile they name, which it keeps for the whole machine. "Leave
// it" asks for nothing, so a profile chosen by hand stays until the next
// change. It reads the files itself, so it runs on Plasma too (kde.qml),
// where the rest of the Power page's settings don't apply.
Scope {
    id: root

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    property var settings: Power.DEFAULTS
    // Whether Quickshell has read power-profiles-daemon's profile yet. Until
    // then it reports Balanced and no Performance (its powerprofiles.hpp), so
    // the first change it reports is that read, and the settings are applied
    // again on it; later changes are someone choosing, and are left.
    property bool discovered: false

    function textOf(file) {
        // A missing file is the defaults' cue, not an error.
        return file.loaded ? file.text() : null;
    }

    function load() {
        if (!shared.settled || !local.settled) {
            return;
        }
        if (shared.broken !== "" || local.broken !== "") {
            // One that can't be read leaves the profile as it is.
            return;
        }
        const result = Power.loadPowerSettings(root.textOf(shared), root.textOf(local), root.settings);
        for (const error of result.errors) {
            console.warn(`tide: ${error}; the power profile follows the last good settings`);
        }
        root.settings = result.settings;
        root.apply();
    }

    function apply() {
        const wanted = Power.profileFor(root.settings, UPower.onBattery, PowerProfiles.hasPerformanceProfile);
        if (wanted === null || PowerProfiles.profile === wanted) {
            return;
        }
        console.info(`tide: ${UPower.onBattery ? "on battery" : "on AC power"}, so the power profile is now ${Power.PROFILE_CHOICES[wanted + 1].label.toLowerCase()}`);
        PowerProfiles.profile = wanted;
    }

    Connections {
        target: root.discovered ? null : PowerProfiles

        function onProfileChanged() {
            root.discovered = true;
            root.apply();
        }

        function onHasPerformanceProfileChanged() {
            root.discovered = true;
            root.apply();
        }
    }

    // A read that changes nothing reports nothing, so stop waiting for one
    // after a while: the placeholders were right.
    Timer {
        running: !root.discovered
        interval: 10 * 1000
        onTriggered: root.discovered = true
    }

    Connections {
        target: UPower

        function onOnBatteryChanged() {
            root.apply();
        }
    }

    FileView {
        id: shared

        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Whether its first load has finished, either way.
        property bool settled: false

        path: `${root.configHome}/tide/power.json`
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
            if (broken !== "") {
                console.warn(`tide: ${broken}; the power profile is left as it is`);
            }
            root.load();
        }
    }

    FileView {
        id: local

        property string broken: ""
        property bool settled: false

        path: `${root.configHome}/tide/power.local.json`
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
            if (broken !== "") {
                console.warn(`tide: ${broken}; the power profile is left as it is`);
            }
            root.load();
        }
    }
}
