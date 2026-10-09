// Tests for unplug.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { COMMAND, INITIAL, next } from "./unplug.mjs";

// Runs events from `state`, collecting each result's run.
function run(events, state = INITIAL) {
    const runs = [];
    for (const event of events) {
        const r = next(state, event);
        state = r.state;
        runs.push(r.run);
    }
    return { state: state, runs: runs };
}

test("the switch to battery checks the flag", () => {
    const r = run([{ type: "power", onBattery: true }]);
    assert.deepEqual(r.runs, [true]);
    assert.equal(r.state.checking, true);
    assert.deepEqual(COMMAND, ["tide", "idle-suspend", "--unplugged"]);
});

test("the switch to AC checks nothing", () => {
    assert.deepEqual(run([{ type: "power", onBattery: false }]).runs, [false]);
});

test("power that flaps during a check is checked again once it ends", () => {
    // Battery, AC, battery again: the check may have seen AC.
    const r = run([
        { type: "power", onBattery: true },
        { type: "power", onBattery: false },
        { type: "power", onBattery: true },
        { type: "done" },
        { type: "done" },
    ]);
    assert.deepEqual(r.runs, [true, false, false, true, false]);
    assert.equal(r.state.checking, false);
});

test("power left on AC after a flap isn't checked again", () => {
    const r = run([
        { type: "power", onBattery: true },
        { type: "power", onBattery: false },
        { type: "done" },
    ]);
    assert.deepEqual(r.runs, [true, false, false]);
    assert.equal(r.state.checking, false);
});

test("a check that ends lets the next switch check again", () => {
    const r = run([
        { type: "power", onBattery: true },
        { type: "done" },
        { type: "power", onBattery: false },
        { type: "power", onBattery: true },
    ]);
    assert.deepEqual(r.runs, [true, false, false, true]);
});
