// The layout symbol after the workspaces (SPEC.md §6.1, §7.1), and the
// settings panel's Layouts page (§16), as pure functions the QML binds to. hypr/tide/layout.lua keeps each
// workspace's mode and announces it on Hyprland's event socket as
// `custom>>tide-layout>>WORKSPACE,MODE`, on each change and whenever
// the workspace becomes active. The bar can't ask for a mode, so until a
// workspace's first announcement (a shell that just started) it assumes the
// layout's default.

export const SYMBOLS = Object.freeze({
    tile: "[]=",
    threecol: "|M|",
    twocol: "||=",
    monocle: "[M]",
});

import { jsonError } from "./clocks.mjs";

// layout.lua's default `ultrawide_aspect`: a workspace starts in the
// ultrawide mode at and above this work-area aspect, and in the normal one
// below it.
export const ULTRAWIDE = 2.1;

// layout.lua's M.defaults for what layouts.json can set, in the file's
// names: the same, camelCased. layouts_test.mjs checks they agree.
export const DEFAULT_LAYOUTS = Object.freeze({
    ultrawideAspect: ULTRAWIDE,
    defaultMode: Object.freeze({ normal: "tile", ultrawide: "threecol" }),
    modes: Object.freeze({
        tile: Object.freeze({ mfact: 0.55, nmaster: 1 }),
        threecol: Object.freeze({ mfact: 0.5, nmaster: 1 }),
        twocol: Object.freeze({ mfact: 0.72, nmaster: 2 }),
    }),
    single: Object.freeze([
        Object.freeze({ minAspect: 2.1, width: 0.8 }),
        Object.freeze({ minAspect: 3.2, width: 0.6 }),
    ]),
});

const PREFIX = "tide-layout>>";

// The mode layout.lua gives a new workspace on a monitor `width` x `height`
// pixels at `scale`, rotated by Hyprland's `transform` (odd values turn it
// 90°), less the `reserved` logical pixels the bar takes from the top.
// `layouts` is the settings in effect (effectiveLayouts), the defaults
// until they're read.
export function defaultMode({ width, height, scale = 1, transform = 0 }, reserved = 0, layouts = DEFAULT_LAYOUTS) {
    const [w, h] = transform % 2 ? [height, width] : [width, height];
    const area = h / scale - reserved;
    const wide = area > 0 && w / scale / area >= layouts.ultrawideAspect;
    return wide ? layouts.defaultMode.ultrawide : layouts.defaultMode.normal;
}

// The {workspace, mode} a custom event's data announces, or null when it's
// another custom event or names a mode this bar doesn't know.
export function parseAnnouncement(data) {
    if (typeof data !== "string" || !data.startsWith(PREFIX)) {
        return null;
    }
    const m = /^(-?\d+),([a-z]+)$/.exec(data.slice(PREFIX.length));
    if (!m || !Object.prototype.hasOwnProperty.call(SYMBOLS, m[2])) {
        return null;
    }
    return { workspace: Number(m[1]), mode: m[2] };
}

// What the bar shows for `mode` with `tiled` tiled windows on the workspace.
// Monocle shows how many windows it hides, `[n]`, and `[M]` while it hides
// none; an unknown mode shows nothing.
export function layoutSymbol(mode, tiled) {
    if (mode === "monocle" && tiled > 1) {
        return `[${tiled - 1}]`;
    }
    return SYMBOLS[mode] ?? "";
}

// The modes a workspace can start in, in the order ‹ and › step through
// them, with what the page calls them.
export const MODE_NAMES = Object.freeze([
    Object.freeze({ mode: "tile", label: "Tile" }),
    Object.freeze({ mode: "threecol", label: "Three columns" }),
    Object.freeze({ mode: "twocol", label: "Two columns" }),
    Object.freeze({ mode: "monocle", label: "Monocle" }),
]);

const START_MODES = MODE_NAMES.map(m => m.mode);
// The fewest masters each mode takes, as layout.lua's removemaster allows.
const MIN_MASTERS = Object.freeze({ tile: 0, threecol: 1, twocol: 1 });

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function numberError(path, v, lo, hi, whole = false) {
    if (typeof v !== "number" || !(v >= lo && v <= hi) || (whole && v % 1 !== 0)) {
        return `${path} must be ${whole ? "a whole number" : "a number"} from ${lo} to ${hi}`;
    }
    return "";
}

// What's wrong with one file's settings, by layout.lua's schema, or "".
function settingsError(v) {
    if (!isObject(v)) {
        return "expected an object of settings";
    }
    for (const key of Object.keys(v)) {
        const x = v[key];
        let err = "";
        if (key === "ultrawideAspect") {
            err = numberError(key, x, 0.1, 100);
        } else if (key === "defaultMode") {
            if (!isObject(x)) {
                err = "defaultMode must be an object of normal and ultrawide";
            }
            for (const k of isObject(x) ? Object.keys(x) : []) {
                if (k !== "normal" && k !== "ultrawide") {
                    err = err || `defaultMode.${k} is not a setting`;
                } else if (!START_MODES.includes(x[k])) {
                    err = err || `defaultMode.${k} must be one of ${START_MODES.join(", ")}`;
                }
            }
        } else if (key === "modes") {
            if (!isObject(x)) {
                err = "modes must be an object of tile, threecol and twocol";
            }
            for (const mode of isObject(x) ? Object.keys(x) : []) {
                const m = x[mode];
                if (!Object.prototype.hasOwnProperty.call(MIN_MASTERS, mode)) {
                    err = err || `modes.${mode} is not a setting`;
                } else if (!isObject(m)) {
                    err = err || `modes.${mode} must be an object of mfact and nmaster`;
                } else {
                    for (const k of Object.keys(m)) {
                        if (k === "mfact") {
                            err = err || numberError(`modes.${mode}.mfact`, m[k], 0.1, 0.9);
                        } else if (k === "nmaster") {
                            err = err || numberError(`modes.${mode}.nmaster`, m[k], MIN_MASTERS[mode], 100, true);
                        } else {
                            err = err || `modes.${mode}.${k} is not a setting`;
                        }
                    }
                }
            }
        } else if (key === "single") {
            if (!Array.isArray(x)) {
                err = "single must be a list of {minAspect, width}";
            }
            (Array.isArray(x) ? x : []).forEach((rule, i) => {
                const at = `single entry ${i + 1}`;
                if (!isObject(rule)) {
                    err = err || `${at} must be {minAspect, width}`;
                    return;
                }
                for (const k of Object.keys(rule)) {
                    if (k !== "minAspect" && k !== "width") {
                        err = err || `${at}: ${k} is not a setting`;
                    }
                }
                err = err || numberError(`${at}: minAspect`, rule.minAspect, 0, 100);
                err = err || numberError(`${at}: width`, rule.width, 0.1, 1);
            });
        } else {
            err = `unknown setting "${key}"`;
        }
        if (err) {
            return err;
        }
    }
    return "";
}

// One layouts.json: {settings} or {error}, never throws.
export function parseLayouts(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    const err = settingsError(value);
    return err ? { error: err } : { settings: value };
}

// `over` merged into `base`: objects key by key, lists and values whole
// (SPEC.md §16.1). Neither is changed.
function merged(base, over) {
    const out = Object.assign({}, base);
    for (const key of Object.keys(over)) {
        out[key] = isObject(base[key]) && isObject(over[key]) ? merged(base[key], over[key]) : over[key];
    }
    return out;
}

// The settings from layouts.json and layouts.local.json, each the file's
// text or null when it doesn't exist: only what they set, the local file's
// over the shared one's. A file that doesn't parse keeps `lastGood`, and
// `errors` names every file that's wrong: {settings, errors}.
export function loadLayouts(sharedText, localText, lastGood = {}) {
    const errors = [];
    let settings = {};
    for (const [name, text] of [["layouts.json", sharedText], ["layouts.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseLayouts(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        settings = merged(settings, parsed.settings);
    }
    return errors.length > 0 ? { settings: lastGood, errors } : { settings, errors };
}

// The settings in effect: what's set, over layout.lua's defaults.
export function effectiveLayouts(settings) {
    return merged(DEFAULT_LAYOUTS, settings);
}

// A setting's value in effect, by its path ("modes.tile.mfact").
export function shownLayout(settings, path) {
    return path.split(".").reduce((v, k) => (v === undefined || v === null ? undefined : v[k]), effectiveLayouts(settings));
}

// The page's − and + for a number setting: its step and its range, inside
// layout.lua's.
const STEPS = Object.freeze({
    ultrawideAspect: { step: 0.1, lo: 1, hi: 5 },
    mfact: { step: 0.05, lo: 0.1, hi: 0.9 },
    nmaster: { step: 1, lo: 0, hi: 9 },
    width: { step: 0.05, lo: 0.1, hi: 1 },
});

// A number setting moved `steps` steps, stopping at either end; `path`'s
// last part names its kind, and a mode's nmaster stops at that mode's
// fewest masters. The files accept more than the page's range, and a value
// set past an end stays put rather than jumping back across it.
export function steppedLayout(path, value, steps) {
    const parts = path.split(".");
    const kind = parts[parts.length - 1];
    const s = STEPS[kind];
    const lo = kind === "nmaster" ? MIN_MASTERS[parts[1]] : s.lo;
    const next = Math.round((value + steps * s.step) / s.step) * s.step;
    // Rounded to the step's places, so 0.55 + 0.05 is 0.6, not 0.6000000001.
    const clamped = Math.max(lo, Math.min(s.hi, Number(next.toFixed(2))));
    return (steps > 0 && clamped < value) || (steps < 0 && clamped > value) ? value : clamped;
}

// How the page shows a number setting: a share as a percentage.
export function formatLayout(path, value) {
    const kind = path.split(".").pop();
    if (kind === "mfact" || kind === "width") {
        return `${Math.round(value * 100)}%`;
    }
    if (kind === "ultrawideAspect") {
        return value.toFixed(1);
    }
    return String(value);
}

// layouts.local.json's text with the setting at `path` ("modes.tile.mfact",
// or "single" for the whole list, which a list always is) set to `value`,
// keeping whatever else it says. Each text is the file's, or null when it
// doesn't exist; the settings panel writes only the .local file (§16.1). A
// bad value or a file that doesn't parse (never overwritten) is an {error}.
export function withLayoutSetting(localText, path, value, sharedText = null) {
    const files = {};
    for (const [name, text] of [["layouts.json", sharedText], ["layouts.local.json", localText]]) {
        if (text === null || text === undefined) {
            files[name] = {};
            continue;
        }
        const parsed = parseLayouts(text);
        if (parsed.error) {
            return { error: `${name}: ${parsed.error}` };
        }
        files[name] = parsed.settings;
    }
    const parts = path.split(".");
    let change = value;
    for (let i = parts.length - 1; i >= 0; i--) {
        change = { [parts[i]]: change };
    }
    const err = settingsError(change);
    if (err) {
        return { error: err };
    }
    return { text: JSON.stringify(merged(files["layouts.local.json"], change), null, 2) + "\n" };
}

function luaValue(v) {
    return typeof v === "string" ? `"${v}"` : String(v);
}

// What's set, as the Lua table layout.lua reads from tide-layouts.lua, in
// setup()'s option names. Mode names and numbers are all it holds, so it
// needs no escapes.
export function layoutsLua(settings) {
    const lines = [
        "-- Written by tide from layouts.json and layouts.local.json (tide SPEC.md §16).",
        "-- Change those, or the Layouts page of tide's settings, not this file. Only",
        "-- what's set is here; hypr/tide/layout.lua has the rest.",
        "return {",
    ];
    if (settings.ultrawideAspect !== undefined) {
        lines.push(`    ultrawide_aspect = ${luaValue(settings.ultrawideAspect)},`);
    }
    if (settings.defaultMode !== undefined) {
        const fields = ["normal", "ultrawide"].filter(k => settings.defaultMode[k] !== undefined)
            .map(k => `${k} = ${luaValue(settings.defaultMode[k])}`);
        lines.push(`    default_mode = { ${fields.join(", ")} },`);
    }
    if (settings.modes !== undefined) {
        const modes = ["tile", "threecol", "twocol"].filter(m => settings.modes[m] !== undefined).map(m => {
            const fields = ["mfact", "nmaster"].filter(k => settings.modes[m][k] !== undefined)
                .map(k => `${k} = ${luaValue(settings.modes[m][k])}`);
            return `${m} = { ${fields.join(", ")} }`;
        });
        lines.push(`    modes = { ${modes.join(", ")} },`);
    }
    if (settings.single !== undefined) {
        const rules = settings.single.map(r => `{ min_aspect = ${luaValue(r.minAspect)}, width = ${luaValue(r.width)} }`);
        lines.push(`    single = { ${rules.join(", ")} },`);
    }
    lines.push("}");
    return lines.join("\n") + "\n";
}

// The Layouts page's rows, from the settings in effect: a heading, a
// mode ‹ and › step through ("mode"), a number − and + step ("number"),
// or a lone window's width by aspect ("single", which sets the whole list,
// since a list is set whole).
export function layoutRows(effective) {
    const rows = [
        { kind: "number", path: "ultrawideAspect", label: "Ultrawide from aspect" },
        { kind: "mode", path: "defaultMode.normal", label: "Other monitors start in" },
        { kind: "mode", path: "defaultMode.ultrawide", label: "Ultrawides start in" },
        { kind: "heading", label: "MASTER WIDTH" },
    ];
    const modes = [["tile", "Tile"], ["threecol", "Three columns"], ["twocol", "Two columns"]];
    for (const [mode, label] of modes) {
        rows.push({ kind: "number", path: `modes.${mode}.mfact`, label });
    }
    rows.push({ kind: "heading", label: "MASTERS" });
    for (const [mode, label] of modes) {
        rows.push({ kind: "number", path: `modes.${mode}.nmaster`, label });
    }
    if (effective.single.length > 0) {
        rows.push({ kind: "heading", label: "A LONE WINDOW'S WIDTH" });
    }
    effective.single.forEach((rule, index) => {
        rows.push({ kind: "single", path: "single", index, label: `Aspect ${rule.minAspect} and up` });
    });
    return rows;
}

// The single-window rules with rule `index`'s width moved `steps` steps.
export function steppedSingle(single, index, steps) {
    return single.map((rule, i) => i === index
        ? { minAspect: rule.minAspect, width: steppedLayout("single.width", rule.width, steps) }
        : { minAspect: rule.minAspect, width: rule.width });
}
