// Tests for popups.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { NOT_TOLD, answered, layoutCall, nextCall, resynced } from "./popups.mjs";

test("the layout hears true or false", () => {
    assert.equal(layoutCall(true), "tide_layout.set_popups_open(true)");
    assert.equal(layoutCall(false), "tide_layout.set_popups_open(false)");
});

test("one call at a time, and none for what the layout already heard", () => {
    let c = nextCall(NOT_TOLD, false);
    assert.equal(c.send, false);
    const busy = nextCall(c.state, true);
    assert.equal(busy.send, null, "waits while a call is out");
    const s = answered(c.state, false, 0);
    assert.equal(nextCall(s, false).send, null, "already heard");
    assert.equal(nextCall(s, true).send, true);
});

test("a resync while a call is out sends again once it's answered", () => {
    // The shell sends true; Hyprland reloads its config before the answer.
    let c = nextCall({ ...NOT_TOLD, pushed: false }, true);
    assert.equal(c.send, true);
    const sentIn = c.state.generation;
    let s = resynced(c.state);
    assert.equal(nextCall(s, true).send, null, "still one call at a time");
    s = answered(s, true, sentIn);
    assert.equal(s.pushed, null, "the stale answer doesn't count as heard");
    assert.equal(nextCall(s, true).send, true, "so it's sent again");
});
