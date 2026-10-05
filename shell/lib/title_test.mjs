// Tests for title.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_TITLE, barTitle, barWindow, activeAtStart, hasFocus, titleWidth, collapseClocks, MIN_TITLE_ROOM } from "./title.mjs";

const editor = { address: "abc", monitor: "DP-1", title: "SPEC.md - tide" };

test("the focused monitor shows the focused window's title", () => {
    assert.equal(barTitle({ monitor: "DP-1", active: editor }), "SPEC.md - tide");
});

test("every other monitor's bar is blank", () => {
    assert.equal(barTitle({ monitor: "DP-2", active: editor }), "", "another monitor, its own windows open");
    assert.equal(barWindow({ monitor: "DP-2", active: editor }), null);
});

test("with nothing focused, every bar is blank", () => {
    assert.equal(barTitle({ monitor: "DP-1", active: null }), "");
    assert.equal(barTitle({ monitor: null, active: editor }), "");
});

test("any focused window on this monitor shows: under a special workspace, or pinned", () => {
    const scratch = { address: "123", monitor: "DP-1", title: "Scratchpad" };
    assert.equal(barTitle({ monitor: "DP-1", active: scratch }), "Scratchpad", "special workspace");
    const pip = { address: "777", monitor: "DP-1", title: "Picture in picture" };
    assert.equal(barTitle({ monitor: "DP-1", active: pip }), "Picture in picture", "pinned");
});

test("at startup, the window hyprctl calls active has focus", () => {
    assert.equal(activeAtStart('{"address": "0x55d4e6f0a1b0", "title": "x"}'), "55d4e6f0a1b0");
    assert.equal(activeAtStart("{}"), null, "nothing focused, as on an empty workspace");
    assert.equal(activeAtStart("{}\n"), null);
    assert.equal(activeAtStart(""), undefined, "no answer");
    assert.equal(activeAtStart("not json"), undefined);
});

test("hasFocus reads activewindowv2's address", () => {
    assert.equal(hasFocus("55d4e6f0a1b0"), true);
    assert.equal(hasFocus("0x55d4e6f0a1b0"), true);
    assert.equal(hasFocus(""), false, "focus moved to an empty workspace");
    assert.equal(hasFocus(","), false);
    assert.equal(hasFocus(undefined), false);
});

test("a long title comes whole, for the bar to elide by width", () => {
    const long = "x".repeat(100) + " क्षत्रिय \u{1F1FA}\u{1F1F8}";
    assert.equal(barTitle({ monitor: "DP-1", active: { ...editor, title: long } }), long);
    assert.equal(MAX_TITLE, 60);
});

test("whitespace collapses onto one line", () => {
    assert.equal(barTitle({ monitor: "DP-1", active: { ...editor, title: "  a\n\tb  " } }), "a b");
});

test("a window with no title shows nothing", () => {
    assert.equal(barTitle({ monitor: "DP-1", active: { ...editor, title: undefined } }), "");
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

test("the bar's title stands for the window a double-click maximizes", () => {
    const focused = { monitor: "DP-1", address: "0xABC", title: "SPEC.md - tide" };
    assert.deepEqual(barWindow({ monitor: "DP-1", active: focused }), { address: "abc", title: "SPEC.md - tide" });
    assert.equal(barWindow({ monitor: "DP-1", active: { ...focused, address: "" } }), null, "no address");
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
