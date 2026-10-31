// Start at login (SPEC.md §16): the commands the shell runs once a
// session, from startup.json and startup.local.json (`commands`), as pure
// functions the QML binds to.

import { jsonError } from "./clocks.mjs";

export const FILES = Object.freeze(["startup.json", "startup.local.json"]);

// Where the shell records the graphical session it last ran the list in,
// under $XDG_RUNTIME_DIR, so a shell restarted later runs nothing.
export const RECORD = "tide-startup-ran";

// What tells one graphical session from the next: graphical-session.target's
// invocation ID, new each time the target starts, which uwsm starts at
// each login and stops at logout. The runtime directory alone outlives a
// logout while an SSH login or lingering keeps the user's manager running.
export const SESSION_COMMAND = Object.freeze(["systemctl", "--user", "show", "-p", "InvocationID", "--value", "graphical-session.target"]);

// The session's ID from SESSION_COMMAND's output, or "" when it gave none.
export function sessionId(output) {
    const id = (output || "").trim();
    return /^[0-9a-f]{32}$/.test(id) ? id : "";
}

// Whether to run the list, given the record's text (null for none) and
// this session's ID ("" when it can't be read): {run, record, warn}.
// `record` is what to write before running, and `warn` what to log, or "".
// A session that can't be read runs the list only with no record at all,
// so a shell restart still runs nothing, and says why.
export function startupDue(recorded, session) {
    const last = recorded === null ? null : recorded.trim();
    if (session === "") {
        if (last !== null) {
            return { run: false, record: null, warn: "couldn't read the graphical session's ID, so not running Start at login's commands again" };
        }
        return { run: true, record: "unknown\n", warn: "couldn't read the graphical session's ID; running Start at login's commands anyway" };
    }
    if (last === session) {
        return { run: false, record: null, warn: "" };
    }
    return { run: true, record: `${session}\n`, warn: "" };
}

// What a command can't hold. It runs as words, with no shell, so quotes,
// backslashes and `$` would mean nothing; control characters can't be
// typed into a command line at all.
const UNSAFE = /["'`\\$]/;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]/;

// A command's words: split at spaces and tabs, as it runs.
export function commandWords(command) {
    return command.split(/[ \t]+/).filter(w => w !== "");
}

// The command as it's kept and compared: its words, one space apart.
export function normalCommand(command) {
    return commandWords(command).join(" ");
}

// Why `command` can't be one, or "".
export function commandError(command) {
    if (typeof command !== "string") {
        return "a command is text";
    }
    if (CONTROL.test(command)) {
        return "a command is one line, with no control characters";
    }
    if (commandWords(command).length === 0) {
        return "a command needs a program to run";
    }
    if (commandWords(command)[0].endsWith("/")) {
        return `${commandWords(command)[0]} is a directory, not a program`;
    }
    if (UNSAFE.test(command)) {
        return `${normalCommand(command)} has a quote, backslash or $, which runs as typed, with no shell; put shell syntax in a script`;
    }
    return "";
}

// One file's settings: {settings: {commands?}, errors} or {error} when it
// doesn't parse, or isn't the shape a startup file is. A bad entry is one
// of `errors`, naming it, and left out, as a bad `muted` entry is; the rest
// still run. So is a command listed twice, after its first.
export function parseStartupFile(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: "expected an object, such as {\"commands\": [\"google-calendar\"]}" };
    }
    const errors = [];
    for (const key of Object.keys(value)) {
        if (key !== "commands") {
            errors.push(`unknown setting "${key}"`);
        }
    }
    if (!Object.prototype.hasOwnProperty.call(value, "commands")) {
        return { settings: {}, errors };
    }
    if (!Array.isArray(value.commands)) {
        return { error: "commands must be a list of commands" };
    }
    const commands = [];
    value.commands.forEach((entry, i) => {
        const bad = commandError(entry);
        if (bad !== "") {
            errors.push(`commands entry ${i + 1}: ${bad}`);
            return;
        }
        const command = normalCommand(entry);
        if (commands.includes(command)) {
            errors.push(`commands entry ${i + 1}: ${command} is listed already`);
            return;
        }
        commands.push(command);
    });
    return { settings: { commands }, errors };
}

// The list the shell runs: startup.local.json's when it has one, since it
// replaces the shared one whole (§16.1), else startup.json's, else none.
// Each text is the file's, or null when it doesn't exist. Returns
// {commands, errors}, each error naming its file. A file that doesn't parse
// is an error and runs nothing, since which list it meant can't be told:
// {commands: null}.
export function loadStartup(sharedText, localText) {
    let commands = [];
    const errors = [];
    let broken = false;
    [[FILES[0], sharedText], [FILES[1], localText]].forEach(([name, text]) => {
        if (text === null || text === undefined) {
            return;
        }
        const parsed = parseStartupFile(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            broken = true;
            return;
        }
        for (const error of parsed.errors) {
            errors.push(`${name}: ${error}`);
        }
        if (parsed.settings.commands) {
            commands = parsed.settings.commands;
        }
    });
    return { commands: broken ? null : commands, errors };
}

// The list the page shows and changes, as loadStartup takes it, with the
// file it's from (null for none): {commands, source}, or {error} naming a
// file that doesn't parse, which the page refuses changes for.
export function editableStartup(sharedText, localText) {
    let found = { commands: [], source: null };
    for (const [name, text] of [[FILES[0], sharedText], [FILES[1], localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseStartupFile(text);
        if (parsed.error) {
            return { error: `${name}: ${parsed.error}` };
        }
        if (parsed.settings.commands) {
            found = { commands: parsed.settings.commands, source: name };
        }
    }
    return found;
}

// startup.local.json's text after `change`, a function from the list to
// {commands} or {error}, as {text, commands}. The panel writes only the
// .local file (§16.1), so the first change copies the shared list into it.
// A file that doesn't parse is an {error}, so a hand edit gone wrong is
// never written over.
export function editedStartup(sharedText, localText, change) {
    const base = editableStartup(sharedText, localText);
    if (base.error) {
        return { error: base.error };
    }
    const result = change(base.commands);
    if (result.error) {
        return { error: result.error };
    }
    const local = localText === null || localText === undefined ? {} : JSON.parse(localText);
    const value = Object.assign({}, local, { commands: result.commands });
    return { text: JSON.stringify(value, null, 2) + "\n", commands: result.commands };
}

// The entry a change is for: `index` (from 0), if it's still `command`, so
// a change can't land on another after a hand edit has moved them; with no
// index, the one that is. -1 when none is.
function commandIndex(commands, index, command) {
    const wanted = normalCommand(command);
    if (index === undefined || index === null) {
        return commands.indexOf(wanted);
    }
    return index >= 0 && index < commands.length && commands[index] === wanted ? index : -1;
}

function missing(index, command) {
    return index === undefined || index === null
        ? { error: `${command} isn't listed` }
        : { error: `entry ${index + 1} isn't ${command}` };
}

// The list with `command` added at the end, or an {error} saying why not.
export function withCommand(commands, command) {
    const bad = commandError(command);
    if (bad !== "") {
        return { error: bad };
    }
    const added = normalCommand(command);
    if (commands.includes(added)) {
        return { error: `${added} is listed already` };
    }
    return { commands: commands.concat([added]) };
}

// The list with `command` moved `step` places (negative is earlier),
// stopping at either end.
export function movedCommand(commands, index, command, step) {
    const from = commandIndex(commands, index, command);
    if (from < 0) {
        return missing(index, command);
    }
    const to = Math.max(0, Math.min(commands.length - 1, from + step));
    const next = commands.slice();
    next.splice(to, 0, next.splice(from, 1)[0]);
    return { commands: next };
}

// The list without `command`.
export function withoutCommand(commands, index, command) {
    const at = commandIndex(commands, index, command);
    if (at < 0) {
        return missing(index, command);
    }
    return { commands: commands.filter((c, i) => i !== at) };
}

// What `tide launch --background` prints on stdout just before it starts
// the command. The shell starts the next one then, or once the run ends,
// so they start in the list's order without waiting on each to exit.
export const STARTED = "tide launch: starting";

// The list's commands, started one after another (SPEC.md §16): the next
// starts once the one before it has started (it printed STARTED) or ended
// (skipped, failed or exited), and each advances the queue once. The state
// is {commands, current}: the index of the one starting now. Each returns
// {state, start}, `start` being {index, command} to start now, or null.
function advance(q) {
    const next = q.current + 1;
    if (next >= q.commands.length) {
        return { state: { commands: q.commands, current: q.commands.length }, start: null };
    }
    return { state: { commands: q.commands, current: next }, start: { index: next, command: q.commands[next] } };
}

export function startQueue(commands) {
    return advance({ commands: commands.slice(), current: -1 });
}

// Command `index` printed `line` on stdout.
export function queuePrinted(q, index, line) {
    return line === STARTED && index === q.current ? advance(q) : { state: q, start: null };
}

// Command `index`'s run ended, however it went.
export function queueEnded(q, index) {
    return index === q.current ? advance(q) : { state: q, start: null };
}

// How the shell runs a command: through `tide launch`, in the background,
// and not if it's running already (§16).
export function launchCommand(command) {
    return ["tide", "launch", "--background", "--unless-running", "--"].concat(commandWords(command));
}

// What to report for a run that's done: why it failed, naming the command,
// or "" for one that worked. `errors` is what it printed on stderr, of
// which the last line is the one most likely to say why.
export function runFailure(command, ok, errors) {
    if (ok) {
        return "";
    }
    const lines = (errors || "").trim().split("\n").filter(l => l.trim() !== "");
    const why = lines.length > 0 ? lines[lines.length - 1].trim() : "it exited with a failure";
    return `${command}: ${why}`;
}
