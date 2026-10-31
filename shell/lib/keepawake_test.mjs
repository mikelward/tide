// Tests for keepawake.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { OFF, ICON, migrated, sign } from "./keepawake.mjs";

test("it's a cup of coffee, one of tide's own icons", () => {
    assert.equal(ICON, "keep-awake-symbolic.svg");
});

test("it says whether it's keeping awake, and what holds it if you didn't ask", () => {
    assert.equal(sign({ on: false, asked: false, presenting: false }), "Not keeping awake");
    assert.equal(sign({ on: true, asked: true, presenting: false }), "Keeping awake");
    assert.equal(sign({ on: true, asked: true, presenting: true }), "Keeping awake", "your own request comes first");
    assert.equal(sign({ on: true, asked: false, presenting: true }), "Keeping awake while presenting");
    assert.equal(sign({ on: true, asked: false, presenting: false }), "Keeping awake while the mic is live");
});

test("it starts off", () => {
    assert.equal(OFF.on, false);
});

test("an old deadline still to come carries over as on, with no end", () => {
    assert.deepEqual(migrated({ on: false, until: 5000 }, 1000), { on: true, until: 0 });
});

test("an old deadline that has passed carries over as off", () => {
    // After a resume, say, before the old version's check cleared it.
    assert.deepEqual(migrated({ on: false, until: 1000 }, 5000), OFF);
    assert.deepEqual(migrated({ on: false, until: 1000 }, 1000), OFF);
});

test("this version's own state carries over as it was", () => {
    assert.deepEqual(migrated({ on: true, until: 0 }, 1000), { on: true, until: 0 });
    assert.deepEqual(migrated(OFF, 1000), OFF);
    assert.deepEqual(migrated(undefined, 1000), OFF);
});
