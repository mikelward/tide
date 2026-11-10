// Tests for keys.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { keyLabel, keysLabel, parseBinds, listedBinds, parseTidewmBinds, listedTidewmBinds } from "./keys.mjs";

// One binding as Hyprland 0.56.2's `hyprctl binds -j` gives it
// (src/debug/HyprCtl.cpp's bindsRequest). 0.57.1's has the same fields.
function bind(fields) {
    return Object.assign({
        locked: false, mouse: false, release: false, repeat: false, longPress: false,
        non_consuming: false, auto_consuming: false, has_description: false, modmask: 0,
        submap: "", submap_universal: "false", key: "", keycode: 0, catch_all: false,
        description: "", allow_input_capture: false, dispatcher: "__lua", arg: "1",
    }, fields);
}

const listing = (...binds) => JSON.stringify(binds);

test("a key reads as it's printed on the keyboard", () => {
    assert.equal(keyLabel("t"), "T");
    assert.equal(keyLabel("T"), "T");
    assert.equal(keyLabel("period"), ".");
    assert.equal(keyLabel("backslash"), "\\");
    assert.equal(keyLabel("BackSpace"), "Backspace");
    assert.equal(keyLabel("Prior"), "PgUp");
    assert.equal(keyLabel("Page_Down"), "PgDn");
    assert.equal(keyLabel("mouse:274"), "Middle click");
    assert.equal(keyLabel("XF86AudioMicMute"), "XF86AudioMicMute");
    // Not a name the table has, whatever objects have.
    assert.equal(keyLabel("constructor"), "constructor");
});

test("modifiers come in the order a binding names them", () => {
    assert.equal(keysLabel(64, "T"), "Super+T");
    assert.equal(keysLabel(64 | 1, "G"), "Super+Shift+G");
    assert.equal(keysLabel(64 | 4 | 8 | 1, "Delete"), "Super+Ctrl+Alt+Shift+Delete");
    assert.equal(keysLabel(0, "Print"), "Print");
    assert.equal(keysLabel(8, "Print"), "Alt+Print");
});

test("a keycode binding reads as its code", () => {
    assert.equal(keysLabel(64, "", 10), "Super+code:10");
    // As 0.56.2 lists a Lua `hl.bind("SUPER + code:28", ...)`: no key and
    // no keycode, only the modifiers.
    assert.equal(keysLabel(64, "", 0), "Super+a keycode");
    assert.equal(keysLabel(0, "", 0), "a keycode");
});

test("a key given as the string it was written as reads as Hyprland reads it", () => {
    assert.equal(keysLabel(64, "SUPER + code:28"), "Super+code:28");
    assert.equal(keysLabel(64 | 1, "SUPER+SHIFT+period"), "Super+Shift+.");
    assert.equal(keysLabel(0, "ctrl + alt + Delete"), "Ctrl+Alt+Delete");
});

test("the listing gives each binding's keys and description, in its order", () => {
    const text = listing(
        bind({ has_description: true, modmask: 64, key: "T", description: "Terminal" }),
        bind({ has_description: true, repeat: true, modmask: 64, key: "backslash", description: "Grow the master" }),
        bind({ has_description: true, mouse: true, modmask: 64, key: "mouse:272", description: "Move a window" }));
    assert.deepEqual(parseBinds(text), {
        binds: [
            { keys: "Super+T", does: "Terminal", submap: "" },
            { keys: "Super+\\", does: "Grow the master", submap: "" },
            { keys: "Super+Left click", does: "Move a window", submap: "" },
        ],
    });
});

test("a Lua binding without a description says nothing it does", () => {
    // Its dispatcher is __lua and its argument a registry reference.
    assert.deepEqual(parseBinds(listing(bind({ modmask: 64, key: "L", arg: "42" }))).binds,
                     [{ keys: "Super+L", does: "", submap: "" }]);
});

test("so does one as 0.57.1 lists it", () => {
    // 0.57.1's dispatcher is the Lua value's name (src/ipc/s1/Commands.cpp's
    // bindsRequest, and hlBind's luaL_tolstring): an hl.dsp dispatcher's or
    // a plain function's.
    const binds = parseBinds(listing(
        bind({ modmask: 64, key: "L", dispatcher: "HL.Dispatcher(exec_cmd)", arg: "42" }),
        bind({ modmask: 64, key: "M", dispatcher: "function: 0x55d0c0ffee00", arg: "43" }),
        bind({ modmask: 64, key: "", keycode: 28, dispatcher: "HL.Dispatcher(window.close)", arg: "44" }))).binds;
    assert.deepEqual(binds, [
        { keys: "Super+L", does: "", submap: "" },
        { keys: "Super+M", does: "", submap: "" },
        // 0.57.1 gives a binding by keycode its code.
        { keys: "Super+code:28", does: "", submap: "" },
    ]);
});

test("a dispatcher binding says its dispatcher", () => {
    assert.equal(parseBinds(listing(bind({ modmask: 64, key: "Q", dispatcher: "killactive", arg: "" }))).binds[0].does, "killactive");
    assert.equal(parseBinds(listing(bind({ modmask: 64, key: "1", dispatcher: "workspace", arg: "1" }))).binds[0].does, "workspace 1");
});

test("a binding in a submap says which, and a catch-all is any key", () => {
    const binds = parseBinds(listing(
        bind({ has_description: true, submap: "resize", key: "Escape", description: "Leave resize" }),
        bind({ submap: "resize", catch_all: true }),
        bind({ submap: "resize", catch_all: true, modmask: 64 }))).binds;
    assert.deepEqual(binds, [
        { keys: "Escape", does: "Leave resize", submap: "resize" },
        { keys: "Any key", does: "", submap: "resize" },
        // Its modifiers kept, so it reads apart from the plain one.
        { keys: "Super+Any key", does: "", submap: "resize" },
    ]);
});

test("a description with a line break reads as one line", () => {
    const text = listing(bind({ has_description: true, modmask: 64, key: "T", description: "Open a\nterminal" }));
    assert.equal(parseBinds(text).binds[0].does, "Open a terminal");
});

test("no bindings is an empty list", () => {
    assert.deepEqual(parseBinds("[]"), { binds: [] });
});

test("0.56.0's misordered JSON is an error naming the version, not a wrong list", () => {
    // The key lands unquoted under keycode.
    const text = '[\n{\n    "has_description": false,\n    "modmask": true,\n    "submap": "64",\n    "submap_universal": "",\n    "key": "false",\n    "keycode": T,\n    "dispatcher": "__lua",\n    "arg": "1"\n}]';
    assert.match(parseBinds(text).error, /^hyprctl binds -j: .*older than 0\.56\.2\?$/);
});

test("a listing that isn't bindings is an error, not an empty list", () => {
    assert.match(parseBinds("{}").error, /expected a list of bindings/);
    assert.match(parseBinds('[{"key": "T"}]').error, /without its modmask, key or dispatcher/);
    assert.deepEqual(listedBinds(false, "{}").binds, []);
    assert.match(listedBinds(false, "{}").error, /expected a list/);
});

test("a failed run lists nothing and says so", () => {
    assert.deepEqual(listedBinds(true, ""), { binds: [], error: "couldn't run hyprctl binds -j" });
    assert.deepEqual(listedBinds(false, listing(bind({ has_description: true, modmask: 64, key: "T", description: "Terminal" }))),
                     { binds: [{ keys: "Super+T", does: "Terminal", submap: "" }], error: "" });
});

test("tidewm's bindings are its config file's, each doing its command", () => {
    const text = JSON.stringify([
        { type: "key", keys: "Mod4+Return", command: "exec   foot", mode: "default", release: false, locked: false },
        { type: "key", keys: "Escape", command: "mode default", mode: "resize", release: false, locked: true },
        { type: "key", keys: "Control+Shift+period", command: "layout toggle", mode: "default" },
        { type: "key", keys: "Ctrl+w", command: "kill", mode: "default", kept_open: true },
        { type: "switch", keys: "lid:on", command: "output eDP-1 disable", mode: "default", locked: true },
    ]);
    assert.deepEqual(parseTidewmBinds(text).binds, [
        { keys: "Super+Return", does: "exec foot", submap: "" },
        { keys: "Escape", does: "mode default", submap: "resize" },
        { keys: "Ctrl+Shift+.", does: "layout toggle", submap: "" },
        { keys: "Ctrl+W", does: "kill, in a pinned window", submap: "" },
        { keys: "Lid closed", does: "output eDP-1 disable", submap: "" },
    ]);
});

test("a tidewm listing that can't be read says why", () => {
    assert.deepEqual(listedTidewmBinds(true, ""), { binds: [], error: "couldn't run tide-msg --type get_bindings" });
    assert.equal(listedTidewmBinds(false, '{"success": false, "error": "unsupported message type"}').error,
        "tide-msg --type get_bindings: unsupported message type; is tidewm too old to list them?");
    assert.match(listedTidewmBinds(false, "unsupported").error, /not JSON/);
    assert.match(listedTidewmBinds(false, "{}").error, /expected a list of bindings/);
    assert.match(listedTidewmBinds(false, '[{"keys": "Mod4+x"}]').error, /without its keys or command/);
});

// Editing the keys (SPEC.md §16).
import {
    catalogPath, keysId, parseCatalog, parseKeysFile, loadKeys, editedKeys, keysLua, mergedKeys, presetDefaults,
    recordedKeys, shortcutRows, withKeys, withDefault, withOff, withPreset, NO_KEYS,
} from "./keys.mjs";

const CATALOG = [
    { name: "terminal", does: "Terminal", defaults: ["SUPER + T"], keys: ["SUPER + T"] },
    { name: "monocle", does: "Monocle", defaults: ["SUPER + grave", "SUPER + O"], keys: ["SUPER + grave", "SUPER + O"] },
    { name: "lock", does: "Lock", defaults: ["SUPER + L"], keys: ["SUPER + L"] },
    { name: "launcher", does: "Launcher", defaults: ["SUPER + Space"], keys: ["SUPER + Space"] },
];
const yours = keys => ({ preset: "tide", keys });

test("conf's list is in the instance's runtime directory", () => {
    assert.equal(catalogPath("/run/user/1000", "abc"), "/run/user/1000/hypr/abc/tide-keys.json");
    assert.equal(catalogPath("", "abc"), "");
    assert.equal(catalogPath("/run/user/1000", ""), "");
});

test("the same keys written any way compare the same", () => {
    assert.equal(keysId("SHIFT + SUPER + period"), "Super+Shift+.");
    assert.equal(keysId("super+shift+period"), "Super+Shift+.");
    assert.equal(keysId("SUPER + Page_Up"), "Super+PgUp");
    assert.equal(keysId("Print"), "Print");
    // As the listing labels Hyprland's own.
    assert.equal(keysId("SUPER + SHIFT + G"), keysLabel(64 | 1, "G"));
});

test("conf's list parses to its bindings in order", () => {
    assert.deepEqual(parseCatalog(JSON.stringify({ keys: CATALOG })), { binds: CATALOG });
    assert.ok(parseCatalog("nope").error);
    assert.ok(parseCatalog(JSON.stringify({ keys: [{ name: "x", does: "X", defaults: ["A"] }] })).error);
    assert.ok(parseCatalog(JSON.stringify([])).error);
});

test("your keys files take a preset and a binding's keys, or none for off", () => {
    assert.deepEqual(parseKeysFile('{"preset": "dwm", "keys": {"terminal": ["SUPER + D"], "lock": []}}'),
        { preset: "dwm", keys: { terminal: ["SUPER + D"], lock: [] } });
    assert.deepEqual(parseKeysFile(""), {});
    assert.deepEqual(parseKeysFile("{}"), {});
    for (const bad of ["nope", "[]", '{"other": 1}', '{"keys": []}', '{"keys": {"Bad Name": []}}',
        '{"keys": {"lock": "SUPER + L"}}', '{"keys": {"lock": [""]}}', '{"keys": {"lock": [1]}}',
        '{"keys": {"lock": ["SUPER + \\"L"]}}', '{"preset": "awesome"}', '{"preset": "constructor"}',
        JSON.stringify({ keys: { lock: Array(9).fill("SUPER + L") } })]) {
        assert.ok(parseKeysFile(bad).error, bad);
    }
});

test("keys.local.json's keys and preset replace keys.json's, and a broken file keeps the last good", () => {
    assert.deepEqual(loadKeys('{"preset": "i3", "keys": {"lock": []}}', '{"keys": {"terminal": ["SUPER + D"]}}'),
        { state: { preset: "i3", keys: { terminal: ["SUPER + D"] } }, errors: [] });
    assert.deepEqual(loadKeys('{"keys": {"lock": []}}', '{"preset": "dwm"}'),
        { state: { preset: "dwm", keys: { lock: [] } }, errors: [] });
    assert.deepEqual(loadKeys(null, null), { state: { preset: "tide", keys: {} }, errors: [] });
    const r = loadKeys(null, "nope", yours({ lock: [] }));
    assert.deepEqual(r.state, yours({ lock: [] }));
    assert.deepEqual(r.errors, ["keys.local.json: not JSON"]);
});

test("an edit writes keys.local.json, building on the keys in effect", () => {
    const r = editedKeys('{"keys": {"lock": []}}', null, state => withKeys(state, CATALOG, "terminal", "SUPER + D"));
    assert.deepEqual(r.state, yours({ lock: [], terminal: ["SUPER + D"] }));
    assert.deepEqual(JSON.parse(r.text), { preset: "tide", keys: { lock: [], terminal: ["SUPER + D"] } });
    const p = editedKeys(null, null, state => withPreset(state, "dwm"));
    assert.deepEqual(JSON.parse(p.text), { preset: "dwm", keys: {} });
    const back = editedKeys('{"preset": "dwm"}', null, state => withPreset(state, "tide"));
    assert.deepEqual(loadKeys('{"preset": "dwm"}', back.text).state.preset, "tide", "tide's overrides keys.json's");
    assert.ok(editedKeys(null, "nope", state => ({ state })).error, "a broken file isn't overwritten");
    assert.deepEqual(editedKeys(null, null, state => withKeys(state, CATALOG, "lock", "SUPER + T")).clash.name, "terminal");
});

test("tide-keys.lua lists your keys over the preset's for conf to read", () => {
    assert.equal(keysLua(yours({ terminal: ["SUPER + D", "SUPER + CTRL + T"], lock: [] })),
        "-- Written by tide's Keyboard shortcuts (SPEC.md §16); changes here are lost.\n"
        + "return { keys = {\n    lock = {  },\n    terminal = { \"SUPER + D\", \"SUPER + CTRL + T\" },\n} }\n");
    const merged = mergedKeys({ preset: "dwm", keys: { terminal: ["SUPER + T"] } });
    assert.deepEqual(merged.terminal, ["SUPER + T"], "yours over the preset's");
    assert.deepEqual(merged.launcher, ["SUPER + P"], "the preset's");
    const taken = mergedKeys({ preset: "i3", keys: { lock: ["SUPER + Return"] } });
    assert.deepEqual(taken.lock, ["SUPER + Return"]);
    assert.equal(taken.terminal, undefined, "i3's terminal gives up the key you gave lock, and keeps conf's own rather than none");
});

test("a preset's keys are a binding's defaults, and a binding it takes keys from goes without them", () => {
    const d = presetDefaults("dwm", CATALOG);
    assert.deepEqual(d.launcher, ["SUPER + P"]);
    assert.deepEqual(d.terminal, ["SUPER + SHIFT + Return"]);
    assert.deepEqual(d.lock, [], "dwm's Super+L grows the master");
    assert.deepEqual(d.monocle, ["SUPER + M"]);
    assert.deepEqual(presetDefaults("tide", CATALOG).lock, ["SUPER + L"]);
});

test("a key press records the keys as Hyprland writes them", () => {
    const SUPER = 0x10000000, SHIFT = 0x02000000, CTRL = 0x04000000, ALT = 0x08000000;
    assert.deepEqual(recordedKeys(0x54, SUPER), { keys: "SUPER + T" });
    assert.deepEqual(recordedKeys(0x47, SUPER | SHIFT), { keys: "SUPER + SHIFT + G" });
    assert.deepEqual(recordedKeys(0x2e, SUPER | CTRL | ALT), { keys: "SUPER + CTRL + ALT + period" });
    assert.deepEqual(recordedKeys(0x21, SUPER | SHIFT), { keys: "SUPER + SHIFT + 1" }, "Shift+1 is !");
    assert.deepEqual(recordedKeys(0x01000002, SUPER | SHIFT), { keys: "SUPER + SHIFT + Tab" }, "Backtab");
    assert.deepEqual(recordedKeys(0x2b, SUPER), { keys: "SUPER + plus" }, "German's own + key, no Shift");
    const KEYPAD = 0x20000000;
    assert.deepEqual(recordedKeys(0x31, CTRL | KEYPAD), { keys: "CTRL + KP_1" }, "the keypad's 1");
    assert.deepEqual(recordedKeys(0x2b, SUPER | KEYPAD), { keys: "SUPER + KP_Add" });
    assert.deepEqual(recordedKeys(0x01000005, SUPER | KEYPAD), { keys: "SUPER + KP_Enter" });
    assert.equal(keysId("SUPER + KP_Add"), "Super+Keypad +");
    assert.equal(keysId("CTRL + KP_1"), "Ctrl+Keypad 1");
    assert.equal(keysId("SUPER + plus"), "Super++");
    assert.deepEqual(recordedKeys(0x01000016, SUPER), { keys: "SUPER + Page_Up" });
    assert.deepEqual(recordedKeys(0x01000033, 0), { keys: "F4" });
    assert.deepEqual(recordedKeys(0x01000009, 0), { keys: "Print" });
    assert.deepEqual(recordedKeys(0x01000022, SUPER), { wait: true }, "Super alone");
    assert.ok(recordedKeys(0x54, 0).error, "a bare T is typing");
    assert.ok(recordedKeys(0x54, SHIFT).error, "so is Shift+T");
    assert.ok(recordedKeys(0x01000100, SUPER).error, "a key a binding can't name");
});

test("the list has the named bindings, which can change, then the rest", () => {
    const catalog = CATALOG.map(b => b.name === "lock" ? Object.assign({}, b, { keys: [] }) : b);
    const binds = [
        { keys: "Super+T", does: "Terminal", submap: "" },
        { keys: "Super+1", does: "Workspace 1 on the bar", submap: "" },
        { keys: "Escape", does: "Stop recording a shortcut", submap: "tide-keys" },
        { keys: "Escape", does: "Leave resize mode", submap: "resize" },
    ];
    const rows = shortcutRows(catalog, binds);
    assert.deepEqual(rows.named.map(r => [r.name, r.label, r.changed]),
        [["terminal", "Super+T", false], ["monocle", "Super+` or Super+O", false], ["lock", "Off", true], ["launcher", "Super+Space", false]]);
    assert.deepEqual(rows.fixed.map(b => b.does), ["Workspace 1 on the bar", "Leave resize mode"]);
    const dwm = shortcutRows(catalog, binds, { preset: "dwm", keys: {} });
    assert.equal(dwm.named.find(r => r.name === "lock").changed, false, "dwm takes Super+L from lock");
    assert.equal(dwm.named.find(r => r.name === "launcher").changed, true, "until conf binds Super+P");
});

test("new keys replace a binding's, and a binding back at its defaults leaves your file", () => {
    assert.deepEqual(withKeys(NO_KEYS, CATALOG, "terminal", "SUPER + D"), { state: yours({ terminal: ["SUPER + D"] }) });
    assert.deepEqual(withKeys(yours({ terminal: ["SUPER + D"] }), CATALOG, "terminal", "SUPER + T"), { state: yours({}) });
    assert.deepEqual(withKeys(NO_KEYS, CATALOG, "monocle", "SUPER + O"), { state: yours({ monocle: ["SUPER + O"] }) }, "one of two");
    assert.deepEqual(withKeys({ preset: "dwm", keys: {} }, CATALOG, "launcher", "SUPER + P"), { state: { preset: "dwm", keys: {} } }, "dwm's");
    assert.ok(withKeys(NO_KEYS, CATALOG, "teleport", "SUPER + D").error);
});

test("keys another binding has are a clash, and a swap gives it the old keys", () => {
    assert.deepEqual(withKeys(NO_KEYS, CATALOG, "lock", "SUPER + T"), { clash: { name: "terminal", does: "Terminal" } });
    assert.deepEqual(withKeys(NO_KEYS, CATALOG, "lock", "super+t"), { clash: { name: "terminal", does: "Terminal" } });
    assert.deepEqual(withKeys(NO_KEYS, CATALOG, "lock", "SUPER + T", true),
        { state: yours({ lock: ["SUPER + T"], terminal: ["SUPER + L"] }) });
    assert.deepEqual(withKeys(NO_KEYS, CATALOG, "lock", "SUPER + O", true),
        { state: yours({ lock: ["SUPER + O"], monocle: ["SUPER + grave", "SUPER + L"] }) }, "monocle keeps its other");
});

test("keys a fixed binding has can't be given", () => {
    const r = withKeys(NO_KEYS, CATALOG, "lock", "SUPER + 1", false, ["Super+1"]);
    assert.equal(r.error, "Super+1 can't change, so it can't be Lock");
});

test("reset, off and starting from a preset", () => {
    assert.deepEqual(withDefault(yours({ lock: [], terminal: ["SUPER + D"] }), "lock"), { state: yours({ terminal: ["SUPER + D"] }) });
    // Reset after a swap: both go back.
    const swapped = withKeys(NO_KEYS, CATALOG, "lock", "SUPER + T", true).state;
    assert.deepEqual(swapped.keys, { lock: ["SUPER + T"], terminal: ["SUPER + L"] });
    assert.deepEqual(withDefault(swapped, "lock", CATALOG), { state: yours({}) });
    // One that keeps other keys keeps those.
    assert.deepEqual(withDefault(yours({ monocle: ["SUPER + grave", "SUPER + L"], lock: ["SUPER + D"] }), "lock", CATALOG),
        { state: yours({ monocle: ["SUPER + grave"] }) });
    assert.deepEqual(withOff(NO_KEYS, "lock"), { state: yours({ lock: [] }) });
    // Quit, the terminal and the launcher always keep a key.
    assert.deepEqual(withOff(NO_KEYS, "terminal"), { error: "Terminal needs a shortcut" });
    assert.deepEqual(withOff(NO_KEYS, "quit"), { error: "Quit needs a shortcut" });
    assert.deepEqual(withOff(NO_KEYS, "launcher"), { error: "The launcher needs a shortcut" });
    assert.deepEqual(mergedKeys(yours({ terminal: [], lock: [] })).terminal, undefined, "a hand-edited file can't either");
    // Nor by a swap: Lock, off, taking the terminal's only key would leave it none.
    const lockOff = CATALOG.map(b => (b.name === "lock" ? Object.assign({}, b, { keys: [] }) : b));
    assert.deepEqual(withKeys(yours({ lock: [] }), lockOff, "lock", "SUPER + T", true), { error: "Terminal needs a shortcut" });
    // A binding that isn't kept gives its last key up to a swap.
    const terminalOff = CATALOG.map(b => (b.name === "terminal" ? Object.assign({}, b, { keys: [] }) : b));
    assert.deepEqual(withKeys(NO_KEYS, terminalOff, "terminal", "SUPER + L", true).state.keys, { terminal: ["SUPER + L"], lock: [] });
    assert.deepEqual(mergedKeys(yours({ terminal: [], lock: [] })).lock, []);
    assert.deepEqual(withPreset(yours({ lock: [] }), "i3"), { state: { preset: "i3", keys: {} } }, "your own go");
    assert.ok(withPreset(NO_KEYS, "awesome").error);
});

// Editing the keys on tidewm (SPEC.md §5.3, §16).
import { fromTidewmKeys, tidewmKeys, nameLabel, parseTidewmCatalog, listedTidewmCatalog, keysConf } from "./keys.mjs";

// One named binding as tidewm's GET_NAMED_BINDINGS gives it.
function named(fields) {
    return Object.assign({
        name: "terminal", type: "key", keys: ["Mod4+t"], default_keys: ["Mod4+t"], command: "exec foot",
        mode: "default", release: false, locked: false, kept_open: false,
    }, fields);
}

test("tidewm's keys read as Hyprland writes them, and back", () => {
    assert.equal(fromTidewmKeys("Mod4+Shift+t"), "SUPER + SHIFT + t");
    assert.equal(fromTidewmKeys("Shift+Control+Mod1+Super+Return"), "SUPER + CTRL + ALT + SHIFT + Return");
    assert.equal(fromTidewmKeys("Lock+Print"), "Print");
    assert.equal(fromTidewmKeys("Hyper+x"), null);
    assert.equal(tidewmKeys("SUPER + SHIFT + G"), "Mod4+Shift+G");
    assert.equal(tidewmKeys("CTRL + ALT + Delete"), "Ctrl+Mod1+Delete");
    assert.equal(tidewmKeys("Print"), "Print");
    assert.equal(tidewmKeys("SUPER + code:28"), null, "tidewm binds by keysym alone");
    assert.equal(tidewmKeys("SUPER + mouse:272"), null);
    assert.equal(tidewmKeys("HYPER + x"), null);
    // As the page compares them.
    assert.equal(keysId(fromTidewmKeys("Mod4+period")), keysLabel(0, "Mod4+period"));
});

test("a name says what a tidewm binding does", () => {
    assert.equal(nameLabel("next_keyboard_layout"), "Next keyboard layout");
    assert.equal(nameLabel("terminal"), "Terminal");
});

test("tidewm's named bindings parse to the page's list, the top level's keys alone", () => {
    const text = JSON.stringify([
        named({ keys: ["Mod4+Return"] }),
        named({ name: "float", keys: [], default_keys: ["Mod4+Shift+f", "Mod4+Insert"], command: "floating toggle" }),
        named({ name: "grow", mode: "resize", keys: ["l"], default_keys: ["l"] }),
        named({ name: "maximize", type: "mouse", keys: ["Mod4+button2"], default_keys: ["Mod4+button2"] }),
    ]);
    assert.deepEqual(parseTidewmCatalog(text).binds, [
        { name: "terminal", does: "Terminal", defaults: ["SUPER + t"], keys: ["SUPER + Return"] },
        { name: "float", does: "Float", defaults: ["SUPER + SHIFT + f", "SUPER + Insert"], keys: [] },
    ]);
});

test("tidewm's named bindings that can't be read are none, and why", () => {
    assert.deepEqual(listedTidewmCatalog(true, ""), { binds: [], error: "couldn't run tide-msg --type get_named_bindings" });
    assert.equal(listedTidewmCatalog(false, '{"success": false, "error": "unsupported message type"}').error,
        "tide-msg --type get_named_bindings: unsupported message type; is tidewm too old to change them?");
    assert.match(listedTidewmCatalog(false, "nope").error, /not JSON/);
    assert.match(listedTidewmCatalog(false, "{}").error, /expected a list/);
    assert.match(listedTidewmCatalog(false, '[{"name": "x"}]').error, /without its name, keys or default keys/);
    assert.match(listedTidewmCatalog(false, JSON.stringify([named({ keys: ["Hyper+x"] })])).error, /terminal's keys/);
});

test("the page's rows and edits work on tidewm's list", () => {
    const catalog = parseTidewmCatalog(JSON.stringify([
        named({}), named({ name: "lock", keys: ["Mod4+l"], default_keys: ["Mod4+l"], command: "exec lock" }),
    ])).binds;
    const binds = parseTidewmBinds(JSON.stringify([
        { type: "key", keys: "Mod4+t", command: "exec foot", mode: "default", name: "terminal" },
        { type: "key", keys: "Mod4+l", command: "exec lock", mode: "default", name: "lock" },
        { type: "key", keys: "Mod4+x", command: "kill", mode: "default", name: "" },
    ])).binds;
    const rows = shortcutRows(catalog, binds, NO_KEYS);
    assert.deepEqual(rows.named.map(r => [r.name, r.label, r.changed]), [["terminal", "Super+T", false], ["lock", "Super+L", false]]);
    assert.deepEqual(rows.fixed.map(b => b.keys), ["Super+X"]);
    assert.deepEqual(withKeys(NO_KEYS, catalog, "terminal", "SUPER + L", false, []).clash, { name: "lock", does: "Lock" });
    // A swap gives lock terminal's keys, as Hyprland writes them.
    assert.deepEqual(withKeys(NO_KEYS, catalog, "terminal", "SUPER + L", true, []).state.keys,
        { terminal: ["SUPER + L"], lock: ["SUPER + t"] });
    assert.deepEqual(withKeys(NO_KEYS, catalog, "terminal", "SUPER + T", false, []).state.keys, {}, "back at its default");
});

test("tide-keys.conf rebinds each binding you changed, and the preset's", () => {
    assert.deepEqual(keysConf(yours({ terminal: ["SUPER + Return", "SUPER + CTRL + T"], lock: [] })), {
        text: "# Written by tide's Keyboard shortcuts (SPEC.md §16); changes here are lost.\n" +
            "rebind lock none\nrebind terminal Mod4+Return Mod4+Ctrl+T\n",
        errors: [],
    });
    assert.deepEqual(keysConf(NO_KEYS).text, "# Written by tide's Keyboard shortcuts (SPEC.md §16); changes here are lost.\n");
    assert.match(keysConf({ preset: "dwm", keys: {} }).text, /^rebind terminal Mod4\+Shift\+Return$/m);
    // Keys tidewm can't bind are left out, and with none left it keeps its own.
    assert.deepEqual(keysConf(yours({ terminal: ["SUPER + code:28"], lock: ["SUPER + code:29", "SUPER + K"] })), {
        text: "# Written by tide's Keyboard shortcuts (SPEC.md §16); changes here are lost.\nrebind lock Mod4+K\n",
        errors: ["lock: tidewm can't bind SUPER + code:29", "terminal: tidewm can't bind SUPER + code:28"],
    });
});

import { keysWritable } from "./keys.mjs";

test("on tidewm, your keys are written only once it's said it takes rebind lines", () => {
    assert.equal(keysWritable(false, false), true, "Hyprland's conf reads tide-keys.lua whatever it is");
    assert.equal(keysWritable(true, false), false, "a tidewm from before named bindings would reject the file");
    assert.equal(keysWritable(true, true), true);
});
