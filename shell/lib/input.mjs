// The Mouse, Touchpad and Keyboard settings (SPEC.md §16), as pure functions
// the QML binds to. input.json and input.local.json hold them; tide writes
// the ones set to ~/.config/hypr/tide-input.lua, in Hyprland's own option
// names, which conf's hyprland.lua reads and applies to each mouse, each
// touchpad and each keyboard.
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

// A device's name, as hyprctl devices gives it: printable ASCII with no
// quote or backslash, so it needs no escapes in the Lua file.
const DEVICE_NAME = /^[ !#-[\]-~]{1,128}$/;

// Which kind of device a pointer's name is, as conf's apply-input.sh
// decides: a touchpad says so in its name, and every other is a mouse.
export function deviceKind(name) {
    return /touchpad|trackpad|synaptics/.test(name) ? "touchpad" : "mouse";
}

// Which section device `name`'s own `key` is one of: the keyboard's for a
// keyboard setting, else its pointer kind's. One name can be a mouse and a
// keyboard both, as a wireless receiver is, and no setting of a keyboard's
// shares a mouse's or a touchpad's name.
export function deviceSection(name, key) {
    return setting("keyboard", key) ? "keyboard" : deviceKind(name);
}

// What device `name` can have of its own, in order: its pointer kind's
// settings, then a keyboard's.
function deviceSettings(name) {
    return SECTIONS[deviceKind(name)].concat(SECTIONS.keyboard);
}

// Why `name` can't be a device's, or "".
function deviceNameError(name) {
    // __proto__ would set an object's prototype, not a key of it.
    if (!DEVICE_NAME.test(name) || name === "__proto__") {
        return `"${name}" isn't a name hyprctl devices gives a mouse, touchpad or keyboard`;
    }
    return "";
}

// Why `value` can't be device `name`'s own `key`, or "": one of its kind's
// settings, or a keyboard's.
export function deviceSettingError(name, key, value) {
    const nameError = deviceNameError(name);
    if (nameError) {
        return `devices: ${nameError}`;
    }
    const kind = deviceSection(name, key);
    const error = settingError(kind, key, value);
    if (error.startsWith(`${kind}.`)) {
        return `devices.${name}.${error.slice(kind.length + 1)}`;
    }
    return error ? `devices.${name}: ${error}` : "";
}

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
        if (section === "devices") {
            const parsed = parseDevices(given);
            if (parsed.error) {
                return { error: parsed.error };
            }
            settings.devices = parsed.devices;
            continue;
        }
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

// input.json's devices: an object of mice, touchpads and keyboards by name,
// each an object of any of its kind's settings, which it takes over its
// kind's. A name can have a keyboard's settings beside a mouse's.
function parseDevices(given) {
    if (given === null || typeof given !== "object" || Array.isArray(given)) {
        return { error: "devices must be an object of mice, touchpads and keyboards, by name" };
    }
    const devices = {};
    for (const name of Object.keys(given)) {
        const nameError = deviceNameError(name);
        if (nameError) {
            return { error: `devices: ${nameError}` };
        }
        const set = given[name];
        if (set === null || typeof set !== "object" || Array.isArray(set)) {
            return { error: `devices.${name} must be an object of its settings` };
        }
        devices[name] = {};
        for (const key of Object.keys(set)) {
            const error = deviceSettingError(name, key, set[key]);
            if (error) {
                return { error };
            }
            devices[name][key] = set[key];
        }
    }
    return { devices };
}

// Why the keyboard's layouts and variants don't pair up, or "": XKB takes
// one variant, or one for each layout. One that isn't set is conf's. So
// with a keyboard's own: either of its own, with every keyboard's other.
export function pairError(input) {
    const first = pairings(input)[0];
    return first ? first.error : "";
}

// Every keyboard whose layouts and variants don't pair up, as [{name,
// error}]: every keyboard's first, named null, then each with its own, by
// name.
function pairings(input) {
    const out = [];
    const error = pairing("keyboard.variant", shown(input, "keyboard", "layout"), shown(input, "keyboard", "variant"));
    if (error) {
        out.push({ name: null, error });
    }
    for (const name of Object.keys(input.devices || {}).sort()) {
        const own = ownDevice(input.devices, name);
        if (own.layout !== undefined || own.variant !== undefined) {
            const error = pairing(`devices.${name}.variant`, deviceShown(input, name, "layout"), deviceShown(input, name, "variant"));
            if (error) {
                out.push({ name, error });
            }
        }
    }
    return out;
}

// The file to fix for keyboard `name`'s pairing (null for every
// keyboard's): the later of those that set its layout and its variant.
function pairingFrom(input, from, name) {
    if (name === null) {
        return from.keyboard;
    }
    const own = ownDevice(input.devices, name);
    const files = [from[`devices.${name}`]];
    if (own.layout === undefined || own.variant === undefined) {
        files.push(from.keyboard);
    }
    return files.includes("input.local.json") ? "input.local.json" : "input.json";
}

function pairing(what, layout, variant) {
    const layouts = layout.split(",").length;
    const variants = variant.split(",").length;
    if (variants === 1 || variants === layouts) {
        return "";
    }
    return `${what} has ${variants} variants for ${layouts} layout${layouts === 1 ? "" : "s"}; it takes one, or one for each layout`;
}

// The settings set, from input.json and then input.local.json (§16.1): each
// text is the file's contents, or null when it doesn't exist. Sections
// merge key by key. A file that fails to parse keeps `lastGood` ({}, nothing
// set, the first time); every file is checked, so `errors` names each one
// that's wrong. So does each keyboard whose layouts and variants, merged,
// don't pair up: the error names the last file to set either, its own or
// every keyboard's where it has none of its own.
export function loadInput(sharedText, localText, lastGood = {}) {
    const errors = [];
    const input = {};
    // The last file to set a layout or variant: "keyboard" for every
    // keyboard's, "devices.NAME" for one's own.
    const from = {};
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
            if (section === "devices") {
                input.devices = mergeDevices(input.devices || {}, parsed.settings.devices);
            } else {
                input[section] = Object.assign({}, input[section] || {}, parsed.settings[section]);
            }
        }
        const keyboard = parsed.settings.keyboard || {};
        if (keyboard.layout !== undefined || keyboard.variant !== undefined) {
            from.keyboard = name;
        }
        for (const [device, set] of Object.entries(parsed.settings.devices || {})) {
            if (set.layout !== undefined || set.variant !== undefined) {
                from[`devices.${device}`] = name;
            }
        }
    }
    if (errors.length === 0) {
        for (const p of pairings(input)) {
            errors.push(`${pairingFrom(input, from, p.name)}: ${p.error}`);
        }
    }
    if (errors.length > 0) {
        return { input: lastGood, errors };
    }
    return { input, errors };
}

// `over`'s devices over `under`'s, each key by key.
function mergeDevices(under, over) {
    const devices = Object.assign({}, under);
    for (const name of Object.keys(over)) {
        devices[name] = Object.assign({}, ownDevice(under, name), over[name]);
    }
    return devices;
}

// The settings `devices` has for `name`, or {}: never one every object
// inherits.
function ownDevice(devices, name) {
    return devices && Object.prototype.hasOwnProperty.call(devices, name) ? devices[name] : {};
}

// What the page shows for device `name`'s `key`: its own setting if it has
// one, else its kind's.
export function deviceShown(input, name, key) {
    const set = ownDevice(input.devices, name)[key];
    return set === undefined ? shown(input, deviceSection(name, key), key) : set;
}

// Whether device `name` has any settings of its own; with `section`, any
// of that section's, so a receiver's mouse settings aren't its keyboard's.
export function hasOwn(input, name, section = undefined) {
    return Object.keys(ownDevice(input.devices, name)).some(key => section === undefined || deviceSection(name, key) === section);
}

// What a Mouse, Touchpad or Keyboard page can set, in order: every device
// of `kind` (""), then each one by name, connected (`connected`, from
// connectedDevices) or with settings of its own of that kind.
export function targets(input, connected, kind) {
    const names = connected.filter(d => d.kind === kind).map(d => d.name)
        .concat(Object.keys(input.devices || {}).filter(n => hasOwn(input, n, kind)));
    return [""].concat(names.filter((n, i) => names.indexOf(n) === i).sort());
}

// A target as the page names it.
export function targetLabel(kind, name) {
    if (name !== "") {
        return name;
    }
    return { touchpad: "Every touchpad", keyboard: "Every keyboard" }[kind] || "Every mouse";
}

// The mice, touchpads and keyboards in `hyprctl devices -j`'s output, as
// [{name, kind}], or {error}. Hyprland lists every pointer as one of its
// mice, and every keyboard it has, power buttons and all.
export function connectedDevices(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: `hyprctl devices -j: ${jsonError(text)}` };
    }
    if (value === null || typeof value !== "object" || !Array.isArray(value.mice)) {
        return { error: "hyprctl devices -j: no list of mice" };
    }
    if (!Array.isArray(value.keyboards)) {
        return { error: "hyprctl devices -j: no list of keyboards" };
    }
    const named = list => list.filter(d => d !== null && typeof d === "object" && typeof d.name === "string" && deviceNameError(d.name) === "");
    const devices = named(value.mice).map(m => ({ name: m.name, kind: deviceKind(m.name) }))
        .concat(named(value.keyboards).map(k => ({ name: k.name, kind: "keyboard" })));
    return { devices };
}

// The devices a run of hyprctl devices -j lists, with why its output didn't
// read ("" if it did): none when the run failed (`failed`) or its output
// didn't read, not the last list's, since those may have gone since.
export function listedDevices(failed, text) {
    if (failed) {
        return { devices: [], error: "" };
    }
    const r = connectedDevices(text);
    return r.error ? { devices: [], error: r.error } : { devices: r.devices, error: "" };
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
    // Only when there are some, so a conf from before devices doesn't
    // report the section as unknown.
    const devices = Object.keys(input.devices || {}).filter(n => hasOwn(input, n)).sort();
    if (devices.length > 0) {
        lines.push("    devices = {");
        for (const name of devices) {
            const set = input.devices[name];
            const fields = deviceSettings(name)
                .filter(s => set[s.key] !== undefined)
                .map(s => `${s.option} = ${luaValue(set[s.key])}`);
            lines.push(`        ["${name}"] = { ${fields.join(", ")} },`);
        }
        lines.push("    },");
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
    const local = localSettings(localText);
    if (local.error) {
        return local;
    }
    const settings = local.settings;
    settings[section] = Object.assign({}, settings[section] || {}, { [key]: value });
    if (section === "keyboard") {
        const error = pairError(merged(sharedText, settings));
        if (error) {
            return { error };
        }
    }
    return { text: settingsText(settings) };
}

// The keyboard's settings and the devices', from input.json's text, and
// input.local.json's `settings` over them, for pairError. A shared file
// that doesn't parse is load's to report.
function merged(sharedText, settings) {
    const shared = sharedText === null || sharedText === undefined ? {} : parseInput(sharedText).settings || {};
    return {
        keyboard: Object.assign({}, shared.keyboard || {}, settings.keyboard || {}),
        devices: mergeDevices(shared.devices || {}, settings.devices || {}),
    };
}

// input.local.json's text with device `name`'s own `key` set to `value`,
// or cleared when `value` is undefined, keeping whatever else it says; as
// withSetting, a keyboard's layout and variant included.
export function withDeviceSetting(localText, name, key, value, sharedText = null) {
    if (value !== undefined) {
        const error = deviceSettingError(name, key, value);
        if (error) {
            return { error };
        }
    } else if (deviceNameError(name)) {
        return { error: `devices: ${deviceNameError(name)}` };
    }
    const local = localSettings(localText);
    if (local.error) {
        return local;
    }
    const settings = local.settings;
    const devices = Object.assign({}, settings.devices || {});
    devices[name] = Object.assign({}, ownDevice(devices, name), { [key]: value });
    settings.devices = devices;
    if (deviceSection(name, key) === "keyboard") {
        const error = pairError(merged(sharedText, settings));
        if (error) {
            return { error };
        }
    }
    return { text: settingsText(settings) };
}

// input.local.json's text with none of device `name`'s own settings, so it
// takes its kind's; with `section`, none of that section's, so a
// receiver's keyboard keeps its own when its mouse's go. As withSetting.
export function withoutDevice(localText, name, section = undefined) {
    const local = localSettings(localText);
    if (local.error) {
        return local;
    }
    const settings = local.settings;
    settings.devices = Object.assign({}, settings.devices || {});
    if (section === undefined) {
        delete settings.devices[name];
    } else {
        const kept = {};
        for (const [key, value] of Object.entries(ownDevice(settings.devices, name))) {
            if (deviceSection(name, key) !== section) {
                kept[key] = value;
            }
        }
        settings.devices[name] = kept;
    }
    return { text: settingsText(settings) };
}

// input.local.json's settings, {} when there's no file, or an {error} when
// it doesn't parse.
function localSettings(localText) {
    if (localText === null || localText === undefined) {
        return { settings: {} };
    }
    const parsed = parseInput(localText);
    if (parsed.error) {
        return { error: `input.local.json: ${parsed.error}` };
    }
    return { settings: parsed.settings };
}

// `set`'s settings in `list`'s order, so the file reads as the page does,
// leaving out any that are undefined.
function ordered(list, set) {
    const out = {};
    for (const s of list) {
        if (set[s.key] !== undefined) {
            out[s.key] = set[s.key];
        }
    }
    return out;
}

// input.local.json's text for `settings`: each section in the page's order,
// then the devices, each with its settings in its kind's order, then a
// keyboard's. A section
// or device with nothing set is left out.
function settingsText(settings) {
    const next = {};
    for (const name of Object.keys(SECTIONS)) {
        const set = ordered(SECTIONS[name], settings[name] || {});
        if (Object.keys(set).length > 0) {
            next[name] = set;
        }
    }
    const devices = {};
    for (const name of Object.keys(settings.devices || {})) {
        const set = ordered(deviceSettings(name), settings.devices[name]);
        if (Object.keys(set).length > 0) {
            devices[name] = set;
        }
    }
    if (Object.keys(devices).length > 0) {
        next.devices = devices;
    }
    return JSON.stringify(next, null, 2) + "\n";
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
