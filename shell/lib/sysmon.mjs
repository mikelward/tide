// The system monitor (SPEC.md §7.4): CPU, memory, CPU temperature and
// thermal throttling, from /proc and /sys, as pure functions the QML feeds
// file contents into. The bar shows CPU %; its popover adds the processes
// using the most CPU and the most memory.

// How many processes each of the popover's two lists shows.
export const TOP = 5;
// A throttle counter that went up within this long still shows as
// throttling, so the warning doesn't flicker between samples.
export const THROTTLE_HOLD_MS = 30000;
// Without a sensor's own limits, the temperature turns amber and red here.
export const HOT_C = 85;
export const CRITICAL_C = 95;
// Memory this full turns the bar's reading amber.
export const MEMORY_HIGH = 0.9;

// /proc/stat's aggregate `cpu` line as {busy, total} jiffies, and how many
// CPUs it lists; null when there's no aggregate line. Idle and iowait count
// as idle; guest time is already inside user and nice, so it's left out.
export function parseStat(text) {
    let cpu = null;
    let count = 0;
    for (const line of String(text ?? "").split("\n")) {
        const fields = line.trim().split(/\s+/);
        if (fields[0] === "cpu") {
            const n = fields.slice(1, 9).map(Number);
            if (n.length < 4 || n.some((v) => !Number.isFinite(v))) {
                return null;
            }
            const total = n.reduce((a, b) => a + b, 0);
            const idle = n[3] + (n[4] ?? 0);
            cpu = { busy: total - idle, total };
        } else if (/^cpu\d+$/.test(fields[0])) {
            count += 1;
        }
    }
    return cpu === null ? null : Object.assign({}, cpu, { count: Math.max(1, count) });
}

// The share of the whole machine busy between two parseStat samples, 0-1;
// null without two samples, or when no time passed between them.
export function cpuUsage(prev, next) {
    if (!prev || !next) {
        return null;
    }
    const total = next.total - prev.total;
    if (total <= 0) {
        return null;
    }
    return Math.min(1, Math.max(0, (next.busy - prev.busy) / total));
}

// /proc/meminfo as {used, total, swapUsed, swapTotal} in bytes, used being
// what isn't available (MemTotal - MemAvailable); null without both. Swap
// is 0 where there's none.
export function parseMeminfo(text) {
    const kib = {};
    for (const line of String(text ?? "").split("\n")) {
        const m = /^(\w+):\s+(\d+)/.exec(line);
        if (m) {
            kib[m[1]] = Number(m[2]);
        }
    }
    if (!Number.isFinite(kib.MemTotal) || !Number.isFinite(kib.MemAvailable) || kib.MemTotal <= 0) {
        return null;
    }
    const swapTotal = Number.isFinite(kib.SwapTotal) ? kib.SwapTotal : 0;
    const swapFree = Number.isFinite(kib.SwapFree) ? kib.SwapFree : swapTotal;
    return {
        used: (kib.MemTotal - kib.MemAvailable) * 1024,
        total: kib.MemTotal * 1024,
        swapUsed: Math.max(0, swapTotal - swapFree) * 1024,
        swapTotal: swapTotal * 1024,
    };
}

// One /proc/<pid>/stat line as {pid, name, start, ticks, rss} (rss in
// pages), or null. The name is in parentheses and may hold spaces or
// parentheses itself, so the fields after it are counted from the last ")".
export function parseProcStat(line) {
    const open = line.indexOf("(");
    const close = line.lastIndexOf(")");
    if (open < 0 || close < open) {
        return null;
    }
    const pid = Number(line.slice(0, open));
    // After the name: field 3 (state) is rest[0], so field n is rest[n - 3].
    const rest = line.slice(close + 1).trim().split(/\s+/);
    const utime = Number(rest[11]);
    const stime = Number(rest[12]);
    const start = Number(rest[19]);
    const rss = Number(rest[21]);
    if (!Number.isInteger(pid) || pid <= 0 || ![utime, stime, start, rss].every(Number.isFinite)) {
        return null;
    }
    return { pid, name: line.slice(open + 1, close), start, ticks: utime + stime, rss: Math.max(0, rss) };
}

// Every process in a dump of /proc/*/stat lines, keyed by pid and start
// time, so a reused pid isn't taken for the process it replaced.
export function parseProcs(text) {
    const procs = new Map();
    for (const line of String(text ?? "").split("\n")) {
        const p = parseProcStat(line);
        if (p) {
            procs.set(`${p.pid}:${p.start}`, p);
        }
    }
    return procs;
}

// The popover's two lists from two process samples and the parseStat
// samples taken with them. CPU is a percentage of one CPU, as top shows
// it, so one busy thread reads 100% however many CPUs there are. A process
// in only the newer sample is left out of CPU until the next one: it may be
// new, or it may have been missed last time (a failed read), and then its
// whole lifetime's ticks would read as this interval's. Memory is resident
// memory in bytes. Each list is the TOP largest, ties by name, zeros left
// out.
export function topProcesses({ prevProcs, procs, prevStat, stat, pageSize }) {
    const list = [...(procs ?? new Map()).entries()].map(([key, p]) => ({
        pid: p.pid, name: p.name, ticks: p.ticks, before: prevProcs?.get(key)?.ticks ?? null,
        memory: p.rss * pageSize,
    }));
    const perCpu = prevStat && stat ? (stat.total - prevStat.total) / stat.count : 0;
    const order = (key) => (a, b) => b[key] - a[key] || a.name.localeCompare(b.name) || a.pid - b.pid;
    const cpu = perCpu > 0 && prevProcs
        ? list.filter((p) => p.before !== null)
            .map((p) => ({ pid: p.pid, name: p.name, cpu: Math.max(0, p.ticks - p.before) / perCpu }))
            .filter((p) => p.cpu > 0).sort(order("cpu")).slice(0, TOP)
        : [];
    const memory = !(pageSize > 0) ? [] : list.filter((p) => p.memory > 0).map((p) => ({ pid: p.pid, name: p.name, memory: p.memory }))
        .sort(order("memory")).slice(0, TOP);
    return { cpu, memory };
}

// Which temperature sensor is the CPU's, from the shell's sensor listing:
// one {input, chip, label, max, crit} per hwmon temp*_input, max and crit
// in millidegrees or null. Package-wide readings beat a single core's, and
// a CPU driver beats the ACPI zone; null when nothing looks like a CPU.
const CHIPS = [
    ["coretemp", ["Package id 0", "Physical id 0"]],
    ["k10temp", ["Tdie", "Tctl"]],
    ["zenpower", ["Tdie", "Tctl"]],
    ["cpu_thermal", []],
    ["soc_thermal", []],
    ["thinkpad", ["CPU"]],
    ["acpitz", []],
];

export function pickCpuSensor(sensors) {
    for (const [chip, labels] of CHIPS) {
        const ours = (sensors ?? []).filter((s) => s.chip === chip);
        if (ours.length === 0) {
            continue;
        }
        for (const label of labels) {
            const s = ours.find((o) => o.label === label);
            if (s) {
                return s;
            }
        }
        // A chip whose preferred labels are all missing still counts, at
        // its first sensor, except thinkpad's, whose others aren't the CPU.
        if (chip !== "thinkpad") {
            return ours[0];
        }
    }
    return null;
}

// The shell's sensor listing, one tab-separated line per temp*_input:
// `temp`, the input's path, the chip name, its label, and its max and crit
// in millidegrees, each field empty when the file is missing. Other lines
// are settings: `page` (bytes), `maxfreq` (kHz) and `throttle` (a path).
// The page size is null until a probe says, never a guess: a 16 KiB-page
// machine would read every process's memory at a quarter of its size.
export function parseProbe(text) {
    const probe = { sensors: [], pageSize: null, maxFreq: null, throttle: "", complete: true };
    const num = (s) => (s === undefined || s.trim() === "" || !Number.isFinite(Number(s)) ? null : Number(s));
    for (const line of String(text ?? "").split("\n")) {
        const f = line.split("\t");
        if (f[0] === "temp" && f[1]) {
            probe.sensors.push({ input: f[1], chip: (f[2] ?? "").trim(), label: (f[3] ?? "").trim(), max: num(f[4]), crit: num(f[5]) });
        } else if (f[0] === "page" && num(f[1]) > 0) {
            probe.pageSize = num(f[1]);
        } else if (f[0] === "maxfreq" && num(f[1]) > 0) {
            probe.maxFreq = num(f[1]);
        } else if (f[0] === "throttle" && f[1]) {
            probe.throttle = f[1].trim();
        } else if (f[0] === "incomplete") {
            probe.complete = false;
        }
    }
    return probe;
}

// A temperature as "62 °C" from millidegrees; "" for no reading.
export function formatTemp(milli) {
    return Number.isFinite(milli) ? `${Math.round(milli / 1000)} °C` : "";
}

// How hot a reading is against its sensor's limits, or HOT_C and
// CRITICAL_C where the sensor has none: "ok", "hot" or "critical".
export function tempLevel(milli, sensor) {
    if (!Number.isFinite(milli)) {
        return "ok";
    }
    const crit = Number.isFinite(sensor?.crit) && sensor.crit > 0 ? sensor.crit : CRITICAL_C * 1000;
    const hot = Number.isFinite(sensor?.max) && sensor.max > 0 && sensor.max < crit ? sensor.max : Math.min(HOT_C * 1000, crit);
    if (milli >= crit) {
        return "critical";
    }
    return milli >= hot ? "hot" : "ok";
}

// The throttle state after a reading of the kernel's throttle counter:
// {count, since}, `since` being when it last went up (ms), or null. The
// first reading only sets the baseline; a counter that went backwards
// (the CPU was replugged) does too.
export function throttleStep(state, count, now) {
    if (!Number.isFinite(count)) {
        return state ?? { count: null, since: null };
    }
    const prev = state?.count;
    const rose = Number.isFinite(prev) && count > prev;
    return { count, since: rose ? now : (state?.since ?? null) };
}

// Whether the CPU throttled within the last THROTTLE_HOLD_MS. A rise that
// seems to be in the future means the wall clock went back since, and
// counts as over rather than holding the bar red for the whole jump.
export function throttling(state, now) {
    if (!Number.isFinite(state?.since)) {
        return false;
    }
    const elapsed = now - state.since;
    return elapsed >= 0 && elapsed < THROTTLE_HOLD_MS;
}

// The highest current frequency of any CPU, in kHz, from the cpufreq
// readings; null without any. Idle cores clock down, so the fastest one is
// what a busy one is getting.
export function topFreq(text) {
    const values = String(text ?? "").split(/\s+/).map(Number).filter((v) => Number.isFinite(v) && v > 0);
    return values.length === 0 ? null : Math.max(...values);
}

// "3.1 / 4.7 GHz", "3.1 GHz", or "" from kHz.
export function formatFreq(cur, max) {
    const ghz = (k) => (k / 1e6).toFixed(1);
    if (!Number.isFinite(cur)) {
        return "";
    }
    return Number.isFinite(max) && max > 0 ? `${ghz(cur)} / ${ghz(max)} GHz` : `${ghz(cur)} GHz`;
}

// "9.4 / 31 GB" for used of total bytes; "" without a total.
export function formatUsage(used, total) {
    return Number.isFinite(total) && total > 0 ? `${formatBytes(used)} / ${formatBytes(total)}` : "";
}

// "12%" from a share 0-1 (or a per-CPU share above 1); "–" for none.
export function formatPercent(share) {
    return Number.isFinite(share) ? `${Math.round(share * 100)}%` : "–";
}

// Bytes as "512 MB", "1.4 GB" or "31 GB", in powers of 1024 as free does.
export function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes < 0) {
        return "";
    }
    const mib = bytes / 1048576;
    if (mib < 1024) {
        return `${Math.max(0, Math.round(mib))} MB`;
    }
    const gib = mib / 1024;
    return gib < 10 ? `${gib.toFixed(1)} GB` : `${Math.round(gib)} GB`;
}

// What the bar shows: CPU %, and its color, "danger" while throttling or
// critically hot, "warn" when hot or memory is nearly full, else "normal".
export function barView({ cpu, temp, sensor, throttled, memory }) {
    const level = tempLevel(temp, sensor);
    const full = memory && memory.total > 0 && memory.used / memory.total >= MEMORY_HIGH;
    const tone = throttled || level === "critical" ? "danger" : level === "hot" || full ? "warn" : "normal";
    return { text: formatPercent(cpu), tone };
}

// `tide-sysmon sample`'s output as its @stat, @freq and @procs sections'
// text; a missing section is "".
export function splitSample(text) {
    const parts = { stat: [], freq: [], procs: [] };
    let into = null;
    for (const line of String(text ?? "").split("\n")) {
        const head = /^@(stat|freq|procs)$/.exec(line);
        if (head) {
            into = parts[head[1]];
        } else if (into) {
            into.push(line);
        }
    }
    return { stat: parts.stat.join("\n"), freq: parts.freq.join("\n"), procs: parts.procs.join("\n") };
}

// The popovers open across monitors after `popover` opens or closes; the
// processes are sampled while any is.
export function trackOpen(open, popover, visible) {
    const rest = (open ?? []).filter((p) => p !== popover);
    return visible ? [...rest, popover] : rest;
}

// Where a sensor stands in CHIPS' order, lower being better: its chip's
// place, then its label's place within the chip, a chip's fallback sensor
// after its named ones. Infinity for none.
export function sensorRank(sensor) {
    const i = CHIPS.findIndex(([chip]) => chip === sensor?.chip);
    if (i < 0) {
        return Infinity;
    }
    const labels = CHIPS[i][1];
    const j = labels.indexOf(sensor.label);
    return i * 100 + (j < 0 ? labels.length : j);
}

// What the best probe so far showed of this machine: its sensor's rank
// (sensorRank), and whether it had a throttle counter and a top frequency.
export const NOTHING_SEEN = { rank: Infinity, throttle: false, maxFreq: false };

// After a probe, what's been seen so far and whether to probe again in a
// minute. Probing goes on while this probe shows less than the best one did
// in any way (a lesser sensor or none, no throttle counter, no top
// frequency), so whatever went away (a driver reload) is taken back when it
// returns, and while it hit a read error (`complete` false), since what it
// couldn't read may be what matters. A machine that never had something (a
// VM) isn't probed forever for it.
export function afterProbe({ seen, probe, sensor }) {
    const was = seen ?? NOTHING_SEEN;
    const now = {
        rank: sensorRank(sensor),
        throttle: (probe?.throttle ?? "") !== "",
        maxFreq: Number.isFinite(probe?.maxFreq),
    };
    const best = {
        rank: Math.min(was.rank, now.rank),
        throttle: was.throttle || now.throttle,
        maxFreq: was.maxFreq || now.maxFreq,
    };
    const less = now.rank > best.rank || now.throttle < best.throttle || now.maxFreq < best.maxFreq;
    return { seen: best, retry: less || probe?.complete === false };
}
