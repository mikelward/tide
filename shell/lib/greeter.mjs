// The greeter (SPEC.md §11): what it offers and what it hands greetd. The
// password face is the lock's (lock.mjs); this is the rest. greeter.qml
// reads the session files, the users and the remembered choice, and carries
// out greetd's conversation; everything that decides something is here.

import { DEFAULT_IDLE } from "./idle.mjs";
import { INITIAL } from "./lock.mjs";

// The entry that runs the user's own shell on the greeter's VT, the way out
// when the desktop is broken. Its ID can't clash with a session file's: a
// desktop file ID is a file name, which never holds a "/".
export const SHELL_ID = "/shell";

export const SHELL_SESSION = Object.freeze({
    id: SHELL_ID,
    name: "Shell",
    // greetd runs the command through `/bin/sh -c "exec ..."`, with the
    // user's SHELL from passwd in the environment.
    command: '"${SHELL:-/bin/sh}" -l',
    env: Object.freeze(["XDG_SESSION_TYPE=tty"]),
});

// The session that leads the list, whatever its name sorts as.
export const FIRST = "tide";

// What greeter.qml runs, with `sh -c`, to read the session files: for each
// one, in $XDG_DATA_DIRS order, a header line "@<1 if its TryExec runs,
// else 0> <path>", then each line of the file with "|" in front, then an
// empty line, so a file with no final newline can't run into the next
// header. It exits 1 if any file couldn't be read, having said why.
export const LISTING_SCRIPT = [
    "status=0",
    "IFS=:",
    "for dir in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do",
    "    for file in \"$dir\"/wayland-sessions/*.desktop; do",
    "        test -f \"$file\" || continue",
    // An unreadable file fails the sed that copies it out, below.
    "        try=$(sed -n 's/^TryExec[[:space:]]*=[[:space:]]*//p' \"$file\" 2>/dev/null | head -n 1)",
    "        ok=1",
    "        if test -n \"$try\" && ! command -v \"$try\" >/dev/null 2>&1; then ok=0; fi",
    "        printf '@%s %s\\n' \"$ok\" \"$file\"",
    "        sed 's/^/|/' \"$file\" || status=1",
    "        echo",
    "    done",
    "done",
    "exit $status",
].join("\n");

// LISTING_SCRIPT's output as [{path, ok, text}].
export function parseListing(output) {
    const records = [];
    let current = null;
    for (const line of String(output || "").split("\n")) {
        if (line.startsWith("@")) {
            current = { path: line.slice(3), ok: line.charAt(1) === "1", lines: [] };
            records.push(current);
        } else if (line.startsWith("|") && current !== null) {
            current.lines.push(line.slice(1));
        }
    }
    return records.map((r) => ({ path: r.path, ok: r.ok, text: r.lines.join("\n") }));
}

// The keys of a desktop entry's [Desktop Entry] group, unlocalized, with
// the string escapes undone; null when it has no such group.
export function parseDesktopEntry(text) {
    let inGroup = false;
    let found = false;
    const keys = {};
    for (const raw of String(text || "").split("\n")) {
        const line = raw.trim();
        if (line === "" || line.startsWith("#")) continue;
        if (line.startsWith("[")) {
            inGroup = line === "[Desktop Entry]";
            found = found || inGroup;
            continue;
        }
        if (!inGroup) continue;
        const eq = line.indexOf("=");
        if (eq < 0) continue;
        const key = line.slice(0, eq).trim();
        // Name[de] and the like: the greeter speaks one language.
        if (key.indexOf("[") >= 0) continue;
        // The first of a repeated key counts.
        if (!(key in keys)) {
            keys[key] = unescape(line.slice(eq + 1).trim());
        }
    }
    return found ? keys : null;
}

function unescape(value) {
    return value.replace(/\\([sntr\\])/g, (match, c) =>
        c === "s" ? " " : c === "n" ? "\n" : c === "t" ? "\t" : c === "r" ? "\r" : "\\");
}

// An Exec line as greetd runs it: the field codes, which mean nothing for a
// session, dropped, and "%%" made "%". greetd hands the command to
// `/bin/sh -c`, so its quoting is the shell's, which is what an Exec line's
// quoting is too.
export function execCommand(exec) {
    return String(exec || "")
        .replace(/%(.)/g, (match, c) => (c === "%" ? "%" : ""))
        .trim();
}

function isTrue(value) {
    return value === "true";
}

// A session file as the greeter offers it: {id, name, command, env}, or
// null when it isn't one to offer (Hidden, NoDisplay, or no Name or Exec).
// `id` is its desktop file ID. The environment goes to pam_systemd, which
// records the session's type and desktop, and on to the session.
export function sessionFromEntry(id, entry) {
    if (entry === null || isTrue(entry.Hidden) || isTrue(entry.NoDisplay)) return null;
    if (entry.Type !== undefined && entry.Type !== "Application") return null;
    const name = entry.Name || "";
    const command = execCommand(entry.Exec);
    if (name === "" || command === "") return null;
    const env = ["XDG_SESSION_TYPE=wayland", `XDG_SESSION_DESKTOP=${id}`];
    const names = String(entry.DesktopNames || "").split(";").filter((n) => n !== "");
    if (names.length > 0) {
        env.push(`XDG_CURRENT_DESKTOP=${names.join(":")}`);
    }
    return Object.freeze({ id, name, command, env: Object.freeze(env) });
}

// The desktop file ID of a session file's path.
export function fileId(path) {
    const base = String(path).split("/").pop();
    return base.endsWith(".desktop") ? base.slice(0, -".desktop".length) : base;
}

// The sessions to offer, from parseListing's records: the first file with
// an ID is the one that counts, as $XDG_DATA_DIRS orders them, so a hidden
// or broken one hides the same ID further down. tide leads, the rest
// follow by name, and the shell comes last.
export function sessionList(records) {
    const seen = {};
    const sessions = [];
    for (const record of records) {
        if (!record.path.endsWith(".desktop")) continue;
        const id = fileId(record.path);
        if (seen[id]) continue;
        seen[id] = true;
        if (!record.ok) continue;
        const session = sessionFromEntry(id, parseDesktopEntry(record.text));
        if (session !== null) sessions.push(session);
    }
    sessions.sort((a, b) => {
        if ((a.id === FIRST) !== (b.id === FIRST)) return a.id === FIRST ? -1 : 1;
        const x = a.name.toLowerCase();
        const y = b.name.toLowerCase();
        return x < y ? -1 : x > y ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
    });
    sessions.push(SHELL_SESSION);
    return sessions;
}

// The range of UIDs that are people, from /etc/login.defs, with its own
// defaults where it says nothing.
export function uidRange(loginDefs) {
    const range = { min: 1000, max: 60000 };
    for (const raw of String(loginDefs || "").split("\n")) {
        const m = /^\s*(UID_MIN|UID_MAX)\s+(\d+)\s*$/.exec(raw);
        if (m) {
            range[m[1] === "UID_MIN" ? "min" : "max"] = Number(m[2]);
        }
    }
    return range;
}

// The people who can log in, from /etc/passwd: [{name, label}], by UID. A
// UID outside `range`, or a shell that refuses logins, leaves an account
// out. The label is the GECOS name, else the user name.
export function parseUsers(passwd, range) {
    const users = [];
    for (const raw of String(passwd || "").split("\n")) {
        const fields = raw.split(":");
        if (fields.length < 7 || fields[0] === "" || raw.startsWith("#")) continue;
        const uid = Number(fields[2]);
        if (!/^\d+$/.test(fields[2]) || uid < range.min || uid > range.max) continue;
        const shell = fields[6].trim();
        if (/\/(nologin|false)$/.test(shell)) continue;
        const gecos = fields[4].split(",")[0].trim();
        users.push({ name: fields[0], uid, label: gecos || fields[0] });
    }
    users.sort((a, b) => a.uid - b.uid);
    return users.map((u) => Object.freeze({ name: u.name, label: u.label }));
}

// What the greeter remembers between logins: who logged in last, and with
// which session. Anything unreadable is nothing remembered.
export function parseRemembered(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { user: "", session: "" };
    }
    return {
        user: typeof value?.user === "string" ? value.user : "",
        session: typeof value?.session === "string" ? value.session : "",
    };
}

export function serializeRemembered(user, session) {
    return JSON.stringify({ user: user, session: session }) + "\n";
}

// The user preselected: the one remembered, while they can still log in,
// else the first.
export function pickUser(users, remembered) {
    if (users.some((u) => u.name === remembered)) return remembered;
    return users.length > 0 ? users[0].name : "";
}

// The session preselected: the one remembered, while it's still offered,
// else the first, which is tide where it's installed.
export function pickSession(sessions, remembered) {
    if (sessions.some((s) => s.id === remembered)) return remembered;
    return sessions.length > 0 ? sessions[0].id : "";
}

// The password face's event for greetd's authFailure. greetd says what PAM
// returned ("pam_authenticate: AUTH_ERR"), not why, so a wrong password and
// too many tries get the lock's own words, and anything else is named.
export function authFailureEvent(description) {
    const text = String(description || "").trim();
    if (/: MAXTRIES$/.test(text)) return { type: "done", result: "maxtries" };
    if (text === "" || /: AUTH_ERR$/.test(text)) return { type: "done", result: "failed" };
    return { type: "failed", detail: text };
}

// The face after greetd reported an error with no attempt to blame, such
// as starting the session failing once the password was taken: the
// password has to be given again, and the error says why.
export function greetdError(state, description, session) {
    const detail = String(description || "").trim() || "greetd failed";
    const what = state.unlocked ? `Couldn't start ${session || "the session"}` : "Couldn't log in";
    return Object.freeze(Object.assign({}, INITIAL, {
        input: state.unlocked ? "" : state.input,
        message: `${what}: ${detail}.`,
        error: true,
        attempts: state.attempts,
    }));
}

// Whether the greeter takes `event` in `state`. An Enter while greetd checks
// the last attempt isn't held for when it fails, as the lock holds it
// (SPEC.md §11, maintainer's call). The keys typed meanwhile still land in
// the field; the next Enter sends them. Once the session is starting, the
// screensaver doesn't cover the line that says so.
export function takes(state, event) {
    if (event.type === "screensaver") return !state.unlocked;
    return !(event.type === "submit" && state.checking);
}

// The greeter's idle (SPEC.md §11): the screensaver face, then the displays
// off, after the lock's default times (§10), in seconds. It has no one's
// Idle settings to read, and no dim.
export const SAVER_AFTER = DEFAULT_IDLE.lock;
export const DISPLAYS_OFF_AFTER = DEFAULT_IDLE.displaysOff;

// What turns every display off or back on: hyprctl's dispatch, which the
// greeter's Hyprland, configured in Lua, takes as a Lua call (Hyprland
// 0.56). The same hyprctl ends that Hyprland (greeter/hyprland.lua).
export function displaysCommand(on) {
    return ["hyprctl", "dispatch", `hl.dsp.dpms({ action = "${on ? "on" : "off"}" })`];
}

// The displays' power, set one hyprctl call at a time:
//   want     on (true) or off, as the idle says
//   sent     what the last call that worked set: on at the start, as
//            Hyprland starts them, and null after a call that failed
//   sending  what the call under way sets, or null with none under way
// Events: {type: "idle", idle} when the displays-off idle starts or ends,
// and {type: "done", ok} when the call ends, ok if hyprctl exited 0. The
// result's `send` is true or false to make a call now that turns them on or
// off, or null for none. A call that fails isn't made again until the idle
// changes, so a hyprctl that keeps failing isn't run in a loop.
export const DISPLAYS_INITIAL = Object.freeze({ want: true, sent: true, sending: null });

export function displaysNext(state, event) {
    let s = state;
    if (event.type === "idle") {
        s = Object.assign({}, s, { want: !event.idle });
    } else if (event.type === "done") {
        s = Object.assign({}, s, { sent: event.ok ? s.sending : null, sending: null });
        if (!event.ok) {
            return { state: Object.freeze(s), send: null };
        }
    }
    if (s.sending !== null || s.want === s.sent) {
        return { state: Object.freeze(s), send: null };
    }
    return { state: Object.freeze(Object.assign({}, s, { sending: s.want })), send: s.want };
}

// Whether another user can be picked: any time until the password is
// taken and the session is starting. Picking mid-login cancels greetd's
// login for the last user, and the greeter drops whatever that login still
// gets back (greetd.mjs), so its answers can't land on the new user's.
export function canPickUser(state) {
    return !state.unlocked;
}

// Whether greetd is in the middle of a login: between Enter and its
// answer, or waiting for the field to answer another prompt. Its replies
// count only then, so one still on its way after a change of user can't
// land on the new user's face.
export function inConversation(state) {
    return state.checking || state.awaiting;
}

// The line under the field: the lock's, until the password is taken, and
// then which session is starting.
export function statusText(state, sessionName, lockStatus) {
    if (state.unlocked) return `Starting ${sessionName || "the session"}`;
    return lockStatus;
}
