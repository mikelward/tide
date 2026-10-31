// Named workspaces (SPEC.md §6.5): what a name may be, how one typed
// matches the ones there are, and the Workspaces settings
// (workspaces.json and workspaces.local.json, §16), as pure functions the
// QML binds to.

import { jsonError } from "./clocks.mjs";
import { isAlnum, match } from "./fuzzy.mjs";

// The longest a name may be, in characters.
export const MAX_NAME = 32;

// The standing workspaces when no file names any: the first is the home
// workspace (§6.5).
export const DEFAULT_STANDING = Object.freeze(["in", "re", "oc", "me"]);

// What each setting is when no file sets it.
export const DEFAULT_SETTINGS = Object.freeze({
    standing: DEFAULT_STANDING,
    inApps: Object.freeze([]),
    namePatterns: Object.freeze([]),
    muted: Object.freeze([]),
});

// What a workspace's name can't hold: quotes, backslashes and control
// characters. A name goes into Hyprland's `name:` selectors, Lua strings,
// JSON over IPC, a FIFO and the shell's command lines; with none of these
// in it, no quoting can go wrong anywhere it goes.
export const UNSAFE = /["'`\\\u0000-\u001f\u007f]/;

// A name as typed, made one: trimmed, and refused if it's empty, runs over
// more than one line, holds an UNSAFE character or is longer than
// MAX_NAME. {name} or {error}.
export function checkName(text) {
    const name = String(text ?? "").trim();
    if (name === "") {
        return { error: "a workspace needs a name" };
    }
    if (/[\n\r]/.test(name)) {
        return { error: "a workspace's name is one line" };
    }
    if (UNSAFE.test(name)) {
        return { error: "a workspace's name can't have quotes, backslashes or control characters" };
    }
    if ([...name].length > MAX_NAME) {
        return { error: `a workspace's name is at most ${MAX_NAME} characters` };
    }
    return { name };
}

// An app ID as every comparison of one sees it: trimmed, lowercase, and
// without a `.desktop` suffix, so a desktop ID, a window class and an app
// name meet on equal terms (`org.telegram.desktop` is `org.telegram`). The
// one normalization for writing, checking and matching app IDs: home's
// apps (inAppPatterns, isHomeApp), muted entries (checkMuteEntry, and
// mute.mjs through isHomeApp) and the focus guard's matching (workspaces.mjs's
// sameApp), so no two of them can disagree about an ID.
export function normalizeAppId(id) {
    return String(id ?? "").trim().toLowerCase().replace(/\.desktop$/, "");
}

// Whether two names are the same workspace's: case doesn't count.
export function sameName(a, b) {
    return String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();
}

// The name in `names` that `typed` matches, ignoring case, or null: a name
// typed at the prompt uses the workspace already there, in the case it was
// made with.
export function matchName(names, typed) {
    return names.find((n) => sameName(n, typed)) ?? null;
}

// The home workspace's name: the first standing one.
export function homeName(settings) {
    return (settings.standing ?? DEFAULT_STANDING)[0];
}

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function listError(key, value) {
    if (!Array.isArray(value)) {
        return `${key} must be a list`;
    }
    const bad = value.findIndex((v) => typeof v !== "string" || v.trim() === "");
    return bad >= 0 ? `${key} must list text, not ${JSON.stringify(value[bad])} at ${bad + 1}` : null;
}

// Why one file's settings can't be taken, or null.
function settingsError(value) {
    if (!isObject(value)) {
        return "expected an object of settings";
    }
    for (const key of Object.keys(value)) {
        if (!Object.prototype.hasOwnProperty.call(DEFAULT_SETTINGS, key)) {
            return `${key} isn't a setting (standing, inApps, namePatterns or muted)`;
        }
        // A bad muted entry is dropped alone (checkMuted), not the file.
        if (key === "muted") {
            if (!Array.isArray(value[key])) {
                return "muted must be a list";
            }
            continue;
        }
        const err = listError(key, value[key]);
        if (err) {
            return err;
        }
    }
    if (value.namePatterns !== undefined) {
        const checked = checkPatterns(value.namePatterns);
        if (checked.error) {
            return checked.error;
        }
    }
    if (value.standing !== undefined) {
        if (value.standing.length === 0) {
            return "standing must name at least one workspace, the first being home";
        }
        const seen = [];
        for (const raw of value.standing) {
            const checked = checkName(raw);
            if (checked.error) {
                return `standing: ${JSON.stringify(raw)}: ${checked.error}`;
            }
            if (checked.name !== raw) {
                return `standing: ${JSON.stringify(raw)} has space around it`;
            }
            if (matchName(seen, raw) !== null) {
                return `standing names ${JSON.stringify(raw)} twice`;
            }
            seen.push(raw);
        }
    }
    return null;
}

// One file's settings: {settings} or {error}.
export function parseWorkspaceSettings(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    const err = settingsError(value);
    return err ? { error: err } : { settings: value };
}

// A site entry in `muted`: `site:` and a host.
const MUTED_SITE = /^site:([a-z0-9-]+(\.[a-z0-9-]+)*)$/i;

// One `muted` entry as written (SPEC.md §9, Muted apps): {entry}, trimmed,
// or {error} saying what's wrong with it. An entry is an app ID, any text
// without control characters (a notification's app name, the fallback when
// it gives no desktop entry, may have spaces: `Example App`), or
// `site:HOST`. The one check for both sides: loading the list, and the
// mute actions before they write an entry (mute.mjs's toggledMuted), so
// nothing they write is refused when it's read back.
export function checkMuteEntry(raw) {
    if (typeof raw !== "string" || raw.trim() === "") {
        return { error: "isn't an app or a site" };
    }
    const entry = raw.trim();
    if (/^site:/i.test(entry)) {
        return MUTED_SITE.test(entry) ? { entry } : { error: "names no host" };
    }
    if (/[\u0000-\u001f\u007f]/.test(entry)) {
        return { error: "isn't an app ID" };
    }
    // Valid only if something's left once normalized, as it's compared
    // (`.desktop` alone would match nothing).
    return normalizeAppId(entry) === "" ? { error: "isn't an app ID" } : { entry };
}

// The `muted` list with its bad entries dropped: {entries, errors}, each
// error naming the setting and the entry (checkMuteEntry).
export function checkMuted(list) {
    const entries = [];
    const errors = [];
    (Array.isArray(list) ? list : []).forEach((raw, i) => {
        const checked = checkMuteEntry(raw);
        if (checked.error) {
            errors.push(`muted: ${JSON.stringify(raw)} at ${i + 1} ${checked.error}`);
        } else {
            entries.push(checked.entry);
        }
    });
    return { entries, errors };
}

// The settings in effect from workspaces.json and workspaces.local.json,
// each the file's text or null when it doesn't exist. Every setting is a
// list, so the local file's replaces the shared one's whole (§16.1). A
// file that's wrong keeps `lastGood`, and `errors` names each file that is.
// A bad entry in `muted` only drops that entry, and `warnings` names it:
// {settings, errors, warnings}.
export function loadWorkspaceSettings(sharedText, localText, lastGood = DEFAULT_SETTINGS) {
    const errors = [];
    const warnings = [];
    const settings = Object.assign({}, DEFAULT_SETTINGS);
    for (const [name, text] of [["workspaces.json", sharedText], ["workspaces.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseWorkspaceSettings(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        const found = Object.assign({}, parsed.settings);
        if (found.muted !== undefined) {
            const checked = checkMuted(found.muted);
            found.muted = checked.entries;
            warnings.push(...checked.errors.map((e) => `${name}: ${e}`));
        }
        Object.assign(settings, found);
    }
    return errors.length > 0 ? { settings: lastGood, errors, warnings } : { settings, errors, warnings };
}

// workspaces.local.json's text with `muted` set to `list`, keeping the
// rest of it: {text}, or {error} when the file isn't a settings object, so
// a hand edit gone wrong isn't overwritten. `localText` is null when the
// file doesn't exist.
export function withMuted(localText, list) {
    let value = {};
    if (localText !== null && localText !== undefined && localText.trim() !== "") {
        try {
            value = JSON.parse(localText);
        } catch (e) {
            return { error: `workspaces.local.json: ${jsonError(localText)}` };
        }
        if (!isObject(value)) {
            return { error: "workspaces.local.json: expected an object of settings" };
        }
    }
    return { text: JSON.stringify(Object.assign({}, value, { muted: list }), null, 2) + "\n" };
}

// `s` as a regular expression that matches only it.
function quoted(s) {
    return s.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}

// The window classes an "in" app's entry matches, as RE2 patterns for a
// Hyprland window rule (which matches the whole class, ignoring nothing).
// Each is matched as a class the way the focus guard matches one
// (focus.lua's same_id): without case, and a bare name as the last part of
// a qualified one, so `thunderbird` takes `org.mozilla.Thunderbird`. One
// that looks like a host is a site too, which takes that site's Chrome and
// Chromium `--app` windows and its subdomains', as a notification's site
// does (notifications.mjs's siteWindowClasses):
// `chrome-mail.google.com__-Default`.
export function inAppPatterns(inApps) {
    const out = [];
    for (const raw of inApps) {
        const app = normalizeAppId(raw);
        if (app === "") {
            continue;
        }
        // A class may itself end in .desktop (org.telegram.desktop); a
        // Hyprland rule can't normalize the class, so the pattern allows
        // the suffix, matching as normalizeAppId does.
        out.push(app.includes(".") ? `(?i)${quoted(app)}(\\.desktop)?` : `(?i)(.*\\.)?${quoted(app)}(\\.desktop)?`);
        if (/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(app)) {
            out.push(`(?i)(chrome|chromium)-([^_]*\\.)?${quoted(app)}_.*-[^-]+`);
        }
    }
    return out;
}

// A Lua string literal holding `s`.
export function luaString(s) {
    let out = '"';
    for (const ch of String(s)) {
        const code = ch.charCodeAt(0);
        if (ch === '"' || ch === "\\") {
            out += "\\" + ch;
        } else if (code < 0x20 || code === 0x7f) {
            out += "\\" + String(code).padStart(3, "0");
        } else {
            out += ch;
        }
    }
    return out + '"';
}

// ~/.config/hypr/tide-workspaces.lua, which conf's hyprland.lua reads as
// data: the home workspace it makes at login and keeps, the standing
// workspaces in order, which its workspace keys step through as the bar
// does, and the classes its window rules send home.
export function workspacesLua(settings) {
    const list = (items) => items.length === 0 ? "{}" : `{\n${items.map((i) => `        ${luaString(i)},\n`).join("")}    }`;
    return "-- Written by tide's shell from workspaces.json and workspaces.local.json\n"
        + "-- (tide SPEC.md §6.5, §16); edit those, not this.\n"
        + "return {\n"
        + `    home = ${luaString(homeName(settings))},\n`
        + `    standing = ${list(settings.standing ?? DEFAULT_STANDING)},\n`
        + `    in_apps = ${list(inAppPatterns(settings.inApps ?? []))},\n`
        + "}\n";
}

// Why `pattern` can't name a workspace, or null. It's JavaScript's syntax,
// as the shell runs it in Qt's engine, which has no lookbehind, named
// groups or Unicode property escapes: there those match nothing rather
// than fail, so they're refused here, by name, instead (SPEC.md §6.5,
// §20). It needs a capture group, whose text is the name.
function patternError(pattern) {
    const named = `namePatterns: ${JSON.stringify(pattern)}`;
    if (/\(\?<[=!]/.test(pattern)) {
        return `${named} uses a lookbehind, which the shell's JavaScript doesn't have`;
    }
    if (/\(\?</.test(pattern)) {
        return `${named} uses a named group, which the shell's JavaScript doesn't have`;
    }
    if (/\\[pP]\{/.test(pattern)) {
        return `${named} uses a Unicode property escape, which the shell's JavaScript doesn't have`;
    }
    let groups;
    try {
        // The pattern itself first: one that compiles only with the `|`
        // after it (one ending in a lone backslash) doesn't compile.
        new RegExp(pattern);
        groups = new RegExp(`${pattern}|`).exec("").length - 1;
    } catch (e) {
        return `${named} doesn't compile: ${e.message}`;
    }
    return groups === 0 ? `${named} has no capture group, whose text would be the name` : null;
}

// The title patterns compiled, in order: {patterns} or {error}, naming the
// first that can't be used.
export function checkPatterns(list) {
    const patterns = [];
    for (const p of list) {
        const err = patternError(p);
        if (err) {
            return { error: err };
        }
        patterns.push(new RegExp(p));
    }
    return { patterns };
}

// `text` as a name can be: without UNSAFE characters, runs of space made
// one, and cut to MAX_NAME characters at a word break, where there's one.
function cutName(text) {
    const safe = String(text).split("").filter((c) => !UNSAFE.test(c)).join("").replace(/\s+/g, " ").trim();
    const chars = [...safe];
    if (chars.length <= MAX_NAME) {
        return safe;
    }
    const head = chars.slice(0, MAX_NAME).join("");
    const space = head.lastIndexOf(" ");
    return (chars[MAX_NAME] !== " " && space > 0 ? head.slice(0, space) : head).trim();
}

// A window's title as a name: a trailing " - APP" or " — APP" dropped,
// where APP is its app's name, runs of space made one, and cut to
// MAX_NAME characters at a word break.
export function cleanTitle(title, appName) {
    let t = String(title ?? "").replace(/\s+/g, " ").trim();
    const app = String(appName ?? "").replace(/\s+/g, " ").trim();
    if (app !== "") {
        for (const sep of [" - ", " — "]) {
            if (t.endsWith(sep + app)) {
                t = t.slice(0, t.length - sep.length - app.length).trim();
                break;
            }
        }
    }
    return cutName(t);
}

// Punctuation that clings to a word's end, as in `ABC-123:` or `Docs,`.
const TRAILING_PUNCT = /[.,:;!?|\u2026\-\u2013\u2014]+$/;

// The first word of `text` with its trailing punctuation dropped, passing
// over words left with no letter or digit (a lone `—` or `|`), or "".
export function firstWord(text) {
    for (const word of String(text ?? "").split(/\s+/)) {
        const w = word.replace(TRAILING_PUNCT, "");
        if ([...w].some(isAlnum)) {
            return w;
        }
    }
    return "";
}

// The short name for a window titled `title` from app `appName` (SPEC.md
// §6.5): the first capture group of the first of `patterns` (compiled,
// from checkPatterns) that matches with a group that isn't empty, else
// the cleaned title's first word.
export function shortName(title, appName, patterns) {
    const text = String(title ?? "");
    for (const re of patterns) {
        const m = re.exec(text);
        const group = m && m[1] !== undefined ? m[1].replace(/\s+/g, " ").trim() : "";
        if (group !== "") {
            return cutName(group);
        }
    }
    return firstWord(cleanTitle(text, appName));
}

// Whether a window of class `cls` is one of home's apps (`inApps`), as
// conf's window rules match it (inAppPatterns).
export function isHomeApp(cls, inApps) {
    const c = normalizeAppId(cls);
    if (c === "") {
        return false;
    }
    return inAppPatterns(inApps).some((p) => new RegExp(`^(?:${p.replace(/^\(\?i\)/, "")})$`, "i").test(c));
}

// The client at `address` in `hyprctl clients -j`'s list, or null.
export function clientAt(clients, address) {
    return (Array.isArray(clients) ? clients : []).find((c) => c && normalizeAddress(c.address) === address) ?? null;
}

// A window address as Quickshell spells it (workspaces.mjs's
// normalizeAddress), without importing that module, which imports this.
function normalizeAddress(address) {
    const hex = String(address ?? "").trim().toLowerCase().replace(/^0x/, "").replace(/^0+(?=.)/, "");
    return /^[0-9a-f]+$/.test(hex) ? hex : null;
}

// Whether a window Hyprland describes as `client` (an object from
// `hyprctl clients -j`) takes the name prompt as it's first focused: it's
// on home, tiled, has a class or a title (a status popup has neither), and
// isn't one of home's apps (SPEC.md §6.5).
export function promptWanted(client, home, inApps) {
    if (!client || typeof client !== "object") {
        return false;
    }
    const cls = String(client.class ?? "");
    const title = String(client.title ?? "");
    return client.workspace?.name === home && client.floating !== true
        && !(cls === "" && title === "") && !isHomeApp(cls, inApps);
}

// The name prompt's rows for what's typed: first the typed name itself,
// when no workspace has it yet ({name, isNew: true}), then the workspaces
// in `names` (the bar's order) that match it, best first, each {name,
// isNew: false, positions}. Home is offered only when `allowHome` (a home
// app's window), and a typed name that is home's otherwise gets no row.
export function promptRows({ names, typed, home, allowHome = false }) {
    const t = String(typed ?? "").trim();
    const offered = names.filter((n) => allowHome || !sameName(n, home));
    const rows = [];
    const existing = matchName(offered, t);
    if (t !== "" && existing === null && (allowHome || !sameName(t, home)) && !checkName(t).error) {
        rows.push({ name: t, isNew: true, positions: [] });
    }
    const scored = [];
    offered.forEach((n, i) => {
        const m = match(t, n);
        if (m) {
            scored.push({ name: n, isNew: false, positions: m.positions, score: m.score, exact: sameName(n, t), i });
        }
    });
    scored.sort((a, b) => (b.exact - a.exact) || (b.score - a.score) || (a.i - b.i));
    for (const r of scored) {
        rows.push({ name: r.name, isNew: false, positions: r.positions });
    }
    return rows;
}

// What Enter on row `selected` does: {name} to go to, or {error} saying
// why nothing can. With no row, it's why the typed name won't do.
export function promptChoice({ rows, selected, typed, home, allowHome = false }) {
    const row = rows[selected];
    if (row) {
        return { name: row.name };
    }
    const checked = checkName(typed);
    if (checked.error) {
        return checked;
    }
    if (!allowHome && sameName(checked.name, home)) {
        return { error: `${home} is home, which holds only its own apps` };
    }
    return { error: "nothing matches" };
}

// The line above the prompt's text, saying what Enter will do.
export function promptHeading(kind) {
    switch (kind) {
    case "launch": return "Open on the workspace named";
    case "go": return "Go to the workspace named";
    case "move": return "Move this window to the workspace named";
    default: return "This window goes to the workspace named";
    }
}

// What Enter on `name` does for `request` (SPEC.md §6.5), one of:
//   {reply: "workspace NAME", answer}  tell a waiting tide launch
//   {launch: argv, cwd, name}           launch it there (Ctrl+Enter)
//   {go: name}                          go there, moving no window
//   {move: address, name}               move the window there, following it
// A new name makes the workspace either way: Hyprland makes one on going
// to a name no workspace has.
export function promptAnswer(request, name) {
    if (request.kind === "launch" && request.answer !== undefined) {
        return { reply: `workspace ${name}`, answer: request.answer };
    }
    if (request.kind === "launch") {
        return { launch: request.argv, cwd: request.cwd, name };
    }
    if (request.kind === "go") {
        return { go: name };
    }
    return { move: request.address, name };
}

// What Esc does for `request`: {close: address} for a new window on home,
// {reply: "cancel", answer} for a waiting tide launch, and {} otherwise:
// a launch from Ctrl+Enter doesn't happen, Super+Return stays where you
// are, and Super+Shift+Return leaves the window where it is.
export function promptCancel(request) {
    if (request.kind === "window") {
        return { close: request.address };
    }
    if (request.kind === "launch" && request.answer !== undefined) {
        return { reply: "cancel", answer: request.answer };
    }
    return {};
}

// The prompts waiting their turn (SPEC.md §6.5, §8.1), the first being the
// one shown. A request is {kind, id, ...}:
//   {kind: "window", address}  a new window on home, first focused
//   {kind: "go"}               Super+Return: a workspace to go to, with
//                              or without a window focused
//   {kind: "move", address}    Super+Shift+Return on the focused window
//   {kind: "launch", argv, cwd, apps}  a launch from home or Ctrl+Enter
// One prompt following another isn't the first one's Esc: each waits for
// its own Enter or Esc, or for its window to close. A second go while one
// waits is the same question, so it isn't asked twice.
export const NO_PROMPTS = Object.freeze({ queue: Object.freeze([]), next: 1 });

export function promptQueued(state, request) {
    if (request.address !== undefined && state.queue.some((r) => r.address === request.address)) {
        return state;
    }
    if (request.kind === "go" && state.queue.some((r) => r.kind === "go")) {
        return state;
    }
    return { queue: state.queue.concat([Object.assign({}, request, { id: state.next })]), next: state.next + 1 };
}

// The prompt with ID `id` answered: it goes, and the next is shown.
export function promptDone(state, id) {
    return { queue: state.queue.filter((r) => r.id !== id), next: state.next };
}

// The window at `address` closed: its prompts go, unanswered.
export function promptWindowGone(state, address) {
    return { queue: state.queue.filter((r) => r.address !== address), next: state.next };
}

// The windows the prompt is waiting to judge (SPEC.md §6.5), so a lookup
// that answers after its window closed is dropped, not queued: `pending`
// opened and not focused yet, `looking` focused, their lookup out. Every
// async answer about a window goes through windowAnswered, which says
// whether the window is still there to act on. At most 100 of each.
export const NO_WINDOWS = Object.freeze({ pending: Object.freeze([]), looking: Object.freeze([]) });

export function windowOpened(state, address) {
    return { pending: [address].concat(state.pending.filter((a) => a !== address)).slice(0, 100), looking: state.looking };
}

// The window was focused: {state, lookup}, lookup saying whether to ask
// Hyprland about it now, which only its first focus does.
export function windowFocused(state, address) {
    if (!state.pending.includes(address)) {
        return { state, lookup: false };
    }
    return {
        state: { pending: state.pending.filter((a) => a !== address), looking: [address].concat(state.looking.filter((a) => a !== address)).slice(0, 100) },
        lookup: true,
    };
}

export function windowClosed(state, address) {
    return { pending: state.pending.filter((a) => a !== address), looking: state.looking.filter((a) => a !== address) };
}

// A lookup about the window at `address` answered: {state, live}, live
// saying whether it's still open, and so may still ask.
export function windowAnswered(state, address) {
    return {
        state: { pending: state.pending, looking: state.looking.filter((a) => a !== address) },
        live: state.looking.includes(address),
    };
}
