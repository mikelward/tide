import { test } from "node:test";
import assert from "node:assert/strict";
import { workspaceOf } from "./span.mjs";

test("a monitor's part is read as its workspace", () => {
    assert.equal(workspaceOf("re@DP-2"), "re");
    assert.equal(workspaceOf("tax return@HDMI-A-1"), "tax return");
    assert.equal(workspaceOf("re"), "re");
    assert.equal(workspaceOf("2"), "2");
});

test("a special workspace and odd names are left alone", () => {
    assert.equal(workspaceOf("special:minimized:re"), "special:minimized:re");
    assert.equal(workspaceOf("@DP-2"), "@DP-2");
    assert.equal(workspaceOf("re@"), "re@");
    assert.equal(workspaceOf(undefined), "");
});
