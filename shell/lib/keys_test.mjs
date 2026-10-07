// Tests for keys.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { keyLabel, keysLabel, parseBinds, listedBinds } from "./keys.mjs";

// One binding as Hyprland 0.56.2's `hyprctl binds -j` gives it
// (src/debug/HyprCtl.cpp's bindsRequest).
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
