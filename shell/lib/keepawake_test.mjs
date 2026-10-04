// Tests for keepawake.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { OFF, migrated, toggled } from "./keepawake.mjs";

test("it starts off", () => {
    assert.equal(OFF.on, false);
});

test("a click turns it on, with no end", () => {
    assert.deepEqual(toggled(OFF), { on: true, until: 0 });
});

test("a second click turns it off", () => {
    assert.deepEqual(toggled(toggled(OFF)), OFF);
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
