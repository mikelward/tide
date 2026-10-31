pragma Singleton

import QtQuick
import Quickshell
import "lib/dnd.mjs" as Dnd
import "lib/report.mjs" as Report

// The Notifications page's settings (SPEC.md §9, §16), from
// notifications.json and notifications.local.json (§16.1): Do not disturb
// on a schedule, and whether critical alerts break through it. The
// schedule turns your own Do not disturb on as a window starts and off as
// it ends, if it turned it on, checked every 30 s; a bad file is a
// notification naming it, once, and the last good settings stay.
Singleton {
    id: root

    property var settings: Dnd.DEFAULTS
    property var reports: Report.NOTHING
    property var fileErrors: []
    // Why the page's last change couldn't be saved, or "".
    property string saveFailure: ""

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    // Sets one setting in notifications.local.json, as the page does.
    // Returns why it didn't, or "".
    function set(key, value) {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing ${key}`;
        }
        const result = Dnd.withSetting(sharedText, localText, key, value);
        if (result.error) {
            return `${result.error}; not changing ${key}`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; ${key} not saved`;
        root.load();
        return root.saveFailure;
    }

    // Turns a day of the schedule on or off, in the days the files have now
    // (Dnd.withDayToggled), so a hand edit made a moment ago is built on.
    function toggleDay(day) {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing dndDays`;
        }
        const result = Dnd.withDayToggled(sharedText, localText, day);
        if (result.error) {
            return `${result.error}; not changing dndDays`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; dndDays not saved`;
        root.load();
        return root.saveFailure;
    }

    function load() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Dnd.loadNotificationSettings(sharedText, localText, root.settings);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        if (root.fileErrors.length === 0) {
            root.settings = result.settings;
        }
        root.report();
        root.check();
        // A popup up now that the criticals setting now holds goes.
        NotificationData.holdForDnd();
    }

    // Whether the schedule's window has started or ended since the last
    // check, and if so, what it does to your own Do not disturb.
    function check() {
        const r = Dnd.scheduleStep(scheduleState.state, Dnd.windowStart(root.settings, new Date()), NotificationData.ownDnd);
        scheduleState.state = r.state;
        if (r.set !== null) {
            NotificationData.setScheduledDnd(r.set);
        }
    }

    // Your own Do not disturb was set, from `was` to `now`: if that turned
    // it on or off, the schedule leaves it.
    function ownChanged(was, now) {
        scheduleState.state = Dnd.ownChanged(scheduleState.state, was, now);
    }

    function report() {
        const errors = root.fileErrors.concat(root.saveFailure !== "" ? [root.saveFailure] : []);
        const v = Report.verdict(root.reports, errors);
        root.reports = v.state;
        root.send(v.send);
    }

    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Notification settings not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    // Kept across config reloads, as Do not disturb itself is, so a reload
    // in a window doesn't turn back on one you turned off.
    PersistentProperties {
        id: scheduleState

        reloadableId: "tide-dnd-schedule"

        property var state: Dnd.SCHEDULE_IDLE
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/notifications.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/notifications.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    Timer {
        interval: 30 * 1000
        running: true
        repeat: true
        onTriggered: root.check()
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
