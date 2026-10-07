// The settings panel's Keys page (SPEC.md §16): the key bindings Hyprland
// has now, read from `hyprctl binds -j`, as pure functions the QML binds
// to.
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
    backspace: "Backspace", return: "Return", space: "Space", tab: "Tab", escape: "Escape",
    prior: "PgUp", page_up: "PgUp", next: "PgDn", page_down: "PgDn", print: "Print",
    insert: "Insert", delete: "Delete", home: "Home", end: "End",
    up: "Up", down: "Down", left: "Left", right: "Right",
    "mouse:272": "Left click", "mouse:273": "Right click", "mouse:274": "Middle click",
    mouse_down: "Scroll down", mouse_up: "Scroll up", mouse_left: "Scroll left", mouse_right: "Scroll right",
};

// A key as it's printed on the keyboard: "T" for t, "." for period.
export function keyLabel(key) {
    const name = key.toLowerCase();
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
