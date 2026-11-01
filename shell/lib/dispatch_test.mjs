// Tests for dispatch.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { focusWorkspace, focusWorkspaceName, renameWorkspace, focusWindow, toggleMaximize, moveWindowToWorkspace, moveWindowToNamed, closeWindow, minimizeWindow, sendWindowTo, floatWindow } from "./dispatch.mjs";

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

test("a workspace is reached by name, quoted for Lua", () => {
    // Under Lua, through conf's go(), which switches every monitor, or
    // Hyprland's own switch without it.
    const viaConf = (lit, sel) => 'function() if type(conf_workspaces) == "table" and type(conf_workspaces.go) == "function" then '
        + `conf_workspaces.go(${lit}) else hl.dispatch(hl.dsp.focus({ workspace = ${sel} })) end end`;
    assert.equal(focusWorkspaceName("in", true), viaConf('"in"', '"name:in"'));
    assert.equal(focusWorkspaceName('PR-12 "x", y\\z', true), viaConf('"PR-12 \\"x\\", y\\\\z"', '"name:PR-12 \\"x\\", y\\\\z"'));
    assert.equal(focusWorkspaceName("PR-12 login", false), "workspace name:PR-12 login");
    assert.equal(focusWorkspaceName("2", true), viaConf('"2"', '"name:2"'));
});

test("home is renamed back by its ID", () => {
    assert.equal(renameWorkspace(-1338, "in", true), 'hl.dsp.workspace.rename({ workspace = -1338, name = "in" })');
    assert.equal(renameWorkspace(-1338, "in", false), "renameworkspace -1338 in");
});

test("a name that isn't one line, or isn't text, goes into no dispatch", () => {
    assert.throws(() => focusWorkspaceName("a\nb", true), /not a workspace name/);
    assert.throws(() => focusWorkspaceName("  ", false), /not a workspace name/);
    assert.throws(() => focusWorkspaceName(3, true), /not a workspace name/);
    assert.throws(() => renameWorkspace("x", "in", true), /not a workspace ID/);
});

test("the name prompt moves its window by address, following it", () => {
    assert.equal(moveWindowToWorkspace("55AA01", "PR-12, login", true),
        'hl.dsp.window.move({ workspace = "name:PR-12, login", follow = true, window = "address:0x55aa01" })');
    assert.equal(moveWindowToWorkspace("0x55aa01", "docs", false), "movetoworkspace name:docs,address:0x55aa01");
    assert.throws(() => moveWindowToWorkspace("x) os.exit(", "docs", true), /not a window address/);
    assert.throws(() => moveWindowToWorkspace("55aa01", "a\nb", true), /not a workspace name/);
});

test("its Esc closes a window politely, by address", () => {
    assert.equal(closeWindow("55aa01", true), 'hl.dsp.window.close({ window = "address:0x55aa01" })');
    assert.equal(closeWindow("55aa01", false), "closewindow address:0x55aa01");
});

test("minimizing moves a window silently to its workspace's minimize workspace", () => {
    assert.equal(minimizeWindow("55AA01", "re", true),
        'hl.dsp.window.move({ workspace = "special:minimized:re", follow = false, window = "address:0x55aa01" })');
    assert.equal(minimizeWindow("0x55aa01", "PR-12, login", false), "movetoworkspacesilent special:minimized:PR-12, login,address:0x55aa01");
    assert.throws(() => minimizeWindow("x) os.exit(", "re", true), /not a window address/);
    assert.throws(() => minimizeWindow("55aa01", "a\nb", true), /not a workspace name/);
    assert.throws(() => minimizeWindow("55aa01", "", true), /not a workspace name/);
});

test("a home app's stray window goes home without following it", () => {
    assert.equal(sendWindowTo("55AA01", "in", true),
        'hl.dsp.window.move({ workspace = "name:in", follow = false, window = "address:0x55aa01" })');
    assert.equal(sendWindowTo("0x55aa01", "in", false), "movetoworkspacesilent name:in,address:0x55aa01");
    assert.throws(() => sendWindowTo("x) os.exit(", "in", true), /not a window address/);
});

test("floating a window a new rule covers enables floating, by its address, in either config", () => {
    assert.equal(floatWindow("55AA01", true), 'hl.dsp.window.float({ action = "enable", window = "address:0x55aa01" })');
    assert.equal(floatWindow("0x55aa01", false), "setfloating address:0x55aa01");
    assert.throws(() => floatWindow("not-hex", true), /not a window address/);
});

test("the name prompt's move goes through conf's move, which keeps the window's monitor", () => {
    assert.equal(moveWindowToNamed("55AA01", "docs", true),
        'function() if type(conf_workspaces) == "table" and type(conf_workspaces.move) == "function" then '
        + 'conf_workspaces.move("0x55aa01", "docs", true) '
        + 'else hl.dispatch(hl.dsp.window.move({ workspace = "name:docs", follow = true, window = "address:0x55aa01" })) end end');
    assert.equal(moveWindowToNamed("0x55aa01", "docs", false), "movetoworkspace name:docs,address:0x55aa01");
    assert.throws(() => moveWindowToNamed("x) os.exit(", "docs", true), /not a window address/);
    assert.throws(() => moveWindowToNamed("55aa01", "a\nb", true), /not a workspace name/);
});
