pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/launch.mjs" as Run
import "lib/sysmon.mjs" as Sysmon

// The system monitor's readings (SPEC.md §7.4), shared by every monitor's
// bar. The bar's CPU %, memory, temperature and throttle state come from a
// few small files read every few seconds; the processes, which mean reading
// every /proc/<pid>/stat, are sampled only while a popover is open.
Singleton {
    id: root

    // The system monitor popovers that are open, across monitors.
    property var open: []
    readonly property bool watching: open.length > 0

    // From `tide-sysmon probe`: sensors, page size, top frequency, and the
    // throttle counters' paths, one per CPU package (none without).
    property var probe: Sysmon.parseProbe("")
    // The CPU's sensors, one per package where the driver has one each.
    readonly property var sensors: Sysmon.pickCpuSensors(probe.sensors)
    // The most a probe has shown of this machine: probes go on while the
    // latest shows less (Sysmon.afterProbe).
    property var seen: Sysmon.NOTHING_SEEN

    property var lastStat: null
    property real cpu: NaN
    property var memory: null
    // Each sensor's last reading, by its input path, and the one shown:
    // the most severe against its own limits, then the hottest.
    property var temps: ({})
    readonly property var hottest: Sysmon.hottest(sensors.map(s => ({ milli: temps[s.input] ?? NaN, sensor: s })))
    readonly property real temp: hottest?.milli ?? NaN
    readonly property var sensor: hottest?.sensor ?? sensors[0] ?? null
    // Each package's throttle state, by its counter's path. The CPU is
    // throttling when any package is.
    property var throttleStates: ({})
    readonly property bool throttled: Sysmon.anyThrottling(throttleStates, probe.throttles, now)
    // Whether the popover's throttling line can say anything (Sysmon.throttleKnown).
    readonly property bool throttleKnown: Sysmon.throttleKnown(throttleStates, probe.throttles, now, seen.throttles)
    property real now: Date.now()

    // The popover's details, from `tide-sysmon sample`.
    property var sampleStat: null
    property var procs: null
    property var top: ({ cpu: [], memory: [] })
    property real freq: NaN

    readonly property var view: Sysmon.barView({
        cpu: root.cpu,
        temp: root.temp,
        sensor: root.sensor,
        throttled: root.throttled,
        memory: root.memory,
    })

    function tick() {
        root.now = Date.now();
        stat.reload();
        meminfo.reload();
        for (let i = 0; i < tempFiles.count; i++) {
            tempFiles.objectAt(i)?.reload();
        }
        for (let i = 0; i < throttleFiles.count; i++) {
            throttleFiles.objectAt(i)?.reload();
        }
        if (root.watching && !sampler.busy) {
            sampler.busy = true;
            root.run(["tide-sysmon", "sample"], (ok, text) => {
                sampler.busy = false;
                if (ok) {
                    root.sampled(text);
                } else {
                    // No stale lists shown as current, and the next good
                    // sample starts a fresh pair.
                    root.resetSample();
                }
            });
        }
    }

    function sampled(text) {
        const parts = Sysmon.splitSample(text);
        const nextStat = Sysmon.parseStat(parts.stat);
        const nextProcs = Sysmon.parseProcs(parts.procs);
        root.top = Sysmon.topProcesses({
            prevProcs: root.procs,
            procs: nextProcs,
            prevStat: root.sampleStat,
            stat: nextStat,
            pageSize: root.probe.pageSize,
        });
        root.sampleStat = nextStat;
        root.procs = nextProcs;
        root.freq = Sysmon.topFreq(parts.freq) ?? NaN;
    }

    function resetSample() {
        root.sampleStat = null;
        root.procs = null;
        root.top = { cpu: [], memory: [] };
        root.freq = NaN;
    }

    // A popover that just opened starts its lists over: CPU shows once a
    // second sample is in, rather than diffing against one minutes old.
    onWatchingChanged: {
        root.resetSample();
        if (watching) {
            root.tick();
        }
    }

    // A file read every tick says why it failed once per run of failures,
    // not every tick; its next good read (onLoaded) re-arms the warning.
    function unreadable(file, error) {
        if (!file.warned) {
            file.warned = true;
            console.warn(`tide: ${file.path}: ${FileViewError.toString(error)}`);
        }
    }

    function probeNow() {
        root.run(["tide-sysmon", "probe"], (ok, text) => {
            if (ok) {
                root.probe = Sysmon.parseProbe(text);
                // A sensor or counter that went away may come back later
                // than one retry, and a lesser sensor may stand in
                // meanwhile: keep probing until all of it is back.
                const next = Sysmon.afterProbe({ seen: root.seen, probe: root.probe, sensors: root.sensors });
                root.seen = next.seen;
                if (next.retry) {
                    reprobe.start();
                }
            } else {
                // Without the probe the bar still shows CPU % and memory;
                // the temperature and throttling wait for it.
                reprobe.start();
            }
        });
    }

    Component.onCompleted: probeNow()

    Timer {
        id: reprobe

        interval: 60 * 1000
        onTriggered: root.probeNow()
    }

    // Faster while a popover is open, so its lists keep up.
    Timer {
        interval: root.watching ? 2000 : 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.tick()
    }

    QtObject {
        id: sampler

        property bool busy: false
    }

    FileView {
        id: stat

        property bool warned: false

        // unreadable() says why once; FileView would say it every tick.
        printErrors: false

        path: "/proc/stat"
        onLoaded: {
            warned = false;
            const next = Sysmon.parseStat(text());
            root.cpu = Sysmon.cpuUsage(root.lastStat, next) ?? root.cpu;
            root.lastStat = next;
        }
        // A failed read shows no reading rather than the last one, and the
        // next good read starts a fresh pair.
        onLoadFailed: error => {
            root.cpu = NaN;
            root.lastStat = null;
            root.unreadable(stat, error);
        }
    }

    FileView {
        id: meminfo

        property bool warned: false

        // unreadable() says why once; FileView would say it every tick.
        printErrors: false

        path: "/proc/meminfo"
        onLoaded: {
            warned = false;
            root.memory = Sysmon.parseMeminfo(text());
        }
        onLoadFailed: error => {
            root.memory = null;
            root.unreadable(meminfo, error);
        }
    }

    // A reading kept only for a file a probe still finds: a sensor that
    // went away leaves no reading rather than its last one, while one
    // found again keeps its reading through the probe.
    onSensorsChanged: root.temps = Sysmon.pruned(root.temps, root.sensors.map(s => s.input))
    onProbeChanged: root.throttleStates = Sysmon.pruned(root.throttleStates, root.probe.throttles)

    function setTemp(path, milli) {
        root.temps = Object.assign({}, root.temps, {
            [path]: milli
        });
    }

    function setThrottle(path, state) {
        root.throttleStates = Object.assign({}, root.throttleStates, {
            [path]: state
        });
    }

    // One reader per sensor, so a second package's heat isn't missed.
    Instantiator {
        id: tempFiles

        model: root.sensors

        delegate: FileView {
            id: tempFile

            required property var modelData
            property bool warned: false

            // unreadable() says why once; FileView would say it every tick.
            printErrors: false

            path: modelData.input
            onLoaded: {
                warned = false;
                root.setTemp(path, Number(text().trim()));
            }
            // A sensor that went away (a driver reload, hwmon renumbering)
            // leaves no reading rather than the last one, and probes again,
            // since a recreated sensor can come back under another hwmonN.
            onLoadFailed: error => {
                root.setTemp(path, NaN);
                root.unreadable(tempFile, error);
                if (!reprobe.running) {
                    reprobe.start();
                }
            }
        }
    }

    // One reader per package's throttle counter.
    Instantiator {
        id: throttleFiles

        model: root.probe.throttles

        delegate: FileView {
            id: throttleFile

            required property var modelData
            property bool warned: false

            // unreadable() says why once; FileView would say it every tick.
            printErrors: false

            path: modelData
            onLoaded: {
                warned = false;
                root.setThrottle(path, Sysmon.throttleStep(root.throttleStates[path] ?? null, Number(text().trim()), Date.now()));
            }
            // An unreadable counter can't say the CPU is throttling. Probe
            // again: a counter that's gone drops out of the probe, and one
            // that's back is read again.
            onLoadFailed: error => {
                root.setThrottle(path, null);
                root.unreadable(throttleFile, error);
                if (!reprobe.running) {
                    reprobe.start();
                }
            }
        }
    }

    // Runs `command` and calls then(ok, stdout) once, when it's done; a
    // failed start or a nonzero exit is logged by shell/lib/launch.mjs.
    function run(command, then) {
        const process = runner.createObject(root, { command: command, then: then });
        process.running = true;
    }

    Component {
        id: runner

        Process {
            id: proc

            property var then: null
            property int code: -1
            property string out: ""
            property bool started: false
            property bool outDone: false
            property bool runDone: false
            property var tracker: null

            Component.onCompleted: tracker = Run.track(command, () => {
                proc.runDone = true;
                proc.finish();
            }, {
                warn: m => console.warn(m),
                log: m => console.log(m)
            })

            // Done once the run is and its output is all in, whichever comes
            // last; a command that never started has no output to wait for.
            function finish() {
                if (!runDone || (started && !outDone)) {
                    return;
                }
                const then = proc.then;
                const ok = code === 0;
                const text = out;
                proc.then = null;
                destroy();
                then?.(ok, text);
            }

            function handle(event) {
                tracker.on(event);
            }

            stdout: StdioCollector {
                onStreamFinished: {
                    proc.out = text;
                    proc.outDone = true;
                    proc.finish();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: proc.handle({ type: "stderr", text: text })
            }
            onStarted: {
                started = true;
                handle({ type: "started" });
            }
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (exitCode, status) => {
                proc.code = exitCode;
                handle({ type: "exited", code: exitCode });
            }
        }
    }
}
