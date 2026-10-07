// Tests for writes.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { TARGET, afterRecord, firstApplied, readTarget, recordOf, targetApplied, targetUnreadable, targetWritten, wantTarget } from "./writes.mjs";

// The file read as `text`, then `wanted`.
function started(text, wanted) {
    return wantTarget(readTarget(TARGET, text).state, wanted);
}

test("a start that wants what the file already says writes and applies nothing", () => {
    assert.equal(wantTarget(TARGET, "x").action, null, "nothing until the file is read");
    assert.equal(started("x", "x").action, null);
});

test("a start that wants what the file already says applies it when told the program has none of it", () => {
    let r = wantTarget(readTarget(TARGET, "x", null).state, "x");
    assert.deepEqual(r.action, { apply: true }, "the program may not have it");
    r = targetApplied(r.state, "");
    assert.equal(r.action, null);
    r = wantTarget(readTarget(r.state, "x", null).state, "x");
    assert.equal(r.action, null, "only the first read");
});

test("a start told the program has something else applies what's wanted, and one told it has that leaves it", () => {
    assert.deepEqual(wantTarget(readTarget(TARGET, "y", "x").state, "y").action, { apply: true });
    assert.equal(wantTarget(readTarget(TARGET, "y", "y").state, "y").action, null);
});

test("with no record yet, the file is what the program has, and is recorded", () => {
    assert.deepEqual(firstApplied("x", null), { applied: "x", record: "x" });
    assert.deepEqual(firstApplied(null, null), { applied: null, record: "" }, "no file is recorded as empty");
});

test("a record of the last apply is what the program has, whatever the file says", () => {
    // A shell that wrote y and died before hypridle restarted for it.
    const { applied, record } = firstApplied("y", "x");
    assert.equal(applied, "x");
    assert.equal(record, null, "the record stands");
    assert.deepEqual(wantTarget(readTarget(TARGET, "y", applied).state, "y").action, { apply: true }, "so its successor applies y");
    assert.equal(firstApplied("x", "").applied, null, "an empty record is no file");
});

test("a first record that can't be written leaves what the program has unknown, so it's applied", () => {
    assert.equal(afterRecord(firstApplied("x", null), true), "x");
    assert.equal(afterRecord(firstApplied("x", null), false), null);
    assert.deepEqual(wantTarget(readTarget(TARGET, "x", afterRecord(firstApplied("x", null), false)).state, "x").action, { apply: true });
    assert.equal(afterRecord(firstApplied("y", "x"), false), "x", "a record already there needs no writing");
});

test("what's applied is recorded as its text, and no file as empty", () => {
    assert.equal(recordOf("x"), "x");
    assert.equal(recordOf(null), "");
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
