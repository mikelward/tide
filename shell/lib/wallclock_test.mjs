// Tests for wallclock.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { CHECK_MS, jumped, lidMoved, woke } from "./wallclock.mjs";

const t = Date.UTC(2026, 10, 7, 9, 30, 0);

test("a check on time, or a little late, isn't a jump", () => {
    assert.equal(jumped(t, t + CHECK_MS), false);
    assert.equal(jumped(t, t + CHECK_MS + 1500), false, "a busy shell");
    assert.equal(jumped(t, t + CHECK_MS - 50), false, "a timer that fires early");
});

test("waking from sleep is a jump", () => {
    assert.equal(jumped(t, t + 8 * 60 * 60 * 1000), true);
    assert.equal(jumped(t, t + CHECK_MS + 5000), true, "even a short sleep");
});

test("the time being set back is a jump", () => {
    assert.equal(jumped(t, t - 60 * 60 * 1000), true);
});

test("logind's signal after a sleep is a wake", () => {
    assert.equal(woke("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"), true);
});

test("logind's signal before a sleep, and its other lines, aren't", () => {
    assert.equal(woke("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"), false);
    assert.equal(woke("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForShutdown (false,)"), false);
    assert.equal(woke("The name org.freedesktop.login1 is owned by :1.3"), false);
    assert.equal(woke(""), false);
});

test("logind's LidClosed changing says the lid opened or closed", () => {
    const changed = (props) => `/org/freedesktop/login1: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Manager', ${props}, @as [])`;
    assert.equal(lidMoved(changed("{'LidClosed': <true>}")), true, "closed");
    assert.equal(lidMoved(changed("{'LidClosed': <false>}")), true, "opened");
    assert.equal(lidMoved(changed("{'Docked': <true>, 'LidClosed': <true>}")), true, "among others");
    assert.equal(lidMoved(changed("{'Docked': <true>}")), false, "another property");
    assert.equal(lidMoved("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"), false);
    assert.equal(lidMoved("The name org.freedesktop.login1 is owned by :1.3"), false);
    assert.equal(woke(changed("{'LidClosed': <false>}")), false, "and isn't a wake");
});
