// The greeter's side of greetd's conversation (SPEC.md §11), carried over
// tide-greetd (cmd/tide-greetd), which relays one request at a time and
// hands back each reply with the type of the request it answers. Replies
// come back in the order their requests went, so the oldest request still
// waiting is always the one a reply answers.
//
// Every create_session and cancel_session starts a new login, and each
// request remembers the login it was sent for. A reply to a request from an
// earlier login is dropped, whatever it says. That's what Quickshell
// 0.3.1's Greetd lacks (quickshell-mirror/quickshell#1266): a cancel's
// reply, or one to a login since replaced, read as the new login's.
//
// Each function takes the state and returns { state, requests, events }:
// `requests` for greetd, in order, and `events` for the greeter:
//   { type: "authMessage", message, error, responseRequired, echo }
//   { type: "authFailure", message }   a wrong answer (greetd's auth_error)
//   { type: "readyToLaunch" }          logged in; launch() hands it the session
//   { type: "launched" }               greetd took the session; time to exit
//   { type: "error", message }         anything else that ended the login
// A login that ends in a failure or an error is cancelled at greetd, which
// otherwise keeps it half set up and refuses the next create_session.

export const INITIAL = Object.freeze({
    // "inactive", "authenticating", "ready" (logged in, not launched),
    // "launching", "launched", or "gone" (the connection failed).
    phase: "inactive",
    login: 0,
    user: "",
    responseRequired: false,
    // Whether this login already started over once on "a session is
    // already being configured", so a second one is an error, not a loop.
    restarted: false,
    // The requests still waiting for a reply, oldest first: { type, login }.
    waiting: Object.freeze([]),
});

function result(state, requests, events) {
    return { state: state, requests: requests, events: events };
}

// Sends `request` for the state's login.
function sending(state, requests, request) {
    requests.push(request);
    return Object.assign({}, state, {
        waiting: state.waiting.concat([{ type: request.type, login: state.login }]),
    });
}

// Ends the current login at greetd: a new login, with a cancel_session sent
// for it.
function cancelling(state, requests) {
    const next = Object.assign({}, state, { phase: "inactive", login: state.login + 1, responseRequired: false });
    return sending(next, requests, { type: "cancel_session" });
}

// Starts a login for `user`, cancelling whatever greetd has going first.
// Not once a session has been handed over: greetd has it scheduled, and the
// greeter is about to exit.
export function createSession(state, user) {
    if (state.phase === "gone") {
        return result(state, [], [{ type: "error", message: "greetd isn't reachable" }]);
    }
    if (state.phase === "launching" || state.phase === "launched") {
        return result(state, [], []);
    }
    const requests = [];
    let s = state.phase === "inactive" ? state : cancelling(state, requests);
    s = Object.assign({}, s, { phase: "authenticating", login: s.login + 1, user: user, responseRequired: false, restarted: false });
    s = sending(s, requests, { type: "create_session", username: user });
    return result(s, requests, []);
}

// Answers the prompt greetd is waiting on. Without one, there's nothing to
// answer, and the text goes nowhere.
export function respond(state, text) {
    if (state.phase !== "authenticating" || !state.responseRequired) {
        return result(state, [], []);
    }
    const requests = [];
    const s = sending(Object.assign({}, state, { responseRequired: false }), requests,
        { type: "post_auth_message_response", response: text });
    return result(s, requests, []);
}

// Stops the login under way, if there is one. A session already handed
// over isn't one: greetd has nothing left to cancel, and the reply to
// start_session still has to count, since the greeter exits on it.
export function cancel(state) {
    if (state.phase !== "authenticating" && state.phase !== "ready") {
        return result(state, [], []);
    }
    const requests = [];
    return result(cancelling(state, requests), requests, []);
}

// Hands greetd the session to start, once logged in.
export function launch(state, command, env) {
    if (state.phase !== "ready") {
        return result(state, [], [{ type: "error", message: "not logged in, so there's no session to start" }]);
    }
    const requests = [];
    const s = sending(Object.assign({}, state, { phase: "launching" }), requests,
        { type: "start_session", cmd: command, env: env });
    return result(s, requests, []);
}

// A line from tide-greetd, parsed: { request, reply }, or { fault }.
export function received(state, line) {
    if (line === null || typeof line !== "object") {
        return gone(state, "tide-greetd sent something that isn't a reply");
    }
    if (typeof line.fault === "string") {
        return gone(state, line.fault);
    }
    const head = state.waiting[0];
    if (head === undefined || head.type !== line.request || line.reply === null || typeof line.reply !== "object") {
        return gone(state, `tide-greetd's reply to ${line.request} doesn't answer what was sent`);
    }
    const s = Object.assign({}, state, { waiting: state.waiting.slice(1) });
    const reply = line.reply;
    if (head.type === "cancel_session") {
        // Nothing waits on a cancel, but a failed one leaves greetd's
        // session in place, so the next login would be refused.
        if (reply.type === "error") {
            return result(s, [], [{ type: "error", message: `couldn't cancel the login: ${reply.description}` }]);
        }
        return result(s, [], []);
    }
    if (head.login !== s.login) {
        // An earlier login's, since cancelled.
        return result(s, [], []);
    }
    if (head.type === "start_session") {
        if (reply.type === "success") {
            return result(Object.assign({}, s, { phase: "launched" }), [], [{ type: "launched" }]);
        }
        // greetd drops the logged-in session when start_session fails.
        return result(Object.assign({}, s, { phase: "inactive", login: s.login + 1 }), [],
            [{ type: "error", message: describe(reply) }]);
    }
    return conversed(s, reply);
}

// A reply to create_session or post_auth_message_response.
function conversed(state, reply) {
    const requests = [];
    if (reply.type === "auth_message") {
        const kind = reply.auth_message_type;
        const responseRequired = kind === "visible" || kind === "secret";
        const event = {
            type: "authMessage",
            message: String(reply.auth_message ?? ""),
            error: kind === "error",
            responseRequired: responseRequired,
            echo: kind === "visible",
        };
        let s = Object.assign({}, state, { responseRequired: responseRequired });
        if (!responseRequired) {
            // An info or error message only needs acknowledging.
            s = sending(s, requests, { type: "post_auth_message_response" });
        }
        return result(s, requests, [event]);
    }
    if (reply.type === "success") {
        return result(Object.assign({}, state, { phase: "ready", responseRequired: false }), [], [{ type: "readyToLaunch" }]);
    }
    if (reply.type === "error" && reply.error_type === "error" && reply.description === "a session is already being configured"
        && !state.restarted) {
        // A login left behind, by an earlier run of the greeter, say:
        // cancel it, then start over for the same user, once.
        const user = state.user;
        let s = cancelling(state, requests);
        s = Object.assign({}, s, { phase: "authenticating", login: s.login + 1, user: user, restarted: true });
        s = sending(s, requests, { type: "create_session", username: user });
        return result(s, requests, []);
    }
    const s = cancelling(state, requests);
    if (reply.type === "error" && reply.error_type === "auth_error") {
        return result(s, requests, [{ type: "authFailure", message: String(reply.description ?? "") }]);
    }
    return result(s, requests, [{ type: "error", message: describe(reply) }]);
}

function describe(reply) {
    if (reply.type === "error" && typeof reply.description === "string" && reply.description !== "") {
        return reply.description;
    }
    return `greetd sent an unexpected ${JSON.stringify(reply.type)} reply`;
}

// The connection's gone: nothing more can be sent.
function gone(state, why) {
    return result(Object.assign({}, state, { phase: "gone", responseRequired: false, waiting: [] }), [],
        [{ type: "error", message: why }]);
}

// What the greeter makes of tide-greetd stopping, with its exit code, or
// null if it never started. A fault line before it said why; this covers a
// stop with no fault, which is still the end of the connection.
export function stopped(state, exitCode) {
    if (state.phase === "gone" || state.phase === "launched") {
        return result(state, [], []);
    }
    return gone(state, exitCode === null ? "couldn't start tide-greetd" : `tide-greetd stopped (exit ${exitCode})`);
}

// Whether a login is under way at greetd: one that cancel() would stop.
export function active(state) {
    return state.phase === "authenticating" || state.phase === "ready" || state.phase === "launching";
}

// Whether greetd can be asked anything.
export function available(state) {
    return state.phase !== "gone";
}
