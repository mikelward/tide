// Tests for title.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_TITLE, barTitle, barWindow, focusReached, shownWorkspace, hasFocus, titleWidth, collapseClocks, MIN_TITLE_ROOM } from "./title.mjs";

const editor = { address: "abc", workspace: 2, monitor: "DP-1", title: "SPEC.md - tide" };
const chat = { address: "def", workspace: 5, monitor: "DP-2", title: "Chat" };
const windows = [editor, chat];

test("the focused monitor shows the focused window's title", () => {
    assert.equal(barTitle({ monitor: "DP-1", workspace: 2, active: editor, lastWindow: "0xdef", windows }), "SPEC.md - tide");
});

test("another monitor shows its own workspace's last focused window", () => {
    assert.equal(barTitle({ monitor: "DP-2", workspace: 5, active: editor, lastWindow: "0xdef", windows }), "Chat");
    assert.equal(barTitle({ monitor: "DP-2", workspace: 5, active: null, lastWindow: "DEF", windows }), "Chat");
});

test("a monitor shows its open special workspace over the regular one", () => {
    assert.equal(shownWorkspace(2, -98), -98);
    assert.equal(shownWorkspace(2, 0), 2);
    assert.equal(shownWorkspace(2, undefined), 2);
    assert.equal(shownWorkspace(null, 0), null);
});

test("a special workspace's title is its own, focused or not", () => {
    const scratch = { address: "123", workspace: -98, monitor: "DP-1", title: "Scratchpad" };
    const all = [...windows, scratch];
    assert.equal(barTitle({ monitor: "DP-1", workspace: -98, active: scratch, lastWindow: "0xabc", windows: all }), "Scratchpad", "focused");
    assert.equal(barTitle({ monitor: "DP-1", workspace: -98, active: chat, lastWindow: "0x123", windows: all }), "Scratchpad", "focus on another monitor");
    assert.equal(barTitle({ monitor: "DP-2", workspace: 5, active: scratch, lastWindow: "0xdef", windows: all }), "Chat", "a monitor without it");
});

test("any focused window on this monitor shows: under a special workspace, or pinned", () => {
    const scratch = { address: "123", workspace: -98, monitor: "DP-1", title: "Scratchpad" };
    const all = [...windows, scratch];
    assert.equal(barTitle({ monitor: "DP-1", workspace: -98, active: editor, lastWindow: "0x123", windows: all }), "SPEC.md - tide", "under the special workspace");
    // A pinned window still reports the workspace it came from.
    const pip = { address: "777", workspace: 3, monitor: "DP-1", title: "Picture in picture" };
    assert.equal(barTitle({ monitor: "DP-1", workspace: 2, active: pip, lastWindow: "0xabc", windows: [...all, pip] }), "Picture in picture", "pinned");
});

test("with nothing focused, the shown workspace's own last window shows", () => {
    assert.equal(barTitle({ monitor: "DP-1", workspace: 7, active: null, lastWindow: "", windows }), "");
});

test("hasFocus reads activewindowv2's address", () => {
    assert.equal(hasFocus("55d4e6f0a1b0"), true);
    assert.equal(hasFocus("0x55d4e6f0a1b0"), true);
    assert.equal(hasFocus(""), false, "focus moved to an empty workspace");
    assert.equal(hasFocus(","), false);
    assert.equal(hasFocus(undefined), false);
});

test("an empty workspace, or one whose last window left, shows nothing", () => {
    assert.equal(barTitle({ monitor: "DP-1", workspace: 7, active: null, lastWindow: "", windows }), "");
    assert.equal(barTitle({ monitor: "DP-1", workspace: 7, active: null, lastWindow: "0xabc", windows }), "", "moved to 2");
    assert.equal(barTitle({ monitor: "DP-1", workspace: 7, active: null, lastWindow: "0x999", windows }), "", "closed");
    assert.equal(barTitle({ monitor: "DP-1", workspace: null, active: editor, lastWindow: "0xabc", windows }), "");
});


test("a long title comes whole, for the bar to elide by width", () => {
    const long = "x".repeat(100) + " क्षत्रिय \u{1F1FA}\u{1F1F8}";
    assert.equal(barTitle({ monitor: "DP-1", workspace: 2, active: { ...editor, title: long }, lastWindow: "", windows }), long);
    assert.equal(MAX_TITLE, 60);
});

test("whitespace collapses onto one line", () => {
    assert.equal(barTitle({ monitor: "DP-1", workspace: 2, active: { ...editor, title: "  a\n\tb  " }, lastWindow: "", windows }), "a b");
});

test("a window with no title shows nothing", () => {
    assert.equal(barTitle({ monitor: "DP-1", workspace: 2, active: { ...editor, title: undefined }, lastWindow: "", windows }), "");
});

test("the title keeps clear of the nearer side, the Sharing pill included", () => {
    const bar = { implicit: 400, max: 500, barWidth: 1000, left: 200, gap: 32 };
    // Right group starts at 800: 300 each side of the middle.
    assert.equal(titleWidth({ ...bar, right: 800 }), 400);
    // A Sharing pill moves the right group's start to 620: 120 of room.
    assert.equal(titleWidth({ ...bar, right: 620 }), 2 * 120 - 32);
    assert.equal(titleWidth({ ...bar, implicit: 600, right: 900 }), 500);
    assert.equal(titleWidth({ ...bar, right: 500 }), 0);
});

test("the bar's title stands for a window a double-click can maximize", () => {
    const windows = [
        { address: "0xabc", workspace: 2, title: "SPEC.md - tide" },
        { address: "0xdef", workspace: 5, title: "Chat" },
    ];
    const editor = { monitor: "DP-1", address: "0xABC", title: "SPEC.md - tide" };
    // The focused window, on its own monitor.
    assert.deepEqual(barWindow({ monitor: "DP-1", workspace: 2, active: editor, lastWindow: "0xabc", windows }), { address: "abc", title: "SPEC.md - tide" });
    // Another monitor's last focused window.
    assert.deepEqual(barWindow({ monitor: "DP-2", workspace: 5, active: editor, lastWindow: "0xdef", windows }), { address: "def", title: "Chat" });
    // Nothing to maximize on an empty workspace.
    assert.equal(barWindow({ monitor: "DP-2", workspace: 7, active: null, lastWindow: "", windows }), null);
});

test("a cross-monitor maximize waits for focus to reach its window", () => {
    assert.equal(focusReached("abc", "0xabc"), true);
    assert.equal(focusReached("abc", "abc,"), true);
    assert.equal(focusReached("abc", "0xdef"), false);
    // Focus moving to an empty workspace names no window.
    assert.equal(focusReached("abc", ","), false);
    assert.equal(focusReached(null, "0xabc"), false);
});

test("the zone clocks collapse only when the title would be squeezed", () => {
    // Every clock takes 330 px; local alone, 80.
    const full = { clocksWidth: 330, fullClocksWidth: 330 };
    const local = { clocksWidth: 80, fullClocksWidth: 330 };
    const bar = { barWidth: 1536, left: 480, gap: 32 };
    // A wide bar: plenty of room with every clock.
    assert.equal(collapseClocks({ barWidth: 3440, left: 480, gap: 32, right: 2600, ...full }), false);
    // At 1536 px with every clock, the right group starts at 840: 2 * 72 - 32
    // of room, under MIN_TITLE_ROOM.
    assert.equal(collapseClocks({ ...bar, right: 840, ...full }), true);
    // Collapsed, the group starts 250 px further right; the answer comes
    // from the full layout, so it stays collapsed.
    assert.equal(collapseClocks({ ...bar, right: 1090, ...local }), true);
    // Exactly MIN_TITLE_ROOM is enough, collapsed or not.
    const edge = 1536 / 2 + (MIN_TITLE_ROOM + 32) / 2;
    assert.equal(collapseClocks({ ...bar, right: edge, ...full }), false);
    assert.equal(collapseClocks({ ...bar, right: edge + 250, ...local }), false);
    // When the workspaces' side is what's short, hiding clocks wouldn't
    // help the centered title, so they stay.
    assert.equal(collapseClocks({ ...bar, left: 700, right: 1300, ...full }), false);
});
