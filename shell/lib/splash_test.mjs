// Tests for splash.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { GIVE_UP_AFTER_MS, SLOW_AFTER_MS, initial, next, text } from "./splash.mjs";

test("it shows until the shell is ready, and says how long that took", () => {
    let s = initial(1000);
    let r = next(s, "activating", 2000);
    assert.equal(r.quit, false);
    assert.equal(r.log, null);
    assert.equal(text(r.state), "Starting tide");
    r = next(r.state, "active", 5400);
    assert.equal(r.quit, true);
    assert.equal(r.log, "the shell is ready after 4 s");
});

test("a slow start says so on screen and in the journal, once", () => {
    let r = next(initial(0), "activating", SLOW_AFTER_MS);
    assert.equal(r.quit, false);
    assert.equal(r.log, "the shell isn't ready after 10 s (tide.service is activating)");
    assert.equal(text(r.state), "Still starting tide");
    r = next(r.state, "activating", SLOW_AFTER_MS + 1000);
    assert.equal(r.log, null);
});

test("a shell that fails leaves the screen to the fallback", () => {
    const r = next(initial(0), "failed", 3000);
    assert.equal(r.quit, true);
    assert.equal(r.log, "the shell failed after 3 s; the fallback takes over");
});

test("it never stays past the limit, whatever systemd says", () => {
    for (const status of ["activating", "inactive", ""]) {
        const r = next(initial(0), status, GIVE_UP_AFTER_MS);
        assert.equal(r.quit, true, status);
        assert.match(r.log, /going anyway$/);
    }
});

test("once it's going, later answers change nothing", () => {
    const r = next(initial(0), "active", 1000);
    const again = next(r.state, "failed", 2000);
    assert.equal(again.quit, false);
    assert.equal(again.log, null);
});
