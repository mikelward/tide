pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/clocks.mjs" as Clocks
import "lib/launch.mjs" as Run
import "lib/report.mjs" as Report
import "lib/tzdata.mjs" as Tz

// The bar's clocks (SPEC.md §7.3). It reads clocks.json and
// clocks.local.json (§16.1) and runs tide-tz for their zones' offsets
// and abbreviations: at startup, when either file changes, and when a
// period ends. A minute's tick only redraws from what it already has.
// The settings panel's Clocks page (§16) changes the list through it, in
// clocks.local.json, read and written synchronously (SettingsFile.qml).
Singleton {
    id: root

    // What the bar shows, from shell/lib/clocks.mjs's barClocks.
    property var items: []

    // The last list whose zones all loaded.
    property var good: Clocks.DEFAULT_CLOCKS
    // The list the Clocks page shows and changes, as the files last parsed:
    // a zone tide-tz can't load is in it, so it can be taken out.
    property var listed: Clocks.DEFAULT_CLOCKS
    // 24-hour time and hiding the local zone's clock, as the last good
    // files say, and the Clocks page's rows for them.
    property var switches: Clocks.DEFAULT_SWITCHES
    readonly property var switchRows: Clocks.SWITCH_ROWS
    // Why the panel's last change couldn't be saved, or "".
    property string saveFailure: ""
    // Why the last change to the system's time zone failed, or "", for the
    // Clocks page; and whether one is under way.
    property string systemZoneFailure: ""
    property bool settingSystemZone: false
    property var table: null
    // The files' errors and which have been reported (shell/lib/report.mjs),
    // so each distinct error is a notification at most once per run of the
    // shell. Each verdict on the files is their complete set of current
    // errors: every file that can't be read and every parse error, else
    // once they parse their zones' errors (none when all load).
    property var reports: Report.NOTHING
    // Counts lookups, so a result from one a later lookup has superseded
    // (tide-tz is still running when the files change again, or one
    // becomes unreadable) is dropped rather than taken for the current
    // list's. Each lookup carries its own list and file.
    property int generation: 0
    // The running lookup, stopped when another starts.
    property var lookup: null
    // The instant `items` was drawn for, so the popover ticks with the bar.
    property real now: Date.now()
    // While scrolling over the clocks, the instant they show instead of
    // now (SPEC.md §7.3); 0 when they show now.
    property real scrubAt: 0

    function scrub(notches) {
        root.scrubAt = Clocks.scrubbed(root.scrubAt || Date.now(), notches);
        root.update();
    }

    function unscrub() {
        if (root.scrubAt !== 0) {
            root.scrubAt = 0;
            root.update();
        }
    }

    readonly property string dir: (Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`) + "/tide"

    function textOf(file) {
        // A missing file is the defaults' cue, not an error.
        return file.loaded ? file.text() : null;
    }

    // A file that exists but can't be read: say so, and keep the last good
    // list rather than taking it for missing.
    function unreadable(file, error) {
        file.broken = `${file.path}: ${FileViewError.toString(error)}`;
        console.warn(`tide: ${file.broken}`);
        root.load();
    }

    // A bad file is a notification naming it and the line (SPEC.md
    // §16.1), once; the log has it every time. So is a change the panel
    // couldn't save, for as long as it's the last one.
    function reportErrors(errors) {
        const v = Report.verdict(root.reports, errors.concat(root.saveFailure !== "" ? [root.saveFailure] : []));
        root.reports = v.state;
        root.send(v.send);
    }

    // An error counts as reported only once notify-send delivers it; one
    // that fails (at login, before the notification server is up) is sent
    // again by `resend`, for as long as it lasts.
    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Clocks not updated", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    function load() {
        // FileView loads in the background, so at startup one file can be
        // in before the other: wait for both, or the shared list could be
        // looked up (and its zones reported) before the local one replaces
        // it.
        if (!shared.settled || !local.settled) {
            return;
        }
        // A file that can't be read is left out of the parse, but the other
        // one is still checked, so the report always holds every current
        // error, whichever file is broken.
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Clocks.loadClocks(shared.broken ? null : textOf(shared), local.broken ? null : textOf(local), root.good, undefined, root.switches);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        const errors = broken.concat(result.errors);
        if (broken.length === 0) {
            const editable = Clocks.editableClocks(textOf(shared), textOf(local));
            // Only when it differs: a new list remakes the page's rows, and
            // with them a label being typed.
            if (!editable.error && JSON.stringify(editable.clocks) !== JSON.stringify(root.listed)) {
                root.listed = editable.clocks;
            }
        }
        if (broken.length > 0) {
            // A lookup still running is of contents this verdict replaces.
            root.supersede();
            root.reportErrors(errors);
            // With nothing shown yet, the defaults beat an empty bar.
            if (!root.table) {
                root.lookUp(root.good, "");
            }
            return;
        }
        // The files' verdict now, even when it's none: an error the edit
        // fixed stops being retried at once, rather than when tide-tz
        // answers (which it may never do). With no files, the defaults are
        // tide's, not a setting to fix: their zones failing is logged and
        // retried, never reported. With files that parse, their zones'
        // errors replace this verdict once tide-tz has read them.
        root.reportErrors(errors);
        // A switch alone changes nothing tide-tz would read, so it shows at
        // once; with a new list, it waits for the lookup that takes it.
        const plan = Clocks.loadPlan(result.clocks, root.good, root.table !== null && errors.length === 0, root.lookup ? root.lookup.clocks : null);
        const source = errors.length === 0 && result.source !== null ? result.source : "";
        if (plan.lookUp) {
            root.lookUp(result.clocks, source, result.switches);
            return;
        }
        // The running lookup takes the list's file as it is now too, so a
        // zone it refuses is reported against the file that has it.
        if (plan.pending) {
            root.lookup.source = source;
            root.lookup.switches = result.switches;
        }
        if (plan.now && JSON.stringify(result.switches) !== JSON.stringify(root.switches)) {
            root.switches = result.switches;
            root.update();
        }
    }

    // Moves, takes out, relabels or adds a clock, as the Clocks page does.
    // `index` is the entry the page showed it at, from 0, so a hand edit
    // that has moved the clocks since is refused rather than built on; IPC
    // gives none, for the first clock in the zone. Each returns why it
    // didn't, or "".
    function move(index, zone, step) {
        return root.edit(clocks => Clocks.movedClock(clocks, index, zone, step));
    }

    function remove(index, zone) {
        return root.edit(clocks => Clocks.withoutClock(clocks, index, zone));
    }

    function relabel(index, zone, label) {
        return root.edit(clocks => Clocks.relabeledClock(clocks, index, zone, label));
    }

    function add(zone) {
        return root.edit(clocks => Clocks.withClock(clocks, zone));
    }

    // Changes the list as `change` says, in clocks.local.json: the settings
    // panel writes only the .local files (§16.1). The files as they are
    // now, not as they last loaded, so a hand edit made a moment ago is
    // built on, and one that doesn't parse is left as it is.
    function edit(change) {
        const sharedText = sharedNow.readNow();
        const localText = localNow.readNow();
        // Either file unreadable keeps the bar on its last good list, as
        // one that doesn't parse does.
        const broken = [sharedNow.broken, localNow.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing the clocks`;
        }
        const result = Clocks.editedClocks(sharedText, localText, change);
        if (result.error) {
            return `${result.error}; not changing the clocks`;
        }
        const error = localNow.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; clocks not saved`;
        if (error === "") {
            // The page at once, not when the bar's reader has it.
            root.listed = result.clocks;
        } else {
            console.warn(`tide: ${root.saveFailure}`);
        }
        // The bar's reader, now rather than when its watch fires: its load
        // reports a save failure, or that it's gone.
        local.reload();
        return root.saveFailure;
    }

    // Turns switch `key` (hour24 or dedupeLocal) on or off, in
    // clocks.local.json, as the Clocks page does. Returns why it didn't,
    // or "", as edit.
    function setSwitch(key, on) {
        const sharedText = sharedNow.readNow();
        const localText = localNow.readNow();
        const broken = [sharedNow.broken, localNow.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing ${key}`;
        }
        const result = Clocks.withClockSwitch(sharedText, localText, key, on);
        if (result.error) {
            return `${result.error}; not changing ${key}`;
        }
        const error = localNow.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; clocks not saved`;
        if (error !== "") {
            console.warn(`tide: ${root.saveFailure}`);
        }
        local.reload();
        return root.saveFailure;
    }

    // Sets the system's time zone, as the Clocks page does (SPEC.md §16).
    // timedatectl asks systemd-timedated, which asks polkit, so it may ask
    // for a password. Returns why it didn't start, or "": how it went comes
    // later, in systemZoneFailure. Once it's set, the clocks are looked up
    // again, since tide-tz reads the local zone as it starts.
    function setSystemZone(zone) {
        if (root.settingSystemZone) {
            return "the time zone is still being set";
        }
        const error = Clocks.systemZoneError(zone);
        if (error) {
            return `${error}; not changing the time zone`;
        }
        root.systemZoneFailure = "";
        root.settingSystemZone = true;
        Launcher.run(Clocks.systemZoneCommand(zone), (ok, errors) => {
            root.settingSystemZone = false;
            if (!ok) {
                root.systemZoneFailure = `couldn't set the time zone to ${zone}: ${errors.trim() || "timedatectl failed"}`;
                console.warn(`tide: ${root.systemZoneFailure}`);
                return;
            }
            // Again, the list a lookup still running has, else the good one.
            const pending = root.lookup;
            if (pending) {
                root.lookUp(pending.clocks, pending.source, pending.switches);
            } else {
                root.lookUp(root.good, "");
            }
        });
        return "";
    }

    // Drops whatever lookup is running: its result won't count.
    function supersede() {
        root.generation++;
        if (root.lookup) {
            root.lookup.running = false;
            root.lookup = null;
        }
    }

    // Looks up `clocks`' zones. `source` names the file they came from, when
    // their zones' errors are the files' to report; "" otherwise. The bar
    // takes `switches` with the list, when its zones load; null keeps its own.
    function lookUp(clocks, source, switches = null) {
        root.supersede();
        root.lookup = tz.createObject(root, {
            generation: root.generation,
            clocks: clocks,
            source: source,
            switches: switches,
            // After "--", so a zone that looks like a flag is reported as
            // a bad zone rather than taken for one.
            command: ["tide-tz", "--"].concat(clocks.map(c => c.zone))
        });
        root.lookup.running = true;
    }

    function looked(lookup, text) {
        if (lookup.generation !== root.generation) {
            return; // superseded
        }
        let table;
        try {
            table = Tz.zoneTable(JSON.parse(text));
        } catch (e) {
            console.warn(`tide: tide-tz: ${e}`);
            root.retry();
            return;
        }
        if (table.localError) {
            // Local's clock may show twice (SPEC.md §7.3), but the bar works.
            console.warn(`tide: clocks: local zone: ${table.localError}`);
        }
        for (const e of table.errors) {
            console.warn(`tide: clocks: ${e.error}`);
        }
        if (lookup.source !== "") {
            root.reportErrors(table.errors.map(e => Clocks.zoneError(lookup.clocks, lookup.source, e.zone, e.error)));
        }
        if (table.errors.length > 0 && lookup.clocks !== root.good) {
            // A zone that doesn't load is an error at load: keep the last
            // good list (SPEC.md §7.3).
            root.lookUp(root.good, "");
            return;
        }
        if (table.errors.length > 0 && root.table) {
            // The good list stopped loading, say while tzdata is being
            // upgraded.
            root.retry();
            return;
        }
        root.good = lookup.clocks;
        if (lookup.switches !== null) {
            root.switches = lookup.switches;
        }
        root.table = table;
        root.update();
        refresh.interval = Math.max(1000, Tz.refreshAt(table, Date.now()) - Date.now());
        refresh.restart();
    }

    // Any failed run keeps the last table and tries again shortly, so a
    // missed refresh can't leave a stale offset up until the next restart.
    function retry() {
        refresh.interval = 60 * 1000;
        refresh.restart();
    }

    function update() {
        if (!root.table) {
            return;
        }
        const table = root.table;
        root.now = Date.now();
        root.items = Clocks.barClocks({
            // Skip any zone that didn't load, so one bad entry in an
            // otherwise unchanged list can't blank the clocks.
            clocks: root.good.filter(c => table.periods.has(c.zone)),
            localZone: table.localZone,
            instant: root.scrubAt || root.now,
            offsetOf: Tz.offsetOf(table),
            abbrOf: Tz.abbrOf(table),
            hour24: root.switches.hour24,
            dedupeLocal: root.switches.dedupeLocal,
        });
    }

    FileView {
        id: shared

        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Whether its first load has finished, either way.
        property bool settled: false

        path: `${root.dir}/clocks.json`
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
            if (error === FileViewError.FileNotFound) {
                broken = "";
                root.load();
            } else {
                root.unreadable(this, error);
            }
        }
    }

    FileView {
        id: local

        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Whether its first load has finished, either way.
        property bool settled: false

        path: `${root.dir}/clocks.local.json`
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
            if (error === FileViewError.FileNotFound) {
                broken = "";
                root.load();
            } else {
                root.unreadable(this, error);
            }
        }
    }

    // The files again, for the Clocks page's changes: read and written as
    // they're needed, synchronously (SettingsFile.qml), so a change builds on
    // the file as it is.
    SettingsFile {
        id: sharedNow

        path: shared.path
    }

    SettingsFile {
        id: localNow

        path: local.path
    }

    // One tide-tz run per lookup, carrying what it was asked, so its result
    // is matched to its own list rather than whatever is current by then.
    Component {
        id: tz

        Process {
            id: run

            property int generation: 0
            property var clocks: []
            property string source: ""
            // The switches that came with the list, taken with it, or null
            // to keep the bar's.
            property var switches: null
            property bool current: generation === root.generation
            // Through shell/lib/launch.mjs only to catch a failed start
            // (tide-tz not on PATH): Quickshell 0.3 then sends no exit
            // code and no output, so `looked` and onExited never run.
            property var runState: Run.initial()
            property bool stopped: false
            property bool read: false

            function handle(event) {
                if (runState.done) {
                    return;
                }
                runState = Run.step(runState, event, command);
                if (runState.done && !runState.started && current) {
                    console.warn(`${runState.report.message}; is it on PATH?`);
                    root.retry();
                }
            }

            // Gone once it has stopped and its output is in (or it never
            // started, and there is none).
            function settle() {
                if (stopped && (read || !runState.started)) {
                    if (root.lookup === run) {
                        root.lookup = null;
                    }
                    destroy();
                }
            }

            stdout: StdioCollector {
                onStreamFinished: {
                    root.looked(run, text);
                    run.read = true;
                    run.settle();
                }
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                    stopped = true;
                    settle();
                }
            }
            onExited: (code, status) => {
                if (code !== 0 && current) {
                    console.warn(`tide: tide-tz exited ${code}`);
                    root.retry();
                }
            }
        }
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

    // At the next change of offset in any zone, and at least daily.
    Timer {
        id: refresh

        onTriggered: root.lookUp(root.good, "")
    }

    SystemClock {
        precision: SystemClock.Minutes
        onDateChanged: root.update()
    }
}
