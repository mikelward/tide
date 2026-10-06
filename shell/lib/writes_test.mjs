// Tests for writes.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { TARGET, readTarget, targetApplied, targetUnreadable, targetWritten, wantTarget } from "./writes.mjs";

// The file read as `text`, then `wanted`.
function started(text, wanted) {
    return wantTarget(readTarget(TARGET, text).state, wanted);
}

test("a start that wants what the file already says writes and applies nothing", () => {
    assert.equal(wantTarget(TARGET, "x").action, null, "nothing until the file is read");
    assert.equal(started("x", "x").action, null);
});

test("a start that wants what the file already says applies it when asked to reapply", () => {
    let r = wantTarget(readTarget(TARGET, "x", true).state, "x");
    assert.deepEqual(r.action, { apply: true }, "the program may not have it");
    r = targetApplied(r.state, "");
    assert.equal(r.action, null);
    r = wantTarget(readTarget(r.state, "x", true).state, "x");
    assert.equal(r.action, null, "only the first read");
});

test("a change is written, then applied", () => {
    let r = started("x", "y");
    assert.deepEqual(r.action, { write: "y" });
    r = targetWritten(r.state, "");
    assert.deepEqual(r.action, { apply: true });
    r = targetApplied(r.state, "");
    assert.equal(r.action, null);
    assert.equal(r.state.applied, "y");
});

test("no file yet is written, then applied", () => {
    assert.deepEqual(started(null, "y").action, { write: "y" });
});

test("a later read doesn't make the file count as applied", () => {
    let r = started("x", "y");
    r = targetWritten(r.state, "");
    r = targetApplied(r.state, "exited 1");
    const s = readTarget(r.state, "y").state;
    assert.equal(s.applied, "x", "only the first read is what the program has");
    assert.deepEqual(wantTarget(s, "y").action, { apply: true });
});

test("a change made while one is being applied follows it", () => {
    let r = targetWritten(started("x", "y").state, "");
    assert.deepEqual(r.action, { apply: true });
    r = wantTarget(r.state, "z");
    assert.equal(r.action, null, "one step at a time");
    r = targetApplied(r.state, "");
    assert.equal(r.state.applied, "y");
    assert.deepEqual(r.action, { write: "z" });
});

test("a write that fails stays pending, and a fresh read and the same wish retry it", () => {
    let r = targetWritten(started("x", "y").state, "permission denied");
    assert.equal(r.action, null);
    assert.equal(r.state.failure, "permission denied");
    assert.equal(r.state.onDisk, "x", "the file is as it was");
    r = wantTarget(readTarget(r.state, "x").state, "y");
    assert.deepEqual(r.action, { write: "y" });
    r = targetWritten(r.state, "");
    assert.equal(r.state.failure, "permission denied", "not cleared until it's applied");
    r = targetApplied(r.state, "");
    assert.equal(r.state.failure, "");
});

test("an apply that fails stays pending, and is retried, not rewritten", () => {
    let r = targetWritten(started("x", "y").state, "");
    r = targetApplied(r.state, "exited 1");
    assert.equal(r.action, null);
    assert.equal(r.state.failure, "exited 1");
    assert.equal(r.state.applied, "x", "the program still has the old one");
    r = wantTarget(readTarget(r.state, "y").state, "y");
    assert.deepEqual(r.action, { apply: true });
    r = targetApplied(r.state, "");
    assert.equal(r.state.applied, "y");
    assert.equal(r.state.failure, "");
});

test("a change after a failure is tried at once", () => {
    let r = targetWritten(started("x", "y").state, "");
    r = targetApplied(r.state, "exited 1");
    assert.deepEqual(wantTarget(r.state, "z").action, { write: "z" });
});

test("a file that can't be read isn't written over, and is once it reads", () => {
    let r = targetUnreadable(TARGET, "permission denied");
    assert.equal(r.state.failure, "permission denied");
    r = wantTarget(r.state, "y");
    assert.equal(r.action, null, "nothing is written over a file that wasn't read");
    r = wantTarget(readTarget(r.state, "x").state, "y");
    assert.deepEqual(r.action, { write: "y" }, "what's wanted goes out once it reads");
    r = targetApplied(targetWritten(r.state, "").state, "");
    assert.equal(r.state.failure, "", "and the failure is over once it's applied");
});

test("a file that becomes readable already saying what's wanted is applied, since the program couldn't read it", () => {
    let r = targetUnreadable(TARGET, "permission denied");
    r = wantTarget(readTarget(r.state, "y").state, "y");
    assert.deepEqual(r.action, { apply: true });
    assert.equal(r.state.failure, "permission denied", "not over until it's applied");
    r = targetApplied(r.state, "");
    assert.equal(r.action, null);
    assert.equal(r.state.failure, "");
});
