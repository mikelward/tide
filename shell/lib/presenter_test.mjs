// Tests for presenter.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { OFF, effective, presenterToggled, dndSet, keepAwakeToggled } from "./presenter.mjs";

const state = (presenting, dnd, keepAwake) => ({ presenting, dnd, keepAwake });

test("it starts off, with both toggles off", () => {
    assert.deepEqual(OFF, state(false, false, false));
    assert.deepEqual(effective(OFF), { dnd: false, keepAwake: false });
});

test("presenter mode turns on Do not disturb and keep awake together", () => {
    const on = presenterToggled(OFF);
    assert.deepEqual(on, state(true, false, false));
    assert.deepEqual(effective(on), { dnd: true, keepAwake: true });
});

test("turning it off puts each toggle back as it was before", () => {
    for (const dnd of [false, true]) {
        for (const keepAwake of [false, true]) {
            const before = state(false, dnd, keepAwake);
            const after = presenterToggled(presenterToggled(before));
            assert.deepEqual(after, before);
            assert.deepEqual(effective(after), { dnd, keepAwake });
        }
    }
});

test("a live mic holds keep awake through presenter mode and after it", () => {
    const after = presenterToggled(presenterToggled(OFF));
    assert.deepEqual(effective(after, true), { dnd: false, keepAwake: true });
    assert.deepEqual(effective(after, false), { dnd: false, keepAwake: false });
});

test("outside presenter mode the toggles work as they always have", () => {
    assert.deepEqual(dndSet(OFF, true), state(false, true, false));
    assert.deepEqual(dndSet(state(false, true, true), false), state(false, false, true));
    assert.deepEqual(keepAwakeToggled(OFF), state(false, false, true));
    assert.deepEqual(keepAwakeToggled(keepAwakeToggled(OFF)), OFF);
});

test("turning Do not disturb off while presenting ends it, and keep awake stays on", () => {
    const next = dndSet(state(true, false, false), false);
    assert.deepEqual(next, state(false, false, true));
    assert.deepEqual(effective(next), { dnd: false, keepAwake: true });
});

test("turning Do not disturb on while presenting changes nothing", () => {
    assert.deepEqual(dndSet(state(true, false, true), true), state(true, false, true));
});

test("turning keep awake off while presenting ends it, and Do not disturb stays on", () => {
    const next = keepAwakeToggled(state(true, false, false));
    assert.deepEqual(next, state(false, true, false));
    assert.deepEqual(effective(next), { dnd: true, keepAwake: false });
});

test("without the shell's Do not disturb, ending it by keep awake leaves Do not disturb alone", () => {
    assert.deepEqual(keepAwakeToggled(state(true, false, true), false), state(false, false, false));
});

test("a missing state reads as off", () => {
    assert.deepEqual(effective(undefined), { dnd: false, keepAwake: false });
    assert.deepEqual(presenterToggled(undefined), state(true, false, false));
});
