// The launcher's results (SPEC.md §8): the apps from desktop entries and
// their desktop actions, matched with fuzzy.mjs, and the command that runs
// one through `tide launch` (§5.4).

import { match } from "./fuzzy.mjs";

// A match outside the name (generic name, keywords, the command) still
// finds an app, but below one that matches its name as well.
const OTHER_FIELD = 24;

function basename(path) {
    return String(path ?? "").split("/").pop();
}

// One row per app a desktop entry shows, and one per desktop action it
// offers ("New Incognito Window"), as plain objects. Entries marked
// NoDisplay, or with nothing to run, are left out. `entries` are
// Quickshell DesktopEntry objects or anything with their properties.
export function launcherItems(entries) {
    const items = [];
    for (const e of entries) {
        if (!e || e.noDisplay || !e.command || e.command.length === 0) {
            continue;
        }
        const app = {
            kind: "app",
            id: e.id,
            name: e.name || e.id,
            sub: e.genericName || e.comment || "",
            icon: e.icon || "",
            keywords: [...(e.keywords ?? [])],
            exec: basename(e.command[0]),
            command: [...e.command],
            terminal: Boolean(e.runInTerminal),
            workingDirectory: e.workingDirectory || "",
            appId: e.startupClass || "",
        };
        items.push(app);
        for (const a of e.actions ?? []) {
            if (!a || !a.command || a.command.length === 0) {
                continue;
            }
            items.push({
                ...app,
                kind: "action",
                id: `${e.id}:${a.id}`,
                name: a.name || a.id,
                sub: app.name,
                icon: a.icon || app.icon,
                keywords: [],
                exec: basename(a.command[0]),
                command: [...a.command],
            });
        }
    }
    return items;
}

// How `item` matches `query`: its score and the matched positions in its
// name (code points, empty when only another field matched), or null.
export function scoreItem(item, query) {
    const byName = match(query, item.name);
    let best = byName ? { score: byName.score, positions: byName.positions } : null;
    const others = [item.sub, item.exec, ...item.keywords];
    for (const text of others) {
        const m = text ? match(query, text) : null;
        if (m && (!best || m.score - OTHER_FIELD > best.score)) {
            best = { score: m.score - OTHER_FIELD, positions: [] };
        }
    }
    return best;
}

function byName(a, b) {
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" }) || a.id.localeCompare(b.id);
}

// The rows for `query`, best first, each `{item, positions}`. An empty
// query lists the apps by name, without their desktop actions, until
// frecency orders them (TODO.md).
export function search(items, query) {
    if (query.trim() === "") {
        return items.filter(i => i.kind === "app").sort(byName).map(item => ({ item, positions: [] }));
    }
    const rows = [];
    for (const item of items) {
        const m = scoreItem(item, query);
        if (m) {
            rows.push({ item, score: m.score, positions: m.positions });
        }
    }
    // An app before its own actions when they score the same.
    rows.sort((a, b) => b.score - a.score || (a.item.kind === b.item.kind ? 0 : a.item.kind === "app" ? -1 : 1) || byName(a.item, b.item));
    return rows.map(({ item, positions }) => ({ item, positions }));
}

// The `tide launch` command that runs `item`. The focus grant goes to its
// StartupWMClass when the entry names one, since that's the window class
// the guard sees. Otherwise nothing says which class its window will have:
// the Exec line is often a wrapper (a script, `env`, `flatpak run`) whose
// name no window has. So it grants the first window of any app (`*`), as
// `tide launch` does for xdg-open; the grant still ends on a key press, a
// focus change or after 10 s. A terminal app's window is the terminal's,
// whatever class the entry names, so it grants `*` too.
export function launchCommand(item) {
    const app = item.appId && !item.terminal ? item.appId : "*";
    const command = ["tide", "launch", "--app", app, "--"];
    if (item.terminal) {
        command.push("xdg-terminal-exec");
    }
    return command.concat(item.command);
}

function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// `name` as styled text with the matched letters underlined in `color`,
// everything else escaped: names come from desktop entries, never markup.
export function highlighted(name, positions, color) {
    const at = new Set(positions);
    return [...name].map((c, i) => (at.has(i) ? `<u><font color="${color}">${escapeHtml(c)}</font></u>` : escapeHtml(c))).join("");
}

// The selection after moving `step` rows from `index` among `count`,
// clamped to the list rather than wrapping.
export function moved(index, step, count) {
    if (count === 0) {
        return -1;
    }
    return Math.max(0, Math.min(count - 1, index + step));
}
