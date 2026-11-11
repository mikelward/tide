// The session's splash (SPEC.md §5.3): what it shows while tide's shell
// starts, and when it goes. splash.qml asks systemd for tide.service's
// state each POLL_MS and passes each answer here.

export const POLL_MS = 1000;
// After this long it says the start is slow.
export const SLOW_AFTER_MS = 10 * 1000;
// After this long it goes anyway, so it never hides a session.
export const GIVE_UP_AFTER_MS = 120 * 1000;

export function initial(now) {
    return Object.freeze({ since: now, slow: false, done: false });
}

// `status` is what `systemctl --user is-active tide.service` printed:
// "active" once the shell has said it's ready, "activating" before,
// "failed" when it gave up, which tide-shell-fallback answers with a
// terminal. Returns {state, quit, log}: quit when the splash should go,
// and log, a line for the journal, or null.
export function next(state, status, now) {
    if (state.done) {
        return { state, quit: false, log: null };
    }
    const secs = Math.round((now - state.since) / 1000);
    const end = (log) => ({ state: Object.freeze(Object.assign({}, state, { done: true })), quit: true, log });
    if (status === "active") {
        return end(`the shell is ready after ${secs} s`);
    }
    if (status === "failed") {
        return end(`the shell failed after ${secs} s; the fallback takes over`);
    }
    if (now - state.since >= GIVE_UP_AFTER_MS) {
        return end(`the shell isn't ready after ${secs} s (tide.service is ${status || "unknown"}); going anyway`);
    }
    if (!state.slow && now - state.since >= SLOW_AFTER_MS) {
        return {
            state: Object.freeze(Object.assign({}, state, { slow: true })),
            quit: false,
            log: `the shell isn't ready after ${secs} s (tide.service is ${status || "unknown"})`,
        };
    }
    return { state, quit: false, log: null };
}

// The line under the hostname.
export function text(state) {
    return state.slow ? "Still starting tide" : "Starting tide";
}
