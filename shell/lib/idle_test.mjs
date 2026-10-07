// Tests for idle.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_IDLE, LADDER, STEPS, SWITCHES, formatDuration, hypridleConf, loadIdle, parseIdle, stepped, suspendConf, withSetting } from "./idle.mjs";

test("the defaults are SPEC.md §10's timeline", () => {
    assert.deepEqual(DEFAULT_IDLE, { dim: 150, lock: 300, displaysOff: 330, suspend: 1800, suspendOnAC: false });
    assert.deepEqual(STEPS.map(s => s.key), ["dim", "lock", "displaysOff", "suspend"]);
    assert.deepEqual(SWITCHES.map(s => s.key), ["suspendOnAC"]);
});

test("a file sets any of the steps, in whole seconds", () => {
    assert.deepEqual(parseIdle('{"lock": 600}'), { settings: { lock: 600 } });
    assert.deepEqual(parseIdle("{}"), { settings: {} });
});

test("a bad setting is an error naming it", () => {
    assert.match(parseIdle('{"lock": 0}').error, /^lock must be a whole number of seconds above 0/);
    assert.match(parseIdle('{"lock": -5}').error, /^lock must be/);
    assert.match(parseIdle('{"lock": 1.5}').error, /^lock must be/);
    assert.match(parseIdle('{"lock": "5 min"}').error, /^lock must be/);
    assert.match(parseIdle('{"lokc": 300}').error, /^unknown setting "lokc"/);
    assert.match(parseIdle("[300]").error, /^expected an object/);
    assert.match(parseIdle("null").error, /^expected an object/);
    assert.match(parseIdle('{"lock": 300').error, /^line 1:/);
});

test("the local file merges key by key over the shared one and the defaults", () => {
    const result = loadIdle('{"lock": 600, "suspend": 3600}', '{"suspend": 900}');
    assert.deepEqual(result, { idle: { dim: 150, lock: 600, displaysOff: 330, suspend: 900, suspendOnAC: false }, errors: [] });
    assert.deepEqual(loadIdle(null, null), { idle: DEFAULT_IDLE, errors: [] });
});

test("a file that fails keeps the last good timings, and every bad file is named", () => {
    const lastGood = { dim: 60, lock: 120, displaysOff: 180, suspend: 600 };
    const result = loadIdle('{"dim": 0}', '{"oops": 1}', lastGood);
    assert.equal(result.idle, lastGood);
    assert.deepEqual(result.errors, [
        "idle.json: dim must be a whole number of seconds above 0",
        'idle.local.json: unknown setting "oops"; expected dim, lock, displaysOff, suspend, suspendOnAC',
    ]);
});

test("hypridle gets each step as the variable conf's hypridle.conf uses", () => {
    const text = hypridleConf(DEFAULT_IDLE);
    assert.ok(text.startsWith("# Written by tide"));
    assert.ok(text.endsWith("\n"));
    const variables = text.split("\n").filter(l => l.startsWith("$"));
    assert.deepEqual(variables, [
        "$tide_idle_dim = 150",
        "$tide_idle_lock = 300",
        "$tide_idle_displays_off = 330",
        "$tide_idle_suspend = 1800",
    ]);
});

test("suspend on AC goes to idle-suspend's own file, so changing it doesn't restart hypridle", () => {
    const on = Object.assign({}, DEFAULT_IDLE, { suspendOnAC: true });
    assert.equal(hypridleConf(on), hypridleConf(DEFAULT_IDLE), "hypridle's file, which a change restarts it for, stays the same");
    assert.deepEqual(suspendConf(DEFAULT_IDLE).split("\n").filter(l => l.startsWith("$")), ["$tide_idle_suspend_on_ac = 0"]);
    assert.deepEqual(suspendConf(on).split("\n").filter(l => l.startsWith("$")), ["$tide_idle_suspend_on_ac = 1"]);
    assert.ok(suspendConf(on).startsWith("# Written by tide"));
});

test("suspend on AC is a switch, true or false", () => {
    assert.deepEqual(parseIdle('{"suspendOnAC": true, "lock": 600}'), { settings: { suspendOnAC: true, lock: 600 } });
    assert.match(parseIdle('{"suspendOnAC": 1}').error, /^suspendOnAC must be true or false/);
    assert.match(parseIdle('{"suspendOnAC": "yes"}').error, /^suspendOnAC must be true or false/);
    assert.deepEqual(loadIdle(null, '{"suspendOnAC": true}').idle.suspendOnAC, true);
    assert.deepEqual(withSetting('{"suspend": 900}', "suspendOnAC", true), { text: '{\n  "suspend": 900,\n  "suspendOnAC": true\n}\n' });
    assert.match(withSetting(null, "suspendOnAC", 0).error, /^suspendOnAC must be true or false/);
});

test("setting a step keeps the rest of the local file", () => {
    assert.deepEqual(withSetting('{"suspend": 900}', "lock", 600), { text: '{\n  "lock": 600,\n  "suspend": 900\n}\n' });
    assert.deepEqual(withSetting(null, "dim", 60), { text: '{\n  "dim": 60\n}\n' });
    assert.deepEqual(withSetting('{"dim": 60}', "dim", 120), { text: '{\n  "dim": 120\n}\n' });
});

test("setting an unknown step or a bad time is an error naming it", () => {
    assert.match(withSetting(null, "lokc", 600).error, /^unknown setting "lokc"/);
    assert.match(withSetting(null, "lock", 0).error, /^lock must be a whole number of seconds above 0/);
    assert.match(withSetting(null, "lock", 2.5).error, /^lock must be/);
});

test("a local file that doesn't parse is never overwritten", () => {
    assert.match(withSetting('{"dim": ', "lock", 600).error, /^idle\.local\.json: line 1:/);
    assert.match(withSetting('{"dim": 0}', "lock", 600).error, /^idle\.local\.json: dim must be/);
});

test("− and + step along the ladder, and stop at its ends", () => {
    assert.equal(stepped(300, 1), 330);
    assert.equal(stepped(300, -1), 180);
    assert.equal(stepped(LADDER[0], -1), LADDER[0]);
    assert.equal(stepped(LADDER[LADDER.length - 1], 1), LADDER[LADDER.length - 1]);
    // A hand-set value between rungs moves to the nearest rung that way.
    assert.equal(stepped(400, 1), 600);
    assert.equal(stepped(400, -1), 330);
    assert.equal(stepped(10, -1), 10);
    assert.equal(stepped(10000, 1), 10000);
});

test("every default is on the ladder", () => {
    for (const step of STEPS) {
        assert.ok(LADDER.includes(DEFAULT_IDLE[step.key]), step.key);
    }
});

test("durations read as the Idle page shows them", () => {
    assert.equal(formatDuration(30), "30 s");
    assert.equal(formatDuration(150), "2 min 30 s");
    assert.equal(formatDuration(300), "5 min");
    assert.equal(formatDuration(3600), "1 h");
    assert.equal(formatDuration(5400), "1 h 30 min");
    assert.equal(formatDuration(3661), "1 h 1 min 1 s");
});
