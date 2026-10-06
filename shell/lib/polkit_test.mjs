// Tests for polkit.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { AUTHENTICATE, escapeMarkup, identityLabel, notifyCommand, notifyOutcome, preferredIdentity, promptText, retrySeconds, route, runStart, runStep, statusLine } from "./polkit.mjs";

test("the agent retries after 5 s, doubling to once a minute", () => {
    assert.deepEqual([0, 1, 2, 3, 4, 5, 40].map(retrySeconds), [5, 10, 20, 40, 60, 60, 60]);
});

test("a retry needs an attempt number", () => {
    assert.throws(() => retrySeconds(-1), /attempt number/);
    assert.throws(() => retrySeconds(1.5), /attempt number/);
    assert.throws(() => retrySeconds(undefined), /attempt number/);
});

test("the prompt takes the keyboard only when the guard says a key was just pressed", () => {
    assert.deepEqual(route(0), { show: "prompt", warn: false });
    assert.deepEqual(route(1), { show: "notify", warn: false });
});

test("a guard that can't say sends the notification, and is worth a warning", () => {
    assert.deepEqual(route(2), { show: "notify", warn: true });
    // tide not on PATH: the process never started, so there's no code.
    assert.deepEqual(route(null), { show: "notify", warn: true });
});

test("the notification is tide's, critical, and offers Authenticate", () => {
    const command = notifyCommand("Authentication is required to install software");
    assert.equal(command[0], "notify-send");
    assert.ok(command.includes("--app-name=tide"));
    assert.ok(command.includes("--urgency=critical"));
    assert.ok(command.includes(`--action=${AUTHENTICATE}=Authenticate`));
    assert.ok(command.includes("--action=default=Authenticate"), "a click on it opens the prompt too");
    assert.ok(command.includes("--wait"));
    assert.deepEqual(command.slice(-2), ["Authentication required", "Authentication is required to install software"]);
});

test("the notification's body is escaped, and never empty", () => {
    assert.equal(notifyCommand("<b>x</b> & y").pop(), "&lt;b&gt;x&lt;/b&gt; &amp; y");
    assert.equal(notifyCommand("").pop(), "An app is asking for your password.");
    assert.equal(escapeMarkup("a&amp;"), "a&amp;amp;");
});

test("Authenticate opens the prompt; closing the notification is a no", () => {
    assert.equal(notifyOutcome(true, 0, `${AUTHENTICATE}\n`), "open");
    assert.equal(notifyOutcome(true, 0, ""), "dismissed");
    assert.equal(notifyOutcome(true, 0, "something else\n"), "dismissed");
    assert.equal(notifyOutcome(true, 0, "default\n"), "open", "a click on the notification");
});

test("a notification that couldn't be shown fails over to the prompt", () => {
    assert.equal(notifyOutcome(false, null, ""), "failed");
    assert.equal(notifyOutcome(true, 1, `${AUTHENTICATE}\n`), "failed");
});

const user = (name, displayName) => ({ string: name, displayName: displayName ?? name, isGroup: false });
const group = name => ({ string: name, displayName: name, isGroup: true });

test("the user running the shell is asked first when polkit lists them", () => {
    assert.equal(preferredIdentity([user("root"), user("ann")], "ann"), 1);
    assert.equal(preferredIdentity([user("root"), user("ann")], "bob"), 0);
    assert.equal(preferredIdentity([group("ann"), user("root")], "ann"), 0, "a group named like the user isn't the user");
    assert.equal(preferredIdentity([], "ann"), -1);
    assert.equal(preferredIdentity(null, "ann"), -1);
});

test("an identity is named by its full name and user name", () => {
    assert.equal(identityLabel(user("ann", "Ann Example,,,")), "Ann Example (ann)");
    assert.equal(identityLabel(user("root", "root")), "root");
    assert.equal(identityLabel(user("bob", ",,,")), "bob");
    assert.equal(identityLabel(group("wheel")), "A member of wheel");
    assert.equal(identityLabel(null), "");
});

test("the field shows PAM's prompt without its colon", () => {
    assert.equal(promptText("Password: "), "Password");
    assert.equal(promptText("Verification code:"), "Verification code");
    assert.equal(promptText(""), "Password");
    assert.equal(promptText(undefined), "Password");
});

test("the status line shows PAM's message, then a failed try's", () => {
    assert.deepEqual(statusLine("Your account expires soon", false, false), { text: "Your account expires soon", error: false });
    assert.deepEqual(statusLine("Too many tries", true, true), { text: "Too many tries", error: true });
    assert.deepEqual(statusLine("", false, true), { text: "That didn't work. Try again.", error: true });
    assert.deepEqual(statusLine(" ", false, false), { text: "", error: false });
});

// Feeds `events` to a run, returning the steps.
function play(events) {
    const steps = [];
    let run = runStart();
    for (const event of events) {
        run = runStep(run, event);
        steps.push(run);
    }
    return steps;
}
const finishedAt = steps => steps.map(s => s.finished).indexOf(true);

test("a run ends once its code and both streams are in, in any order", () => {
    const steps = play([{ type: "stdout", text: "default\n" }, { type: "exited", code: 0 }, { type: "started" }, { type: "stderr", text: "" }, { type: "stopped" }]);
    assert.equal(finishedAt(steps), 3);
    assert.equal(steps.filter(s => s.finished).length, 1, "finished once");
    const last = steps[steps.length - 1];
    assert.deepEqual([last.code, last.out, last.err], [0, "default\n", ""]);
});

test("a run waits for its stdout too", () => {
    const steps = play([{ type: "started" }, { type: "exited", code: 1 }, { type: "stderr", text: "" }, { type: "stdout", text: "" }]);
    assert.equal(finishedAt(steps), 3);
});

test("a command that can't start ends when it stops, with no code", () => {
    const steps = play([{ type: "stopped" }]);
    assert.equal(finishedAt(steps), 0);
    assert.equal(steps[0].code, null);
    assert.deepEqual(route(steps[0].code), { show: "notify", warn: true });
});

test("a run stopping before it reports starting still waits for its code", () => {
    const steps = play([{ type: "exited", code: 0 }, { type: "stopped" }, { type: "stderr", text: "" }, { type: "stdout", text: "" }]);
    assert.equal(finishedAt(steps), 3);
    assert.equal(steps[3].code, 0);
});

test("an unknown event is a bug", () => {
    assert.throws(() => runStep(runStart(), { type: "nonsense" }), /unknown process event/);
});
