// Tests for why.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PREFIX, line, workspaceShown, focusMoved } from "./why.mjs";

test("a line starts tide why:, which tide report-bug looks for", () => {
    assert.equal(PREFIX, "tide why:");
    assert.equal(line("go to workspace web", "the bar"), "tide why: go to workspace web: the bar");
});

test("a line with no cause has no colon after it", () => {
    assert.equal(line("workspace web shows", ""), "tide why: workspace web shows");
});

test("a name with a line break stays on one line", () => {
    assert.equal(line("go to workspace a\nb", "the\r\nbar"), "tide why: go to workspace a b: the bar");
});

test("a workspace coming up is a line; the same one again, or none, isn't", () => {
    assert.equal(workspaceShown("in", "web"), "tide why: workspace web shows");
    assert.equal(workspaceShown("web", "web"), null);
    assert.equal(workspaceShown("web", ""), null);
});

test("focus moving is a line naming the app, its window and the workspace", () => {
    const kitty = { address: "0x1", app: "kitty" };
    assert.equal(focusMoved(null, kitty, "web"), "tide why: kitty (0x1) has focus on web");
    assert.equal(focusMoved(kitty, null, "web"), "tide why: no window has focus on web");
    assert.equal(focusMoved(kitty, { address: "0x1", app: "kitty" }, "web"), null, "the same window");
    assert.equal(focusMoved(null, { address: "0x2", app: "" }, ""), "tide why: a window (0x2) has focus");
});
