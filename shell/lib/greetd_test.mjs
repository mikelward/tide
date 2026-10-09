// Tests for greetd.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { INITIAL, active, available, cancel, createSession, launch, received, respond, stopped } from "./greetd.mjs";

const PASSWORD = { type: "auth_message", auth_message_type: "secret", auth_message: "Password: " };
const SUCCESS = { type: "success" };
const WRONG = { type: "error", error_type: "auth_error", description: "pam_authenticate: AUTH_ERR" };

// Runs steps against the state, collecting every request and event. A step
// is a function of the state, or [request type, reply] for tide-greetd's
// line answering that request.
function run(steps, state = INITIAL) {
    const requests = [];
    const events = [];
    for (const step of steps) {
        const r = typeof step === "function" ? step(state) : received(state, { request: step[0], reply: step[1] });
        state = r.state;
        requests.push(...r.requests);
        events.push(...r.events);
    }
    return { state: state, requests: requests, events: events };
}

test("a login asks for the password, takes it and is ready to launch", () => {
    const r = run([
        (s) => createSession(s, "probe"),
        ["create_session", PASSWORD],
        (s) => respond(s, "right"),
        ["post_auth_message_response", SUCCESS],
    ]);
    assert.deepEqual(r.requests, [
        { type: "create_session", username: "probe" },
        { type: "post_auth_message_response", response: "right" },
    ]);
    assert.deepEqual(r.events, [
        { type: "authMessage", message: "Password: ", error: false, responseRequired: true, echo: false },
        { type: "readyToLaunch" },
    ]);
    assert.equal(r.state.phase, "ready");
    assert.equal(active(r.state), true);
    assert.deepEqual(r.state.waiting, []);
});

test("launching hands greetd the session, and its success means exit", () => {
    const ready = run([(s) => createSession(s, "probe"), ["create_session", SUCCESS]]).state;
    const r = run([(s) => launch(s, ["tide"], ["XDG_SESSION_TYPE=wayland"]), ["start_session", SUCCESS]], ready);
    assert.deepEqual(r.requests, [{ type: "start_session", cmd: ["tide"], env: ["XDG_SESSION_TYPE=wayland"] }]);
    assert.deepEqual(r.events, [{ type: "launched" }]);
    assert.equal(r.state.phase, "launched");
    assert.deepEqual(stopped(r.state, 0).events, []);
});

test("a failed launch is an error, and the login is over", () => {
    const ready = run([(s) => createSession(s, "probe"), ["create_session", SUCCESS]]).state;
    const r = run([(s) => launch(s, ["tide"], []),
        ["start_session", { type: "error", error_type: "error", description: "a session is already scheduled" }]], ready);
    assert.deepEqual(r.events, [{ type: "error", message: "a session is already scheduled" }]);
    assert.equal(r.state.phase, "inactive");
    assert.equal(active(r.state), false);
});

test("launch before logging in sends nothing and says why", () => {
    const r = launch(INITIAL, ["tide"], []);
    assert.deepEqual(r.requests, []);
    assert.equal(r.events[0].type, "error");
});

test("a visible prompt echoes; info and error messages are acknowledged without an answer", () => {
    const r = run([
        (s) => createSession(s, "probe"),
        ["create_session", { type: "auth_message", auth_message_type: "info", auth_message: "Touch the key" }],
        ["post_auth_message_response", { type: "auth_message", auth_message_type: "error", auth_message: "Key not found" }],
        ["post_auth_message_response", { type: "auth_message", auth_message_type: "visible", auth_message: "Code: " }],
    ]);
    assert.deepEqual(r.requests, [
        { type: "create_session", username: "probe" },
        { type: "post_auth_message_response" },
        { type: "post_auth_message_response" },
    ]);
    assert.deepEqual(r.events, [
        { type: "authMessage", message: "Touch the key", error: false, responseRequired: false, echo: false },
        { type: "authMessage", message: "Key not found", error: true, responseRequired: false, echo: false },
        { type: "authMessage", message: "Code: ", error: false, responseRequired: true, echo: true },
    ]);
});

test("an answer with no prompt waiting goes nowhere", () => {
    assert.deepEqual(respond(INITIAL, "hunter2").requests, []);
    const answered = run([(s) => createSession(s, "probe"), ["create_session", PASSWORD], (s) => respond(s, "x")]).state;
    assert.deepEqual(respond(answered, "again").requests, []);
});

test("a wrong password is a failure, and greetd's session is cancelled", () => {
    const r = run([
        (s) => createSession(s, "probe"),
        ["create_session", PASSWORD],
        (s) => respond(s, "wrong"),
        ["post_auth_message_response", WRONG],
    ]);
    assert.deepEqual(r.requests[r.requests.length - 1], { type: "cancel_session" });
    assert.deepEqual(r.events[r.events.length - 1], { type: "authFailure", message: "pam_authenticate: AUTH_ERR" });
    assert.equal(r.state.phase, "inactive");
});

// quickshell-mirror/quickshell#1266: the next login starts before greetd
// has answered the cancel, and the cancel's success isn't the new login's.
test("a cancel's reply is never read as the next login's", () => {
    const r = run([
        (s) => createSession(s, "probe"),
        ["create_session", PASSWORD],
        (s) => respond(s, "wrong"),
        ["post_auth_message_response", WRONG],
        (s) => createSession(s, "probe"),
        ["cancel_session", SUCCESS],
        ["create_session", PASSWORD],
    ]);
    assert.deepEqual(r.requests, [
        { type: "create_session", username: "probe" },
        { type: "post_auth_message_response", response: "wrong" },
        { type: "cancel_session" },
        { type: "create_session", username: "probe" },
    ]);
    assert.deepEqual(r.events.map((e) => e.type), ["authMessage", "authFailure", "authMessage"]);
    assert.equal(r.state.phase, "authenticating");
    assert.equal(r.state.responseRequired, true);
});

test("switching user mid-login drops the first login's late replies", () => {
    const r = run([
        (s) => createSession(s, "alice"),
        (s) => createSession(s, "bob"),
        ["create_session", PASSWORD],
        ["cancel_session", SUCCESS],
        ["create_session", { type: "auth_message", auth_message_type: "secret", auth_message: "bob's password: " }],
    ]);
    assert.deepEqual(r.requests, [
        { type: "create_session", username: "alice" },
        { type: "cancel_session" },
        { type: "create_session", username: "bob" },
    ]);
    assert.deepEqual(r.events, [
        { type: "authMessage", message: "bob's password: ", error: false, responseRequired: true, echo: false },
    ]);
    assert.equal(r.state.user, "bob");
});

test("a late success for a cancelled login doesn't make it ready", () => {
    const r = run([
        (s) => createSession(s, "probe"),
        (s) => cancel(s),
        ["create_session", SUCCESS],
        ["cancel_session", SUCCESS],
    ]);
    assert.deepEqual(r.events, []);
    assert.equal(r.state.phase, "inactive");
    assert.equal(active(r.state), false);
});

test("cancel with no login under way sends nothing", () => {
    assert.deepEqual(cancel(INITIAL).requests, []);
});

test("once the session is handed over, cancel and a new login do nothing, and its success still counts", () => {
    const ready = run([(s) => createSession(s, "probe"), ["create_session", SUCCESS]]).state;
    const r = run([
        (s) => launch(s, ["tide"], []),
        (s) => cancel(s),
        (s) => createSession(s, "other"),
        ["start_session", SUCCESS],
    ], ready);
    assert.deepEqual(r.requests, [{ type: "start_session", cmd: ["tide"], env: [] }]);
    assert.deepEqual(r.events, [{ type: "launched" }]);
});

test("a failed cancel is reported", () => {
    const r = run([(s) => createSession(s, "probe"), (s) => cancel(s), ["create_session", PASSWORD],
        ["cancel_session", { type: "error", error_type: "error", description: "pam_end failed" }]]);
    assert.deepEqual(r.events, [{ type: "error", message: "couldn't cancel the login: pam_end failed" }]);
});

test("a login left configured is cancelled and started over, once", () => {
    const busy = { type: "error", error_type: "error", description: "a session is already being configured" };
    const r = run([
        (s) => createSession(s, "probe"),
        ["create_session", busy],
        ["cancel_session", SUCCESS],
        ["create_session", busy],
    ]);
    assert.deepEqual(r.requests, [
        { type: "create_session", username: "probe" },
        { type: "cancel_session" },
        { type: "create_session", username: "probe" },
        { type: "cancel_session" },
    ]);
    assert.deepEqual(r.events, [{ type: "error", message: "a session is already being configured" }]);
    assert.equal(r.state.phase, "inactive");
});

test("any other error ends the login and cancels it", () => {
    const r = run([(s) => createSession(s, "probe"),
        ["create_session", { type: "error", error_type: "error", description: "session not active" }]]);
    assert.deepEqual(r.requests[r.requests.length - 1], { type: "cancel_session" });
    assert.deepEqual(r.events, [{ type: "error", message: "session not active" }]);
});

test("an unexpected reply type is an error", () => {
    const r = run([(s) => createSession(s, "probe"), ["create_session", { type: "mystery" }]]);
    assert.deepEqual(r.events, [{ type: "error", message: 'greetd sent an unexpected "mystery" reply' }]);
    assert.deepEqual(r.requests[r.requests.length - 1], { type: "cancel_session" });
});

test("a fault from tide-greetd ends the connection", () => {
    const r = received(createSession(INITIAL, "probe").state, { fault: "couldn't connect to greetd at /run/greetd.sock: no such file" });
    assert.deepEqual(r.events, [{ type: "error", message: "couldn't connect to greetd at /run/greetd.sock: no such file" }]);
    assert.equal(available(r.state), false);
    const again = createSession(r.state, "probe");
    assert.deepEqual(again.requests, []);
    assert.deepEqual(again.events, [{ type: "error", message: "greetd isn't reachable" }]);
});

test("a reply to nothing sent, or to the wrong request, ends the connection", () => {
    assert.equal(received(INITIAL, { request: "create_session", reply: PASSWORD }).state.phase, "gone");
    const waiting = createSession(INITIAL, "probe").state;
    assert.equal(received(waiting, { request: "cancel_session", reply: SUCCESS }).state.phase, "gone");
    assert.equal(received(waiting, { request: "create_session", reply: null }).state.phase, "gone");
    assert.equal(received(waiting, null).state.phase, "gone");
});

test("tide-greetd stopping without a fault ends the connection", () => {
    const r = stopped(createSession(INITIAL, "probe").state, 1);
    assert.deepEqual(r.events, [{ type: "error", message: "tide-greetd stopped (exit 1)" }]);
    assert.equal(available(r.state), false);
    assert.deepEqual(stopped(r.state, 1).events, []);
    assert.deepEqual(stopped(INITIAL, null).events, [{ type: "error", message: "couldn't start tide-greetd" }]);
});
