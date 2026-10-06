// The shell's polkit agent (SPEC.md §5.2, §14.1), as pure functions that
// shell/PolkitData.qml and shell/PolkitPrompt.qml call.

// How long to wait for the agent to register with polkitd before taking it
// as refused, and between tries after that: 5 s, doubling to once a
// minute, as the transitional shell does for its agent (§5.2). polkitd
// refuses a second agent for a session, so this is how the shell takes
// over once another desktop's agent goes. Quickshell 0.3.1 only logs a
// refusal (src/services/polkit/agentimpl.cpp), so the wait stands in for a
// signal it doesn't send.
export const FIRST_RETRY_SECONDS = 5;
export const LAST_RETRY_SECONDS = 60;

export function retrySeconds(attempt) {
    if (!Number.isInteger(attempt) || attempt < 0) {
        throw new Error(`retrySeconds: expected an attempt number from 0, got ${attempt}`);
    }
    return Math.min(FIRST_RETRY_SECONDS * Math.pow(2, Math.min(attempt, 8)), LAST_RETRY_SECONDS);
}

// What a request does first, from `tide prompt-focus`'s exit code: the
// prompt takes the keyboard after a key press (0, §14.1); otherwise (1) a
// notification offers it. Any other code means the guard couldn't say, and
// the safe answer is the notification too, so a password field never
// appears under typing meant for something else. `warn` is whether that's
// worth a log line.
export function route(code) {
    if (code === 0) {
        return { show: "prompt", warn: false };
    }
    return { show: "notify", warn: code !== 1 };
}

// The notification that offers the prompt (§14.1). It's critical, so it
// waits for you, and from `tide`, a system sender, so it shows through Do
// not disturb (§9). Its Authenticate button and a click on it both open
// the prompt: a click is the server's "default" action. The polkit message
// comes from the action's description, so it's escaped: a server that
// takes body markup would otherwise read its own tags into it.
export const AUTHENTICATE = "authenticate";

export function escapeMarkup(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function notifyCommand(message) {
    return [
        "notify-send",
        "--app-name=tide",
        "--urgency=critical",
        "--icon=changes-prevent-symbolic",
        "--action=default=Authenticate",
        `--action=${AUTHENTICATE}=Authenticate`,
        "--wait",
        "Authentication required",
        escapeMarkup(message || "An app is asking for your password.")
    ];
}

// What became of the notification, from notify-send --wait's output and
// exit: "open" when Authenticate was clicked, "dismissed" when it closed
// without that, and "failed" when it couldn't be shown (no notify-send, no
// server). A dismissal cancels the request, so the app hears no rather
// than waiting on a prompt nobody will open. On a failure the prompt shows
// without taking the keyboard, so a click opens it.
export function notifyOutcome(started, code, output) {
    if (!started || code !== 0) {
        return "failed";
    }
    const lines = String(output ?? "").split("\n").map(l => l.trim());
    return lines.indexOf(AUTHENTICATE) >= 0 || lines.indexOf("default") >= 0 ? "open" : "dismissed";
}

// One run of a command whose answer matters (`tide prompt-focus`,
// notify-send), from the Process signals the QML feeds in: {type:
// "started"}, {type: "stopped"}, {type: "exited", code}, and {type:
// "stdout" | "stderr", text} as each stream ends. They arrive in no fixed
// order, and Quickshell 0.3 reports a command that can't start only by
// `running` going false without `started` (shell/lib/launch.mjs says the
// same). So a run is over then, or once the exit code and both streams are
// in. `finished` is true on exactly the step that ends it.
export function runStart() {
    return Object.freeze({ started: false, stopped: false, code: null, out: null, err: null, done: false, finished: false });
}

export function runStep(run, event) {
    const next = Object.assign({}, run, { finished: false });
    if (run.done) {
        return Object.freeze(next);
    }
    switch (event.type) {
    case "started":
        next.started = true;
        break;
    case "stopped":
        next.stopped = true;
        break;
    case "exited":
        next.code = event.code;
        break;
    case "stdout":
        next.out = event.text;
        break;
    case "stderr":
        next.err = event.text;
        break;
    default:
        throw new Error(`unknown process event: ${event.type}`);
    }
    if ((next.stopped && !next.started && next.code === null) || (next.code !== null && next.out !== null && next.err !== null)) {
        next.done = true;
        next.finished = true;
    }
    return Object.freeze(next);
}

// The identity to ask for first: the user running the shell, when polkit
// lists them (an admin's own password), else polkit's first. Each is
// Quickshell's Identity ({string, displayName, isGroup}); `string` is the
// user or group name.
export function preferredIdentity(identities, user) {
    const list = identities ?? [];
    for (let i = 0; i < list.length; i++) {
        if (!list[i].isGroup && user && list[i].string === user) {
            return i;
        }
    }
    return list.length > 0 ? 0 : -1;
}

// The line under the message naming whose password is asked for.
export function identityLabel(identity) {
    if (!identity) {
        return "";
    }
    const name = identity.displayName || identity.string || "";
    if (identity.isGroup) {
        return `A member of ${name}`;
    }
    // A full name from GECOS can carry the rest of the field after a comma.
    const full = name.split(",")[0].trim();
    return full && full !== identity.string ? `${full} (${identity.string})` : identity.string || full;
}

// The field's placeholder: PAM's own prompt, without its trailing colon,
// or "Password".
export function promptText(inputPrompt) {
    const text = String(inputPrompt ?? "").trim().replace(/:$/, "").trim();
    return text || "Password";
}

// The line under the field: PAM's message while there is one, else a
// failed attempt's, else nothing. `failed` is AuthFlow.failed, which stays
// true for the rest of the request.
export function statusLine(supplementary, isError, failed) {
    const text = String(supplementary ?? "").trim();
    if (text !== "") {
        return { text: text, error: !!isError };
    }
    if (failed) {
        return { text: "That didn't work. Try again.", error: true };
    }
    return { text: "", error: false };
}
