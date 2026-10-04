// Tests for keepawake.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { toggled, isOn, remaining, OFF, HOLD_MS } from "./keepawake.mjs";

test("a click turns it on for two hours", () => {
    const on = toggled(OFF, 1000);
    assert.equal(isOn(on, 1000), true);
    assert.equal(remaining(on, 1000), HOLD_MS);
    assert.equal(HOLD_MS, 2 * 60 * 60 * 1000);
});

test("a second click turns it off", () => {
    const on = toggled(OFF, 0);
    const off = toggled(on, 60000);
    assert.equal(isOn(off, 60000), false);
    assert.equal(remaining(off, 60000), 0);
});

test("it turns itself off when its time is up", () => {
    const on = toggled(OFF, 0);
    assert.equal(isOn(on, HOLD_MS - 1), true);
    assert.equal(isOn(on, HOLD_MS), false);
    // A click after it ran out turns it on again, rather than off.
    assert.equal(isOn(toggled(on, HOLD_MS + 5), HOLD_MS + 5), true);
});

test("a missing or malformed state is off", () => {
    assert.equal(isOn(null, 0), false);
    assert.equal(isOn({ on: true, until: NaN }, 0), false);
    assert.equal(isOn({ on: false, until: 99 }, 0), false);
});
