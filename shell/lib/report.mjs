// Reporting a bad config file (SPEC.md §16.1): a notification naming the
// file and line, at most once per distinct error for the life of the
// shell, rather than at every reload. An error fixed and later made again
// isn't reported twice; the log has it every time.
//
// The state is { current, delivered, sending }: the errors the last verdict
// on the files found, those a notification has reached the user for (kept
// for the life of the shell), and those whose notification is on its way.
// An error counts as reported only once its notification is delivered, so
// one sent before the notification server is up (at login, say) is sent
// again rather than lost.

export const NOTHING = Object.freeze({ current: [], delivered: [], sending: [] });

function unsent(state) {
    return state.current.filter(e => !state.delivered.includes(e) && !state.sending.includes(e));
}

// A new verdict: `errors` is the files' complete set of current errors.
// Returns the state and the errors to send now: those never delivered.
export function verdict(state, errors) {
    const current = [...new Set(errors)];
    const next = Object.assign({}, state, { current });
    const send = unsent(next);
    return { state: Object.assign({}, next, { sending: next.sending.concat(send) }), send };
}

// A notification for `error` finished, delivered (`ok`) or not.
export function sent(state, error, ok) {
    const sending = state.sending.filter(e => e !== error);
    const delivered = ok && !state.delivered.includes(error)
        ? state.delivered.concat([error])
        : state.delivered;
    return Object.assign({}, state, { sending, delivered });
}

// The current errors still waiting to be delivered, to send again.
export function retry(state) {
    const send = unsent(state);
    return { state: Object.assign({}, state, { sending: state.sending.concat(send) }), send };
}

// Whether any current error hasn't been delivered.
export function pending(state) {
    return state.current.some(e => !state.delivered.includes(e));
}

// The notify-send command reporting one error. notify-send hands it to
// whichever server owns the notifications name: swaync today, the shell
// itself once it is the server (§9).
export function notifyCommand(summary, error) {
    return ["notify-send", "--app-name=tide", summary, error];
}
