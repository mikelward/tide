// Tests for workspacekeys.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { workspaceOrder } from "./workspaces.mjs";
import { NO_HISTORY, HISTORY_SIZE, used, lastUsed, nth, homeOrBack, lastOther, step } from "./workspacekeys.mjs";

const standing = ["in", "re"];
// Visits each in turn from an empty history.
const visit = (...names) => names.reduce((h, n) => used(h, n, "in"), NO_HISTORY);
const place = (names) => ({ home: "in", standing, names });

test("the history keeps the workspace used last first, once each", () => {
    assert.deepEqual(visit("a", "b", "a", "c"), ["c", "a", "b"]);
});

test("the history leaves out home, special workspaces and none", () => {
    assert.deepEqual(visit("a", "in", "special:minimized", "", "b"), ["b", "a"]);
});

test("a monitor's part of a spanning workspace counts as the workspace", () => {
    assert.deepEqual(visit("a@DP-2", "b", "a"), ["a", "b"]);
});

test("the history keeps the last fifty", () => {
    const names = Array.from({ length: HISTORY_SIZE + 5 }, (_, i) => `w${i}`);
    const h = visit(...names);
    assert.equal(h.length, HISTORY_SIZE);
    assert.equal(h[0], `w${HISTORY_SIZE + 4}`);
});

test("Super+N goes to the Nth workspace on the bar, standing ones first, made or not", () => {
    const order = workspaceOrder([{ id: 1, order: -1, name: "in" }, { id: 2, order: -2, name: "x" }, { id: 3, order: -3, name: "y" }], standing);
    assert.equal(nth(order, 1), "in");
    assert.equal(nth(order, 2), "re");
    assert.equal(nth(order, 3), "x");
    assert.equal(nth(order, 4), "y");
});

test("Super+N past the last workspace goes nowhere, and Super+0 is the last", () => {
    const order = [{ name: "in" }, { name: "re" }, { name: "x" }];
    assert.equal(nth(order, 4), null);
    assert.equal(nth(order, 9), null);
    assert.equal(nth(order, 0), "x");
    assert.equal(nth([], 0), null);
});

test("Super+N takes only 0 to 9", () => {
    const order = Array.from({ length: 12 }, (_, i) => ({ name: `w${i}` }));
    assert.equal(nth(order, 10), null);
    assert.equal(nth(order, -1), null);
    assert.equal(nth(order, 1.5), null);
});

test("Super+Tab goes home from any other workspace", () => {
    assert.equal(homeOrBack("x", visit("x"), place(["in", "x"])), "in");
    assert.equal(homeOrBack("", NO_HISTORY, place(["in"])), "in");
});

test("Super+Tab goes from home back to the last other workspace, so presses toggle", () => {
    const h = visit("x", "y");
    assert.equal(homeOrBack("in", h, place(["in", "x", "y"])), "y");
});

test("Super+Tab from home skips a workspace removed since, and with none stays", () => {
    const h = visit("x", "y");
    assert.equal(homeOrBack("in", h, place(["in", "x"])), "x");
    assert.equal(homeOrBack("in", h, place(["in"])), null);
});

test("a standing workspace counts as still there, made or not, in any case", () => {
    const h = visit("Re");
    assert.equal(homeOrBack("in", h, place(["in"])), "Re");
});

test("a workspace in the history that became home isn't gone back to", () => {
    const h = visit("x", "y");
    assert.equal(homeOrBack("y", h, { home: "y", standing: ["y"], names: ["x", "y"] }), "x");
});

test("Super+End goes to the last workspace other than home and this one", () => {
    const h = visit("x", "y");
    const p = place(["in", "x", "y"]);
    assert.equal(lastOther("y", h, p), "x");
    assert.equal(lastOther("x", visit("x", "y", "x"), p), "y");
});

test("Super+End from home goes where Super+Tab does, never home", () => {
    const h = visit("x", "y");
    const p = place(["in", "x", "y"]);
    assert.equal(lastOther("in", h, p), homeOrBack("in", h, p));
    assert.equal(lastOther("x", visit("x"), place(["in", "x"])), null);
});

test("lastUsed with nothing used is null", () => {
    assert.equal(lastUsed(NO_HISTORY, place(["in", "x"])), null);
});

// The bar's order: in, re, two empty, then ti, made before re
const BAR = ["in", "re", "ab", "cd", "ti"].map(name => ({ name }));

test("Super+PgDn goes to the next workspace on the bar with a window, not the next made", () => {
    assert.equal(step(BAR, "in", 1, { withWindows: ["in", "re", "ti"] }), "re");
    assert.equal(step(BAR, "re", 1, { withWindows: ["in", "re", "ti"] }), "ti", "past the empty ones");
});

test("Super+PgDn goes round from the last to the first, and PgUp back", () => {
    assert.equal(step(BAR, "ti", 1, { withWindows: ["in", "re", "ti"] }), "in");
    assert.equal(step(BAR, "in", -1, { withWindows: ["in", "re", "ti"] }), "ti");
    assert.equal(step(BAR, "re", -1, { withWindows: ["in", "re", "ti"] }), "in");
});

test("from an empty workspace, Super+PgDn goes to the next with a window", () => {
    assert.equal(step(BAR, "ab", 1, { withWindows: ["in", "ti"] }), "ti");
});

test("with no other workspace with a window, Super+PgDn stays", () => {
    assert.equal(step(BAR, "in", 1, { withWindows: ["in"] }), null);
    assert.equal(step(BAR, "in", 1), null);
});

test("Super+Shift+PgDn's workspace is the very next, empty or not", () => {
    assert.equal(step(BAR, "re", 1, { any: true }), "ab");
    assert.equal(step(BAR, "in", -1, { any: true }), "ti");
});

test("a workspace not on the bar steps nowhere", () => {
    assert.equal(step(BAR, "special:x", 1, { any: true }), null);
});
