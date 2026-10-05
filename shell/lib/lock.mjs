// The lock's password face (SPEC.md §10): what typing, Enter and PAM do to
// the field. tide-lock (lock.qml) holds the state, feeds it each key and
// each PAM event through `next`, and carries out the actions it returns:
// "start" begins a PAM conversation, {respond} answers PAM's prompt.
//
// The state:
//   input      the text in the field, never logged or shown; typing goes
//              here even while PAM checks, so no key is ever dropped
//   checking   PAM has the password; "Checking" shows under the field
//   queued     Enter was pressed while PAM checked: the field is
//              submitted as soon as that check fails
//   pending    the password typed before PAM asked for it (Enter starts
//              the conversation, and PAM's first prompt takes this)
//   awaiting   PAM asked and nothing was pending: the next Enter answers
//   prompt     PAM's prompt text while awaiting, shown in the field
//   message    PAM's last message, shown verbatim under the field
//   error      whether that message, or the failure, is an error
//   attempts   failed attempts since the lock started
//   unlocked   PAM said yes
//
// Every key changes what the field shows (see fieldText), and changes it at
// once: no step here waits or animates, so each keystroke shows on the
// frame it's pressed, including while PAM checks the last attempt.

export const INITIAL = Object.freeze({
    input: "",
    checking: false,
    queued: false,
    pending: null,
    awaiting: false,
    prompt: "",
    message: "",
    error: false,
    attempts: 0,
    unlocked: false,
});

// A failure's message when PAM gave none of its own.
export const WRONG = "Wrong password. Try again.";

function with_(state, changes) {
    return Object.freeze(Object.assign({}, state, changes));
}

function result(state, actions) {
    return { state, actions: actions || [] };
}

// The state and actions after `event`:
//   {type: "key", text}       a printable key
//   {type: "backspace"}
//   {type: "clear"}           Escape
//   {type: "submit"}          Enter
//   {type: "pam", text, isError, responseRequired}
//                             PAM's message (PamContext's pamMessage)
//   {type: "done", result}    "success", "failed", "maxtries" or "error"
//                             (PamContext's completed)
//   {type: "failed", detail}  PAM couldn't run at all (start() false, or
//                             PamContext's error), so there's no result
export function next(state, event) {
    switch (event.type) {
    case "key":
        if (!event.text) return result(state);
        // A new attempt clears the last failure's message; while PAM
        // checks, the keys are the next attempt.
        return result(with_(state, {
            input: state.input + event.text,
            message: state.awaiting || state.checking ? state.message : "",
            error: state.checking ? state.error : false,
        }));
    case "backspace":
        if (state.input === "") return result(state);
        return result(with_(state, { input: state.input.slice(0, -1) }));
    case "clear":
        return result(with_(state, { input: "", queued: false }));
    case "submit":
        // An empty Enter is a no-op. Enter while PAM checks is held, and
        // sends the field if that check fails.
        if (state.input === "") return result(state);
        if (state.checking) return result(with_(state, { queued: true }));
        if (state.awaiting) {
            return result(
                with_(state, { input: "", checking: true, awaiting: false, prompt: "" }),
                [{ type: "respond", text: state.input }],
            );
        }
        return result(
            with_(state, { input: "", checking: true, pending: state.input, message: "", error: false }),
            [{ type: "start" }],
        );
    case "pam":
        if (event.responseRequired) {
            // The prompt for the password Enter already took.
            if (state.pending !== null) {
                return result(
                    with_(state, { pending: null }),
                    [{ type: "respond", text: state.pending }],
                );
            }
            // A second prompt (a one-time code, say): the field answers it.
            return result(with_(state, {
                checking: false,
                awaiting: true,
                prompt: event.text || "",
            }));
        }
        return result(with_(state, { message: event.text || "", error: Boolean(event.isError) }));
    case "done":
        if (event.result === "success") {
            return result(with_(state, { checking: false, pending: null, awaiting: false, unlocked: true }));
        }
        return retry(failure(state, event.result === "maxtries"
            ? "Too many attempts. Wait, then try again."
            : event.result === "error" ? "Couldn't check the password." : WRONG));
    case "failed":
        return retry(failure(state, "Couldn't check the password: " + (event.detail || "PAM failed") + "."));
    default:
        return result(state);
    }
}

// A failed attempt. The field keeps whatever was typed while PAM checked
// (it was cleared at Enter), and takes keys again. PAM's own error, a
// faillock countdown say, is kept verbatim over the generic text.
function failure(state, fallback) {
    return with_(state, {
        checking: false,
        pending: null,
        awaiting: false,
        prompt: "",
        message: state.error && state.message ? state.message : fallback,
        error: true,
        attempts: state.attempts + 1,
    });
}

// After a failure: an Enter held during the check sends the field now.
function retry(state) {
    if (!state.queued) return result(state);
    return next(with_(state, { queued: false }), { type: "submit" });
}

// The most dots the field shows; past this it shows a count instead, so the
// next key still changes what's drawn rather than adding a dot off the end.
export const MAX_DOTS = 20;

// What the field shows: a dot per typed character (past MAX_DOTS, a count),
// else PAM's prompt, else "" for the placeholder.
export function fieldText(state) {
    const n = state.input.length;
    if (n > MAX_DOTS) return "•".repeat(MAX_DOTS - 4) + " " + n;
    if (n > 0) return "•".repeat(n);
    if (state.awaiting && state.prompt) return state.prompt.replace(/:\s*$/, "");
    return "";
}

// The line under the field: "Checking" while PAM checks, else PAM's message
// or the failure.
export function statusText(state) {
    return state.checking ? "Checking" : state.message;
}

// The hostname the lock leads with (SPEC.md §11): the first label, without
// a leading "<user>-", the rule i3statusdwm uses. A name that is only the
// prefix keeps it, so the face never reads blank.
export function shortHostname(name, user) {
    const label = String(name || "").trim().split(".")[0];
    const prefix = user ? user + "-" : "";
    if (prefix && label.startsWith(prefix) && label.length > prefix.length) {
        return label.slice(prefix.length);
    }
    return label;
}
