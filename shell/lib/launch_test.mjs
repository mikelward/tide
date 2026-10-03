// Tests for launch.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { initial, step, track } from "./launch.mjs";

// Array.prototype.at, which the shell's engine lacks (qtjs_env_test.mjs).
const last = (list) => list[list.length - 1];

const COMMAND = ["tide", "launch", "--", "blueman-manager"];

// Feeds `events` through step, returning every run along the way.
function play(events) {
    const runs = [];
    let run = initial();
    for (const event of events) {
        run = step(run, event, COMMAND);
        runs.push(run);
    }
    return runs;
}

// The reports a sequence produced, in order.
function reports(events) {
    return play(events).filter(r => r.done && r.report !== null).map(r => r.report);
}

const STARTED = { type: "started" };
const STOPPED = { type: "stopped" };
const exited = code => ({ type: "exited", code });
const stderr = text => ({ type: "stderr", text });

test("a quiet success finishes silently, once both exit and stderr are in", () => {
    const runs = play([STARTED, exited(0), STOPPED, stderr("")]);
    assert.deepEqual(runs.map(r => r.done), [false, false, false, true]);
    assert.equal(runs[3].report, null);
});

test("a nonzero exit warns with the code and the whole of stderr", () => {
    assert.deepEqual(reports([STARTED, exited(127), STOPPED, stderr("blueman-manager: not found\n")]), [
        { level: "warn", message: "tide: tide launch -- blueman-manager exited 127: blueman-manager: not found" },
    ]);
});

test("stderr from a successful run is logged, not warned", () => {
    assert.deepEqual(reports([STARTED, exited(0), stderr("tide: no focus grant\n")]), [
        { level: "log", message: "tide: tide launch -- blueman-manager: tide: no focus grant" },
    ]);
});

test("stderr ending before the exit code waits for the code", () => {
    const runs = play([STARTED, stderr("oops"), exited(1)]);
    assert.deepEqual(runs.map(r => r.done), [false, false, true]);
    assert.equal(runs[2].report.message, "tide: tide launch -- blueman-manager exited 1: oops");
});

test("an exit code alone isn't the end: stderr may still be coming", () => {
    const runs = play([STARTED, exited(1), STOPPED]);
    assert.equal(last(runs).done, false);
});

test("stopping without starting is a failed start", () => {
    const runs = play([STOPPED]);
    assert.equal(runs[0].done, true);
    assert.deepEqual(runs[0].report, { level: "warn", message: "tide: couldn't start tide launch -- blueman-manager" });
});

test("a finished run reports once, whatever arrives after", () => {
    assert.equal(reports([STARTED, exited(2), stderr("x"), STOPPED, stderr("y"), exited(3)]).length, 1);
    assert.equal(reports([STOPPED, STOPPED, exited(1), stderr("z")]).length, 1);
    const runs = play([STARTED, exited(0), stderr(""), STOPPED]);
    assert.equal(last(runs).done, true);
    assert.equal(last(runs).report, null);
});

test("an unknown event is an error", () => {
    assert.throws(() => step(initial(), { type: "crashed" }, COMMAND), /unknown process event: crashed/);
});

test("a finished run keeps its code and stderr for a caller that reads them", () => {
    // SessionMenu reads systemctl's blockers from a failed run's stderr.
    const run = last(play([STARTED, stderr("Operation inhibited\n"), exited(1)]));
    assert.equal(run.done, true);
    assert.equal(run.started, true);
    assert.equal(run.code, 1);
    assert.equal(run.errors, "Operation inhibited\n");
});

test("a run whose stderr isn't read finishes only by failing to start", () => {
    // ClockData reads tide-tz's stdout, not its stderr.
    assert.equal(last(play([STARTED, exited(0), STOPPED])).done, false);
    assert.equal(last(play([STOPPED])).done, true);
});

// A log that remembers what it was told.
function recorder() {
    const lines = [];
    return { lines, warn: m => lines.push(["warn", m]), log: m => lines.push(["log", m]) };
}

test("a tracked run calls back once when it's done, whatever the outcome", () => {
    for (const events of [
        [STARTED, exited(0), stderr("")],
        [STARTED, stderr("nope"), exited(1)],
        [STOPPED],
        [STARTED, exited(0), stderr("slow shell\n")],
    ]) {
        let calls = 0;
        const t = track(COMMAND, () => calls++, recorder());
        const done = events.map(e => t.on(e));
        assert.equal(last(done), true);
        assert.equal(done.slice(0, -1).includes(true), false);
        assert.equal(calls, 1);
        // Anything after the end changes nothing.
        assert.equal(t.on(STOPPED), true);
        assert.equal(t.on(exited(3)), true);
        assert.equal(calls, 1);
    }
});

test("a tracked run tells its callback whether it worked", () => {
    for (const [events, ok] of [
        [[STARTED, exited(0), stderr("")], true],
        [[STARTED, exited(0), stderr("slow shell\n")], true],
        // The signals come in no fixed order: an exit before `started` is
        // still a run that worked.
        [[exited(0), stderr(""), STARTED], true],
        [[stderr(""), exited(0)], true],
        [[STARTED, stderr("nope"), exited(1)], false],
        [[STOPPED], false],
    ]) {
        const got = [];
        const t = track(COMMAND, worked => got.push(worked), recorder());
        events.forEach(e => t.on(e));
        assert.deepEqual(got, [ok]);
    }
});

test("a tracked run logs its report at its level", () => {
    const failed = recorder();
    track(COMMAND, null, failed).on(STOPPED);
    assert.deepEqual(failed.lines, [["warn", "tide: couldn't start tide launch -- blueman-manager"]]);
    const chatty = recorder();
    const t = track(COMMAND, null, chatty);
    [STARTED, exited(0), stderr("slow shell\n")].forEach(e => t.on(e));
    assert.deepEqual(chatty.lines, [["log", "tide: tide launch -- blueman-manager: slow shell"]]);
    const quiet = recorder();
    const q = track(COMMAND, null, quiet);
    [STARTED, exited(0), stderr("")].forEach(e => q.on(e));
    assert.deepEqual(quiet.lines, []);
});
