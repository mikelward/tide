// The Mouse, Touchpad and Keyboard settings (SPEC.md §16), as pure functions
// the QML binds to. input.json and input.local.json hold them; tide writes
// the ones set to ~/.config/hypr/tide-input.lua, in Hyprland's own option
// names, which conf's hyprland.lua reads and applies to each mouse, each
// touchpad and every keyboard.
// What isn't set is left to conf's config, so tide's defaults never override
// a setting made there.

import { jsonError } from "./clocks.mjs";

// Each section's settings: the setting, its row on the page, the Hyprland
// option it's written as, its kind, and what's shown while it isn't set
// (conf's config, as tide found it).
const SPEED = Object.freeze({ key: "speed", label: "Speed", option: "sensitivity", kind: "speed", shown: 1 });
const NATURAL = { key: "naturalScroll", label: "Natural scrolling", option: "natural_scroll", kind: "toggle" };
const LEFT = { key: "leftHanded", label: "Left-handed", option: "left_handed", kind: "toggle" };

export const SECTIONS = Object.freeze({
    mouse: Object.freeze([
        SPEED,
        Object.freeze({ key: "scrollSpeed", label: "Scroll speed", option: "scroll_factor", kind: "scroll", shown: 3 }),
        Object.freeze(Object.assign({}, NATURAL, { shown: false })),
        Object.freeze(Object.assign({}, LEFT, { shown: true })),
    ]),
    touchpad: Object.freeze([
        SPEED,
        Object.freeze({ key: "scrollSpeed", label: "Scroll speed", option: "scroll_factor", kind: "scroll", shown: 1 }),
        Object.freeze(Object.assign({}, NATURAL, { shown: true })),
        Object.freeze(Object.assign({}, LEFT, { shown: false })),
        Object.freeze({ key: "tapToClick", label: "Tap to click", option: "tap_to_click", kind: "toggle", shown: true }),
        Object.freeze({ key: "disableWhileTyping", label: "Off while typing", option: "disable_while_typing", kind: "toggle", shown: true }),
    ]),
    // XKB's names: a layout such as us, or us,de for two; a variant for
    // each, such as dvorak, or none.
    keyboard: Object.freeze([
        Object.freeze({ key: "layout", label: "Layout", option: "kb_layout", kind: "layout", shown: "us" }),
        Object.freeze({ key: "variant", label: "Variant", option: "kb_variant", kind: "variant", shown: "dvorak" }),
        Object.freeze({ key: "repeatDelay", label: "Repeat delay", option: "repeat_delay", kind: "delay", shown: 600 }),
        Object.freeze({ key: "repeatRate", label: "Repeat rate", option: "repeat_rate", kind: "rate", shown: 25 }),
    ]),
});

// The kinds typed as text, not stepped or switched.
const TEXT_KINDS = Object.freeze(["layout", "variant"]);

export function isText(kind) {
    return TEXT_KINDS.includes(kind);
}

// What − and + step through: Hyprland's sensitivity runs from -1 to 1, a
// scroll factor multiplies the device's own, a key repeats after a delay
// in milliseconds, then a rate a second.
export const LADDERS = Object.freeze({
    speed: Object.freeze([-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1]),
    scroll: Object.freeze([0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5]),
    delay: Object.freeze([150, 200, 250, 300, 400, 500, 600, 800, 1000]),
    rate: Object.freeze([10, 15, 20, 25, 30, 40, 50, 60]),
});

// XKB names, comma-separated, of letters, digits, - and _: nothing else
// can reach the Lua file. XKB has at most four layouts at once. A variant
// may be empty, for none, as may each of a list's.
const LAYOUT = /^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+){0,3}$/;
const VARIANT = /^[A-Za-z0-9_-]*(,[A-Za-z0-9_-]*){0,3}$/;

// SECTIONS' own entry for `name`, or undefined: never "constructor" or the
// like, which every object inherits.
function sectionSettings(name) {
    return Object.prototype.hasOwnProperty.call(SECTIONS, name) ? SECTIONS[name] : undefined;
}

function setting(section, key) {
    return (sectionSettings(section) || []).find(s => s.key === key);
}

// Why `value` can't be `section`.`key`, or "".
export function settingError(section, key, value) {
    if (!sectionSettings(section)) {
        return `unknown section "${section}"; expected ${Object.keys(SECTIONS).join(", ")}`;
    }
    const s = setting(section, key);
    if (!s) {
        return `unknown setting "${section}.${key}"; expected ${SECTIONS[section].map(x => x.key).join(", ")}`;
    }
    if (s.kind === "toggle") {
        return typeof value === "boolean" ? "" : `${section}.${key} must be true or false`;
    }
    if (s.kind === "layout") {
        return typeof value === "string" && LAYOUT.test(value) ? "" : `${section}.${key} must be up to four XKB layouts, such as us or us,de`;
    }
    if (s.kind === "variant") {
        return typeof value === "string" && VARIANT.test(value) ? "" : `${section}.${key} must be up to four XKB variants, such as dvorak, or empty for none`;
    }
    if (typeof value !== "number" || !isFinite(value)) {
        return `${section}.${key} must be a number`;
    }
    if (s.kind === "speed" && (value < -1 || value > 1)) {
        return `${section}.${key} must be from -1 to 1`;
    }
    if (s.kind === "scroll" && (value <= 0 || value > 10)) {
        return `${section}.${key} must be above 0 and at most 10`;
    }
    if (s.kind === "delay" && (!Number.isInteger(value) || value < 100 || value > 2000)) {
        return `${section}.${key} must be a whole number of milliseconds from 100 to 2000`;
    }
    if (s.kind === "rate" && (!Number.isInteger(value) || value < 1 || value > 100)) {
        return `${section}.${key} must be a whole number a second from 1 to 100`;
    }
    return "";
}

// Parses one input.json: an object of sections, each an object of any of
// its settings. Returns {settings} or {error}, never throws; the error
// names the setting.
export function parseInput(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: `expected an object of ${Object.keys(SECTIONS).join(", ")}` };
    }
    const settings = {};
    for (const section of Object.keys(value)) {
        const given = value[section];
        if (!sectionSettings(section)) {
            return { error: `unknown section "${section}"; expected ${Object.keys(SECTIONS).join(", ")}` };
        }
        if (given === null || typeof given !== "object" || Array.isArray(given)) {
            return { error: `${section} must be an object of its settings` };
        }
        settings[section] = {};
        for (const key of Object.keys(given)) {
            const error = settingError(section, key, given[key]);
            if (error) {
                return { error };
            }
            settings[section][key] = given[key];
        }
    }
    return { settings };
}

// Why the keyboard's layouts and variants don't pair up, or "": XKB takes
// one variant, or one for each layout. One that isn't set is conf's.
export function pairError(input) {
    const layouts = shown(input, "keyboard", "layout").split(",").length;
    const variants = shown(input, "keyboard", "variant").split(",").length;
    if (variants === 1 || variants === layouts) {
        return "";
    }
    return `keyboard.variant has ${variants} variants for ${layouts} layout${layouts === 1 ? "" : "s"}; it takes one, or one for each layout`;
}

// The settings set, from input.json and then input.local.json (§16.1): each
// text is the file's contents, or null when it doesn't exist. Sections
// merge key by key. A file that fails to parse keeps `lastGood` ({}, nothing
// set, the first time); every file is checked, so `errors` names each one
// that's wrong. So does a keyboard whose layouts and variants, merged,
// don't pair up: the error names the last file to set either.
export function loadInput(sharedText, localText, lastGood = {}) {
    const errors = [];
    const input = {};
    let keyboardFrom = "";
    for (const [name, text] of [["input.json", sharedText], ["input.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseInput(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        for (const section of Object.keys(parsed.settings)) {
            input[section] = Object.assign({}, input[section] || {}, parsed.settings[section]);
        }
        const keyboard = parsed.settings.keyboard || {};
        if (keyboard.layout !== undefined || keyboard.variant !== undefined) {
            keyboardFrom = name;
        }
    }
    if (errors.length === 0 && pairError(input) !== "") {
        errors.push(`${keyboardFrom}: ${pairError(input)}`);
    }
    if (errors.length > 0) {
        return { input: lastGood, errors };
    }
    return { input, errors };
}

// What the page shows for `section`.`key`: the setting if it's set, else
// what conf's config has.
export function shown(input, section, key) {
    const set = (input[section] || {})[key];
    return set === undefined ? setting(section, key).shown : set;
}

// A setting as Lua: a name quoted, which settingError has kept to letters,
// digits, -, _ and commas, so it needs no escapes.
function luaValue(value) {
    return typeof value === "string" ? `"${value}"` : String(value);
}

// The file conf's hyprland.lua reads: every section, with what's set in it.
export function inputLua(input) {
    const lines = [
        "-- Written by tide from input.json and input.local.json (tide SPEC.md §16).",
        "-- Change those, or the Mouse, Touchpad and Keyboard pages of tide's",
        "-- settings, not this file. Only what's set is here; conf's hyprland.lua",
        "-- has the rest.",
        "return {",
    ];
    for (const section of Object.keys(SECTIONS)) {
        const set = input[section] || {};
        const fields = SECTIONS[section]
            .filter(s => set[s.key] !== undefined)
            .map(s => `${s.option} = ${luaValue(set[s.key])}`);
        lines.push(`    ${section} = {${fields.length > 0 ? ` ${fields.join(", ")} ` : ""}},`);
    }
    lines.push("}");
    return lines.join("\n") + "\n";
}

// input.local.json's text with `section`.`key` set to `value`, keeping
// whatever else it says. `localText` is null when the file doesn't exist. A
// bad setting, or a file that doesn't parse, is an {error}, so a hand edit
// gone wrong is never overwritten. So is a keyboard layout or variant that
// wouldn't pair up with the other, as `sharedText` (input.json) and the
// local file set them.
export function withSetting(localText, section, key, value, sharedText = null) {
    const error = settingError(section, key, value);
    if (error) {
        return { error };
    }
    let settings = {};
    if (localText !== null && localText !== undefined) {
        const parsed = parseInput(localText);
        if (parsed.error) {
            return { error: `input.local.json: ${parsed.error}` };
        }
        settings = parsed.settings;
    }
    const next = {};
    for (const name of Object.keys(SECTIONS)) {
        const set = Object.assign({}, settings[name] || {});
        if (name === section) {
            set[key] = value;
        }
        if (Object.keys(set).length > 0) {
            next[name] = {};
            // In the page's order, so the file reads the same way.
            for (const s of SECTIONS[name]) {
                if (set[s.key] !== undefined) {
                    next[name][s.key] = set[s.key];
                }
            }
        }
    }
    if (section === "keyboard") {
        // A shared file that doesn't parse is load's to report.
        const shared = sharedText === null || sharedText === undefined ? {} : parseInput(sharedText).settings || {};
        const error = pairError({ keyboard: Object.assign({}, shared.keyboard || {}, next.keyboard) });
        if (error) {
            return { error };
        }
    }
    return { text: JSON.stringify(next, null, 2) + "\n" };
}

// The next value along `kind`'s ladder from `value`, up (`step` 1) or down
// (-1), staying put at either end; a value between rungs moves to the
// nearest rung that way.
export function stepped(kind, value, step) {
    const ladder = LADDERS[kind];
    // A switch has no ladder.
    if (!ladder) {
        return value;
    }
    if (step > 0) {
        const up = ladder.find(v => v > value);
        return up === undefined ? value : up;
    }
    const down = ladder.filter(v => v < value);
    return down.length === 0 ? value : down[down.length - 1];
}

// A value as the page shows it: a speed as -1 to +1, a scroll speed as a
// multiple, a repeat delay in milliseconds and its rate a second.
export function formatValue(kind, value) {
    if (kind === "speed") {
        return (value > 0 ? "+" : value < 0 ? "−" : "") + Math.abs(value).toFixed(2);
    }
    if (kind === "scroll") {
        return `${value}×`;
    }
    if (kind === "delay") {
        return `${value} ms`;
    }
    if (kind === "rate") {
        return `${value}/s`;
    }
    if (isText(kind)) {
        return value === "" ? "none" : value;
    }
    return value ? "On" : "Off";
}

// `section`.`key` from text, as `qs ipc` passes it: the text itself for a
// name, true or false for a switch, else a number (NaN for anything that
// isn't, which settingError refuses).
export function parseValue(section, key, text) {
    const s = setting(section, key);
    if (s && isText(s.kind)) {
        return text;
    }
    if (text === "true" || text === "false") {
        return text === "true";
    }
    return text.trim() === "" ? NaN : Number(text);
}
