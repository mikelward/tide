// Tests for lock.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { IDLE_FLAG_SECONDS, INITIAL, MAX_DOTS, WRONG, fieldText, idleFlagFresh, next, saverPosition, shortHostname, statusText } from "./lock.mjs";

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
