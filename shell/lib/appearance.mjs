// Light or dark (SPEC.md §15), as pure functions the QML binds to: the
// settings in appearance.json and appearance.local.json, the schedule they
// give, and a manual flip that lasts until the schedule's next change.
//
// Local time comes in as a `clock`, so the tests can pin a time zone:
// `clock.time(y, m, d, h, min)` is the instant of a local wall time (month
// from 1), and `clock.dayOf(ms)` the local date {y, m, d} an instant falls
// on. LOCAL is the engine's own local time, which follows the system's
// time zone and its daylight saving changes.

import { jsonError } from "./clocks.mjs";

export const LOCAL = Object.freeze({
    time: (y, m, d, h, min) => new Date(y, m - 1, d, h, min).getTime(),
    dayOf: (ms) => {
        const t = new Date(ms);
        return { y: t.getFullYear(), m: t.getMonth() + 1, d: t.getDate() };
    },
});

export const DEFAULTS = Object.freeze({ mode: "schedule", light: "07:00", dark: "19:00" });

const MODES = ["schedule", "sun", "light", "dark"];
const KEYS = ["mode", "light", "dark", "latitude", "longitude"];
const DAY = 24 * 60 * 60 * 1000;

// "HH:MM" as {h, min}, or null when it isn't a 24-hour time.
export function parseTime(text) {
    const m = typeof text === "string" ? /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(text) : null;
    return m ? { h: Number(m[1]), min: Number(m[2]) } : null;
}

// One file's settings: an object with any of KEYS. Returns {settings} or
// {error}, never throws. Whether they make sense together is checkSettings'.
export function parseAppearance(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: "expected an object of settings" };
    }
    const settings = {};
    for (const key of Object.keys(value)) {
        const v = value[key];
        switch (key) {
        case "mode":
            if (!MODES.includes(v)) {
                return { error: `mode must be one of ${MODES.map(m => `"${m}"`).join(", ")}` };
            }
            break;
        case "light":
        case "dark":
            if (!parseTime(v)) {
                return { error: `${key} must be a time like "07:00"` };
            }
            break;
        case "latitude":
            if (typeof v !== "number" || !(v >= -90 && v <= 90)) {
                return { error: "latitude must be a number from -90 to 90" };
            }
            break;
        case "longitude":
            if (typeof v !== "number" || !(v >= -180 && v <= 180)) {
                return { error: "longitude must be a number from -180 to 180" };
            }
            break;
        default:
            return { error: `unknown setting "${key}"` };
        }
        settings[key] = v;
    }
    return { settings };
}

// Whether merged settings work together: null, or what's wrong.
export function checkSettings(s) {
    if (s.mode === "sun" && (s.latitude === undefined || s.longitude === undefined)) {
        return 'mode "sun" needs latitude and longitude';
    }
    if (s.mode === "schedule" && s.light === s.dark) {
        return "light and dark must be different times";
    }
    return null;
}

// The settings in effect, from appearance.json and appearance.local.json
// (SPEC.md §16.1). Each text is the file's contents, or null when it
// doesn't exist. The local file's settings replace the shared file's one
// by one. A file that fails to parse, or settings that don't work
// together, keep `lastGood` (the defaults the first time), and `errors`
// names every problem: {settings, errors}.
export function loadAppearance(sharedText, localText, lastGood = DEFAULTS) {
    const errors = [];
    let settings = Object.assign({}, DEFAULTS);
    for (const [name, text] of [["appearance.json", sharedText], ["appearance.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseAppearance(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        settings = Object.assign(settings, parsed.settings);
    }
    if (errors.length === 0) {
        const wrong = checkSettings(settings);
        if (wrong) {
            errors.push(`${localText !== null && localText !== undefined ? "appearance.local.json" : "appearance.json"}: ${wrong}`);
        }
    }
    return errors.length > 0 ? { settings: lastGood, errors } : { settings, errors };
}

// The sun's altitude in degrees at an instant (ms), at a latitude and
// longitude (east positive): the low-precision solar position, good to a
// fraction of a degree, which puts a sunrise within a minute or two. No
// network lookup.
export function sunAltitude(ms, latitude, longitude) {
    const rad = Math.PI / 180;
    const d = ms / DAY + 2440587.5 - 2451545.0;
    const g = (357.529 + 0.98560028 * d) * rad;
    const q = 280.459 + 0.98564736 * d;
    const L = (q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * rad;
    const e = (23.439 - 0.00000036 * d) * rad;
    const ra = Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L));
    const decl = Math.asin(Math.sin(e) * Math.sin(L));
    const gmst = (18.697374558 + 24.06570982441908 * d) * 15 * rad;
    const hourAngle = gmst + longitude * rad - ra;
    const lat = latitude * rad;
    return Math.asin(Math.sin(lat) * Math.sin(decl) + Math.cos(lat) * Math.cos(decl) * Math.cos(hourAngle)) / rad;
}

// Sunrise and sunset are the sun's upper edge on the horizon, with
// refraction.
const HORIZON_ALTITUDE = -0.833;

// Whether it's dark (the sun below the horizon) at an instant.
export function sunDown(ms, latitude, longitude) {
    return sunAltitude(ms, latitude, longitude) < HORIZON_ALTITUDE;
}

// How far ahead the sun's next change is looked for: past the longest
// polar day or night, about six months at the poles.
const HORIZON_DAYS = 400;
const MINUTE = 60 * 1000;

// The instant the sun next rises or sets after `now` (to the second), or
// null if it doesn't within HORIZON_DAYS. The altitude changes at most a
// quarter of a degree a minute, the Earth's turn, so a step as long as its
// distance from the horizon allows can't skip a crossing; that keeps the
// steps long through a polar day or night.
export function nextSunChange(now, latitude, longitude) {
    const down = sunDown(now, latitude, longitude);
    const end = now + HORIZON_DAYS * DAY;
    let before = now;
    while (before < end) {
        const gap = Math.abs(sunAltitude(before, latitude, longitude) - HORIZON_ALTITUDE);
        const after = Math.min(end, before + Math.max(MINUTE, gap / 0.26 * MINUTE));
        if (sunDown(after, latitude, longitude) !== down) {
            let lo = before;
            let hi = after;
            while (hi - lo > 1000) {
                const mid = (lo + hi) / 2;
                if (sunDown(mid, latitude, longitude) !== down) {
                    hi = mid;
                } else {
                    lo = mid;
                }
            }
            return hi;
        }
        before = after;
    }
    return null;
}

let sunCache = null;

// What the settings say at `now`: {dark, next}, `next` being the instant
// of the next change, or null when the mode is fixed.
export function scheduled(s, now, clock = LOCAL) {
    if (s.mode === "light" || s.mode === "dark") {
        return { dark: s.mode === "dark", next: null };
    }
    if (s.mode === "sun") {
        // Where the sun is now, not a day's rise and set: a polar day or
        // night, and the days either side of one, need no special case.
        // Through a polar day the search runs months ahead, so the answer
        // is kept until the change it found, rather than found each minute.
        const c = sunCache;
        if (c && c.latitude === s.latitude && c.longitude === s.longitude && now >= c.from && (c.next === null ? now < c.from + DAY : now < c.next)) {
            return { dark: c.dark, next: c.next };
        }
        const dark = sunDown(now, s.latitude, s.longitude);
        const next = nextSunChange(now, s.latitude, s.longitude);
        sunCache = { latitude: s.latitude, longitude: s.longitude, from: now, dark, next };
        return { dark, next };
    }
    const light = parseTime(s.light);
    const darkAt = parseTime(s.dark);
    const today = clock.dayOf(now);
    // Noon steps a whole local day whatever daylight saving does.
    const noon = clock.time(today.y, today.m, today.d, 12, 0);
    const changes = [];
    for (let offset = -2; offset <= 2; offset++) {
        const day = clock.dayOf(noon + offset * DAY);
        changes.push({ at: clock.time(day.y, day.m, day.d, light.h, light.min), dark: false });
        changes.push({ at: clock.time(day.y, day.m, day.d, darkAt.h, darkAt.min), dark: true });
    }
    changes.sort((a, b) => a.at - b.at);
    let dark = true;
    for (const c of changes) {
        if (c.at <= now) {
            dark = c.dark;
        }
    }
    const next = changes.find(c => c.at > now && c.dark !== dark);
    return { dark, next: next ? next.at : null };
}

// The settings as a key, so a flip made under some settings is dropped
// when they change.
export function settingsKey(s) {
    return JSON.stringify(KEYS.filter(k => s[k] !== undefined).map(k => [k, s[k]]));
}

// What shows at `now`: the schedule, unless a flip still holds. A flip
// ({dark, until, settings}) holds until the schedule's next change after it
// was made (`until`, null when the mode is fixed) and while the settings
// are the ones it was made under. Returns {dark, next, override}, where
// `override` is the flip still holding, or null.
export function themeAt(s, now, override, clock = LOCAL) {
    const plan = scheduled(s, now, clock);
    const holds = override !== null && override !== undefined
        && override.settings === settingsKey(s)
        && (override.until === null || now < override.until);
    if (!holds) {
        return { dark: plan.dark, next: plan.next, override: null };
    }
    return { dark: override.dark, next: override.until === null ? null : plan.next, override };
}

// The flip from the launcher: the other one from what shows now, until the
// schedule's next change. Flipping back to what the schedule says drops it.
export function flip(s, now, override, clock = LOCAL) {
    const shown = themeAt(s, now, override, clock);
    const plan = scheduled(s, now, clock);
    if (!shown.dark === plan.dark) {
        return null;
    }
    return { dark: !shown.dark, until: plan.next, settings: settingsKey(s) };
}

// Whether a line of `gsettings monitor` output (`color-scheme:
// 'prefer-dark'`) or `gsettings get` output means dark; `default` is
// GNOME's "no preference", which apps show light. null for any other line.
export function schemeIsDark(line) {
    if (typeof line !== "string") {
        return null;
    }
    const m = /^(?:color-scheme:\s*)?'(default|prefer-dark|prefer-light)'\s*$/.exec(line.trim());
    return m ? m[1] === "prefer-dark" : null;
}

// "HH:MM" of an instant in local time.
export function clockTime(ms) {
    const t = new Date(ms);
    const pad = n => String(n).padStart(2, "0");
    return `${pad(t.getHours())}:${pad(t.getMinutes())}`;
}

// The commands that tell apps (SPEC.md §15): the color scheme, which
// xdg-desktop-portal-gtk publishes to them, and the GTK 3 theme. Adwaita
// until setup installs adw-gtk3 (M7).
export function schemeCommands(dark) {
    const set = (key, value) => ["gsettings", "set", "org.gnome.desktop.interface", key, value];
    return [
        set("color-scheme", dark ? "prefer-dark" : "prefer-light"),
        set("gtk-theme", dark ? "Adwaita-dark" : "Adwaita"),
    ];
}
