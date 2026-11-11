// tidewm's config errors (its docs/config.md), for ConfigErrorsData.qml:
// tidewm leaves a bad line out and names it in GET_CONFIG's `errors`, so
// the session comes up with a key or a setting missing and nothing on
// screen to say why. The shell asks as it connects and after each reload
// it knows of, shows a warning in the bar while there are errors, and
// sends one notification per distinct set (SPEC.md §7.4). Pure functions
// over plain data, so they're tested here.
//
// The state is { errors, told, sending }: the last load's errors, as
// tidewm worded them; the set (key) a notification last reached the user
// for, or ""; and the set whose notification is on its way, or "".

export const NOTHING = Object.freeze({ errors: Object.freeze([]), told: "", sending: "" });

// How many errors the bar's list shows before it says how many more.
export const SHOWN = 8;

// The warning triangle, from the icon theme.
export const ICON = "dialog-warning-symbolic";

// GET_CONFIG's reply, `tide-msg --type get_config`'s output: { errors },
// each as tidewm reported it, or { why } for a reply that doesn't say,
// as a tidewm from before `errors`, or no reply at all. Never a guess: a
// reply that can't be read shows no warning.
export function replyErrors(text) {
    if (typeof text !== "string" || text.trim() === "") {
        return { why: "it said nothing" };
    }
    let reply;
    try {
        reply = JSON.parse(text);
    } catch (e) {
        return { why: `its reply isn't JSON (${e.message})` };
    }
    if (reply === null || typeof reply !== "object" || Array.isArray(reply)) {
        return { why: "its reply isn't an object" };
    }
    if (!Object.prototype.hasOwnProperty.call(reply, "errors")) {
        return { why: "its reply has no errors, as an older tidewm's" };
    }
    if (!Array.isArray(reply.errors) || reply.errors.some(e => typeof e !== "string")) {
        return { why: "its reply's errors aren't a list of strings" };
    }
    return { errors: reply.errors.filter(e => e.trim() !== "") };
}

// A set of errors as one string, the same whatever their order, or "" for
// none.
export function keyOf(errors) {
    return errors.length === 0 ? "" : JSON.stringify([...new Set(errors)].sort());
}

function toSend(state) {
    const key = keyOf(state.errors);
    return key !== "" && key !== state.told && key !== state.sending;
}

// A load's errors are in. Returns the state and whether to notify now:
// for a set that's neither been delivered nor is on its way, so a
// reconnect or a reload reporting the same errors says nothing more. A
// load with none forgets the last set, so the same mistake made again
// later is reported again.
export function loaded(state, errors) {
    const next = { errors, told: errors.length === 0 ? "" : state.told, sending: state.sending };
    const notify = toSend(next);
    return { state: notify ? Object.assign({}, next, { sending: keyOf(errors) }) : next, notify };
}

// The errors couldn't be read: nothing is shown, since nothing is known,
// and what was delivered is kept, so tidewm answering again with the same
// errors isn't news.
export function unreadable(state) {
    return { errors: [], told: state.told, sending: state.sending };
}

// The notification for the set `key` finished, delivered (`ok`) or not.
export function sent(state, key, ok) {
    return {
        errors: state.errors,
        told: ok ? key : state.told,
        sending: state.sending === key ? "" : state.sending,
    };
}

// Whether the current errors' notification is still owed, as when
// notify-send failed (at login, before the notification server is up).
export function pending(state) {
    return toSend(state);
}

// Sends it again: the state and whether to notify now, as loaded.
export function retry(state) {
    return loaded(state, state.errors);
}

// "tidewm's config has 2 errors", the notification's summary, the bar
// icon's hover text and the list's heading; "" for none.
export function summary(errors) {
    if (errors.length === 0) {
        return "";
    }
    return `tidewm's config has ${errors.length} ${errors.length === 1 ? "error" : "errors"}`;
}

// The notification's second line: where to see them.
export function body(errors) {
    return `Click the warning in the bar to see ${errors.length === 1 ? "it" : "them"}, or run tide doctor.`;
}

// The notify-send command for `errors`. Critical, so it stays until it's
// dismissed. notify-send hands it to whichever server owns the
// notifications name: swaync, or the shell itself (§9).
export function notifyCommand(errors) {
    return ["notify-send", "--app-name=tide", "--urgency=critical", `--icon=${ICON}`, summary(errors), body(errors)];
}

// One error as tidewm words it, "/path/to/config:12: what's wrong", in
// two parts: { where, what }, `where` the file and line with `home` as ~,
// or "" for one with no file to name.
export function parts(error, home = "") {
    const m = /^(\/.*?):(\d+): (.*)$/.exec(error) ?? /^(\/.*?): (.*)$/.exec(error);
    if (m === null) {
        return { where: "", what: error };
    }
    let file = m[1];
    if (home !== "" && home !== "/" && (file === home || file.startsWith(`${home}/`))) {
        file = `~${file.slice(home.length)}`;
    }
    return { where: m.length === 4 ? `${file}:${m[2]}` : file, what: m[m.length - 1] };
}

// The bar's list: { rows, more }, the first SHOWN errors as parts, and
// the line that says how many it left out, or "".
export function listed(errors, home = "") {
    const left = errors.length - SHOWN;
    return {
        rows: errors.slice(0, SHOWN).map(e => parts(e, home)),
        more: left > 0 ? `and ${left} more: tide doctor lists them all` : "",
    };
}

// The list's last line: what to do about them.
export function advice(errors) {
    return `Fix ${errors.length === 1 ? "it" : "them"}, then reload tidewm's config.`;
}

function commandsOf(command) {
    const commands = [];
    let current = "";
    let quoted = false;
    for (const c of command) {
        if (c === '"') {
            quoted = !quoted;
        } else if (c === ";" && !quoted) {
            commands.push(current);
            current = "";
            continue;
        }
        current += c;
    }
    commands.push(current);
    return commands;
}

// Whether an event, of `type` and its JSON or already parsed, calls for
// the errors again: the listener's first tick, which says it has
// connected, to a tidewm that may be a new one; or a binding that runs
// `reload`, as conf's reload key. tidewm sends a binding's event before
// it runs the command, and reads no request until the command is done, so
// asking as the event is heard gets the reload's errors.
export function asksForErrors(type, data) {
    let event = data ?? null;
    if (typeof data === "string") {
        try {
            event = JSON.parse(data);
        } catch (e) {
            return false;
        }
    }
    if (type === "tick") {
        return event?.first === true;
    }
    if (type !== "binding" || event?.change !== "run" || typeof event.binding?.command !== "string") {
        return false;
    }
    return commandsOf(event.binding.command).some(c => /^\s*reload\s*$/.test(c));
}
