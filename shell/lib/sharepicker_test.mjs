// Tests for sharepicker.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    REPEAT_MS, areaFor, decimalToHex, isUltrawide, options, orderWindows,
    parseWindows, preselect, selectionLine, shareLabel, validReply
} from "./sharepicker.mjs";

const wide = { name: "DP-1", width: 3440, height: 1440 };
const laptop = { name: "eDP-1", width: 1920, height: 1200 };

test("xdph's window list parses into id, class, title and address", () => {
    const list = "11[HC>]kitty[HT>]~/src[HE>]94509173227536[HA>]"
        + "22[HC>]google-chrome[HT>]Meet - Design review[HE>]0[HA>]";
    assert.deepEqual(parseWindows(list), [
        { id: "11", cls: "kitty", title: "~/src", address: "55f4a1b2c010" },
        { id: "22", cls: "google-chrome", title: "Meet - Design review", address: null },
    ]);
});

test("an empty or malformed window list gives no windows", () => {
    assert.deepEqual(parseWindows(""), []);
    assert.deepEqual(parseWindows(undefined), []);
    assert.deepEqual(parseWindows("x[HC>]a[HT>]b[HE>]1[HA>]"), []);
    assert.deepEqual(parseWindows("11[HC>]kitty[HA>]"), []);
});

test("decimal addresses convert to Hyprland's hex, past a double's precision", () => {
    assert.equal(decimalToHex("255"), "ff");
    assert.equal(decimalToHex("94509173227536"), "55f4a1b2c010");
    // 2^64 - 1, which a double can't hold exactly.
    assert.equal(decimalToHex("18446744073709551615"), "ffffffffffffffff");
    assert.equal(decimalToHex("0"), null);
    assert.equal(decimalToHex(""), null);
    assert.equal(decimalToHex("0x10"), null);
});

test("an ultrawide is 2:1 or wider", () => {
    assert.equal(isUltrawide(wide), true);
    assert.equal(isUltrawide({ name: "a", width: 5120, height: 1440 }), true);
    assert.equal(isUltrawide({ name: "a", width: 2560, height: 1440 }), false);
    assert.equal(isUltrawide(laptop), false);
    assert.equal(isUltrawide(null), false);
});

test("the 16:9 area is centered on a monitor wider than 16:9", () => {
    assert.deepEqual(areaFor(wide), { output: "DP-1", x: 440, y: 0, w: 2560, h: 1440 });
    // Scale 1.25 gives 2752×1152 logical pixels.
    assert.deepEqual(areaFor({ name: "DP-1", width: 2752, height: 1152 }), { output: "DP-1", x: 352, y: 0, w: 2048, h: 1152 });
    assert.equal(areaFor({ name: "a", width: 1920, height: 1080 }), null);
    assert.equal(areaFor(laptop), null);
});

test("windows on the current workspace come first, then by workspace", () => {
    const ws = { a: 3, b: 2, c: 1, d: 2 };
    const windows = ["a", "b", "c", "d", "e"].map(x => ({ id: x, address: x }));
    const order = orderWindows(windows, addr => ws[addr] ?? null, 2).map(w => w.id);
    assert.deepEqual(order, ["b", "d", "c", "a", "e"]);
});

test("options run screens, windows, then areas, with xdph's keys", () => {
    const windows = parseWindows("11[HC>]kitty[HT>]~/src[HE>]255[HA>]22[HC>]chrome[HT>][HE>]0[HA>]");
    const opts = options([wide, laptop], windows, addr => (addr === "ff" ? 1 : null), 1);
    assert.deepEqual(opts.map(o => o.key), [
        "screen:DP-1",
        "screen:eDP-1",
        "window:11",
        "window:22",
        "region:DP-1@440,0,2560,1440",
    ]);
    assert.equal(opts[2].label, "~/src");
    assert.equal(opts[2].detail, "1");
    // A window with no title is labeled by its class.
    assert.equal(opts[3].label, "chrome");
    assert.equal(opts[3].detail, "");
});

test("an ultrawide opens on the focused window, other monitors on the screen", () => {
    const windows = parseWindows("11[HC>]kitty[HT>]a[HE>]255[HA>]22[HC>]chrome[HT>]b[HE>]256[HA>]");
    const opts = options([wide, laptop], windows, () => 1, 1);
    assert.equal(opts[preselect(opts, { screen: wide, address: "100" }, null, 0)].key, "window:22");
    assert.equal(opts[preselect(opts, { screen: laptop, address: "100" }, null, 0)].key, "screen:eDP-1");
    // No focused window: the screen.
    assert.equal(opts[preselect(opts, { screen: wide, address: null }, null, 0)].key, "screen:DP-1");
    // Nothing focused at all: the first option.
    assert.equal(preselect(opts, { screen: null, address: null }, null, 0), 0);
    assert.equal(preselect([], { screen: null, address: null }, null, 0), -1);
});

test("a request within 10 s opens on the last choice, while it's offered", () => {
    const opts = options([wide, laptop], [], () => null, 1);
    const last = { key: "region:DP-1@440,0,2560,1440", time: 1000 };
    const focus = { screen: laptop, address: null };
    assert.equal(opts[preselect(opts, focus, last, 1000 + REPEAT_MS)].key, last.key);
    assert.equal(opts[preselect(opts, focus, last, 1001 + REPEAT_MS)].key, "screen:eDP-1");
    // A clock set back doesn't make an old choice recent.
    assert.equal(opts[preselect(opts, focus, last, 500)].key, "screen:eDP-1");
    // A choice no longer offered falls through.
    assert.equal(opts[preselect(opts, focus, { key: "window:9", time: 1000 }, 2000)].key, "screen:eDP-1");
});

test("the selection line is xdph's format, with r for reuse", () => {
    const opts = options([wide], parseWindows("11[HC>]kitty[HT>]a[HE>]255[HA>]"), () => 1, 1);
    assert.equal(selectionLine(opts[0], false), "[SELECTION]/screen:DP-1");
    assert.equal(selectionLine(opts[1], true), "[SELECTION]r/window:11");
    assert.equal(selectionLine(opts[2], false), "[SELECTION]/region:DP-1@440,0,2560,1440");
});

test("the share button names what it shares", () => {
    assert.equal(shareLabel({ kind: "screen" }), "Share screen");
    assert.equal(shareLabel({ kind: "window" }), "Share window");
    assert.equal(shareLabel({ kind: "region" }), "Share area");
    assert.equal(shareLabel(null), "Share");
});

test("the shell answers only on a reply pipe the picker made", () => {
    assert.equal(validReply("/run/user/1000/tide-share-picker.Ab12Cd", "/run/user/1000"), true);
    assert.equal(validReply("/run/user/1000/tide-share-picker.Ab12Cd", "/run/user/1000/"), true);
    assert.equal(validReply("/run/user/1000/tide-share-picker.", "/run/user/1000"), false);
    assert.equal(validReply("/run/user/1000/tide-share-picker.a/../x", "/run/user/1000"), false);
    assert.equal(validReply("/tmp/tide-share-picker.Ab12Cd", "/run/user/1000"), false);
    assert.equal(validReply("/run/user/1000/other", "/run/user/1000"), false);
    assert.equal(validReply("/run/user/1000/tide-share-picker.Ab12Cd", ""), false);
});
