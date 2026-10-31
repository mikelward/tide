// Tests for dnd.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DEFAULTS,
    SCHEDULE_IDLE,
    inWindow,
    windowStart,
    withDayToggled,
    steppedDndTime,
    loadNotificationSettings,
    ownChanged,
    scheduleStep,
    scheduleSummary,
    toggledDay,
    withSetting,
} from "./dnd.mjs";

// 2026-11-06 is a Friday; local time, as the shell reads it.
const at = (day, hh, mm) => new Date(2026, 10, day, hh, mm);

test("no schedule and criticals breaking through by default", () => {
    assert.deepEqual(loadNotificationSettings(null, null), { settings: Object.assign({}, DEFAULTS), errors: [] });
    assert.equal(inWindow(DEFAULTS, at(6, 23, 0)), false);
});

test("the local file overrides the shared one key by key", () => {
    const r = loadNotificationSettings('{"dndScheduled": true, "dndFrom": "21:00"}', '{"dndFrom": "23:00"}');
    assert.equal(r.settings.dndScheduled, true);
    assert.equal(r.settings.dndFrom, "23:00");
    assert.equal(r.settings.dndTo, "07:00");
});

test("a bad setting is an error at load naming it, and the last good settings stay", () => {
    const good = Object.assign({}, DEFAULTS, { dndScheduled: true });
    for (const [text, why] of [
        ['{"dndFrom": "25:00"}', /dndFrom must be a 24-hour time/],
        ['{"dndDays": ["mon", "funday"]}', /"funday" isn't a day/],
        ['{"dndDays": ["mon", "mon"]}', /names a day twice/],
        ['{"criticalsBreakThrough": "yes"}', /criticalsBreakThrough must be true or false/],
        ['{"dnd": true}', /"dnd" isn't a setting/],
        ['{"dndScheduled": true, "dndFrom": "07:00", "dndTo": "07:00"}', /dndFrom and dndTo are both 07:00/],
        ['{"dndScheduled": true, "dndFrom": "7:00", "dndTo": "07:00"}', /dndFrom and dndTo are both 07:00/],
        ["{", /^notifications\.local\.json: line 1/],
    ]) {
        const r = loadNotificationSettings(null, text, good);
        assert.equal(r.settings, good, text);
        assert.match(r.errors[0], why, text);
    }
});

test("a change writes only the local file, keeping its other settings, and refuses what wouldn't work", () => {
    const r = withSetting('{"dndScheduled": true}', '{"criticalsBreakThrough": false}', "dndFrom", "21:30");
    assert.deepEqual(JSON.parse(r.text), { criticalsBreakThrough: false, dndFrom: "21:30" });
    assert.match(withSetting('{"dndScheduled": true, "dndTo": "21:30"}', null, "dndFrom", "21:30").error, /same time/);
    assert.match(withSetting(null, "{", "dndScheduled", true).error, /^notifications\.local\.json: /);
    assert.match(withSetting(null, null, "dndDays", ["xyz"]).error, /isn't a day/);
});

test("an overnight window starts on a listed day and runs into the next", () => {
    const s = Object.assign({}, DEFAULTS, { dndScheduled: true, dndFrom: "22:00", dndTo: "07:00", dndDays: ["fri"] });
    assert.equal(inWindow(s, at(6, 21, 59)), false, "Friday before it starts");
    assert.equal(inWindow(s, at(6, 22, 0)), true, "Friday as it starts");
    assert.equal(inWindow(s, at(7, 6, 59)), true, "Saturday morning, still Friday's");
    assert.equal(inWindow(s, at(7, 7, 0)), false, "Saturday as it ends");
    assert.equal(inWindow(s, at(7, 22, 30)), false, "Saturday isn't listed");
    assert.equal(inWindow(s, at(6, 3, 0)), false, "Friday morning is Thursday's, which isn't listed");
});

test("a daytime window is within its day", () => {
    const s = Object.assign({}, DEFAULTS, { dndScheduled: true, dndFrom: "12:00", dndTo: "13:00", dndDays: ["mon", "tue", "wed", "thu", "fri"] });
    assert.equal(inWindow(s, at(6, 12, 30)), true);
    assert.equal(inWindow(s, at(6, 13, 0)), false);
    assert.equal(inWindow(s, at(7, 12, 30)), false, "Saturday");
});

const FRI = new Date(2026, 10, 6, 22, 0).getTime();
const SAT = new Date(2026, 10, 7, 22, 0).getTime();

test("the schedule turns Do not disturb on as a window starts and off as it ends", () => {
    let r = scheduleStep(SCHEDULE_IDLE, null, false);
    assert.equal(r.set, null, "outside at start, nothing");
    r = scheduleStep(r.state, FRI, false);
    assert.equal(r.set, true, "the window starts");
    r = scheduleStep(r.state, FRI, true);
    assert.equal(r.set, null, "inside, nothing more");
    r = scheduleStep(r.state, null, true);
    assert.equal(r.set, false, "the window ends");
});

test("a shell started in a window turns it on", () => {
    assert.equal(scheduleStep(SCHEDULE_IDLE, FRI, false).set, true);
});

test("one you turned on yourself stays on past the window; one you changed during it is yours", () => {
    let r = scheduleStep({ window: null, scheduledOn: false }, FRI, true);
    assert.equal(r.set, null, "already on");
    r = scheduleStep(r.state, null, true);
    assert.equal(r.set, null, "yours, so it stays on as the window ends");
    r = scheduleStep({ window: null, scheduledOn: false }, FRI, false);
    const yours = ownChanged(r.state, false, true);
    assert.equal(scheduleStep(yours, null, true).set, null);
});

test("turning it off in one window lasts only that window, even with no check between them", () => {
    let r = scheduleStep(SCHEDULE_IDLE, FRI, false);
    // You turn it off on Friday night, then suspend until Saturday night.
    const off = ownChanged(r.state, true, false);
    r = scheduleStep(off, SAT, false);
    assert.equal(r.set, true, "Saturday's window turns it on again");
    assert.equal(r.state.scheduledOn, true);
    r = scheduleStep(r.state, null, true);
    assert.equal(r.set, false, "and off as it ends");
});

test("a window that follows the schedule's own keeps it on, still the schedule's", () => {
    let r = scheduleStep(SCHEDULE_IDLE, FRI, false);
    r = scheduleStep(r.state, SAT, true);
    assert.equal(r.set, null);
    assert.equal(scheduleStep(r.state, null, true).set, false);
});

test("each window is told by when it started", () => {
    const s = Object.assign({}, DEFAULTS, { dndScheduled: true, dndFrom: "22:00", dndTo: "07:00" });
    assert.equal(windowStart(s, at(6, 23, 0)), FRI);
    assert.equal(windowStart(s, at(7, 6, 0)), FRI, "Saturday morning is still Friday's");
    assert.equal(windowStart(s, at(7, 22, 30)), SAT);
    assert.equal(windowStart(s, at(7, 12, 0)), null);
});

test("days toggle in the week's order, and the page says what the schedule is", () => {
    assert.deepEqual(toggledDay(["fri", "mon"], "wed"), ["mon", "wed", "fri"]);
    assert.deepEqual(toggledDay(["mon", "wed"], "mon"), ["wed"]);
    assert.equal(scheduleSummary(DEFAULTS), "Off");
    assert.equal(scheduleSummary(Object.assign({}, DEFAULTS, { dndScheduled: true })), "22:00 to 07:00, every day");
    assert.equal(scheduleSummary(Object.assign({}, DEFAULTS, { dndScheduled: true, dndDays: ["sat", "sun"] })), "22:00 to 07:00, sat, sun");
});

test("the same time written two ways is never a window, not an always-on one", () => {
    const s = Object.assign({}, DEFAULTS, { dndScheduled: true, dndFrom: "7:00", dndTo: "07:00" });
    assert.equal(inWindow(s, at(6, 12, 0)), false);
    assert.match(withSetting(null, '{"dndScheduled": true, "dndTo": "07:00"}', "dndFrom", "7:00").error, /both 07:00/);
});

test("setting your own Do not disturb to what it is, as presenter mode and keep awake do, leaves the schedule's", () => {
    const on = scheduleStep(SCHEDULE_IDLE, FRI, false).state;
    const same = ownChanged(on, true, true);
    assert.equal(scheduleStep(same, null, true).set, false, "the window's end still turns it off");
    assert.equal(ownChanged(on, true, false).scheduledOn, false, "a real change takes it");
});

test("a day is turned on in the days the files have now, so a hand edit isn't lost", () => {
    // Monday added by hand a moment ago, before the shell heard of it.
    const r = withDayToggled(null, '{"dndDays": ["mon", "fri"]}', "tue");
    assert.deepEqual(JSON.parse(r.text).dndDays, ["mon", "tue", "fri"]);
    assert.deepEqual(JSON.parse(withDayToggled('{"dndDays": ["sat"]}', null, "sat").text).dndDays, []);
    assert.match(withDayToggled(null, "{", "tue").error, /^notifications\.local\.json: /);
});

test("a step goes past the other time even when it's written without a leading zero", () => {
    assert.equal(steppedDndTime("06:45", 1, "7:00"), "07:15");
    assert.equal(steppedDndTime("07:15", -1, "7:00"), "06:45");
    assert.equal(steppedDndTime("22:00", 1, "07:00"), "22:15");
    const s = Object.assign({}, DEFAULTS, { dndScheduled: true, dndFrom: "06:45", dndTo: "7:00" });
    assert.ok(withSetting(JSON.stringify(s), null, "dndFrom", steppedDndTime(s.dndFrom, 1, s.dndTo)).text, "the + is taken");
});
