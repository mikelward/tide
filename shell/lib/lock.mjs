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
//   saver      the screensaver face shows instead of the password face;
//              any key or pointer motion brings the password face back,
//              and a typed key lands in the field
//
// Every key changes what the field shows (see fieldText), and changes it at
// once: no step here waits or animates, so each keystroke shows on the
// frame it's pressed, including while PAM checks the last attempt.

import { initial as runInitial, step as runStep } from "./launch.mjs";
import { ACTIONS, actionCommand, blockers } from "./session.mjs";

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
    saver: false,
});

// A failure's message when PAM gave none of its own.
export const WRONG = "Wrong password. Try again.";

function with_(state, changes) {
    return Object.freeze(Object.assign({}, state, changes));
}

function result(state, actions) {
    return { state, actions: actions || [] };
}

// The event a key press makes, or null for one the lock ignores. `key` is
// "enter", "backspace", "escape", "u" (the key, whatever it types) or ""
// for any other; `text` is what it types, passed through untouched;
// `ctrl` whether Control is held. Ctrl+U erases the field, as in a
// terminal; other Control chords type nothing, so they never land in the
// password.
export function keyEvent({ key, text, ctrl }) {
    if (key === "enter") return { type: "submit" };
    if (key === "backspace") return { type: "backspace" };
    if (key === "escape") return { type: "clear" };
    if (ctrl) return key === "u" ? { type: "clear" } : null;
    if (text !== "" && text >= " ") return { type: "key", text };
    return null;
}

// The state and actions after `event`:
//   {type: "key", text}       a printable key
//   {type: "backspace"}
//   {type: "clear"}           Escape or Ctrl+U
//   {type: "submit"}          Enter
//   {type: "pam", text, isError, responseRequired}
//                             PAM's message (PamContext's pamMessage)
//   {type: "done", result}    "success", "failed", "maxtries" or "error"
//                             (PamContext's completed)
//   {type: "failed", detail}  PAM couldn't run at all (start() false, or
//                             PamContext's error), so there's no result
//   {type: "screensaver"}     show the screensaver face (an idle lock)
//   {type: "wake"}            pointer motion: back to the password face
export function next(state, event) {
    // Any key wakes the screensaver, and then does what it does on the
    // password face, so the first key typed is never lost.
    const typing = event.type === "key" || event.type === "backspace"
        || event.type === "clear" || event.type === "submit";
    if (state.saver && typing) {
        state = with_(state, { saver: false });
    }
    switch (event.type) {
    case "screensaver":
        return result(state.saver ? state : with_(state, { saver: true }));
    case "wake":
        return result(state.saver ? with_(state, { saver: false }) : state);
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

// How long a `tide idle-lock` flag counts (seconds): longer than logind
// and systemd take to start the lock, short enough that a flag left by an
// idle lock that never happened can't turn a later Super+L into the
// screensaver.
export const IDLE_FLAG_SECONDS = 10;

// Whether the idle flag's text (the Unix time `tide idle-lock` wrote) is
// from this lock: written at most IDLE_FLAG_SECONDS before `nowMs`, and not
// in the future.
export function idleFlagFresh(text, nowMs) {
    const written = Number(String(text || "").trim());
    if (!Number.isFinite(written) || written <= 0) return false;
    const age = nowMs / 1000 - written;
    return age >= -1 && age <= IDLE_FLAG_SECONDS;
}

// Where the screensaver's block sits in `minute` (minutes since the epoch),
// as its top-left corner in an area of areaW x areaH, for a block of
// blockW x blockH (SPEC.md §10: a new spot each minute, to spare OLED
// panels). It stays a margin inside the edges. The spots follow the R2
// sequence (fractional parts of m·α), which spreads them evenly and moves
// the block at least 24% of the free width every minute, so no spot holds
// two minutes running. The same minute gives the same spot, so outputs of
// one size agree and a redraw doesn't jump.
const R2_X = 0.7548776662466927;
const R2_Y = 0.5698402909980532;

export function saverPosition(minute, areaW, areaH, blockW, blockH) {
    const marginX = Math.round(areaW * 0.06);
    const marginY = Math.round(areaH * 0.06);
    const freeX = Math.max(0, areaW - blockW - 2 * marginX);
    const freeY = Math.max(0, areaH - blockH - 2 * marginY);
    // Modulo a large period keeps m·α exact enough in a double.
    const m = Math.max(0, Math.floor(minute)) % 1000003;
    return {
        x: marginX + Math.round(frac(m * R2_X) * freeX),
        y: marginY + Math.round(frac(m * R2_Y) * freeY),
    };
}

function frac(v) {
    return v - Math.floor(v);
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

// The line under the lock's power buttons after Suspend, Restart or Shut
// down ran (`label`), from the run's {started, code, errors} (stderr):
// nothing when it worked, what blocks it when logind's inhibitors did (the
// lock never offers to go ahead anyway: anyone at a locked screen could),
// else why it failed. systemctl's stderr names programs and users, never
// anything typed.
export function powerMessage(label, run) {
    // A failed start sends no exit code; an exit code proves a start,
    // whichever order the signals came in (shell/lib/launch.mjs).
    if (run.code === null || run.code === undefined) return `${label} didn't start.`;
    if (run.code === 0) return "";
    const found = blockers(run.errors || "");
    if (found.length > 0) return `${label} is blocked by ${found.join("; ")}.`;
    const why = String(run.errors || "").trim().split("\n").pop();
    return why ? `${label} failed: ${why}` : `${label} failed (exit ${run.code}).`;
}

// The power buttons' one run at a time. A press starts a run only while
// idle: from the press until the run has its result (exit code and stderr,
// or a failed start) AND its process has stopped, whichever comes last, so
// no signal of one run can be taken for the next's, in any order the
// Process sends them (shell/lib/launch.mjs). The QML holds the state,
// feeds it presses and its Process's signals, and starts the command a
// press returns.
//   action   the action id of the latest run, "" before the first
//   run      that run's launch.mjs state
//   stopped  whether its process has stopped
//   message  powerMessage for it, once it's done
export const POWER_IDLE = Object.freeze({ action: "", run: runInitial(), stopped: true, message: "" });

export function powerBusy(state) {
    return state.action !== "" && !(state.run.done && state.stopped);
}

// The state after `event` and the command to start, if any:
//   {type: "press", id}   a power button
//   {type: "started"}, {type: "exited", code}, {type: "stderr", text},
//   {type: "stopped"}     the Process's signals
// Returns {state, command}; `command` is null unless a press started a run.
export function powerNext(state, event) {
    if (event.type === "press") {
        if (powerBusy(state)) {
            return { state, command: null };
        }
        const command = actionCommand(event.id, false);
        return {
            state: Object.freeze({ action: event.id, run: runInitial(), stopped: false, message: "" }),
            command,
        };
    }
    if (state.action === "") {
        return { state, command: null };
    }
    const command = actionCommand(state.action, false);
    const run = runStep(state.run, event, command);
    const stopped = state.stopped || event.type === "stopped";
    let message = state.message;
    if (run.done && !state.run.done) {
        const label = ACTIONS.find((a) => a.id === state.action)?.label ?? state.action;
        message = powerMessage(label, run);
    }
    return { state: Object.freeze({ action: state.action, run, stopped, message }), command: null };
}

// The keyboard layout badge by the password field (SPEC.md §10), so a
// failed password isn't a layout mystery. Hyprland names a layout by its
// xkb description, "English (Dvorak)" or "English (US)": the badge is the
// part in parentheses, else the whole name, in capitals ("DVORAK", "US",
// "GERMAN"). "" when there's no layout to show.
export function layoutBadge(name) {
    const text = String(name || "").trim();
    const inner = /\(([^()]+)\)\s*$/.exec(text);
    return (inner ? inner[1].trim() : text).toUpperCase();
}

// The main keyboard's layout from `hyprctl devices -j` (Hyprland 0.56):
// {keyboards: [{name, active_keymap, main}]}. The main one, else the first.
// Its description ("English (Dvorak)"), or null when there's no keyboard or
// the text isn't that JSON.
export function mainKeymap(text) {
    let devices;
    try {
        devices = JSON.parse(text);
    } catch (e) {
        return null;
    }
    const keyboards = Array.isArray(devices?.keyboards) ? devices.keyboards : [];
    const keyboard = keyboards.find((k) => k && k.main === true) || keyboards[0];
    if (!keyboard || typeof keyboard.active_keymap !== "string") return null;
    return keyboard.active_keymap;
}

// Which layout the badge shows. Only `hyprctl devices -j` says which
// keyboard is the main one, and in Hyprland 0.56 that changes: it's the
// keyboard last typed on (onKeyboardMod), or another one after an unplug,
// which sends no event. So nothing here remembers a keyboard. Each
// refresh reads hyprctl afresh; a refresh while a read runs, whose answer
// may already be old, reads again once it ends, so at most one runs and
// the last answer is never older than the last refresh.
//   keymap     the main keyboard's layout, "" while unknown
//   querying   a read is running
//   again      a refresh arrived while it ran
export const LAYOUT_INITIAL = Object.freeze({ keymap: "", querying: false, again: false });

// Events: {type: "refresh"} (the lock starts, Hyprland reports a layout
// switch, or a password fails) and {type: "answer", keymap} (mainKeymap's
// result, null when the read failed, which hides the badge rather than
// keep a layout that may be stale). Returns {state, query}: `query` asks
// the QML to start a read.
export function layoutNext(state, event) {
    switch (event.type) {
    case "refresh":
        if (state.querying) {
            return { state: Object.freeze(Object.assign({}, state, { again: true })), query: false };
        }
        return { state: Object.freeze(Object.assign({}, state, { querying: true })), query: true };
    case "answer": {
        const keymap = typeof event.keymap === "string" ? event.keymap : "";
        return {
            state: Object.freeze({ keymap: keymap, querying: state.again, again: false }),
            query: state.again,
        };
    }
    default:
        throw new Error(`unknown layout event: ${event.type}`);
    }
}
