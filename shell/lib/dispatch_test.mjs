// Tests for dispatch.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { focusEmptyWorkspace, focusWorkspace, focusWindow, toggleMaximize } from "./dispatch.mjs";

test("a Lua config gets hl.dsp calls", () => {
    assert.equal(focusWorkspace(3, true), "hl.dsp.focus({ workspace = 3 })");
    assert.equal(focusWindow("55d3a1b2c0", true), 'hl.dsp.focus({ window = "address:0x55d3a1b2c0" })');
});

test("hyprlang gets the text form", () => {
    assert.equal(focusWorkspace(3, false), "workspace 3");
    assert.equal(focusWindow("0x55D3A1B2C0", false), "focuswindow address:0x55d3a1b2c0");
});

test("nothing but a workspace number or a hex address goes into a dispatch", () => {
    assert.throws(() => focusWorkspace("3) os.exit(", true), /not a workspace ID/);
    assert.throws(() => focusWorkspace(null, true), /not a workspace ID/);
    assert.throws(() => focusWindow('abc" })', true), /not a window address/);
    assert.throws(() => focusWindow("", false), /not a window address/);
});

test("maximize toggles Hyprland's fullscreen state 1", () => {
    assert.equal(toggleMaximize(true), 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })');
    assert.equal(toggleMaximize(false), "fullscreen 1");
});

test("Ctrl+Enter's empty workspace is Hyprland's emptym selector, in either form", () => {
    assert.equal(focusEmptyWorkspace(true), 'hl.dsp.focus({ workspace = "emptym" })');
    assert.equal(focusEmptyWorkspace(false), "workspace emptym");
});
