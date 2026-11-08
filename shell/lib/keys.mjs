// The settings panel's keyboard shortcuts (SPEC.md §16): the key
// bindings Hyprland has now, read from `hyprctl binds -j`, or on tidewm
// its config file's, read from its GET_BINDINGS, as pure functions the QML
// binds to.
//
// That needs Hyprland 0.56.2, tide's pin: 0.56.0's JSON gives each value
// one field late from has_description on (src/debug/HyprCtl.cpp's
// bindsRequest), so it doesn't parse, and the page says so. Every Lua
// binding's dispatcher is "__lua", so what one does is only its
// description, which conf gives in hl.bind's `description` option.

// Hyprland's modifier bits, in xkb's order, as a binding names them.
const MODIFIERS = [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"], [2, "Caps"], [16, "Mod2"], [32, "Mod3"], [128, "Mod5"]];

// The modifiers a written key string names, as Hyprland's modFromSv reads
// them.
const MODIFIER_NAMES = {
    SHIFT: "Shift", CAPS: "Caps", CTRL: "Ctrl", CONTROL: "Ctrl", ALT: "Alt", MOD1: "Alt",
    MOD2: "Mod2", MOD3: "Mod3", SUPER: "Super", WIN: "Super", LOGO: "Super", MOD4: "Super",
    META: "Super", MOD5: "Mod5",
};

// Keys whose XKB names aren't what's on the key, and the mouse's.
const KEY_NAMES = {
    period: ".", comma: ",", grave: "`", backslash: "\\", slash: "/", equal: "=", minus: "-",
    semicolon: ";", apostrophe: "'", bracketleft: "[", bracketright: "]",
    exclam: "!", quotedbl: "\"", numbersign: "#", dollar: "$", percent: "%", ampersand: "&",
    parenleft: "(", parenright: ")", asterisk: "*", plus: "+", colon: ":", less: "<", greater: ">",
    question: "?", at: "@", asciicircum: "^", underscore: "_", braceleft: "{", bar: "|", braceright: "}",
    asciitilde: "~",
    backspace: "Backspace", return: "Return", space: "Space", tab: "Tab", escape: "Escape",
    prior: "PgUp", page_up: "PgUp", next: "PgDn", page_down: "PgDn", print: "Print",
    insert: "Insert", delete: "Delete", home: "Home", end: "End",
    up: "Up", down: "Down", left: "Left", right: "Right",
    "mouse:272": "Left click", "mouse:273": "Right click", "mouse:274": "Middle click",
    mouse_down: "Scroll down", mouse_up: "Scroll up", mouse_left: "Scroll left", mouse_right: "Scroll right",
};

// The keypad's keys whose XKB names aren't what's on the key.
const KEYPAD_NAMES = {
    add: "+", subtract: "-", multiply: "*", divide: "/", decimal: ".", equal: "=", separator: ",",
};

// A key as it's printed on the keyboard: "T" for t, "." for period.
export function keyLabel(key) {
    const name = key.toLowerCase();
    if (name.startsWith("kp_") && name.length > 3) {
        const rest = name.slice(3);
        return `Keypad ${Object.prototype.hasOwnProperty.call(KEYPAD_NAMES, rest) ? KEYPAD_NAMES[rest] : keyLabel(key.slice(3))}`;
    }
    if (Object.prototype.hasOwnProperty.call(KEY_NAMES, name)) {
        return KEY_NAMES[name];
    }
    return key.length === 1 ? key.toUpperCase() : key;
}

// A binding's keys, as "Super+Shift+T". A key given as the whole string
// it was written as ("SUPER + code:28") is read as Hyprland reads it. A
// Lua binding by keycode has neither a key nor a keycode in 0.56.2's
// listing (parseKeyString keeps the code to itself), so all it can say is
// that it's one.
export function keysLabel(modmask, key, keycode = 0) {
    if (key.includes("+")) {
        return key.split("+").map(k => k.trim()).filter(k => k !== "").map(k => {
            const upper = k.toUpperCase();
            return Object.prototype.hasOwnProperty.call(MODIFIER_NAMES, upper) ? MODIFIER_NAMES[upper] : keyLabel(k);
        }).join("+");
    }
    const mods = MODIFIERS.filter(([bit]) => (modmask & bit) !== 0).map(([, name]) => name);
    let last = "a keycode";
    if (key !== "") {
        last = keyLabel(key);
    } else if (keycode > 0) {
        last = `code:${keycode}`;
    }
    return mods.concat([last]).join("+");
}

// Parses `hyprctl binds -j`. Returns {binds} as [{keys, does, submap}], in
// Hyprland's order, which is the config's, or {error}. `does` is the
// description, a dispatcher's name and argument when it isn't Lua's, or
// "".
export function parseBinds(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        // The engine's own message differs from Node's, and runs over lines.
        return { error: "hyprctl binds -j: not JSON; is Hyprland older than 0.56.2?" };
    }
    if (!Array.isArray(value)) {
        return { error: "hyprctl binds -j: expected a list of bindings" };
    }
    const binds = [];
    for (const b of value) {
        if (b === null || typeof b !== "object" || typeof b.modmask !== "number" ||
            typeof b.key !== "string" || typeof b.dispatcher !== "string") {
            return { error: "hyprctl binds -j: a binding without its modmask, key or dispatcher" };
        }
        let does = "";
        if (b.has_description === true && typeof b.description === "string") {
            does = b.description.replace(/\s+/g, " ").trim();
        } else if (b.dispatcher !== "__lua") {
            does = `${b.dispatcher} ${typeof b.arg === "string" ? b.arg : ""}`.trim();
        }
        binds.push({
            // Any key, with whatever modifiers it was given.
            keys: keysLabel(b.modmask, b.catch_all === true ? "Any key" : b.key, typeof b.keycode === "number" ? b.keycode : 0),
            does,
            submap: typeof b.submap === "string" ? b.submap : "",
        });
    }
    return { binds };
}

// What the page shows from a run of `hyprctl binds -j`: its bindings, or
// none and why. `failed` is the run's own failure, which the log has.
export function listedBinds(failed, text) {
    if (failed) {
        return { binds: [], error: "couldn't run hyprctl binds -j" };
    }
    const r = parseBinds(text);
    return r.error ? { binds: [], error: r.error } : { binds: r.binds, error: "" };
}

// A switch binding on tidewm, as its sway name says.
const SWITCHES = {
    "lid:on": "Lid closed", "lid:off": "Lid opened", "lid:toggle": "Lid closed or opened",
    "tablet:on": "Tablet mode on", "tablet:off": "Tablet mode off", "tablet:toggle": "Tablet mode on or off",
};

// Parses tidewm's GET_BINDINGS (`tide-msg --type get_bindings`), as
// parseBinds parses hyprctl's: {binds} as [{keys, does, submap}], in the
// config file's order, or {error}. tidewm's lines have no descriptions,
// so what one does is its command, and a --kept-open one's counts only in
// a window kept open, which is a pinned one (SPEC.md §6.5).
export function parseTidewmBinds(text) {
    const what = "tide-msg --type get_bindings";
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: `${what}: not JSON` };
    }
    // A tidewm from before GET_BINDINGS says it doesn't know the request
    if (value !== null && typeof value === "object" && typeof value.error === "string") {
        return { error: `${what}: ${value.error}; is tidewm too old to list them?` };
    }
    if (!Array.isArray(value)) {
        return { error: `${what}: expected a list of bindings` };
    }
    const binds = [];
    for (const b of value) {
        if (b === null || typeof b !== "object" || typeof b.keys !== "string" || typeof b.command !== "string") {
            return { error: `${what}: a binding without its keys or command` };
        }
        const isSwitch = b.type === "switch";
        const command = b.command.replace(/\s+/g, " ").trim();
        binds.push({
            keys: isSwitch ? (SWITCHES[b.keys] || b.keys) : keysLabel(0, b.keys),
            does: b.kept_open === true ? `${command}, in a pinned window` : command,
            submap: typeof b.mode === "string" && b.mode !== "default" ? b.mode : "",
        });
    }
    return { binds };
}

// What the page shows from a run of `tide-msg --type get_bindings`, as
// listedBinds.
export function listedTidewmBinds(failed, text) {
    if (failed) {
        return { binds: [], error: "couldn't run tide-msg --type get_bindings" };
    }
    const r = parseTidewmBinds(text);
    return r.error ? { binds: [], error: r.error } : { binds: r.binds, error: "" };
}

// Editing the keys (SPEC.md §16). conf names most of Hyprland's bindings
// and lists each one's name, what it does, its defaults and its keys now in
// tide-keys.json, in its instance's runtime directory. Your keys are kept
// in keys.json and keys.local.json (§16.1) as { "keys": { "terminal":
// ["SUPER + D"], "lock": [] } }, a binding's keys in place of its defaults,
// none turning it off, and written to ~/.config/hypr/tide-keys.lua, which
// conf reads. Keys are written as Hyprland's config writes them: the
// modifiers, then the key's XKB name, joined by " + ".

export const FILES = Object.freeze(["keys.json", "keys.local.json"]);
// As conf's MAX_KEYS_PER_BIND.
export const MAX_KEYS = 8;
const NAME = /^[a-z][a-z0-9_]*$/;
// The modifiers in the order a binding names them, as written.
const WRITTEN_MODIFIERS = [["Super", "SUPER"], ["Ctrl", "CTRL"], ["Alt", "ALT"], ["Shift", "SHIFT"]];

// Where conf lists its named bindings: "" without a runtime directory or
// a Hyprland instance.
export function catalogPath(runtimeDir, instance) {
    return runtimeDir && instance ? `${runtimeDir}/hypr/${instance}/tide-keys.json` : "";
}

// A written key string ("SHIFT + SUPER + period") as the listing labels
// it, the modifiers in their order: "Super+Shift+.". The same keys always
// give the same label, so it's what two bindings' keys are compared by.
export function keysId(keys) {
    const parts = String(keys).split("+").map(k => k.trim()).filter(k => k !== "");
    const last = parts.pop() ?? "";
    const mods = new Set(parts.map(p => {
        const upper = p.toUpperCase();
        return Object.prototype.hasOwnProperty.call(MODIFIER_NAMES, upper) ? MODIFIER_NAMES[upper] : p;
    }));
    const order = MODIFIERS.map(([, name]) => name);
    const sorted = Array.from(mods).sort((a, b) => {
        const ia = order.indexOf(a), ib = order.indexOf(b);
        return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
    });
    return sorted.concat([keyLabel(last)]).join("+");
}

function stringList(v) {
    return Array.isArray(v) && v.every(k => typeof k === "string");
}

// Parses conf's tide-keys.json: {binds: [{name, does, defaults, keys}]},
// in conf's order, or {error}.
export function parseCatalog(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: "tide-keys.json: not JSON" };
    }
    if (value === null || typeof value !== "object" || !Array.isArray(value.keys)) {
        return { error: "tide-keys.json: expected { keys: [...] }" };
    }
    const binds = [];
    for (const b of value.keys) {
        if (b === null || typeof b !== "object" || typeof b.name !== "string" || typeof b.does !== "string" ||
            !stringList(b.defaults) || !stringList(b.keys)) {
            return { error: "tide-keys.json: a binding without its name, description, defaults or keys" };
        }
        binds.push({ name: b.name, does: b.does, defaults: b.defaults.slice(), keys: b.keys.slice() });
    }
    return { binds };
}

// A key string one of your files may give: {keys}, its whole text trimmed,
// or {error}.
function checkKeys(raw, where) {
    if (typeof raw !== "string" || raw.trim() === "" || /[\u0000-\u001f\u007f"\\]/.test(raw)) {
        return { error: `${where}: ${JSON.stringify(raw)} isn't keys` };
    }
    return { keys: raw.trim() };
}

// Parses keys.json or keys.local.json: {keys} (undefined when the file
// doesn't set it) or {error}.
export function parseKeysFile(text) {
    if (text.trim() === "") {
        return {};
    }
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: "not JSON" };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: "expected an object" };
    }
    for (const k of Object.keys(value)) {
        if (k !== "keys") {
            return { error: `unknown setting ${k}` };
        }
    }
    if (value.keys === undefined) {
        return {};
    }
    if (value.keys === null || typeof value.keys !== "object" || Array.isArray(value.keys)) {
        return { error: "keys should be an object of names" };
    }
    const keys = {};
    for (const [name, list] of Object.entries(value.keys)) {
        if (!NAME.test(name)) {
            return { error: `${JSON.stringify(name)} isn't a binding's name` };
        }
        if (!Array.isArray(list)) {
            return { error: `${name} should list its keys` };
        }
        if (list.length > MAX_KEYS) {
            return { error: `${name} lists ${list.length} keys, more than ${MAX_KEYS}` };
        }
        const out = [];
        for (const raw of list) {
            const c = checkKeys(raw, name);
            if (c.error) {
                return { error: c.error };
            }
            out.push(c.keys);
        }
        keys[name] = out;
    }
    return { keys };
}

// Your keys from both files, keys.local.json's replacing keys.json's
// whole: {keys, errors}. With an error, `lastGood` stands.
export function loadKeys(sharedText, localText, lastGood = {}) {
    let keys = {};
    const errors = [];
    for (const [name, text] of [[FILES[0], sharedText], [FILES[1], localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseKeysFile(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        if (parsed.keys !== undefined) {
            keys = parsed.keys;
        }
    }
    return errors.length > 0 ? { keys: lastGood, errors } : { keys, errors };
}

// keys.local.json's text with the keys `change` makes of the ones in
// effect: {text, keys} or {error}. Either file not loading is an {error},
// so a hand edit gone wrong isn't overwritten.
export function editedKeys(sharedText, localText, change) {
    const loaded = loadKeys(sharedText, localText);
    if (loaded.errors.length > 0) {
        return { error: loaded.errors[0] };
    }
    const result = change(Object.assign({}, loaded.keys));
    if (result.error) {
        return { error: result.error };
    }
    const local = localText === null || localText === undefined || localText.trim() === "" ? {} : JSON.parse(localText);
    const sorted = {};
    for (const name of Object.keys(result.keys).sort()) {
        sorted[name] = result.keys[name];
    }
    const text = JSON.stringify(Object.assign({}, local, { keys: sorted }), null, 2) + "\n";
    return { text, keys: sorted };
}

// A Lua string literal holding `s`, which checkKeys and NAME keep to
// printable text with no quotes or backslashes.
function luaString(s) {
    return `"${s}"`;
}

// tide-keys.lua, which conf's hyprland.lua reads as data.
export function keysLua(keys) {
    const lines = ["-- Written by tide's Keyboard shortcuts (SPEC.md §16); changes here are lost.", "return { keys = {"];
    for (const name of Object.keys(keys).sort()) {
        lines.push(`    ${name} = { ${keys[name].map(luaString).join(", ")} },`);
    }
    lines.push("} }");
    return lines.join("\n") + "\n";
}

// Qt's key codes for the keys a binding can name, by their XKB names.
const QT_KEYS = {
    0x20: "Space", 0x27: "apostrophe", 0x2c: "comma", 0x2d: "minus", 0x2e: "period", 0x2f: "slash",
    0x3b: "semicolon", 0x3d: "equal", 0x5b: "bracketleft", 0x5c: "backslash", 0x5d: "bracketright", 0x60: "grave",
    0x01000001: "Tab", 0x01000002: "Tab", 0x01000003: "BackSpace", 0x01000004: "Return", 0x01000005: "KP_Enter",
    0x01000006: "Insert", 0x01000007: "Delete", 0x01000008: "Pause", 0x01000009: "Print",
    0x01000010: "Home", 0x01000011: "End", 0x01000012: "Left", 0x01000013: "Up", 0x01000014: "Right",
    0x01000015: "Down", 0x01000016: "Page_Up", 0x01000017: "Page_Down", 0x01000055: "Menu",
};
// The symbols Shift makes of a US keyboard's keys, as Qt reports them, so
// Super+Shift+1 is written as Hyprland binds it, with the key's own name.
// Only with Shift held: without it, the symbol is the key's own.
const SHIFTED = {
    0x21: "1", 0x40: "2", 0x23: "3", 0x24: "4", 0x25: "5", 0x5e: "6", 0x26: "7", 0x2a: "8", 0x28: "9", 0x29: "0",
    0x3c: "comma", 0x3e: "period", 0x3f: "slash", 0x3a: "semicolon", 0x22: "apostrophe", 0x7b: "bracketleft",
    0x7d: "bracketright", 0x7c: "backslash", 0x5f: "minus", 0x2b: "equal", 0x7e: "grave",
};
// The symbols a layout may have on a key of their own, by their XKB names.
const SYMBOLS = {
    0x21: "exclam", 0x22: "quotedbl", 0x23: "numbersign", 0x24: "dollar", 0x25: "percent", 0x26: "ampersand",
    0x28: "parenleft", 0x29: "parenright", 0x2a: "asterisk", 0x2b: "plus", 0x3a: "colon", 0x3c: "less",
    0x3e: "greater", 0x3f: "question", 0x40: "at", 0x5e: "asciicircum", 0x5f: "underscore", 0x7b: "braceleft",
    0x7c: "bar", 0x7d: "braceright", 0x7e: "asciitilde",
};
const MODIFIER_KEYS = new Set([0x01000020, 0x01000021, 0x01000022, 0x01000023, 0x01000024, 0x01000053, 0x01000054, 0x01001103]);
// The keypad's keys, by Qt's code with its KeypadModifier, as XKB names
// them: Super with the keypad's 1 is KP_1, not the main keyboard's 1.
const KEYPAD_MODIFIER = 0x20000000;
const KEYPAD = {
    0x2a: "KP_Multiply", 0x2b: "KP_Add", 0x2d: "KP_Subtract", 0x2e: "KP_Decimal", 0x2f: "KP_Divide",
    0x3d: "KP_Equal", 0x2c: "KP_Separator", 0x01000004: "KP_Enter", 0x01000005: "KP_Enter",
};
// Qt's modifier bits, by how a binding writes them.
const QT_MODIFIERS = [[0x10000000, "SUPER"], [0x04000000, "CTRL"], [0x08000000, "ALT"], [0x02000000, "SHIFT"]];

// The keys a key press records, from Qt's key and modifiers: {keys}, as
// written ("SUPER + SHIFT + G"), {wait} for a modifier on its own, or
// {error}. A binding needs Super, Ctrl or Alt, so it doesn't take a key you
// type, except Print, Pause and the function keys.
export function recordedKeys(key, modifiers) {
    if (MODIFIER_KEYS.has(key)) {
        return { wait: true };
    }
    let name = null;
    const keypad = (modifiers & KEYPAD_MODIFIER) !== 0;
    if (keypad && key >= 0x30 && key <= 0x39) {
        name = `KP_${String.fromCharCode(key)}`;
    } else if (keypad && Object.prototype.hasOwnProperty.call(KEYPAD, key)) {
        name = KEYPAD[key];
    } else if ((key >= 0x41 && key <= 0x5a) || (key >= 0x30 && key <= 0x39)) {
        name = String.fromCharCode(key);
    } else if (key >= 0x01000030 && key <= 0x01000052) {
        name = `F${key - 0x01000030 + 1}`;
    } else if (Object.prototype.hasOwnProperty.call(QT_KEYS, key)) {
        name = QT_KEYS[key];
    } else if ((modifiers & 0x02000000) !== 0 && Object.prototype.hasOwnProperty.call(SHIFTED, key)) {
        name = SHIFTED[key];
    } else if (Object.prototype.hasOwnProperty.call(SYMBOLS, key)) {
        // A layout's own key for the symbol, as German's + is.
        name = SYMBOLS[key];
    }
    if (name === null) {
        return { error: "that key can't be a shortcut" };
    }
    // Shift+Tab is Qt's Backtab.
    const mods = QT_MODIFIERS.filter(([bit, m]) => (modifiers & bit) !== 0 || (m === "SHIFT" && key === 0x01000002)).map(([, m]) => m);
    const free = /^F\d+$/.test(name) || name === "Print" || name === "Pause";
    if (!free && !mods.some(m => m !== "SHIFT")) {
        return { error: "hold Super, Ctrl or Alt with it" };
    }
    return { keys: mods.concat([name]).join(" + ") };
}

// The page's list (SPEC.md §16): conf's named bindings, which can change,
// as [{name, does, keys, label, changed}], then the rest of Hyprland's
// listing, which can't, as parseBinds gives them. A fixed binding's keys a
// named one has now are that one's. `label` is "Off" for none.
export function shortcutRows(catalog, binds) {
    const named = catalog.map(b => ({
        name: b.name,
        does: b.does,
        keys: b.keys.slice(),
        label: b.keys.length === 0 ? "Off" : b.keys.map(keysId).join(" or "),
        changed: b.keys.map(keysId).join("|") !== b.defaults.map(keysId).join("|"),
    }));
    const namedIds = new Set(catalog.reduce((ids, b) => ids.concat(b.keys.map(keysId)), []));
    const fixed = binds.filter(b => b.submap !== "tide-keys" && !(b.submap === "" && namedIds.has(b.keys)));
    return { named, fixed };
}

// Your keys with `name` given `keys` (as written) alone, or {clash}: the
// named binding ({name, does}) that has them now, unless `swap`, which
// gives that one the keys `name` had. Keys a fixed binding has
// (`fixedIds`, as keysId gives them) are an {error}. A binding back at its
// defaults is left out of your keys.
export function withKeys(yours, catalog, name, keys, swap = false, fixedIds = []) {
    const target = catalog.find(b => b.name === name);
    if (!target) {
        return { error: `no shortcut is called ${name}` };
    }
    const id = keysId(keys);
    if (fixedIds.includes(id)) {
        return { error: `${id} can't change, so it can't be ${target.does}` };
    }
    const other = catalog.find(b => b.name !== name && b.keys.some(k => keysId(k) === id));
    const out = Object.assign({}, yours);
    if (other) {
        if (!swap) {
            return { clash: { name: other.name, does: other.does } };
        }
        const given = other.keys.filter(k => keysId(k) !== id)
            .concat(target.keys.filter(k => keysId(k) !== id));
        setOrDefault(out, other, given.slice(0, MAX_KEYS));
    }
    setOrDefault(out, target, [keys]);
    return { keys: out };
}

function setOrDefault(out, bind, keys) {
    if (keys.map(keysId).join("|") === bind.defaults.map(keysId).join("|")) {
        delete out[bind.name];
    } else {
        out[bind.name] = keys;
    }
}

// Your keys with `name` back at its defaults.
export function withDefault(yours, name) {
    const out = Object.assign({}, yours);
    delete out[name];
    return { keys: out };
}

// Your keys with `name` off.
export function withOff(yours, name) {
    return { keys: Object.assign({}, yours, { [name]: [] }) };
}
