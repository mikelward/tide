// The settings panel's Displays page (SPEC.md §16): each monitor's scale and
// where it goes beside the others, as pure functions the QML binds to.
//
// A monitor is named by its description as `hyprctl monitors` gives it
// ("Dell Inc. DELL U2720Q 1234ABC"), not its port, so its settings follow
// it from one port to another; conf's hyprland.lua passes it to
// hl.monitor as `desc:` and the description.

import { jsonError } from "./clocks.mjs";
import { stepped } from "./steps.mjs";

// The places a monitor can go, as Hyprland 0.56's monitor rules name them
// (src/config/shared/monitor/Parser.cpp's parsePosition), in the order ‹
// and › step through them.
export const POSITIONS = Object.freeze([
    Object.freeze({ position: "auto", label: "Automatic" }),
    Object.freeze({ position: "auto-right", label: "To the right" }),
    Object.freeze({ position: "auto-left", label: "To the left" }),
    Object.freeze({ position: "auto-up", label: "Above" }),
    Object.freeze({ position: "auto-down", label: "Below" }),
]);

// The page's − and + move a scale this much, inside Hyprland's floor of
// 0.25. Hyprland may choose the nearest scale that divides the monitor's
// pixels evenly.
export const SCALE_STEP = 0.25;
const SCALE_LO = 0.5;
const SCALE_HI = 3;

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// What's wrong with one monitor's settings, or "".
function monitorError(name, m) {
    if (!isObject(m)) {
        return `monitors."${name}" must be an object of scale and position`;
    }
    for (const key of Object.keys(m)) {
        const v = m[key];
        if (key === "scale") {
            if (typeof v !== "number" || !(v >= 0.25 && v <= 10)) {
                return `monitors."${name}".scale must be a number from 0.25 to 10`;
            }
        } else if (key === "position") {
            if (!POSITIONS.some(p => p.position === v)) {
                return `monitors."${name}".position must be one of ${POSITIONS.map(p => p.position).join(", ")}`;
            }
        } else {
            return `monitors."${name}".${key} is not a setting`;
        }
    }
    return "";
}

// What's wrong with one file's settings, or "".
function settingsError(v) {
    if (!isObject(v)) {
        return "expected an object of settings";
    }
    for (const key of Object.keys(v)) {
        if (key !== "monitors") {
            return `unknown setting "${key}"`;
        }
        if (!isObject(v.monitors)) {
            return "monitors must be an object, each monitor by its description";
        }
        for (const name of Object.keys(v.monitors)) {
            if (name === "" || /[\u0000-\u001f\u007f]/.test(name)) {
                return "a monitor's description must be one line of text";
            }
            const err = monitorError(name, v.monitors[name]);
            if (err) {
                return err;
            }
        }
    }
    return "";
}

// One outputs.json: {settings} or {error}, never throws.
export function parseOutputs(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    const err = settingsError(value);
    return err ? { error: err } : { settings: value };
}

function merged(base, over) {
    const out = Object.assign({}, base);
    for (const key of Object.keys(over)) {
        out[key] = isObject(base[key]) && isObject(over[key]) ? merged(base[key], over[key]) : over[key];
    }
    return out;
}

// The settings from outputs.json and outputs.local.json, each the file's
// text or null when it doesn't exist: the local file's over the shared
// one's, monitor by monitor and setting by setting (SPEC.md §16.1). A file
// that doesn't parse keeps `lastGood`, and `errors` names every file
// that's wrong: {settings, errors}.
export function loadOutputs(sharedText, localText, lastGood = {}) {
    const errors = [];
    let settings = {};
    for (const [name, text] of [["outputs.json", sharedText], ["outputs.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseOutputs(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        settings = merged(settings, parsed.settings);
    }
    return errors.length > 0 ? { settings: lastGood, errors } : { settings, errors };
}

// One monitor's settings: {} when it has none.
export function monitorSettings(settings, description) {
    const monitors = settings.monitors || {};
    return Object.prototype.hasOwnProperty.call(monitors, description) ? monitors[description] : {};
}

// outputs.local.json's text with `description`'s `key` set to `value`, or
// cleared when `value` is undefined (a monitor with nothing left goes).
// Each text is the file's, or null when it doesn't exist. A bad value or a
// file that doesn't parse (never overwritten) is an {error}.
export function withOutputSetting(localText, description, key, value, sharedText = null) {
    // A bad shared file keeps the last good settings, so a change made now
    // couldn't show either: refused, as one in the local file is.
    if (sharedText !== null && sharedText !== undefined) {
        const shared = parseOutputs(sharedText);
        if (shared.error) {
            return { error: `outputs.json: ${shared.error}` };
        }
    }
    let local = {};
    if (localText !== null && localText !== undefined) {
        const parsed = parseOutputs(localText);
        if (parsed.error) {
            return { error: `outputs.local.json: ${parsed.error}` };
        }
        local = parsed.settings;
    }
    const monitor = Object.assign({}, monitorSettings(local, description));
    if (value === undefined) {
        delete monitor[key];
    } else {
        monitor[key] = value;
    }
    const monitors = Object.assign({}, local.monitors || {});
    if (Object.keys(monitor).length === 0) {
        delete monitors[description];
    } else {
        monitors[description] = monitor;
    }
    const next = Object.assign({}, local, { monitors });
    const err = settingsError(next);
    if (err) {
        return { error: err };
    }
    return { text: JSON.stringify(next, null, 2) + "\n" };
}

// outputs.local.json's text with none of `description`'s settings, as
// withOutputSetting: what the page's Reset writes. outputs.json's, if any,
// still apply.
export function withoutMonitor(localText, description, sharedText = null) {
    const scaleless = withOutputSetting(localText, description, "scale", undefined, sharedText);
    return scaleless.error ? scaleless : withOutputSetting(scaleless.text, description, "position", undefined, sharedText);
}

// The settings outputs.local.json alone has, {} when there's no file or it
// doesn't parse (loadOutputs reports that): what Reset would clear.
export function localOutputs(localText) {
    if (localText === null || localText === undefined) {
        return {};
    }
    return parseOutputs(localText).settings || {};
}

// A scale moved `steps` quarters, as shell/lib/steps.mjs moves one: one
// Hyprland rounded to fit the screen goes to the next quarter that way.
export function steppedScale(value, steps) {
    return stepped(value, steps, SCALE_STEP, SCALE_LO, SCALE_HI);
}

// How the page shows a scale: what's set, or Hyprland's own as automatic.
export function formatScale(set, current) {
    if (set !== undefined) {
        return `${set}×`;
    }
    return typeof current === "number" ? `Auto (${current}×)` : "Auto";
}

// A Lua string literal holding `s`, whatever it holds: a monitor's
// description comes from its EDID.
function luaString(s) {
    let out = '"';
    for (const ch of s) {
        const code = ch.charCodeAt(0);
        if (ch === '"' || ch === "\\") {
            out += "\\" + ch;
        } else if (code < 0x20 || code === 0x7f) {
            out += "\\" + String(code).padStart(3, "0");
        } else {
            out += ch;
        }
    }
    return out + '"';
}

// What's set, as the Lua table conf's hyprland.lua reads from
// tide-outputs.lua: each monitor by its hl.monitor output, `desc:` and its
// description, sorted so the file is the same for the same settings.
export function outputsLua(settings) {
    const lines = [
        "-- Written by tide from outputs.json and outputs.local.json (tide SPEC.md §16).",
        "-- Change those, or the Displays page of tide's settings, not this file.",
        "return {",
    ];
    const monitors = settings.monitors || {};
    for (const name of Object.keys(monitors).sort()) {
        const m = monitors[name];
        const fields = [];
        if (m.scale !== undefined) {
            fields.push(`scale = ${m.scale}`);
        }
        if (m.position !== undefined) {
            fields.push(`position = ${luaString(m.position)}`);
        }
        lines.push(`    [${luaString(`desc:${name}`)}] = { ${fields.join(", ")} },`);
    }
    lines.push("}");
    return lines.join("\n") + "\n";
}

// The monitors from `hyprctl monitors all -j` as [{name, description,
// scale}], or {error}; `failed` is the run's own failure, which the log
// has.
export function listedMonitors(failed, text) {
    if (failed) {
        return { monitors: [], error: "couldn't run hyprctl monitors" };
    }
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { monitors: [], error: "hyprctl monitors: not JSON" };
    }
    if (!Array.isArray(value)) {
        return { monitors: [], error: "hyprctl monitors: expected a list of monitors" };
    }
    const monitors = [];
    for (const m of value) {
        if (!isObject(m) || typeof m.name !== "string" || typeof m.description !== "string") {
            return { monitors: [], error: "hyprctl monitors: a monitor without its name or description" };
        }
        monitors.push({ name: m.name, description: m.description, scale: typeof m.scale === "number" ? m.scale : null });
    }
    return { monitors, error: "" };
}

// The monitors the page lists: each one connected, then each one with
// settings that isn't, by description.
export function shownMonitors(settings, connected) {
    const shown = connected.map(m => ({ name: m.name, description: m.description, scale: m.scale }));
    for (const description of Object.keys(settings.monitors || {}).sort()) {
        if (!shown.some(m => m.description === description)) {
            shown.push({ name: "", description, scale: null });
        }
    }
    return shown;
}
