// Tests for report.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { NOTHING, verdict, sent, retry, pending, notifyCommand } from "./report.mjs";

test("a new error is sent", () => {
    const v = verdict(NOTHING, ["clocks.json: line 3: x"]);
    assert.deepEqual(v.send, ["clocks.json: line 3: x"]);
    assert.equal(pending(v.state), true);
});

test("a delivered error isn't sent again while it lasts", () => {
    let v = verdict(NOTHING, ["a"]);
    const state = sent(v.state, "a", true);
    assert.equal(pending(state), false);
    v = verdict(state, ["a"]);
    assert.deepEqual(v.send, []);
});

test("an error on its way isn't sent twice", () => {
    const v = verdict(NOTHING, ["a"]);
    assert.deepEqual(verdict(v.state, ["a"]).send, []);
    assert.deepEqual(retry(v.state).send, []);
});

test("an undelivered error is sent again on retry", () => {
    const v = verdict(NOTHING, ["a"]);
    const failed = sent(v.state, "a", false);
    assert.equal(pending(failed), true);
    const r = retry(failed);
    assert.deepEqual(r.send, ["a"]);
    assert.equal(pending(sent(r.state, "a", true)), false);
});

test("an undelivered error is sent again at the next verdict too", () => {
    const failed = sent(verdict(NOTHING, ["a"]).state, "a", false);
    assert.deepEqual(verdict(failed, ["a"]).send, ["a"]);
});

test("an error is reported once per run, even if it's fixed and comes back", () => {
    const delivered = sent(verdict(NOTHING, ["a"]).state, "a", true);
    const fixed = verdict(delivered, []);
    assert.deepEqual(fixed.send, []);
    assert.equal(pending(fixed.state), false);
    assert.deepEqual(verdict(fixed.state, ["a"]).send, []);
    // A different error still gets its own.
    assert.deepEqual(verdict(fixed.state, ["a", "b"]).send, ["b"]);
});

test("an undelivered error that's fixed isn't retried", () => {
    const failed = sent(verdict(NOTHING, ["a"]).state, "a", false);
    const fixed = verdict(failed, []).state;
    assert.equal(pending(fixed), false);
    assert.deepEqual(retry(fixed).send, []);
});

test("a delivery for an error fixed meanwhile still counts: the user saw it", () => {
    const v = verdict(NOTHING, ["a"]);
    const fixed = verdict(v.state, []).state;
    const late = sent(fixed, "a", true);
    assert.deepEqual(late.delivered, ["a"]);
    assert.deepEqual(late.sending, []);
    assert.deepEqual(verdict(late, ["a"]).send, []);
});

test("errors are kept apart: one delivered, one still owed", () => {
    let state = verdict(NOTHING, ["a", "b"]).state;
    state = sent(state, "a", true);
    state = sent(state, "b", false);
    assert.deepEqual(retry(state).send, ["b"]);
    assert.deepEqual(verdict(state, ["a", "b"]).send, ["b"]);
});

test("a repeated error in one verdict is sent once", () => {
    assert.deepEqual(verdict(NOTHING, ["a", "a"]).send, ["a"]);
});

test("the command names tide as the sender", () => {
    assert.deepEqual(notifyCommand("Clocks not updated", "clocks.json: line 3: x"),
        ["notify-send", "--app-name=tide", "Clocks not updated", "clocks.json: line 3: x"]);
});
