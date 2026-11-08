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
import { PALETTE } from "./palette.mjs";
import { stepped } from "./steps.mjs";

export const LOCAL = Object.freeze({
    time: (y, m, d, h, min) => new Date(y, m - 1, d, h, min).getTime(),
    dayOf: (ms) => {
        const t = new Date(ms);
        return { y: t.getFullYear(), m: t.getMonth() + 1, d: t.getDate() };
    },
});

export const DEFAULTS = Object.freeze({ mode: "schedule", light: "07:00", dark: "19:00" });

const MODES = ["schedule", "sun", "light", "dark"];
// The settings that decide light or dark, and every one there is.
const THEME_KEYS = ["mode", "light", "dark", "latitude", "longitude"];
const KEYS = THEME_KEYS.concat(["dimStrength", "lightWallpaper", "darkWallpaper", "lightWallpaperPosition",
    "darkWallpaperPosition", "wallpaperPosition"]);
// How a picture is placed on a monitor (SPEC.md §15): each mode's own,
// lightWallpaperPosition or darkWallpaperPosition, else wallpaperPosition,
// for both.
export const POSITIONS = Object.freeze(["fill", "fill-top", "fill-bottom", "fit", "stretch"]);
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
        case "dimStrength":
            // Hyprland's decoration:dim_strength, as conf takes it.
            if (typeof v !== "number" || !(v >= 0 && v <= 1)) {
                return { error: "dimStrength must be a number from 0 to 1" };
            }
            break;
        case "lightWallpaper":
        case "darkWallpaper":
            if (wallpaperError(key, v)) {
                return { error: wallpaperError(key, v) };
            }
            break;
        case "lightWallpaperPosition":
        case "darkWallpaperPosition":
        case "wallpaperPosition":
            if (!POSITIONS.includes(v)) {
                return { error: `${key} must be one of ${POSITIONS.map(p => `"${p}"`).join(", ")}` };
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

// The settings that decide light or dark as a key, so a flip made under
// some settings is dropped when they change, and kept when only the dim
// does.
export function settingsKey(s) {
    return JSON.stringify(THEME_KEYS.filter(k => s[k] !== undefined).map(k => [k, s[k]]));
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
// until setup installs adw-gtk3 (M7). Switches wait for each other
// (tellNext), so each is stopped after `seconds`, as the hook is: a
// gsettings stuck on an unresponsive dconf would otherwise hold up every
// later switch. `--verbose` has timeout itself say when it stops one, which
// Launcher logs.
export const SCHEME_SECONDS = 10;

export function schemeCommands(dark, seconds = SCHEME_SECONDS) {
    const set = (key, value) => ["timeout", "--verbose", "--kill-after=5", String(seconds),
        "gsettings", "set", "org.gnome.desktop.interface", key, value];
    return [
        set("color-scheme", dark ? "prefer-dark" : "prefer-light"),
        set("gtk-theme", dark ? "Adwaita-dark" : "Adwaita"),
    ];
}

// The hook a user's config can install to follow the scheme with what the
// shell doesn't draw (SPEC.md §15): `appearance-hook` in the tide config
// directory `dir`, run with no arguments after each change, once the
// scheme commands have finished, so it can read the scheme as it now is.
// No hook is the usual case and does nothing; one that can't run says so,
// a link to a file that's gone included.
// Switches wait for each other (tellNext), so a hook still running after
// `seconds` is stopped rather than holding up every later switch: TERM,
// then KILL 5 s later for one that ignores TERM. timeout says so itself
// (`--verbose`), since a hook's own exit status can't tell a stop apart.
// Not exec'd: on KILL, timeout kills itself too, and sh turns that into
// an exit of 137 for Launcher to log.
export const HOOK_SECONDS = 30;

export function hookCommand(dir, seconds = HOOK_SECONDS) {
    return ["sh", "-c",
        'if ! test -e "$1"; then if test -L "$1"; then echo "$1 is a link to nothing" >&2; exit 1; fi; exit 0; fi; if ! test -x "$1"; then echo "$1 is not executable" >&2; exit 1; fi; '
        + 'timeout --verbose --kill-after=5 "$2" "$1"',
        "sh", `${dir}/appearance-hook`, String(seconds)];
}

// Telling apps, one run at a time (SPEC.md §15): a change while a run is
// going is held, and runs once that run ends, for the scheme as it is then,
// so runs can't overtake each other and the last always tells the latest.
// {running, again}; each step returns {state, start}: whether to start a
// run now.
export const TELL_IDLE = Object.freeze({ running: false, again: false });

export function tellNext(state, event) {
    switch (event) {
    case "change":
        if (state.running) {
            return { state: Object.freeze({ running: true, again: true }), start: false };
        }
        return { state: Object.freeze({ running: true, again: false }), start: true };
    case "done":
        if (state.again) {
            return { state: Object.freeze({ running: true, again: false }), start: true };
        }
        return { state: TELL_IDLE, start: false };
    default:
        throw new Error(`unknown tell event: ${event}`);
    }
}

// The settings panel's Appearance page (SPEC.md §16): its modes, in the
// order ‹ and › step through them.
export const MODE_CHOICES = Object.freeze([
    Object.freeze({ mode: "schedule", label: "By the clock" }),
    Object.freeze({ mode: "sun", label: "Sunrise and sunset" }),
    Object.freeze({ mode: "light", label: "Always light" }),
    Object.freeze({ mode: "dark", label: "Always dark" }),
]);

// The mode `steps` steps through MODE_CHOICES from the one at index `at`,
// as an index, stopping at either end. "sun" is stepped past while
// `settings` has no latitude and longitude, which it needs, so the modes
// on its far side can still be reached.
export function steppedModeAt(settings, at, steps) {
    const located = settings.latitude !== undefined && settings.longitude !== undefined;
    const dir = Math.sign(steps);
    let i = at;
    for (let n = Math.abs(steps); n > 0; n--) {
        let j = i + dir;
        while (!located && MODE_CHOICES[j]?.mode === "sun") {
            j += dir;
        }
        if (j < 0 || j >= MODE_CHOICES.length) {
            break;
        }
        i = j;
    }
    return i;
}

// The page's − and + move a time by this many minutes.
export const TIME_STEP = 15;

function hhmm(minutes) {
    return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

// The time `steps` quarter hours from `text` ("HH:MM"), stopping at 00:00
// and 23:45. One off a quarter hour goes to the next one that way first,
// so 07:10 goes to 07:15 or 07:00.
export function steppedTime(text, steps) {
    const t = parseTime(text);
    if (t === null || steps === 0) {
        return text;
    }
    const at = t.h * 60 + t.min;
    let next;
    if (at % TIME_STEP === 0) {
        next = at + steps * TIME_STEP;
    } else {
        const edge = steps > 0 ? Math.ceil(at / TIME_STEP) : Math.floor(at / TIME_STEP);
        next = (edge + steps - Math.sign(steps)) * TIME_STEP;
    }
    const clamped = Math.max(0, Math.min(24 * 60 - TIME_STEP, next));
    // Past the last quarter hour (23:50, typed by hand), + has nowhere to
    // go, and stays rather than stepping back.
    return (steps > 0 && clamped < at) || (steps < 0 && clamped > at) ? text : hhmm(clamped);
}

// As steppedTime, but a step that would land on `other`, the opposite
// time, goes past it: light and dark can't be the same, and an overnight
// schedule needs the two to cross. At the end of the day, with nowhere
// past it, the time stays where it is.
export function steppedTimePast(text, steps, other) {
    const next = steppedTime(text, steps);
    if (next !== other) {
        return next;
    }
    const past = steppedTime(next, Math.sign(steps));
    return past === next ? text : past;
}

// A latitude or longitude as typed on the page: a decimal number, east and
// north positive. Returns {value} or {error} naming the setting.
export function parseCoordinate(key, text) {
    const trimmed = typeof text === "string" ? text.trim() : "";
    if (!/^[-+]?\d+(\.\d+)?$/.test(trimmed)) {
        return { error: `${key} must be a number in decimal degrees, such as ${key === "latitude" ? "37.77" : "-122.42"}` };
    }
    const value = Number(trimmed);
    const bad = parseAppearance(JSON.stringify({ [key]: value }));
    return bad.error ? { error: bad.error } : { value };
}

// appearance.local.json's text with `key` set to `value`, keeping whatever
// else it says. Each text is the file's, or null when it doesn't exist. The
// settings panel writes only the .local file (§16.1). A bad value, a file
// that doesn't parse (never overwritten, so a hand edit gone wrong isn't
// lost), or settings that wouldn't work together with the shared file's
// (`mode` "sun" with no latitude and longitude, say) is an {error}.
export function withSetting(localText, key, value, sharedText = null) {
    const bad = parseAppearance(JSON.stringify({ [key]: value }));
    if (bad.error) {
        return { error: bad.error };
    }
    const files = {};
    for (const [name, text] of [["appearance.json", sharedText], ["appearance.local.json", localText]]) {
        if (text === null || text === undefined) {
            files[name] = {};
            continue;
        }
        const parsed = parseAppearance(text);
        if (parsed.error) {
            return { error: `${name}: ${parsed.error}` };
        }
        files[name] = parsed.settings;
    }
    const local = Object.assign({}, files["appearance.local.json"], { [key]: value });
    const wrong = checkSettings(Object.assign({}, DEFAULTS, files["appearance.json"], local));
    if (wrong) {
        return { error: wrong };
    }
    const next = {};
    for (const k of KEYS) {
        if (local[k] !== undefined) {
            next[k] = local[k];
        }
    }
    return { text: JSON.stringify(next, null, 2) + "\n" };
}

// The inactive dim's strength (SPEC.md §6.2) when nothing sets it: conf's
// hyprland.lua's, which applies then.
export const DIM_STRENGTH = 0.12;

// The page's − and + for it: a point at a time, from none to half.
const DIM_STEP = 0.01;
const DIM_HI = 0.5;

// The dim strength in effect.
export function dimStrength(settings) {
    return settings.dimStrength ?? DIM_STRENGTH;
}

// The dim strength moved `steps` steps, as shell/lib/steps.mjs moves one.
export function steppedDim(value, steps) {
    return stepped(value, steps, DIM_STEP, 0, DIM_HI);
}

// How the page shows a dim strength: as a percentage.
export function formatDim(value) {
    return `${Math.round(value * 100)}%`;
}

// What reaches Hyprland, as the Lua table conf's hyprland.lua reads from
// ~/.config/hypr/tide-appearance.lua: only what's set, so the config's own
// stands for the rest. A number is all it holds, so it needs no escapes.
export function appearanceLua(settings) {
    const lines = [
        "-- Written by tide from appearance.json and appearance.local.json (tide SPEC.md §16).",
        "-- Change those, or the Appearance page of tide's settings, not this file. Only",
        "-- what's set is here; hyprland.lua has the rest.",
        "return {",
    ];
    if (settings.dimStrength !== undefined) {
        lines.push(`    dim_strength = ${settings.dimStrength},`);
    }
    lines.push("}");
    return lines.join("\n") + "\n";
}

// What reaches tidewm (SPEC.md §5.3), as the lines conf's tidewm config
// includes from ~/.config/tidewm/tide-appearance.conf: only what's set, so
// the config's own stands for the rest. tidewm's dim_inactive takes the
// strength as Hyprland's dim_strength does, from 0 to 1.
export function appearanceConf(settings) {
    const lines = [
        "# Written by tide from appearance.json and appearance.local.json (tide SPEC.md §16).",
        "# Change those, or the Appearance page of tide's settings, not this file. Only",
        "# what's set is here; conf's tidewm config has the rest.",
    ];
    if (settings.dimStrength !== undefined) {
        lines.push(`dim_inactive ${settings.dimStrength}`);
    }
    return lines.join("\n") + "\n";
}

// What's wrong with a wallpaper setting, or "": a file's path, absolute or
// from ~/, on one line, a color, or "" for the default.
function wallpaperError(key, v) {
    if (typeof v === "string" && v.startsWith("#")) {
        return wallpaperColor(v) === "" ? `${key} must be a color as #rrggbb or #rgb, such as "#1a1d2e"` : "";
    }
    if (typeof v !== "string" || /[\n\r]/.test(v) || (v !== "" && !v.startsWith("/") && !v.startsWith("~/"))) {
        return `${key} must be a file's path, such as "~/Pictures/day.jpg", a color such as "#1a1d2e", or "" for the default`;
    }
    return "";
}

// A wallpaper that's a solid color (SPEC.md §15), `#rrggbb` or `#rgb` in
// either case, as #rrggbb in lower case; "" for anything else, a file's
// path say. A path never starts with #, so the two can't be confused.
export function wallpaperColor(v) {
    if (typeof v !== "string") {
        return "";
    }
    if (/^#[0-9a-fA-F]{6}$/.test(v)) {
        return v.toLowerCase();
    }
    if (/^#[0-9a-fA-F]{3}$/.test(v)) {
        return "#" + v.slice(1).split("").map(c => c + c).join("").toLowerCase();
    }
    return "";
}

// The colors the Appearance page offers for a wallpaper (SPEC.md §16), from
// tide's palette: dark backgrounds, then light ones. The two teal and
// violet ones are the lock's own gradient (LockFace.qml).
export const WALLPAPER_COLORS = Object.freeze([
    { label: "Night", color: PALETTE.dark.stripNight },
    { label: "Charcoal", color: PALETTE.dark.surface },
    { label: "Teal", color: "#13303a" },
    { label: "Violet", color: "#241a3a" },
    { label: "Dusk", color: PALETTE.dark.stripDay },
    { label: "Sky", color: PALETTE.light.stripDay },
    { label: "Mist", color: PALETTE.light.stripNight },
    { label: "Paper", color: PALETTE.light.surface2 },
].map(c => Object.freeze(c)));

// The lock's backdrop for a color wallpaper: `color` darkened as the
// lock's MultiEffect darkens a picture (brightness -0.25, each channel a
// quarter down), so the face's light text reads on a light color too. On
// the light face (`dark` false), lightened as much, for its dark text.
export const LOCK_DARKEN = 0.25;

export function lockColor(color, dark = true) {
    const c = wallpaperColor(color);
    if (c === "") {
        return "";
    }
    const by = Math.round(LOCK_DARKEN * 255) * (dark ? -1 : 1);
    return "#" + [1, 3, 5].map(i => Math.min(255, Math.max(0, parseInt(c.slice(i, i + 2), 16) + by)).toString(16).padStart(2, "0")).join("");
}

// `path` with a leading ~/ as `home`.
export function expandHome(path, home) {
    return path.startsWith("~/") ? `${home}/${path.slice(2)}` : path;
}

// The wallpapers to try, in order, for light or `dark` (SPEC.md §15): the
// one set for it, then $TIDE_WALLPAPER (`env`, "" when it's unset), then
// conf's per-mode image and its one for both, as theme.sh and tide-shell
// have them. The shell shows the first that can be read. A color set for
// the mode is the only one: it can always be drawn.
export function wallpaperCandidates(settings, dark, home, env = "") {
    const mode = dark ? "dark" : "light";
    const set = settings[`${mode}Wallpaper`] ?? "";
    if (wallpaperColor(set) !== "") {
        return [wallpaperColor(set)];
    }
    const out = [];
    for (const path of [set, env, `~/.config/hypr/wallpaper-${mode}.jpg`, "~/.config/hypr/wallpaper.jpg"]) {
        const full = path === "" ? "" : expandHome(path, home);
        if (full !== "" && !out.includes(full)) {
            out.push(full);
        }
    }
    return out;
}

// The command that asks for a wallpaper, `label`'s (SPEC.md §16): tide-pick,
// the desktop portal's file chooser, offering images, and opening where
// `setting`'s file is, when one is set (not a color).
export function pickCommand(label, setting, home) {
    const command = ["tide-pick", "--images", "--title", label];
    const full = typeof setting === "string" && setting !== "" && wallpaperColor(setting) === "" ? expandHome(setting, home) : "";
    const folder = full.slice(0, full.lastIndexOf("/"));
    if (folder !== "") {
        command.push("--folder", folder);
    }
    return command;
}

// The setting for the file tide-pick chose, from what it printed, `text`:
// a file under `home` as from ~/, so it reads the same on another machine
// sharing appearance.json; "" for none, as when the chooser was cancelled.
export function pickedWallpaper(text, home) {
    const path = String(text ?? "").replace(/\n$/, "");
    if (!path.startsWith("/") || /[\n\r]/.test(path)) {
        return "";
    }
    return home !== "" && path.startsWith(`${home}/`) ? `~/${path.slice(home.length + 1)}` : path;
}

// The folders the wallpaper grid shows (SPEC.md §16): the distro's
// collections (GNOME's, Ubuntu's and Fedora's in backgrounds, Plasma's in
// wallpapers), then your own.
export function galleryFolders(home) {
    return ["/usr/share/backgrounds", "/usr/share/wallpapers", `${home}/Pictures/wallpapers`];
}

// Where the grid's buttons find more wallpapers, each opened in your
// browser (SPEC.md §16), as [{ site, url }]:
// - Unsplash's desktop wallpapers, landscape, free ones only (Unsplash+
//   asks you to pay). It can't search by size.
// - Wallhaven's, general and safe for work only, at least the size of
//   your widest monitor in pixels, `screens` being previewScreens's, and
//   of its shape when it's one Wallhaven names, else landscape or
//   portrait. Its pictures are uploads, with licenses that vary.
export const UNSPLASH = "https://unsplash.com/s/photos/desktop?orientation=landscape&license=free";

// The shapes Wallhaven searches by.
const WALLHAVEN_RATIOS = [[16, 9], [16, 10], [21, 9], [32, 9], [48, 9], [9, 16], [10, 16], [9, 18], [1, 1], [3, 2], [4, 3], [5, 4]];

export function moreWallpapers(screens) {
    let url = "https://wallhaven.cc/search?categories=100&purity=100&sorting=toplist";
    const widest = screens.reduce((a, s) => (a === null || s.width > a.width || (s.width === a.width && s.height > a.height) ? s : a), null);
    if (widest !== null && widest.width > 0 && widest.height > 0) {
        url += `&atleast=${widest.width}x${widest.height}`;
        // 3440×1440, called 21:9, is 2.39 to 21:9's 2.33.
        const shape = widest.width / widest.height;
        const ratio = WALLHAVEN_RATIOS.find(([w, h]) => Math.abs(shape / (w / h) - 1) <= 0.03);
        url += ratio ? `&ratios=${ratio[0]}x${ratio[1]}` : `&ratios=${widest.width >= widest.height ? "landscape" : "portrait"}`;
    }
    return [{ site: "Unsplash", url: UNSPLASH }, { site: "Wallhaven", url }];
}

// The command that opens `url` in your browser.
export function openCommand(url) {
    return ["xdg-open", url];
}

// The pictures the grid can show: Qt decodes these, JPEG XL where
// kimageformats is installed and SVG with Qt's SVG plugin. One it can't
// decode shows its name. tide-pick --list lists the same types.
const GALLERY_TYPES = ["jpg", "jpeg", "png", "webp", "jxl", "svg"];

// The command that lists every picture under `folders` with its size:
// tide-pick --list, which reads each one's header, passes over a folder
// that isn't there, and fails, still listing what it could, when it can't
// read all of one, a subfolder it may not open say.
export function galleryCommand(folders) {
    return ["tide-pick", "--list"].concat(folders);
}

// The grid's pictures from what galleryCommand printed, `text`, a line
// each of width, height and path, tab-separated, as `{ path, name, width,
// height, collection, mode }` sorted by name; a size unknown is 0.
// - collection is galleryCollection's.
// - mode is "light" or "dark" for one of a light and dark pair, else "".
// A Plasma wallpaper is a folder of the same picture at several sizes
// (contents/images/WxH.ext), with its dark version in images_dark: it's
// one picture, or a light one and a dark one, each its largest, named for
// its folder. Its preview and the rest of contents/ aren't shown.
export function galleryImages(text, home = "", distro = "") {
    const plain = new Map();
    const plasma = new Map();
    for (const line of String(text ?? "").split("\n")) {
        const fields = /^(\d+(?:\.\d+)?)\t(\d+(?:\.\d+)?)\t(\/.*)$/.exec(line);
        if (!fields) {
            continue;
        }
        const width = Number(fields[1]);
        const height = Number(fields[2]);
        const path = fields[3];
        const type = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
        if (!GALLERY_TYPES.includes(type)) {
            continue;
        }
        const sized = /^(.*\/([^/]+))\/contents\/(images|images_dark)\/(\d+)x(\d+)\.[^./]+$/.exec(path);
        if (sized) {
            const key = `${sized[1]}\n${sized[3]}`;
            const area = Number(sized[4]) * Number(sized[5]);
            const had = plasma.get(key);
            if (!had || area > had.area) {
                plasma.set(key, { path, name: sized[2], width, height, folder: sized[1], dark: sized[3] === "images_dark", area });
            }
        } else if (!path.includes("/contents/")) {
            const base = path.slice(path.lastIndexOf("/") + 1);
            plain.set(path, { path, name: base.slice(0, base.lastIndexOf(".")), width, height });
        }
    }
    const all = [];
    for (const p of plasma.values()) {
        const paired = plasma.has(`${p.folder}\n${p.dark ? "images" : "images_dark"}`);
        all.push({ path: p.path, name: p.name, width: p.width, height: p.height, mode: paired ? (p.dark ? "dark" : "light") : "" });
    }
    const modes = pictureModes([...plain.keys()]);
    for (const p of plain.values()) {
        all.push(Object.assign({}, p, { mode: modes.get(p.path) }));
    }
    for (const p of all) {
        p.collection = galleryCollection(p.path, home, distro);
    }
    return all.sort((a, b) => a.name.localeCompare(b.name, "en", { sensitivity: "base" }) || a.path.localeCompare(b.path));
}

// A picture's pair, by its name, a size at its end aside: { base, mode }
// for one named as the light or dark one of a pair (GNOME's -l and -d,
// Ubuntu's -light, -dark and dimmed, Fedora's -day and -night), else null.
function pairName(path) {
    const stem = path.slice(0, path.lastIndexOf(".")).replace(/[-_ ]\d+x\d+$/, "");
    const word = /^(.*[-_ ])(dark|dimmed|night|light|day)$/i.exec(stem);
    if (word) {
        return { base: word[1].toLowerCase(), mode: /^(light|day)$/i.test(word[2]) ? "light" : "dark" };
    }
    const letter = /^(.*-)([ld])$/.exec(stem);
    return letter ? { base: `${letter[1]}\n`, mode: letter[2] === "l" ? "light" : "dark" } : null;
}

// Each picture's mode among `paths`: "light" or "dark" when it's named as
// one of a pair and its partner is there too, else "", so a lone
// city-night.jpg shows for either.
function pictureModes(paths) {
    const pairs = new Map();
    for (const path of paths) {
        const p = pairName(path);
        if (p) {
            pairs.set(p.base, (pairs.get(p.base) ?? new Set()).add(p.mode));
        }
    }
    const modes = new Map();
    for (const path of paths) {
        const p = pairName(path);
        modes.set(path, p && pairs.get(p.base).size === 2 ? p.mode : "");
    }
    return modes;
}

// Which collection a picture is in, for the grid's chips: Yours under
// `home`'s ~/Pictures/wallpapers; Plasma's in /usr/share/wallpapers; one
// in a folder of /usr/share/backgrounds by that folder (gnome is GNOME,
// f40 Fedora 40); and one loose in it the distro's, `distro`, as Ubuntu
// installs its own, or Other with none.
export function galleryCollection(path, home, distro = "") {
    if (home !== "" && path.startsWith(`${home}/Pictures/wallpapers/`)) {
        return "Yours";
    }
    if (path.startsWith("/usr/share/wallpapers/")) {
        return "Plasma";
    }
    const sub = /^\/usr\/share\/backgrounds\/(?:([^/]+)\/)?[^/]+$|^\/usr\/share\/backgrounds\/([^/]+)\//.exec(path);
    if (!sub) {
        return "Other";
    }
    const folder = sub[1] ?? sub[2];
    if (folder === undefined) {
        return distro || "Other";
    }
    if (/^gnome$/i.test(folder)) {
        return "GNOME";
    }
    const fedora = /^f(\d+)$/i.exec(folder);
    if (fedora) {
        return `Fedora ${fedora[1]}`;
    }
    return folder.split(/[-_ ]+/).filter(w => w !== "").map(w => w[0].toUpperCase() + w.slice(1)).join(" ");
}

// The distro's name for the grid's chips, from /etc/os-release's `text`:
// its NAME, less a trailing "Linux" or "GNU/Linux", so Fedora Linux is
// Fedora; "" with none.
export function distroName(text) {
    const m = /^NAME=(?:"([^"\n]*)"|'([^'\n]*)'|([^\n]*))$/m.exec(String(text ?? ""));
    const name = m ? (m[1] ?? m[2] ?? m[3] ?? "") : "";
    return name.replace(/\s+(GNU\/)?Linux$/, "").trim();
}

// The collections among `images`, for the grid's chips, by name with
// Yours last; none when there's only one.
export function galleryCollections(images) {
    const names = [...new Set(images.map(i => i.collection))];
    if (names.length < 2) {
        return [];
    }
    return names.sort((a, b) => (a === "Yours") - (b === "Yours") || a.localeCompare(b, "en", { sensitivity: "base" }));
}

// The grid's light and dark filter's choices, and the one it opens on for
// a setting, `key`: Light for lightWallpaper, Dark for darkWallpaper.
export const GALLERY_MODES = ["light", "dark", "any"];

export function galleryModeFor(key) {
    return key === "darkWallpaper" ? "dark" : key === "lightWallpaper" ? "light" : "any";
}

// The pictures `images` the grid shows with its filters: `mode` (one of
// GALLERY_MODES) keeps a pair's picture for that mode, and every picture
// that isn't one of a pair; `collection`, "" for all, keeps that one's.
export function galleryFiltered(images, mode, collection) {
    return images.filter(i => (mode === "any" || i.mode === "" || i.mode === mode) && (collection === "" || i.collection === collection));
}

// How far a picture's shape, width over height, may be from a monitor's
// and still fit it: 2%, so 2560×1080 fits 3440×1440, trimming under 1%,
// where 16:10 on 16:9 trims 10%.
const SHAPE_TOLERANCE = 0.02;

// Whether `image`, {width, height}, is the shape of one of `screens`,
// previewScreens's. One whose size is unknown isn't.
export function fitsScreens(image, screens) {
    if (!(image?.width > 0 && image?.height > 0)) {
        return false;
    }
    const shape = image.width / image.height;
    return screens.some(s => s.width > 0 && s.height > 0 && Math.abs(shape / (s.width / s.height) - 1) <= SHAPE_TOLERANCE);
}

// The grid's rows, `columns` pictures to a row at most (SPEC.md §16): the
// pictures your monitors' shape, then the rest, each in galleryImages's
// order. Each row is { section, heading, images }, section "fits" or
// "others"; heading is the section's, on its first row, and "" on the
// rest, and on every row when all the pictures are in the one section.
export function galleryRows(images, screens, columns) {
    const fits = images.filter(i => fitsScreens(i, screens));
    const others = images.filter(i => !fitsScreens(i, screens));
    const both = fits.length > 0 && others.length > 0;
    const headings = {
        fits: screens.length > 1 ? "Fits one of your screens" : "Fits your screen",
        others: "Other shapes",
    };
    const rows = [];
    for (const [section, list] of [["fits", fits], ["others", others]]) {
        for (let i = 0; i < list.length; i += columns) {
            rows.push({ section, heading: both && i === 0 ? headings[section] : "", images: list.slice(i, i + columns) });
        }
    }
    return rows;
}

// The command that prints the first of `paths` that's a regular file it
// can read, or exits 1 with none: so a directory, which `test -r` alone
// passes, isn't taken for a picture.
export function findCommand(paths) {
    return ["sh", "-c", 'for f; do if test -f "$f" && test -r "$f"; then printf %s "$f"; exit 0; fi; done; exit 1', "sh"].concat(paths);
}

// `candidates` less those the shell found it couldn't draw, a corrupt
// image say, so the next is tried.
export function drawableCandidates(candidates, undrawable) {
    return candidates.filter(c => !undrawable.includes(c));
}

// What the shell writes for the lock to draw (SPEC.md §15): the wallpaper
// it draws now, on a line: a file's path, which the lock blurs, a color as
// #rrggbb, or an empty line for none; then the position (POSITIONS) on a
// line of its own, so the lock frames a picture as the shell does; then,
// when `dark` is given, "dark" or "light", which the lock's face follows
// (SPEC.md §10). Never
// empty: Quickshell 0.3.1's FileView.setText skips text equal to what it
// holds, and a file that doesn't exist holds "", so it could never be
// written empty.
export function wallpaperRecord(wallpaper, position = "fill", dark = undefined) {
    const mode = dark === undefined ? "" : `${dark ? "dark" : "light"}\n`;
    return `${wallpaper}\n${position}\n${mode}`;
}

// The wallpaper a record the shell wrote names: {path, color, position},
// path and color each "" but the one it is, both "" for none, and `dark`
// when the record says light or dark (absent from older records). One that's
// neither a file's absolute path nor a color on a line, or whose position
// isn't one, is none, with an error. A record from before positions, the
// wallpaper's line alone, is "fill", as the shell drew it then; one from
// before colors, a path or none, reads as it did.
export function recordedWallpaper(text) {
    const lines = (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n");
    const none = error => ({ path: "", color: "", position: "fill", error });
    if (lines.length > 3 || (lines.length === 3 && !["dark", "light"].includes(lines[2]))) {
        return none("expected a file's absolute path or a color, on a line of its own, then a position, then dark or light");
    }
    const line = lines[0];
    const position = lines.length > 1 ? lines[1] : "fill";
    if (!POSITIONS.includes(position)) {
        return none(`expected a position, one of ${POSITIONS.join(", ")}, on the line after the wallpaper`);
    }
    const withMode = r => (lines.length === 3 ? Object.assign(r, { dark: lines[2] === "dark" }) : r);
    if (line === "") {
        return withMode({ path: "", color: "", position });
    }
    if (wallpaperColor(line) !== "") {
        return withMode({ path: "", color: wallpaperColor(line), position });
    }
    if (!line.startsWith("/") || /[\r\0]/.test(line)) {
        return none("expected a file's absolute path or a color, on a line of its own");
    }
    return withMode({ path: line, color: "", position });
}

// A file's path as a file: URL, each part escaped, so a name with a space,
// a # or a ? still names the file.
export function fileUrl(path) {
    return "file://" + path.split("/").map(encodeURIComponent).join("/");
}

// Where a picture lands on a monitor (SPEC.md §15), for the Appearance
// page's preview (§16). `image` and `screen` are {width, height} in pixels;
// `position` is one of POSITIONS:
// - "fill" scales it to cover the monitor, centered, as swaybg's fill
//   does, trimming what's left over;
// - "fill-top" covers it too, keeping the top and trimming the bottom;
// - "fill-bottom" keeps the bottom and trims the top;
// - "fit" shows all of it, centered, with bars where it doesn't reach;
// - "stretch" shows all of it across the whole monitor, out of its shape
//   where the two shapes differ.
// A picture wider than the monitor is trimmed equally at the sides in each
// fill: the position only chooses which way a tall one gives.
// Returns null until both sizes are known (an image still loading), or:
// - scale: monitor pixels per picture pixel, across;
// - scaleY: the same, down: scale but for "stretch";
// - shown: the picture's size on the monitor, {width, height};
// - frame: the monitor's rectangle in the picture's pixels, {x, y, width,
//   height};
// - visible: the part of the picture the monitor shows, the same way;
// - trimmed: the fraction of the picture's width or height cut off each
//   side, {top, bottom, left, right};
// - bars: the width of each bar beside the picture, {x, y}, in the
//   monitor's pixels: none but for "fit".
export function wallpaperFrame(image, screen, position = "fill") {
    if (!(image?.width > 0 && image?.height > 0 && screen?.width > 0 && screen?.height > 0)) {
        return null;
    }
    if (!POSITIONS.includes(position)) {
        throw new Error(`unknown wallpaper position: ${position}`);
    }
    if (position === "stretch") {
        return {
            scale: screen.width / image.width,
            scaleY: screen.height / image.height,
            shown: { width: screen.width, height: screen.height },
            frame: { x: 0, y: 0, width: image.width, height: image.height },
            visible: { x: 0, y: 0, width: image.width, height: image.height },
            trimmed: { top: 0, bottom: 0, left: 0, right: 0 },
            bars: { x: 0, y: 0 },
        };
    }
    const fit = position === "fit";
    const scale = (fit ? Math.min : Math.max)(screen.width / image.width, screen.height / image.height);
    const width = screen.width / scale;
    const height = screen.height / scale;
    const spare = image.height - height;
    const y = position === "fill-top" ? 0 : position === "fill-bottom" ? spare : spare / 2;
    const frame = { x: (image.width - width) / 2, y, width, height };
    const x0 = Math.max(0, frame.x);
    const y0 = Math.max(0, frame.y);
    const x1 = Math.min(image.width, frame.x + frame.width);
    const y1 = Math.min(image.height, frame.y + frame.height);
    return {
        scale,
        scaleY: scale,
        shown: { width: image.width * scale, height: image.height * scale },
        frame,
        visible: { x: x0, y: y0, width: x1 - x0, height: y1 - y0 },
        trimmed: {
            top: y0 / image.height,
            bottom: (image.height - y1) / image.height,
            left: x0 / image.width,
            right: (image.width - x1) / image.width,
        },
        bars: { x: Math.max(0, -frame.x * scale), y: Math.max(0, -frame.y * scale) },
    };
}

// One monitor's line under the preview: what it shows of the picture, in
// the monitor's pixels. `name` is the monitor's, or several joined.
export function framingCaption(name, image, screen, position = "fill") {
    const f = wallpaperFrame(image, screen, position);
    if (f === null) {
        return "";
    }
    const size = `${name}, ${screen.width}×${screen.height}`;
    const w = Math.round(f.shown.width);
    const h = Math.round(f.shown.height);
    const px = (fraction, whole) => Math.round(fraction * whole);
    const parts = (a, aName, b, bName, whole) => [[a, aName], [b, bName]]
        .filter(([v]) => px(v, whole) > 0).map(([v, side]) => `${px(v, whole)} px ${side}`).join(", ");
    const t = f.trimmed;
    const bars = { x: Math.round(f.bars.x), y: Math.round(f.bars.y) };
    // Out of shape by how much wider or taller the monitor is than the
    // picture, to the nearest percent.
    const wider = Math.round((f.scale / f.scaleY - 1) * 100);
    const taller = Math.round((f.scaleY / f.scale - 1) * 100);
    if (wider > 0) {
        return `${size}: stretches all of it to ${w}×${h}, ${wider}% wider`;
    }
    if (taller > 0) {
        return `${size}: stretches all of it to ${w}×${h}, ${taller}% taller`;
    }
    if (bars.x > 0) {
        return `${size}: shows all of it at ${w}×${h}, with ${bars.x} px bars left and right`;
    }
    if (bars.y > 0) {
        return `${size}: shows all of it at ${w}×${h}, with ${bars.y} px bars top and bottom`;
    }
    if (px(t.top + t.bottom, h) > 0) {
        return `${size}: scaled to ${w}×${h}, trims ${Math.round((t.top + t.bottom) * 100)}% of its height (${parts(t.top, "top", t.bottom, "bottom", h)})`;
    }
    if (px(t.left + t.right, w) > 0) {
        return `${size}: scaled to ${w}×${h}, trims ${Math.round((t.left + t.right) * 100)}% of its width (${parts(t.left, "left", t.right, "right", w)})`;
    }
    return `${size}: shows all of it, scaled to ${w}×${h}`;
}

// The monitors a preview is drawn for, from Quickshell.screens' {name,
// width, height, devicePixelRatio}: each size once, in pixels, with the
// names of the monitors that have it, so two alike share one preview.
export function previewScreens(screens) {
    const out = [];
    for (const s of screens) {
        const width = Math.round(s.width * (s.devicePixelRatio || 1));
        const height = Math.round(s.height * (s.devicePixelRatio || 1));
        if (!(width > 0 && height > 0)) {
            continue;
        }
        const same = out.find(o => o.width === width && o.height === height);
        if (same) {
            same.name = `${same.name}, ${s.name}`;
        } else {
            out.push({ name: String(s.name ?? ""), width, height });
        }
    }
    return out;
}

// A preview's drawing, at most `maxWidth` by `maxHeight`: the picture and
// the monitor's frame over it, and the parts of the picture outside the
// frame, which are dimmed; each {x, y, width, height} in the preview's own
// pixels. A frame bigger than the picture ("fit") is drawn whole, its bars
// around the picture. null while wallpaperFrame is.
export function previewLayout(image, screen, position, maxWidth, maxHeight) {
    const f = wallpaperFrame(image, screen, position);
    if (f === null) {
        return null;
    }
    if (position === "stretch") {
        // The whole picture in the monitor's shape, as it's drawn there.
        const k = Math.min(maxWidth / screen.width, maxHeight / screen.height);
        const w = screen.width * k;
        const h = screen.height * k;
        return { width: w, height: h, image: { x: 0, y: 0, width: w, height: h }, frame: { x: 0, y: 0, width: w, height: h }, dims: [] };
    }
    const x0 = Math.min(0, f.frame.x);
    const y0 = Math.min(0, f.frame.y);
    const x1 = Math.max(image.width, f.frame.x + f.frame.width);
    const y1 = Math.max(image.height, f.frame.y + f.frame.height);
    const k = Math.min(maxWidth / (x1 - x0), maxHeight / (y1 - y0));
    const rect = (x, y, width, height) => ({ x: (x - x0) * k, y: (y - y0) * k, width: width * k, height: height * k });
    const v = f.visible;
    const dims = [
        rect(0, 0, image.width, v.y),
        rect(0, v.y + v.height, image.width, image.height - v.y - v.height),
        rect(0, v.y, v.x, v.height),
        rect(v.x + v.width, v.y, image.width - v.x - v.width, v.height),
    ].filter(r => r.width > 0.01 && r.height > 0.01);
    return {
        width: (x1 - x0) * k,
        height: (y1 - y0) * k,
        image: rect(0, 0, image.width, image.height),
        frame: rect(f.frame.x, f.frame.y, f.frame.width, f.frame.height),
        dims,
    };
}

// The pictures the Appearance page may preview for light or `dark`, in
// order, the next tried when one can't load. For the mode showing now
// (`nowDark`), only `drawn`, the file the shell draws (WallpaperData), or
// none for a color. For the other, its candidates, as the shell would look
// for them (wallpaperCandidates). A color is never previewed.
export function previewCandidates(settings, dark, nowDark, drawn, home, env = "") {
    if (dark === nowDark) {
        return drawn === "" ? [] : [drawn];
    }
    const set = settings[`${dark ? "dark" : "light"}Wallpaper`] ?? "";
    if (wallpaperColor(set) !== "") {
        return [];
    }
    return wallpaperCandidates(settings, dark, home, env);
}

// The position in effect for light or `dark`: the mode's own, else
// wallpaperPosition, else fill.
export function wallpaperPosition(settings, dark) {
    return settings[dark ? "darkWallpaperPosition" : "lightWallpaperPosition"] ?? settings.wallpaperPosition ?? "fill";
}

// How Wallpaper.qml and the lock place a picture at `position`: fitted,
// stretched or cropped, and which edge to keep, as Qt's Image fillMode and
// verticalAlignment take them. Qt crops from the side its alignment is
// away from (QQuickImage::updatePaintNode), so this draws what
// wallpaperFrame says. A picture wider than the monitor stays centered.
export function wallpaperPlacement(position) {
    return {
        fit: position === "fit",
        stretch: position === "stretch",
        vertical: position === "fill-top" ? "top" : position === "fill-bottom" ? "bottom" : "center",
    };
}

// The Appearance page's positions (SPEC.md §16), in the order ‹ and › step
// through them.
export const POSITION_CHOICES = Object.freeze([
    Object.freeze({ position: "fill", label: "Fill, centered" }),
    Object.freeze({ position: "fill-top", label: "Fill, keep top" }),
    Object.freeze({ position: "fill-bottom", label: "Fill, keep bottom" }),
    Object.freeze({ position: "fit", label: "Fit whole picture" }),
    Object.freeze({ position: "stretch", label: "Stretch to fill" }),
]);

// The index in POSITION_CHOICES of `settings`' position for light or
// `dark`.
export function positionAt(settings, dark) {
    return Math.max(0, POSITION_CHOICES.findIndex(c => c.position === wallpaperPosition(settings, dark)));
}

// The index `steps` steps through POSITION_CHOICES from `at`, stopping at
// either end.
export function steppedPositionAt(at, steps) {
    return Math.max(0, Math.min(POSITION_CHOICES.length - 1, at + steps));
}

// The greeter's copy of a user's look (SPEC.md §11, §15): what the shell
// keeps in LOOK_ROOT/<user>/ for the greeter, which runs as greetd's own
// user and can't read the user's home. `setup` makes the folder, owned by
// the user and readable by all. TIDE_LOOK_DIR names another root, for the
// tests.
export const LOOK_ROOT = "/var/lib/tide/look";

// The folder for `user`'s look, under `root` (LOOK_ROOT when ""), or "" when
// the user's name couldn't be a folder's.
export function lookDir(root, user) {
    const name = String(user ?? "");
    if (name === "" || name === "." || name === ".." || name.includes("/")) {
        return "";
    }
    return `${root || LOOK_ROOT}/${name}`;
}

// The command that copies each mode's wallpaper into the look folder `dir`
// as the file `light` or `dark`: the first of that mode's candidates that's
// a regular file it can read, as findCommand takes them. The light ones
// come first, then "--", then the dark ones (candidates are absolute paths,
// so never "--"). A copy that's already the same is left be, and a mode
// with none has its file removed. It prints each mode it has a file for, a
// line apiece, and exits 2 when `dir` isn't a folder it can write, which
// `setup` hasn't made yet, or 1 when a copy failed, having said why.
export const LOOK_SCRIPT = [
    'dir=$1',
    'shift',
    'test -d "$dir" && test -w "$dir" || exit 2',
    'status=0',
    // copy MODE CANDIDATE... [-- ...]: the first readable file before any
    // "--", copied in as MODE unless it's there already.
    'copy() {',
    '    mode=$1',
    '    shift',
    '    found=',
    '    for f; do',
    '        test "$f" = -- && break',
    '        if test -z "$found" && test -f "$f" && test -r "$f"; then found=$f; fi',
    '    done',
    '    if test -z "$found"; then',
    '        rm -f -- "$dir/$mode" || status=1',
    '        return',
    '    fi',
    '    if ! cmp -s -- "$found" "$dir/$mode" 2>/dev/null; then',
    '        if ! { cp -- "$found" "$dir/.$mode.tmp" && chmod 644 "$dir/.$mode.tmp" && mv -f -- "$dir/.$mode.tmp" "$dir/$mode"; }; then',
    '            rm -f -- "$dir/.$mode.tmp"',
    '            status=1',
    '            return',
    '        fi',
    '    fi',
    '    echo "$mode"',
    '}',
    'copy light "$@"',
    'while test $# -gt 0 && test "$1" != --; do shift; done',
    'test $# -gt 0 && shift',
    'copy dark "$@"',
    'exit $status',
].join("\n");

// LOOK_SCRIPT's command: `light` and `dark` are each mode's candidates
// (wallpaperCandidates'), a color being none to copy.
export function lookCommand(dir, light, dark) {
    const files = list => list.filter(c => wallpaperColor(c) === "");
    return ["sh", "-c", LOOK_SCRIPT, "sh", dir].concat(files(light), ["--"], files(dark));
}

// Which modes LOOK_SCRIPT has a file for, from what it printed.
export function lookCopied(text) {
    const lines = String(text ?? "").split("\n");
    return { light: lines.includes("light"), dark: lines.includes("dark") };
}

// The command that writes `json` as `dir`/look.json, by rename, readable
// by all whatever the umask: the greeter reads it as greetd's user.
export function lookWriteCommand(dir, json) {
    return ["sh", "-c", 'printf %s "$2" >"$1/.look.json.tmp" && chmod 644 "$1/.look.json.tmp" && mv -f -- "$1/.look.json.tmp" "$1/look.json" || { rm -f -- "$1/.look.json.tmp"; exit 1; }', "sh", dir, json];
}

// The look the greeter shows (SPEC.md §11), as the JSON the shell writes
// beside the copies: the settings that decide light or dark, and for each
// mode its color, or whether there's a file, and its position. `settings`
// are AppearanceData's, `light` and `dark` each mode's candidates, and
// `copied` lookCopied's.
export function lookJson(settings, light, dark, copied) {
    const look = {};
    for (const key of THEME_KEYS) {
        if (settings[key] !== undefined) {
            look[key] = settings[key];
        }
    }
    const mode = (candidates, isDark) => {
        const color = candidates.length === 1 ? wallpaperColor(candidates[0]) : "";
        return {
            color,
            image: color === "" && Boolean(isDark ? copied.dark : copied.light),
            position: wallpaperPosition(settings, isDark),
        };
    };
    look.lightWallpaper = mode(light, false);
    look.darkWallpaper = mode(dark, true);
    return JSON.stringify(look, null, 2) + "\n";
}

// A look file's text as {look} or {error}: its settings checked as
// appearance.json's are, and each mode's wallpaper.
export function parseLook(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: "expected an object" };
    }
    const theme = {};
    for (const key of THEME_KEYS) {
        if (value[key] !== undefined) {
            theme[key] = value[key];
        }
    }
    const parsed = parseAppearance(JSON.stringify(theme));
    if (parsed.error) {
        return { error: parsed.error };
    }
    const settings = Object.assign({}, DEFAULTS, parsed.settings);
    const wrong = checkSettings(settings);
    if (wrong) {
        return { error: wrong };
    }
    const look = { settings };
    for (const name of ["lightWallpaper", "darkWallpaper"]) {
        const w = value[name] ?? {};
        const color = w.color ? wallpaperColor(w.color) : "";
        if (w.color && color === "") {
            return { error: `${name}.color must be a color as #rrggbb` };
        }
        const position = w.position ?? "fill";
        if (!POSITIONS.includes(position)) {
            return { error: `${name}.position must be one of ${POSITIONS.join(", ")}` };
        }
        look[name] = { color, image: w.image === true && color === "", position };
    }
    return { look };
}

// What the greeter draws at `now` for a look parseLook gave, kept in
// `dir`: {dark, next, path, color, position}, `path` the mode's copy or "",
// and `next` the instant of the next change or null.
export function lookAt(look, now, dir, clock = LOCAL) {
    const plan = scheduled(look.settings, now, clock);
    const w = plan.dark ? look.darkWallpaper : look.lightWallpaper;
    return {
        dark: plan.dark,
        next: plan.next,
        path: w.image ? `${dir}/${plan.dark ? "dark" : "light"}` : "",
        color: w.color,
        position: w.position,
    };
}

