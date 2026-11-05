// Tests for session.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ACTIONS, actionCommand, blockers, isPower } from "./session.mjs";

test("the menu lists lock, log out, suspend, restart and shut down, in that order", () => {
    assert.deepEqual(ACTIONS.map(a => a.label), ["Lock", "Log out", "Suspend", "Restart", "Shut down"]);
});

test("lock goes through tide lock and log out through uwsm", () => {
    assert.deepEqual(actionCommand("lock"), ["tide", "lock"]);
    assert.deepEqual(actionCommand("logout"), ["uwsm", "stop"]);
    assert.equal(isPower("lock"), false);
    assert.equal(isPower("logout"), false);
});

test("power actions check inhibitors unless forced", () => {
    assert.deepEqual(actionCommand("suspend"), ["systemctl", "--check-inhibitors=yes", "suspend"]);
    assert.deepEqual(actionCommand("poweroff", true), ["systemctl", "--check-inhibitors=no", "poweroff"]);
    assert.deepEqual(actionCommand("reboot"), ["systemctl", "--check-inhibitors=yes", "reboot"]);
    assert.equal(isPower("reboot"), true);
});

test("an unknown action is an error", () => {
    assert.throws(() => actionCommand("hibernate"), /unknown session action: hibernate/);
});

test("blockers come from systemctl's inhibitor and logged-in-user lines", () => {
    const stderr = [
        'Operation inhibited by "Firefox" (PID 1234 "firefox", user user1), reason is "Playing video".',
        'Operation inhibited by "Backup" (PID 99 "rsync", user root), reason is "Copying files".',
        "User user2 is logged in on tty3.",
        "Please retry operation after closing inhibitors and logging out other users.",
        "'systemd-inhibit' can be used to list active inhibitors.",
    ].join("\n");
    assert.deepEqual(blockers(stderr), [
        "Firefox: Playing video",
        "Backup: Copying files",
        "user2 is logged in on tty3",
    ]);
});

test("a failure with nothing blocking has no blockers", () => {
    assert.deepEqual(blockers("Failed to connect to bus: No such file or directory"), []);
    assert.deepEqual(blockers(""), []);
});
