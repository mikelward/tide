// tidewm's config errors (its docs/config.md), for ConfigErrorsData.qml:
// tidewm leaves a bad line out and names it in GET_CONFIG's `errors`, so
// the session comes up with a key or a setting missing and nothing on
// screen to say why. The shell asks as it connects and after each reload
// it knows of, shows a warning in the bar while there are errors, and
// sends one notification per distinct set (SPEC.md §7.4). Pure functions
// over plain data, so they're tested here.
//
// The state is { errors, told, sending, outdated }: the last load's
// errors, as tidewm worded them; the news (newsOf) a notification last
// reached the user for, or ""; the news whose notification is on its way,
// or ""; and whether the tidewm running isn't the one installed.
//
// A setup run that builds a newer tidewm leaves the old one running until
// the session ends, beside a config written for the new one. Nothing of
// tide's reloads the config into it (`tide-msg --if-current`), and the
// warning says to log out and back in rather than to fix errors that may
// only be the old tidewm's.

export const NOTHING = Object.freeze({ errors: Object.freeze([]), told: "", sending: "", outdated: false, checked: false });

// The news of a tidewm that was updated, as keyOf's of a set of errors.
export const OUTDATED = "outdated";

// `tide-msg --outdated`'s exit status as whether the tidewm running isn't
// the one installed: 0 it isn't, 1 it is, and anything else, as an older
// tide-msg's usage error, doesn't say (undefined).
export function outdatedOf(code) {
    return code === 0 ? true : code === 1 ? false : undefined;
}

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

// What there is to say of the state, as one string: that tidewm was
// updated, whatever its errors, which logging in again may end; else its
// errors (keyOf); or "" for nothing.
export function newsOf(state) {
    return state.outdated ? OUTDATED : keyOf(state.errors);
}

// Whether the bar's warning shows.
export function warns(state) {
    return newsOf(state) !== "";
}

// An update already told of, as a shell that reloads remembers, waits for
// this shell's first answer on the version (versioned, unversioned): until
// then its errors aren't known to be news, and saying them would have the
// update said again after them.
function toSend(state) {
    const key = newsOf(state);
    if (state.told === OUTDATED && !state.checked) {
        return false;
    }
    return key !== "" && key !== state.told && key !== state.sending;
}

function taken(next) {
    const notify = toSend(next);
    return { state: notify ? Object.assign(next, { sending: newsOf(next) }) : next, notify };
}

// A load's errors are in. Returns the state and whether to notify now:
// for a set that's neither been delivered nor is on its way, so a
// reconnect or a reload reporting the same errors says nothing more. A
// load with none forgets the last set, so the same mistake made again
// later is reported again.
export function loaded(state, errors) {
    const forget = errors.length === 0 && state.told !== OUTDATED;
    return taken(Object.assign({}, state, { errors }, forget ? { told: "" } : {}));
}

// Whether the tidewm running isn't the one installed is in (outdatedOf).
// Returns the state and whether to notify now, as loaded: once for an
// update, however its errors change meanwhile, and whichever of the two
// answers first. One that's over is forgotten, as a set of errors is.
export function versioned(state, outdated) {
    const forget = !outdated && state.told === OUTDATED;
    return taken(Object.assign({}, state, { outdated, checked: true }, forget ? { told: "" } : {}));
}

// Whether it was updated couldn't be told (outdatedOf's undefined): what
// was known is kept, and errors that waited on the answer are said.
export function unversioned(state) {
    return taken(Object.assign({}, state, { checked: true }));
}

// The errors couldn't be read: nothing is shown, since nothing is known,
// and what was delivered is kept, so tidewm answering again with the same
// errors isn't news.
export function unreadable(state) {
    return Object.assign({}, state, { errors: [] });
}

// The notification for the set `key` finished, delivered (`ok`) or not.
export function sent(state, key, ok) {
    return Object.assign({}, state, {
        told: ok ? key : state.told,
        sending: state.sending === key ? "" : state.sending,
    });
}

// Whether the current errors' notification is still owed, as when
// notify-send failed (at login, before the notification server is up).
export function pending(state) {
    return toSend(state);
}

// Sends it again: the state and whether to notify now, as loaded.
export function retry(state) {
    return taken(Object.assign({}, state));
}

// The compositor whose config it is, as the words below name it.
export function compositorName(tidewm) {
    return tidewm ? "tidewm" : "Hyprland";
}

// "tidewm's config has 2 errors", the notification's summary, the bar
// icon's hover text and the list's heading; "" for none. `name` is the
// compositor's (compositorName). A tidewm that was updated says that
// instead, whatever its errors.
export function summary(errors, name = "tidewm", outdated = false) {
    if (outdated) {
        return "tidewm was updated";
    }
    if (errors.length === 0) {
        return "";
    }
    return `${name}'s config has ${errors.length} ${errors.length === 1 ? "error" : "errors"}`;
}

// The notification's second line: where to see them, or what to do about
// an update.
export function body(errors, outdated = false) {
    if (outdated) {
        return "Log out and back in to use it.";
    }
    return `Click the warning in the bar to see ${errors.length === 1 ? "it" : "them"}, or run tide doctor.`;
}

// The notify-send command for `errors`. Critical, so it stays until it's
// dismissed. notify-send hands it to whichever server owns the
// notifications name: swaync, or the shell itself (§9).
export function notifyCommand(errors, name = "tidewm", outdated = false) {
    return ["notify-send", "--app-name=tide", "--urgency=critical", `--icon=${ICON}`, summary(errors, name, outdated), body(errors, outdated)];
}

// `hyprctl configerrors`' output, one error a line and nothing when there
// are none: { errors }, as replyErrors gives tidewm's, or { why } when
// hyprctl said nothing at all, as when it couldn't reach Hyprland.
export function hyprlandErrors(text, ok = true) {
    if (!ok || typeof text !== "string") {
        return { why: "hyprctl configerrors failed" };
    }
    return { errors: text.split("\n").map(e => e.trim()).filter(e => e !== "") };
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

// The list's last line: what to do about them. After an update the
// errors may be the old tidewm's, at lines only the new one reads, so
// there's nothing to fix until it runs.
export function advice(errors, name = "tidewm", outdated = false) {
    if (outdated) {
        return `Log out and back in to use it.${errors.length === 0 ? "" : " That may fix these errors too."}`;
    }
    return `Fix ${errors.length === 1 ? "it" : "them"}, then reload ${name}'s config.`;
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
    // A reload from anywhere, as `tide-msg reload` in a terminal, as i3
    // and sway say it.
    if (type === "workspace") {
        return event?.change === "reload";
    }
    if (type !== "binding" || event?.change !== "run" || typeof event.binding?.command !== "string") {
        return false;
    }
    return commandsOf(event.binding.command).some(c => /^\s*reload\s*$/.test(c));
}
