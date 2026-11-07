// Tests for wallclock.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { CHECK_MS, jumped } from "./wallclock.mjs";

const t = Date.UTC(2026, 10, 7, 9, 30, 0);

test("a check on time, or a little late, isn't a jump", () => {
    assert.equal(jumped(t, t + CHECK_MS), false);
    assert.equal(jumped(t, t + CHECK_MS + 1500), false, "a busy shell");
    assert.equal(jumped(t, t + CHECK_MS - 50), false, "a timer that fires early");
});

test("waking from sleep is a jump", () => {
    assert.equal(jumped(t, t + 8 * 60 * 60 * 1000), true);
    assert.equal(jumped(t, t + CHECK_MS + 5000), true, "even a short sleep");
});

test("the time being set back is a jump", () => {
    assert.equal(jumped(t, t - 60 * 60 * 1000), true);
});
