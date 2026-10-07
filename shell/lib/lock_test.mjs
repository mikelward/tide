// Tests for lock.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as Run from "./launch.mjs";
import { LAYOUT_INITIAL, layoutNext, layoutBadge, mainKeymap, POWER_IDLE, powerBusy, powerNext, IDLE_FLAG_SECONDS, INITIAL, MAX_DOTS, MAX_ECHO, WRONG, fieldText, idleFlagFresh, keyEvent, next, powerMessage, saverPosition, shortHostname, statusText } from "./lock.mjs";

// Runs events from `state`, collecting every action.
function run(state, ...events) {
    const actions = [];
    for (const event of events) {
        const r = next(state, event);
        state = r.state;
        actions.push(...r.actions);
    }
    return { state, actions };
}

const type = text => text.split("").map(c => ({ type: "key", text: c }));
const prompt = { type: "pam", text: "Password: ", isError: false, responseRequired: true };

test("each key shows as a dot at once", () => {
    const { state } = run(INITIAL, ...type("abc"));
    assert.equal(state.input, "abc");
    assert.equal(fieldText(state), "•••");
});

test("Ctrl+U erases the field, and no other Control chord types", () => {
    assert.deepEqual(keyEvent({ key: "u", text: "\x15", ctrl: true }), { type: "clear" });
    assert.equal(run(INITIAL, ...type("abc"), keyEvent({ key: "u", text: "\x15", ctrl: true })).state.input, "");
    assert.equal(keyEvent({ key: "", text: "\x01", ctrl: true }), null);
    assert.equal(keyEvent({ key: "", text: "a", ctrl: true }), null);
});

test("the U key without Control types what it types", () => {
    // Shift+U, and whatever another layout puts on that key, must reach the
    // password as typed, or it can never match.
    assert.deepEqual(keyEvent({ key: "u", text: "u", ctrl: false }), { type: "key", text: "u" });
    assert.deepEqual(keyEvent({ key: "u", text: "U", ctrl: false }), { type: "key", text: "U" });
    assert.deepEqual(keyEvent({ key: "u", text: "ü", ctrl: false }), { type: "key", text: "ü" });
});

test("Enter, Backspace and Escape map to their events", () => {
    assert.deepEqual(keyEvent({ key: "enter", text: "\r", ctrl: false }), { type: "submit" });
    assert.deepEqual(keyEvent({ key: "backspace", text: "\b", ctrl: false }), { type: "backspace" });
    assert.deepEqual(keyEvent({ key: "escape", text: "\x1b", ctrl: false }), { type: "clear" });
    assert.equal(keyEvent({ key: "", text: "", ctrl: false }), null);
});

test("backspace and Escape edit the field", () => {
    assert.equal(run(INITIAL, ...type("abc"), { type: "backspace" }).state.input, "ab");
    assert.equal(run(INITIAL, ...type("abc"), { type: "clear" }).state.input, "");
    assert.equal(run(INITIAL, { type: "backspace" }).state.input, "");
});

test("an empty Enter does nothing", () => {
    const r = run(INITIAL, { type: "submit" });
    assert.deepEqual(r.state, INITIAL);
    assert.deepEqual(r.actions, []);
});

test("Enter starts PAM and answers its prompt with the typed password", () => {
    const r = run(INITIAL, ...type("pw"), { type: "submit" });
    assert.deepEqual(r.actions, [{ type: "start" }]);
    assert.equal(r.state.checking, true);
    assert.equal(r.state.input, "");
    assert.equal(fieldText(r.state), "");
    assert.equal(statusText(r.state), "Checking");
    const answered = next(r.state, prompt);
    assert.deepEqual(answered.actions, [{ type: "respond", text: "pw" }]);
    assert.equal(answered.state.pending, null);
});

test("success unlocks", () => {
    const { state } = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, { type: "done", result: "success" });
    assert.equal(state.unlocked, true);
});

test("a wrong password clears the field, counts, and says so", () => {
    const { state } = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, { type: "done", result: "failed" });
    assert.equal(state.unlocked, false);
    assert.equal(state.checking, false);
    assert.equal(state.input, "");
    assert.equal(state.attempts, 1);
    assert.equal(state.message, WRONG);
    assert.equal(state.error, true);
});

test("PAM's own error is shown verbatim instead of the generic text", () => {
    const locked = { type: "pam", text: "Account locked for 10 minutes", isError: true, responseRequired: false };
    const { state } = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, locked, { type: "done", result: "failed" });
    assert.equal(state.message, "Account locked for 10 minutes");
});

test("typing after a failure clears its message", () => {
    const { state } = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, { type: "done", result: "failed" }, ...type("x"));
    assert.equal(state.message, "");
    assert.equal(state.error, false);
});

test("every key changes what the field shows", () => {
    let state = INITIAL;
    let shown = fieldText(state);
    for (let i = 0; i < MAX_DOTS * 2; i++) {
        state = next(state, { type: "key", text: "a" }).state;
        assert.notEqual(fieldText(state), shown, `key ${i + 1}`);
        shown = fieldText(state);
    }
    for (let i = 0; i < MAX_DOTS * 2; i++) {
        state = next(state, { type: "backspace" }).state;
        assert.notEqual(fieldText(state), shown, `backspace ${i + 1}`);
        shown = fieldText(state);
    }
});

test("keys while PAM checks go into the field as the next attempt", () => {
    let r = run(INITIAL, ...type("pw"), { type: "submit" }, ...type("new"), { type: "backspace" });
    assert.equal(r.state.checking, true);
    assert.equal(r.state.input, "ne");
    assert.equal(fieldText(r.state), "••");
    r = run(r.state, prompt, { type: "done", result: "failed" });
    assert.equal(r.state.input, "ne");
    assert.equal(r.state.message, WRONG);
});

test("Enter while PAM checks sends the field once that check fails", () => {
    let r = run(INITIAL, ...type("pw"), { type: "submit" }, ...type("pw2"), { type: "submit" });
    assert.deepEqual(r.actions, [{ type: "start" }]);
    assert.equal(r.state.queued, true);
    r = run(r.state, prompt, { type: "done", result: "failed" });
    assert.deepEqual(r.actions, [{ type: "respond", text: "pw" }, { type: "start" }]);
    assert.equal(r.state.checking, true);
    assert.equal(r.state.pending, "pw2");
    assert.equal(r.state.queued, false);
    assert.equal(r.state.attempts, 1);
});

test("a held Enter does nothing if the check succeeds", () => {
    const r = run(INITIAL, ...type("pw"), { type: "submit" }, ...type("x"), { type: "submit" }, prompt, { type: "done", result: "success" });
    assert.equal(r.state.unlocked, true);
});

test("a second prompt is answered from the field", () => {
    const code = { type: "pam", text: "Verification code: ", isError: false, responseRequired: true };
    let r = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, code);
    assert.equal(r.state.awaiting, true);
    assert.equal(r.state.checking, false);
    assert.equal(fieldText(r.state), "Verification code");
    r = run(r.state, ...type("123"), { type: "submit" });
    assert.deepEqual(r.actions, [{ type: "respond", text: "123" }]);
    assert.equal(r.state.checking, true);
});

test("a prompt PAM wants answered visibly shows what's typed", () => {
    const name = { type: "pam", text: "Name: ", isError: false, responseRequired: true, echo: true };
    let r = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, name);
    assert.equal(r.state.awaiting, true);
    assert.equal(r.state.echo, true);
    assert.equal(fieldText(r.state), "Name");
    r = run(r.state, ...type("ab c"));
    assert.equal(fieldText(r.state), "ab c");
    r = run(r.state, { type: "backspace" });
    assert.equal(fieldText(r.state), "ab ");
    r = run(r.state, { type: "submit" });
    assert.deepEqual(r.actions, [{ type: "respond", text: "ab " }]);
    assert.equal(r.state.echo, false);
});

test("a visible answer doesn't show keys typed blind while PAM checked", () => {
    const name = { type: "pam", text: "Name: ", isError: false, responseRequired: true, echo: true };
    const r = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, ...type("hunter2"), name);
    assert.equal(r.state.input, "");
    assert.equal(fieldText(r.state), "Name");
    // A hidden one keeps them, as dots: they may well be its answer.
    const code = { type: "pam", text: "Verification code: ", isError: false, responseRequired: true, echo: false };
    const hidden = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, ...type("123"), code);
    assert.equal(fieldText(hidden.state), "•••");
});

test("a visible prompt before the password's is answered from the field", () => {
    const name = { type: "pam", text: "Name: ", isError: false, responseRequired: true, echo: true };
    let r = run(INITIAL, ...type("pw"), { type: "submit" }, name);
    // The password isn't the answer, and the prompt shows.
    assert.deepEqual(r.actions, [{ type: "start" }]);
    assert.equal(r.state.awaiting, true);
    assert.equal(r.state.echo, true);
    assert.equal(fieldText(r.state), "Name");
    r = run(r.state, ...type("me"), { type: "submit" });
    assert.deepEqual(r.actions, [{ type: "respond", text: "me" }]);
    // The password answers the hidden prompt that follows.
    r = run(r.state, prompt);
    assert.deepEqual(r.actions, [{ type: "respond", text: "pw" }]);
    r = run(r.state, { type: "done", result: "success" });
    assert.equal(r.state.unlocked, true);
    assert.equal(r.state.pending, null);
});

test("a long visible answer shows its end", () => {
    const name = { type: "pam", text: "Name: ", isError: false, responseRequired: true, echo: true };
    const long = "abcdefghijklmnopqrstuvwxyz0123456789";
    const r = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, name, ...type(long));
    const shown = fieldText(r.state);
    assert.equal(shown.length, MAX_ECHO);
    assert.equal(shown, "…" + long.slice(long.length - MAX_ECHO + 1));
    assert.notEqual(fieldText(run(r.state, ...type("!")).state), shown);
});

test("after a visible prompt fails, the next password shows as dots", () => {
    const name = { type: "pam", text: "Name: ", isError: false, responseRequired: true, echo: true };
    const r = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, name, { type: "done", result: "failed" }, ...type("pw"));
    assert.equal(r.state.echo, false);
    assert.equal(fieldText(r.state), "••");
});

test("too many attempts and PAM errors say so", () => {
    const maxed = run(INITIAL, ...type("pw"), { type: "submit" }, prompt, { type: "done", result: "maxtries" }).state;
    assert.match(maxed.message, /Too many attempts/);
    const broken = run(INITIAL, ...type("pw"), { type: "submit" }, { type: "failed", detail: "PAM didn't start" }).state;
    assert.equal(broken.checking, false);
    assert.match(broken.message, /PAM didn't start/);
});

test("the password never reaches the message", () => {
    const { state } = run(INITIAL, ...type("hunter2"), { type: "submit" }, prompt, { type: "done", result: "failed" });
    assert.equal(state.message.includes("hunter2"), false);
    assert.equal(JSON.stringify(state).includes("hunter2"), false);
});

test("the short hostname drops the domain and a user- prefix", () => {
    assert.equal(shortHostname("host1.example.com", "user"), "host1");
    assert.equal(shortHostname("user-host1", "user"), "host1");
    assert.equal(shortHostname("user-host1.example.com", "user"), "host1");
    assert.equal(shortHostname("other-host1", "user"), "other-host1");
    assert.equal(shortHostname("user-", "user"), "user-");
    assert.equal(shortHostname("host1\n", ""), "host1");
});

test("the screensaver face shows, and the pointer brings back the password face", () => {
    let { state } = run(INITIAL, { type: "screensaver" });
    assert.equal(state.saver, true);
    state = run(state, { type: "wake" }).state;
    assert.equal(state.saver, false);
});

test("the first key typed on the screensaver wakes it and lands in the field", () => {
    const { state } = run(INITIAL, { type: "screensaver" }, ...type("p"));
    assert.equal(state.saver, false);
    assert.equal(state.input, "p");
    assert.equal(fieldText(state), "•");
});

test("Enter, Backspace and Escape on the screensaver only wake it", () => {
    for (const key of ["submit", "backspace", "clear"]) {
        const r = run(INITIAL, { type: "screensaver" }, { type: key });
        assert.equal(r.state.saver, false, key);
        assert.deepEqual(r.actions, [], key);
        assert.equal(r.state.input, "", key);
    }
});

test("PAM events leave the face alone", () => {
    const { state } = run(INITIAL, { type: "screensaver" }, { type: "pam", text: "hi", isError: false, responseRequired: false });
    assert.equal(state.saver, true);
});

test("the idle flag counts only for a few seconds after it's written", () => {
    const now = 1_000_000_000_000;
    const written = String(now / 1000);
    assert.equal(idleFlagFresh(written, now), true);
    assert.equal(idleFlagFresh(written + "\n", now + 5000), true);
    assert.equal(idleFlagFresh(written, now + (IDLE_FLAG_SECONDS + 1) * 1000), false);
    assert.equal(idleFlagFresh(String(now / 1000 + 60), now), false);
    assert.equal(idleFlagFresh("", now), false);
    assert.equal(idleFlagFresh("garbage", now), false);
});

test("the screensaver's spot stays inside the margins", () => {
    for (let minute = 0; minute < 5000; minute++) {
        const p = saverPosition(minute, 1920, 1080, 400, 200);
        assert.ok(p.x >= 115 && p.x + 400 <= 1920 - 115, `x ${p.x} at ${minute}`);
        assert.ok(p.y >= 64 && p.y + 200 <= 1080 - 64, `y ${p.y} at ${minute}`);
    }
});

test("the screensaver moves well away every minute", () => {
    const freeX = 1920 - 400 - 2 * 115;
    for (let minute = 1; minute < 5000; minute++) {
        const a = saverPosition(minute - 1, 1920, 1080, 400, 200);
        const b = saverPosition(minute, 1920, 1080, 400, 200);
        assert.ok(Math.abs(a.x - b.x) >= freeX * 0.24, `minute ${minute}: ${a.x} -> ${b.x}`);
    }
});

test("the same minute is the same spot", () => {
    assert.deepEqual(saverPosition(29000000, 2560, 1440, 500, 220), saverPosition(29000000, 2560, 1440, 500, 220));
});

test("a block bigger than the area sits at the margin", () => {
    assert.deepEqual(saverPosition(7, 300, 200, 400, 300), { x: 18, y: 12 });
});

test("a power action that worked says nothing", () => {
    assert.equal(powerMessage("Suspend", { started: true, code: 0, errors: "" }), "");
});

test("a power action logind's inhibitors block names them", () => {
    const errors = 'Operation inhibited by "Firefox" (PID 42 "firefox", user user), reason is "Playing video".\n'
        + "Please retry operation after closing inhibitors and logging out other users.";
    assert.equal(powerMessage("Restart", { started: true, code: 1, errors }), "Restart is blocked by Firefox: Playing video.");
});

test("a power action that fails otherwise says why", () => {
    assert.equal(powerMessage("Shut down", { started: true, code: 1, errors: "Failed to power off: Access denied\n" }),
        "Shut down failed: Failed to power off: Access denied");
    assert.equal(powerMessage("Shut down", { started: true, code: 1, errors: "" }), "Shut down failed (exit 1).");
    assert.equal(powerMessage("Suspend", { started: false, code: null }), "Suspend didn't start.");
});

test("an exit before the started signal still counts as started", () => {
    // Run.step can finish a run on its exit code and stderr before
    // `started` arrives (launch_test.mjs).
    let run = Run.initial();
    run = Run.step(run, { type: "exited", code: 0 }, ["systemctl"]);
    run = Run.step(run, { type: "stderr", text: "" }, ["systemctl"]);
    assert.equal(run.done, true);
    assert.equal(powerMessage("Suspend", run), "");
    run = Run.step(Run.initial(), { type: "exited", code: 1 }, ["systemctl"]);
    run = Run.step(run, { type: "stderr", text: "Failed to suspend: Access denied\n" }, ["systemctl"]);
    assert.equal(powerMessage("Suspend", run), "Suspend failed: Failed to suspend: Access denied");
});

// Every order of `events`.
function orders(events) {
    if (events.length <= 1) return [events];
    // No flatMap: the tests run with Qt's JS built-ins (qtjs_env_test.mjs).
    const all = [];
    events.forEach((e, i) => {
        for (const rest of orders(events.filter((_, j) => j !== i))) {
            all.push([e].concat(rest));
        }
    });
    return all;
}

function power(state, ...events) {
    let command = null;
    for (const event of events) {
        const r = powerNext(state, event);
        state = r.state;
        command = r.command ?? command;
    }
    return { state, command };
}

test("a power press starts its command, never forced", () => {
    const { state, command } = power(POWER_IDLE, { type: "press", id: "suspend" });
    assert.deepEqual(command, ["systemctl", "--check-inhibitors=yes", "suspend"]);
    assert.equal(powerBusy(state), true);
    assert.equal(powerBusy(POWER_IDLE), false);
});

test("the power buttons stay busy until the result is in and the process has stopped, in any order", () => {
    const signals = [
        { type: "started" },
        { type: "exited", code: 1 },
        { type: "stderr", text: "Operation inhibited by \"Firefox\" (PID 1 \"firefox\", user u), reason is \"Playing video\".\n" },
        { type: "stopped" },
    ];
    // A process starts before it stops; every other order happens.
    const possible = orders(signals).filter((o) =>
        o.findIndex((e) => e.type === "started") < o.findIndex((e) => e.type === "stopped"));
    let checked = 0;
    for (const order of possible) {
        let { state } = power(POWER_IDLE, { type: "press", id: "reboot" });
        for (let i = 0; i < order.length; i++) {
            assert.equal(powerBusy(state), true, `busy before ${order.map((e) => e.type).slice(0, i)}`);
            // A press while busy is ignored, and starts nothing.
            const pressed = powerNext(state, { type: "press", id: "poweroff" });
            assert.equal(pressed.command, null);
            assert.equal(pressed.state, state);
            state = powerNext(state, order[i]).state;
        }
        assert.equal(powerBusy(state), false, order.map((e) => e.type).join(","));
        assert.equal(state.message, "Restart is blocked by Firefox: Playing video.");
        // Free again: the next press starts its own run.
        assert.deepEqual(power(state, { type: "press", id: "suspend" }).command,
            ["systemctl", "--check-inhibitors=yes", "suspend"]);
        checked++;
    }
    assert.equal(checked, 12);
});

test("a power action that works says nothing, whatever the order", () => {
    for (const order of orders([{ type: "started" }, { type: "exited", code: 0 }, { type: "stderr", text: "" }, { type: "stopped" }])
        .filter((o) => o.findIndex((e) => e.type === "started") < o.findIndex((e) => e.type === "stopped"))) {
        const { state } = power(POWER_IDLE, { type: "press", id: "suspend" }, ...order);
        assert.equal(powerBusy(state), false);
        assert.equal(state.message, "");
    }
});

test("a power command that can't start frees the buttons and says so", () => {
    const { state } = power(POWER_IDLE, { type: "press", id: "poweroff" }, { type: "stopped" });
    assert.equal(powerBusy(state), false);
    assert.equal(state.message, "Shut down didn't start.");
});

test("a late signal from a finished run changes nothing", () => {
    const done = power(POWER_IDLE, { type: "press", id: "suspend" }, { type: "exited", code: 1 },
        { type: "stderr", text: "Failed to suspend: Access denied\n" }, { type: "stopped" }).state;
    const after = power(done, { type: "started" }).state;
    assert.equal(after.message, "Suspend failed: Failed to suspend: Access denied");
    assert.equal(powerBusy(after), false);
    // Signals with no run yet are ignored too.
    assert.equal(powerNext(POWER_IDLE, { type: "stopped" }).state, POWER_IDLE);
});

test("the layout badge is the layout's variant, in capitals", () => {
    assert.equal(layoutBadge("English (Dvorak)"), "DVORAK");
    assert.equal(layoutBadge("English (US)"), "US");
    assert.equal(layoutBadge("German"), "GERMAN");
    assert.equal(layoutBadge("English (US, intl., with dead keys)"), "US, INTL., WITH DEAD KEYS");
    assert.equal(layoutBadge(""), "");
    assert.equal(layoutBadge(undefined), "");
});

test("the main keyboard's keymap comes from hyprctl devices", () => {
    const devices = JSON.stringify({
        mice: [],
        keyboards: [
            { name: "power-button", active_keymap: "English (US)", main: false },
            { name: "at-translated-set-2-keyboard", active_keymap: "English (Dvorak)", main: true },
        ],
    });
    assert.equal(mainKeymap(devices), "English (Dvorak)");
    // No main one: the first.
    assert.equal(mainKeymap(JSON.stringify({ keyboards: [{ name: "kb", active_keymap: "German" }] })), "German");
    assert.equal(mainKeymap(JSON.stringify({ keyboards: [] })), null);
    assert.equal(mainKeymap(JSON.stringify({ keyboards: [{ name: "kb" }] })), null);
    assert.equal(mainKeymap("not json"), null);
    assert.equal(mainKeymap(""), null);
});

function layout(state, ...events) {
    let queries = 0;
    for (const event of events) {
        const r = layoutNext(state, event);
        state = r.state;
        if (r.query) queries++;
    }
    return { state, queries };
}

test("each refresh reads hyprctl, and the badge takes its answer", () => {
    const first = layout(LAYOUT_INITIAL, { type: "refresh" }, { type: "answer", keymap: "English (Dvorak)" });
    assert.equal(first.queries, 1);
    assert.equal(first.state.keymap, "English (Dvorak)");
    assert.equal(first.state.querying, false);
    // A later switch, or the main keyboard unplugged and another promoted:
    // the next refresh reads again and takes whatever is main now.
    const later = layout(first.state, { type: "refresh" }, { type: "answer", keymap: "German" });
    assert.equal(later.queries, 1);
    assert.equal(later.state.keymap, "German");
});

test("a refresh while a read runs reads again once, after it", () => {
    let r = layoutNext(LAYOUT_INITIAL, { type: "refresh" });
    assert.equal(r.query, true);
    // Two switches during the read: one more read, not two, and not yet.
    const during = layout(r.state, { type: "refresh" }, { type: "refresh" });
    assert.equal(during.queries, 0);
    // The first answer may predate the switches; it shows, and the reread
    // starts.
    r = layoutNext(during.state, { type: "answer", keymap: "English (Dvorak)" });
    assert.equal(r.query, true);
    assert.equal(r.state.querying, true);
    const done = layout(r.state, { type: "answer", keymap: "German" });
    assert.equal(done.queries, 0);
    assert.equal(done.state.keymap, "German");
    assert.equal(done.state.querying, false);
});

test("a failed read hides the badge, and a refresh during it still rereads", () => {
    let { state } = layout(LAYOUT_INITIAL, { type: "refresh" }, { type: "answer", keymap: "German" });
    const failed = layout(state, { type: "refresh" }, { type: "refresh" }, { type: "answer", keymap: null });
    assert.equal(failed.state.keymap, "");
    assert.equal(failed.state.querying, true);
    assert.equal(failed.queries, 2);
    assert.equal(layout(failed.state, { type: "answer", keymap: "German" }).state.keymap, "German");
});
