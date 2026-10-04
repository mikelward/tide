// Tests for sysmon.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    parseStat, cpuUsage, parseMeminfo, parseProcStat, parseProcs, topProcesses, pickCpuSensor, pickCpuSensors, hottest, parseProbe,
    formatTemp, tempLevel, throttleStep, throttling, topFreq, formatFreq, formatPercent, formatBytes, formatUsage, barView, splitSample, trackOpen, afterProbe, pruned, anyThrottling, throttleKnown, sensorRank, NOTHING_SEEN,
    THROTTLE_HOLD_MS, TOP,
} from "./sysmon.mjs";

const STAT_A = "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 50 0 50 350 50 0 0 0 0 0\ncpu1 50 0 50 350 50 0 0 0 0 0\nintr 1\n";
const STAT_B = "cpu  250 0 150 900 100 0 0 0 0 0\ncpu0 1 0 0 0 0 0 0 0 0 0\ncpu1 1 0 0 0 0 0 0 0 0 0\n";

// A /proc/<pid>/stat line with the fields this reads set.
function procLine(pid, name, ticks, rss, start = 1000) {
    const rest = Array(22).fill("0");
    rest[0] = "S";
    rest[11] = String(ticks);
    rest[19] = String(start);
    rest[21] = String(rss);
    return `${pid} (${name}) ${rest.join(" ")}`;
}

test("/proc/stat gives busy and total jiffies and the CPU count", () => {
    assert.deepEqual(parseStat(STAT_A), { busy: 200, total: 1000, count: 2 });
    assert.equal(parseStat("intr 1\n"), null);
    assert.equal(parseStat("cpu x y z w\n"), null);
});

test("CPU usage is busy time over all time between samples", () => {
    assert.equal(cpuUsage(parseStat(STAT_A), parseStat(STAT_B)), 0.5);
    assert.equal(cpuUsage(null, parseStat(STAT_B)), null);
    assert.equal(cpuUsage(parseStat(STAT_A), parseStat(STAT_A)), null);
});

test("memory used is what isn't available", () => {
    const m = parseMeminfo("MemTotal:       16000 kB\nMemFree:  1000 kB\nMemAvailable:    4000 kB\n");
    assert.deepEqual(m, { used: 12000 * 1024, total: 16000 * 1024, swapUsed: 0, swapTotal: 0 });
    const swap = parseMeminfo("MemTotal: 16 kB\nMemAvailable: 4 kB\nSwapTotal: 8 kB\nSwapFree: 6 kB\n");
    assert.equal(swap.swapUsed, 2048);
    assert.equal(swap.swapTotal, 8192);
    assert.equal(parseMeminfo("MemTotal: 16000 kB\n"), null);
    assert.equal(parseMeminfo(""), null);
});

test("a process name may hold spaces and parentheses", () => {
    const p = parseProcStat(procLine(42, "Web Content (x)", 30, 100));
    assert.deepEqual(p, { pid: 42, name: "Web Content (x)", start: 1000, ticks: 30, rss: 100 });
    assert.equal(parseProcStat("garbage"), null);
    assert.equal(parseProcStat("42 (short) S 1"), null);
});

test("a reused pid is a different process", () => {
    const procs = parseProcs([procLine(7, "a", 1, 1, 100), procLine(7, "b", 1, 1, 200), "junk"].join("\n"));
    assert.equal(procs.size, 2);
});

test("the top lists rank CPU per CPU, as top does, and memory by RSS", () => {
    const prevProcs = parseProcs([procLine(1, "idle", 10, 10), procLine(2, "busy", 0, 50), procLine(3, "half", 0, 300)].join("\n"));
    const procs = parseProcs([procLine(1, "idle", 10, 10), procLine(2, "busy", 250, 50), procLine(3, "half", 125, 300),
        procLine(4, "new", 25, 0)].join("\n"));
    // 500 jiffies over 2 CPUs: 250 a CPU.
    const top = topProcesses({ prevProcs, procs, prevStat: { busy: 0, total: 0, count: 2 },
        stat: { busy: 0, total: 500, count: 2 }, pageSize: 4096 });
    // "new" is in only this sample, so it waits for the next one.
    assert.deepEqual(top.cpu.map((p) => [p.name, p.cpu]), [["busy", 1], ["half", 0.5]]);
    assert.deepEqual(top.memory.map((p) => [p.name, p.memory]), [["half", 300 * 4096], ["busy", 50 * 4096], ["idle", 10 * 4096]]);
});

test("a process missed by one sample doesn't count its lifetime as this interval", () => {
    // pid 5 has run for hours; the last sample failed to read it.
    const prevProcs = parseProcs(procLine(2, "busy", 0, 50));
    const procs = parseProcs([procLine(2, "busy", 50, 50), procLine(5, "old", 360000, 10)].join("\n"));
    const top = topProcesses({ prevProcs, procs, prevStat: { total: 0, count: 1 }, stat: { total: 100, count: 1 }, pageSize: 1 });
    assert.deepEqual(top.cpu.map((p) => p.name), ["busy"]);
    // Its memory is a reading, not a difference, so it shows at once.
    assert.ok(top.memory.some((p) => p.name === "old"));
});

test("the top lists hold at most TOP each, and CPU needs two samples", () => {
    const lines = Array.from({ length: 9 }, (_, i) => procLine(i + 1, `p${i}`, i + 1, i + 1));
    const procs = parseProcs(lines.join("\n"));
    const prevProcs = parseProcs(lines.map((_, i) => procLine(i + 1, `p${i}`, 0, i + 1)).join("\n"));
    const both = topProcesses({ prevProcs, procs, prevStat: { total: 0, count: 1 }, stat: { total: 100, count: 1 }, pageSize: 1 });
    assert.equal(both.cpu.length, TOP);
    assert.equal(both.memory.length, TOP);
    assert.equal(both.cpu[0].name, "p8");
    const first = topProcesses({ prevProcs: null, procs, prevStat: null, stat: { total: 100, count: 1 }, pageSize: 1 });
    assert.deepEqual(first.cpu, []);
    assert.equal(first.memory.length, TOP);
});

test("the CPU sensor prefers a package reading from a CPU driver", () => {
    const s = (chip, label) => ({ input: `/x/${chip}/${label}`, chip, label, max: null, crit: null });
    assert.equal(pickCpuSensor([s("acpitz", ""), s("coretemp", "Core 0"), s("coretemp", "Package id 0")]).label, "Package id 0");
    assert.equal(pickCpuSensor([s("coretemp", "Core 3")]).label, "Core 3");
    assert.equal(pickCpuSensor([s("k10temp", "Tccd1"), s("k10temp", "Tctl")]).label, "Tctl");
    assert.equal(pickCpuSensor([s("thinkpad", "GPU"), s("acpitz", "")]).chip, "acpitz");
    assert.equal(pickCpuSensor([s("nvme", "Composite"), s("amdgpu", "edge")]), null);
    assert.equal(pickCpuSensor([]), null);
});

test("a CPU driver gives one sensor per package", () => {
    const s = (dev, chip, label) => ({ input: `/sys/class/hwmon/${dev}/temp1_input`, chip, label, max: null, crit: null });
    // Two coretemp packages, each its own hwmon device with cores beside it.
    const two = pickCpuSensors([
        s("hwmon2", "coretemp", "Core 0"), s("hwmon2", "coretemp", "Package id 0"),
        s("hwmon3", "coretemp", "Core 0"), s("hwmon3", "coretemp", "Package id 1"),
        s("hwmon4", "acpitz", ""),
    ]);
    assert.deepEqual(two.map((x) => x.label), ["Package id 0", "Package id 1"]);
    // Two k10temp sockets, each its own Tctl.
    assert.deepEqual(pickCpuSensors([s("hwmon0", "k10temp", "Tctl"), s("hwmon1", "k10temp", "Tctl")]).map((x) => x.input),
        ["/sys/class/hwmon/hwmon0/temp1_input", "/sys/class/hwmon/hwmon1/temp1_input"]);
    // A package without its package reading falls back to its first sensor.
    assert.deepEqual(pickCpuSensors([s("hwmon2", "coretemp", "Package id 0"), s("hwmon3", "coretemp", "Core 4")]).map((x) => x.label),
        ["Package id 0", "Core 4"]);
    // Chips that aren't per package give one, whatever their count: an
    // ACPI zone may not be the CPU's.
    assert.equal(pickCpuSensors([s("hwmon0", "acpitz", ""), s("hwmon1", "acpitz", "")]).length, 1);
    assert.deepEqual(pickCpuSensors([s("hwmon0", "nvme", "Composite")]), []);
});

test("of several packages, the most severe reading shows", () => {
    const limits = (max, crit) => ({ input: "/x", chip: "coretemp", label: "Package id 0", max, crit });
    const cool = limits(80000, 90000);
    const plain = limits(null, null);
    // The hotter of two with the same limits.
    assert.equal(hottest([{ milli: 50000, sensor: plain }, { milli: 60000, sensor: plain }]).milli, 60000);
    // A cooler reading past its own lower limit beats a hotter one below
    // the default.
    assert.equal(hottest([{ milli: 84000, sensor: plain }, { milli: 82000, sensor: cool }]).sensor, cool);
    // A package without a reading yet doesn't hide the others.
    assert.equal(hottest([{ milli: NaN, sensor: plain }, { milli: 55000, sensor: plain }]).milli, 55000);
    assert.equal(hottest([{ milli: NaN, sensor: plain }]), null);
    assert.equal(hottest([]), null);
});

test("the probe lists sensors and settings", () => {
    const p = parseProbe("page\t16384\nmaxfreq\t4700000\nthrottle\t/sys/t\nthrottle\t/sys/u\nthrottle\t\ntemp\t/h/temp1_input\tcoretemp\tPackage id 0\t100000\t\n"
        + "temp\t\tbroken\n");
    assert.equal(p.pageSize, 16384);
    assert.equal(p.maxFreq, 4700000);
    assert.deepEqual(p.throttles, ["/sys/t", "/sys/u"]);
    assert.deepEqual(p.sensors, [{ input: "/h/temp1_input", chip: "coretemp", label: "Package id 0", max: 100000, crit: null }]);
    assert.equal(p.complete, true);
    assert.deepEqual(parseProbe(""), { sensors: [], pageSize: null, maxFreq: null, throttles: [], complete: true });
    assert.equal(parseProbe("page\t4096\nincomplete\n").complete, false);
});

test("temperatures are hot and critical by the sensor's limits, or the defaults", () => {
    assert.equal(formatTemp(61600), "62 °C");
    assert.equal(formatTemp(NaN), "");
    assert.equal(tempLevel(60000, null), "ok");
    assert.equal(tempLevel(85000, null), "hot");
    assert.equal(tempLevel(95000, null), "critical");
    assert.equal(tempLevel(75000, { max: 70000, crit: 90000 }), "hot");
    assert.equal(tempLevel(90000, { max: 70000, crit: 90000 }), "critical");
    // A sensor whose crit is below the default hot point.
    assert.equal(tempLevel(81000, { max: null, crit: 80000 }), "critical");
    assert.equal(tempLevel(NaN, null), "ok");
});

test("throttling shows from a rise in the counter, for a while", () => {
    let st = throttleStep(null, 5, 0);
    assert.equal(throttling(st, 0), false);
    st = throttleStep(st, 5, 1000);
    assert.equal(throttling(st, 1000), false);
    st = throttleStep(st, 9, 2000);
    assert.equal(throttling(st, 2000), true);
    st = throttleStep(st, 9, 3000);
    assert.equal(throttling(st, 2000 + THROTTLE_HOLD_MS - 1), true);
    assert.equal(throttling(st, 2000 + THROTTLE_HOLD_MS), false);
    // A counter that went back down is a new baseline, not a throttle.
    st = throttleStep({ count: 9, since: null }, 1, 0);
    assert.equal(throttling(st, 0), false);
    assert.deepEqual(throttleStep(null, NaN, 0), { count: null, since: null });
    // A wall clock set back after a rise ends the hold, not extends it.
    assert.equal(throttling({ count: 9, since: 3_600_000 }, 1000), false);
});

test("the frequency is the fastest CPU's", () => {
    assert.equal(topFreq("800000\n3100000\n1200000\n"), 3100000);
    assert.equal(topFreq(""), null);
    assert.equal(formatFreq(3100000, 4700000), "3.1 / 4.7 GHz");
    assert.equal(formatFreq(3100000, null), "3.1 GHz");
    assert.equal(formatFreq(null, 4700000), "");
});

test("percentages and sizes read short", () => {
    assert.equal(formatPercent(0.123), "12%");
    assert.equal(formatPercent(1.5), "150%");
    assert.equal(formatPercent(null), "–");
    assert.equal(formatBytes(512 * 1048576), "512 MB");
    assert.equal(formatBytes(1.44 * 1073741824), "1.4 GB");
    assert.equal(formatBytes(31.2 * 1073741824), "31 GB");
    assert.equal(formatBytes(-1), "");
    assert.equal(formatUsage(512 * 1048576, 2 * 1073741824), "512 MB / 2.0 GB");
    assert.equal(formatUsage(1, 0), "");
});

test("the bar's reading turns amber when hot or memory is nearly full, red when throttling", () => {
    const mem = { used: 1, total: 10 };
    assert.deepEqual(barView({ cpu: 0.23, temp: 50000, sensor: null, throttled: false, memory: mem }), { text: "23%", tone: "normal" });
    assert.equal(barView({ cpu: 0.2, temp: 88000, sensor: null, throttled: false, memory: mem }).tone, "warn");
    assert.equal(barView({ cpu: 0.2, temp: null, sensor: null, throttled: false, memory: { used: 9, total: 10 } }).tone, "warn");
    assert.equal(barView({ cpu: 0.2, temp: 50000, sensor: null, throttled: true, memory: mem }).tone, "danger");
    assert.equal(barView({ cpu: 0.2, temp: 99000, sensor: null, throttled: false, memory: mem }).tone, "danger");
    assert.equal(barView({ cpu: null, temp: null, sensor: null, throttled: false, memory: null }).text, "–");
});

test("a sample splits into its sections", () => {
    const s = splitSample("@stat\ncpu 1 2 3 4\n@freq\n800000\n@procs\n1 (init) S\n2 (x) S\n");
    assert.equal(s.stat, "cpu 1 2 3 4");
    assert.equal(s.freq, "800000");
    assert.equal(s.procs, "1 (init) S\n2 (x) S\n");
    assert.deepEqual(splitSample("junk\n@freq\n1"), { stat: "", freq: "1", procs: "" });
});

test("open popovers are tracked across monitors", () => {
    const a = {}, b = {};
    let open = trackOpen([], a, true);
    open = trackOpen(open, b, true);
    open = trackOpen(open, a, true);
    assert.deepEqual(open, [b, a]);
    assert.deepEqual(trackOpen(open, b, false), [a]);
    assert.deepEqual(trackOpen(null, a, false), []);
});

test("probing goes on until what went away, or as good, comes back", () => {
    const core = { input: "/x/temp1_input", chip: "coretemp", label: "Package id 0", max: null, crit: null };
    const core1 = { input: "/z/temp1_input", chip: "coretemp", label: "Package id 1", max: null, crit: null };
    const core1Fallback = { input: "/z/temp2_input", chip: "coretemp", label: "Core 8", max: null, crit: null };
    const acpi = { input: "/y/temp1_input", chip: "acpitz", label: "", max: null, crit: null };
    const full = { throttles: ["/t"], maxFreq: 4700000, complete: true };
    const bare = { throttles: [], maxFreq: null, complete: true };
    // The first probe sets the bar without retrying.
    let next = afterProbe({ seen: NOTHING_SEEN, probe: full, sensors: [core] });
    assert.deepEqual(next, { seen: { ranks: [sensorRank(core)], throttles: 1, maxFreq: true }, retry: false });
    const all = next.seen;
    // coretemp goes away: probing goes on with nothing, and with the ACPI
    // fallback standing in, until coretemp is back.
    assert.equal(afterProbe({ seen: all, probe: full, sensors: [] }).retry, true);
    next = afterProbe({ seen: all, probe: full, sensors: [acpi] });
    assert.equal(next.retry, true);
    assert.deepEqual(next.seen, all);
    assert.deepEqual(afterProbe({ seen: next.seen, probe: full, sensors: [core] }), { seen: all, retry: false });
    // So with the throttle counter, and the top frequency, each on its own.
    assert.equal(afterProbe({ seen: all, probe: { ...full, throttles: [] }, sensors: [core] }).retry, true);
    assert.equal(afterProbe({ seen: all, probe: { ...full, maxFreq: null }, sensors: [core] }).retry, true);
    // A second package's sensor or counter that went away is waited for.
    const two = { ...full, throttles: ["/t", "/u"] };
    const both = afterProbe({ seen: NOTHING_SEEN, probe: two, sensors: [core, core1] }).seen;
    assert.deepEqual(both, { ranks: [sensorRank(core), sensorRank(core1)], throttles: 2, maxFreq: true });
    assert.equal(afterProbe({ seen: both, probe: two, sensors: [core1] }).retry, true);
    assert.equal(afterProbe({ seen: both, probe: full, sensors: [core, core1] }).retry, true);
    assert.equal(afterProbe({ seen: both, probe: two, sensors: [core, core1] }).retry, false);
    // So is one package falling back to a core reading, with the count and
    // the other package unchanged; what was seen stays the better.
    next = afterProbe({ seen: both, probe: two, sensors: [core, core1Fallback] });
    assert.deepEqual(next, { seen: both, retry: true });
    assert.equal(afterProbe({ seen: next.seen, probe: two, sensors: [core, core1] }).retry, false);
    // A better chip coming back replaces the fallback it stood in for.
    const fallback = afterProbe({ seen: NOTHING_SEEN, probe: full, sensors: [acpi] }).seen;
    assert.deepEqual(afterProbe({ seen: fallback, probe: full, sensors: [core] }).seen.ranks, [sensorRank(core)]);
    // A machine that never had them (a VM) isn't probed forever, nor one
    // whose only sensor is the fallback.
    assert.deepEqual(afterProbe({ seen: NOTHING_SEEN, probe: bare, sensors: [] }), { seen: NOTHING_SEEN, retry: false });
    assert.equal(afterProbe({ seen: NOTHING_SEEN, probe: full, sensors: [acpi] }).retry, false);
    // A probe that hit a read error is tried again, whatever it found.
    assert.equal(afterProbe({ seen: NOTHING_SEEN, probe: { ...bare, complete: false }, sensors: [acpi] }).retry, true);
    assert.equal(afterProbe({ seen: all, probe: { ...full, complete: false }, sensors: [core] }).retry, true);
});

test("sensors rank by chip, then label", () => {
    const core = (label) => ({ chip: "coretemp", label });
    assert.ok(sensorRank(core("Package id 0")) < sensorRank(core("Physical id 0")));
    assert.ok(sensorRank(core("Physical id 0")) < sensorRank(core("Core 0")));
    assert.ok(sensorRank(core("Core 0")) < sensorRank({ chip: "k10temp", label: "Tdie" }));
    assert.ok(sensorRank({ chip: "cpu_thermal", label: "" }) < sensorRank({ chip: "acpitz", label: "" }));
    assert.equal(sensorRank(null), Infinity);
    assert.equal(sensorRank({ chip: "nvme", label: "Composite" }), Infinity);
});

test("process memory waits for the real page size", () => {
    const procs = parseProcs(procLine(1, "a", 1, 100));
    const top = topProcesses({ prevProcs: null, procs, prevStat: null, stat: null, pageSize: null });
    assert.deepEqual(top.memory, []);
    assert.equal(topProcesses({ prevProcs: null, procs, prevStat: null, stat: null, pageSize: 16384 }).memory[0].memory, 100 * 16384);
});

test("each package's file keeps its reading across probes that still find it", () => {
    assert.deepEqual(pruned({ "/a": 1, "/b": 2 }, ["/a", "/c"]), { "/a": 1 });
    assert.deepEqual(pruned(null, ["/a"]), {});
    assert.deepEqual(pruned({ "/a": 1 }, []), {});
});

test("throttling on any package shows", () => {
    const states = { "/p0": { count: 3, since: null }, "/p1": { count: 4, since: 1000 } };
    assert.equal(anyThrottling(states, ["/p0", "/p1"], 2000), true);
    assert.equal(anyThrottling(states, ["/p0"], 2000), false);
    assert.equal(anyThrottling(states, ["/p0", "/p1"], 1000 + THROTTLE_HOLD_MS), false);
    assert.equal(anyThrottling({}, [], 0), false);
});

test("the throttling line speaks only for packages it could read", () => {
    const quiet = { count: 3, since: null };
    const hot = { count: 4, since: 1000 };
    // Every package read: "No" or "Now" holds for them all.
    assert.equal(throttleKnown({ "/p0": quiet, "/p1": quiet }, ["/p0", "/p1"], 2000), true);
    // One unreadable: "No" can't be said, but a package throttling can.
    assert.equal(throttleKnown({ "/p0": quiet, "/p1": null }, ["/p0", "/p1"], 2000), false);
    assert.equal(throttleKnown({ "/p0": quiet }, ["/p0", "/p1"], 2000), false);
    assert.equal(throttleKnown({ "/p0": hot, "/p1": null }, ["/p0", "/p1"], 2000), true);
    // A package a probe no longer finds leaves "No" unsaid too, until it's
    // back; one throttling still shows.
    assert.equal(throttleKnown({ "/p0": quiet }, ["/p0"], 2000, 2), false);
    assert.equal(throttleKnown({ "/p0": hot }, ["/p0"], 2000, 2), true);
    assert.equal(throttleKnown({ "/p0": quiet, "/p1": quiet }, ["/p0", "/p1"], 2000, 2), true);
    // No counters, no line.
    assert.equal(throttleKnown({}, [], 0), false);
});
