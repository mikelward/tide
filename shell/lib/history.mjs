// The notification center's history (SPEC.md §9), as pure functions the
// QML binds to. Entries are plain objects, newest first, so they store as
// JSON in $XDG_STATE_HOME/tide/notifications.json and survive a
// shell restart.

// The most entries kept; past it, the oldest go.
export const MAX_ENTRIES = 200;

// How many entries a group shows before "Show N more".
export const GROUP_SHOWN = 3;

// The history after a notification arrives or is updated. `item` is
// {key, app, icon, entry, summary, body, critical, transient, replaces}:
// `key` names this notification for as long as it lives, and `replaces`
// the key of one it took the place of (a synchronous replacement), whose
// entry goes. An update in place keeps its key, and moves to the top as
// news. A transient notification (the hint of that name) asks to be kept
// out of the history, so it is, and one updated to transient leaves it.
export function record(entries, item, now) {
    const rest = entries.filter(e => e.key !== String(item.key) && e.key !== item.replaces);
    if (item.transient) {
        return rest.length === entries.length ? entries : rest;
    }
    const entry = {
        key: String(item.key),
        app: item.app ?? "",
        icon: item.icon ?? "",
        entry: item.entry ?? "",
        summary: item.summary ?? "",
        body: item.body ?? "",
        critical: item.critical === true,
        time: now,
    };
    return [entry, ...rest].slice(0, MAX_ENTRIES);
}

// The name a group goes by: the app's own, else its desktop entry.
export function appOf(entry) {
    return entry.app || entry.entry || "Notifications";
}

// Entries grouped by app, the group with the newest entry first, each
// group newest first: [{app, icon, entry, items}].
export function groups(entries) {
    const byApp = new Map();
    for (const e of entries) {
        const app = appOf(e);
        if (!byApp.has(app)) {
            byApp.set(app, { app, icon: e.icon, entry: e.entry, items: [] });
        }
        byApp.get(app).items.push(e);
    }
    return [...byApp.values()];
}

// The history without `app`'s group (its ✕).
export function clearApp(entries, app) {
    return entries.filter(e => appOf(e) !== app);
}

// A group's items as shown: the first GROUP_SHOWN unless expanded, and how
// many more there are behind "Show N more".
export function shownItems(items, expanded) {
    if (expanded || items.length <= GROUP_SHOWN) {
        return { items, more: 0 };
    }
    return { items: items.slice(0, GROUP_SHOWN), more: items.length - GROUP_SHOWN };
}

// The history ({entries, unread}) after one change: {op: "record", item,
// time, carried?}, {op: "clearAll"}, {op: "clearApp", app} or {op:
// "seen"} (the center was open). `unread` lists the keys of entries that arrived since
// the center was last open: it follows the order of the changes, not their
// times, so a clock that steps back can't hide an arrival, and an unread
// entry that goes (cleared, replaced, made transient, past the cap) stops
// counting with it.
export function apply(state, change) {
    switch (change.op) {
    case "record": {
        // One carried over a config reload ({carried: true}) is already in
        // the history unless it was never saved (a shell whose file couldn't
        // be read) or was cleared; only then is it recorded.
        if (change.carried && state.entries.some(e => e.key === String(change.item.key))) {
            return state;
        }
        const entries = record(state.entries, change.item, change.time);
        const key = String(change.item.key);
        const added = entries[0]?.key === key && !change.item.transient;
        const unread = state.unread.filter(k => k !== key);
        return kept({ entries, unread: added ? [...unread, key] : unread });
    }
    case "clearAll":
        return { entries: [], unread: [] };
    case "clearApp":
        return kept(Object.assign({}, state, { entries: clearApp(state.entries, change.app) }));
    case "seen":
        return Object.assign({}, state, { unread: [] });
    }
    throw new Error(`unknown history change ${change.op}`);
}

// Only entries still in the history can be unread.
function kept(state) {
    const keys = new Set(state.entries.map(e => e.key));
    return Object.assign({}, state, { unread: state.unread.filter(k => keys.has(k)) });
}

// How long ago `time` was, as the center shows it.
export function age(time, now) {
    const minutes = Math.floor(Math.max(0, now - time) / 60000);
    if (minutes < 1) {
        return "now";
    }
    if (minutes < 60) {
        return `${minutes} min`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
        return `${hours} h`;
    }
    return `${Math.floor(hours / 24)} d`;
}

// Whether the bell shows its dot: something arrived since the center was
// last open, and it hasn't all been cleared since.
export function unread(state) {
    return kept(state).unread.length > 0;
}

// The file's contents for the history.
export function serialize(state) {
    return JSON.stringify({ version: 1, unread: state.unread, entries: state.entries }) + "\n";
}

function isEntry(e) {
    return e !== null && typeof e === "object"
        && ["key", "app", "icon", "entry", "summary", "body"].every(k => typeof e[k] === "string")
        && typeof e.critical === "boolean"
        && Number.isFinite(e.time);
}

// The history from the file's text (null when there's no file yet):
// {entries, unread, errors}. What can't be read is left out and named in
// `errors`, so a damaged file costs only its damaged entries.
export function parse(text) {
    const empty = { entries: [], unread: [], errors: [] };
    if (text === null || text === undefined || text.trim() === "") {
        return empty;
    }
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return Object.assign({}, empty, { errors: [`not JSON (${e.message})`] });
    }
    if (data === null || typeof data !== "object" || data.version !== 1 || !Array.isArray(data.entries)) {
        return Object.assign({}, empty, { errors: ["not a version 1 history"] });
    }
    const entries = data.entries.filter(isEntry);
    const errors = [];
    const dropped = data.entries.length - entries.length;
    if (dropped > 0) {
        errors.push(`${dropped} unreadable ${dropped === 1 ? "entry" : "entries"} left out`);
    }
    entries.sort((a, b) => b.time - a.time);
    return Object.assign(kept({
        entries: entries.slice(0, MAX_ENTRIES),
        unread: Array.isArray(data.unread) ? data.unread.filter(k => typeof k === "string") : [],
    }), { errors });
}

// What a click on an entry in the center does (SPEC.md §9). `live` is its
// notification while the server still has it (shown, or resting), else null.
// A live one does what clicking its popup does: runs its default action,
// or dismisses it when it has none. One that has gone took its actions
// with it, so the click brings up its app's most recent window instead.
// Returns {action}, {dismiss: true}, {app} (the id to focus), or null when
// a gone entry names no app.
export function clickTarget(entry, live, defaultAction) {
    if (live) {
        const action = defaultAction(live.actions ?? []);
        return action ? { action } : { dismiss: true };
    }
    for (const id of [entry.entry, entry.app]) {
        const trimmed = (id ?? "").trim();
        if (trimmed !== "") {
            return { app: trimmed };
        }
    }
    return null;
}
