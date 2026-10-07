// Tests for shell/lib/steps.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { stepped } from "./steps.mjs";

test("a step moves to the next mark, rounded to the step's places", () => {
    assert.equal(stepped(0.55, 1, 0.05, 0.1, 0.9), 0.6);
    assert.equal(stepped(0.55, -1, 0.05, 0.1, 0.9), 0.5);
    assert.equal(stepped(0.6, 1, 0.05, 0.1, 0.9), 0.65, "0.6 / 0.05 is a hair under 12");
    assert.equal(stepped(1, 2, 0.25, 0.5, 3), 1.5);
    assert.equal(stepped(3, -1, 1, 0, 9), 2);
    assert.equal(stepped(0.55, 0, 0.05, 0.1, 0.9), 0.55);
});

test("off a mark, the first step lands on the nearest one that way", () => {
    assert.equal(stepped(0.73, 1, 0.05, 0.1, 0.9), 0.75);
    assert.equal(stepped(0.73, -1, 0.05, 0.1, 0.9), 0.7);
    assert.equal(stepped(0.72, -1, 0.05, 0.1, 0.9), 0.7);
    assert.equal(stepped(0.73, 2, 0.05, 0.1, 0.9), 0.8);
    // A scale Hyprland rounded to fit the screen.
    assert.equal(stepped(1.6, -1, 0.25, 0.5, 3), 1.5);
    assert.equal(stepped(1.4, 1, 0.25, 0.5, 3), 1.5);
});

test("a step stops at either end, and never moves back across one", () => {
    assert.equal(stepped(0.9, 1, 0.05, 0.1, 0.9), 0.9);
    assert.equal(stepped(0.1, -1, 0.05, 0.1, 0.9), 0.1);
    assert.equal(stepped(0.88, 1, 0.05, 0.1, 0.9), 0.9, "onto the end");
    // Past an end, as a file may set it.
    assert.equal(stepped(10, 1, 1, 0, 9), 10, "+ past the top stays");
    assert.equal(stepped(10, -1, 1, 0, 9), 9, "− comes back into range");
    assert.equal(stepped(0.25, -1, 0.25, 0.5, 3), 0.25, "− past the bottom stays");
    assert.equal(stepped(0.25, 1, 0.25, 0.5, 3), 0.5, "+ comes back into range");
});
