// The idle timeline's settings (SPEC.md §10, §16), as pure functions the
// QML binds to. idle.json and idle.local.json give the seconds from the
// last input to each step; tide writes them for hypridle as the variables
// conf's hypridle.conf sources, which keeps hypridle's commands in conf.

import { jsonError } from "./clocks.mjs";

// The steps, in the timeline's order: each one's setting, what the Idle
// page calls it, and the hypridle variable it's written to.
export const STEPS = Object.freeze([
    Object.freeze({ key: "dim", label: "Dim the screen", variable: "tide_idle_dim" }),
    Object.freeze({ key: "lock", label: "Lock", variable: "tide_idle_lock" }),
    Object.freeze({ key: "displaysOff", label: "Turn off displays", variable: "tide_idle_displays_off" }),
    Object.freeze({ key: "suspend", label: "Suspend, on battery", variable: "tide_idle_suspend" }),
]);

// §10's timeline, as conf's hypridle.conf also falls back to.
export const DEFAULT_IDLE = Object.freeze({ dim: 150, lock: 300, displaysOff: 330, suspend: 1800 });

// What the Idle page's − and + step through, in seconds.
export const LADDER = Object.freeze([30, 60, 120, 150, 180, 300, 330, 600, 900, 1200, 1800, 2700, 3600, 5400, 7200]);

// Parses one idle.json: an object of any of the steps' settings, each a
// whole number of seconds above 0. Returns {settings} or {error}, never
// throws; the error names the setting.
export function parseIdle(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: `expected an object of ${STEPS.map(s => s.key).join(", ")}` };
    }
    const settings = {};
    for (const key of Object.keys(value)) {
        if (!STEPS.some(s => s.key === key)) {
            return { error: `unknown setting "${key}"; expected ${STEPS.map(s => s.key).join(", ")}` };
        }
        const seconds = value[key];
        if (typeof seconds !== "number" || !Number.isInteger(seconds) || seconds <= 0) {
            return { error: `${key} must be a whole number of seconds above 0` };
        }
        settings[key] = seconds;
    }
    return { settings };
}

// The timings, from idle.json and then idle.local.json (SPEC.md §16.1):
// each text is the file's contents, or null when it doesn't exist. Objects
// merge key by key over the defaults, so a machine can change one step and
// inherit the rest. A file that fails to parse keeps `lastGood` (the
// defaults the first time); every file is checked, so `errors` names each
// one that's wrong.
export function loadIdle(sharedText, localText, lastGood = DEFAULT_IDLE) {
    const errors = [];
    const idle = Object.assign({}, DEFAULT_IDLE);
    for (const [name, text] of [["idle.json", sharedText], ["idle.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseIdle(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        Object.assign(idle, parsed.settings);
    }
    if (errors.length > 0) {
        return { idle: lastGood, errors };
    }
    return { idle, errors };
}

// The file hypridle sources, setting each step's variable.
export function hypridleConf(idle) {
    const lines = [
        "# Written by tide from idle.json and idle.local.json (tide SPEC.md §10,",
        "# §16). Change those, or the Idle page of tide's settings, not this file.",
    ];
    for (const step of STEPS) {
        lines.push(`$${step.variable} = ${idle[step.key]}`);
    }
    return lines.join("\n") + "\n";
}

// idle.local.json's text with `key` set to `seconds`, keeping whatever else
// it says. `localText` is null when the file doesn't exist. An unknown key
// or a bad time is an {error} naming it, and so is a file that doesn't
// parse, so a hand edit gone wrong is never overwritten.
export function withSetting(localText, key, seconds) {
    const bad = parseIdle(JSON.stringify({ [key]: seconds }));
    if (bad.error) {
        return { error: bad.error };
    }
    let settings = {};
    if (localText !== null && localText !== undefined) {
        const parsed = parseIdle(localText);
        if (parsed.error) {
            return { error: `idle.local.json: ${parsed.error}` };
        }
        settings = parsed.settings;
    }
    const next = {};
    for (const step of STEPS) {
        if (step.key === key) {
            next[key] = seconds;
        } else if (settings[step.key] !== undefined) {
            next[step.key] = settings[step.key];
        }
    }
    return { text: JSON.stringify(next, null, 2) + "\n" };
}

// The next value along LADDER from `seconds`, up (`step` 1) or down (-1),
// staying put at either end. A value between rungs, set by hand, moves to
// the nearest rung that way.
export function stepped(seconds, step) {
    if (step > 0) {
        const up = LADDER.find(s => s > seconds);
        return up === undefined ? seconds : up;
    }
    const down = LADDER.filter(s => s < seconds);
    return down.length === 0 ? seconds : down[down.length - 1];
}

// A duration as the Idle page shows it: "30 s", "2 min 30 s", "5 min",
// "1 h 30 min".
export function formatDuration(seconds) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    const parts = [];
    if (h > 0) {
        parts.push(`${h} h`);
    }
    if (m > 0) {
        parts.push(`${m} min`);
    }
    if (s > 0 || parts.length === 0) {
        parts.push(`${s} s`);
    }
    return parts.join(" ");
}
