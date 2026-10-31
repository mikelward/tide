// The switcher (SPEC.md §8.1): one overlay with four tabs, the launcher
// being the first, as pure functions the QML binds to. Each tab's rows have
// the launcher's shape ({item: {kind, id, name, sub, icon}, positions,
// section}), so one list draws them all.

import { match } from "./fuzzy.mjs";
import { attentionOrder, markedWindows } from "./workspaces.mjs";

// The tabs, in order.
export const TABS = Object.freeze(["apps", "workspaces", "windows", "attention"]);

export const TAB_NAMES = Object.freeze({
    apps: "Apps",
    workspaces: "Workspaces",
    windows: "Windows",
    attention: "Attention",
});

// What each tab's empty field says.
export const PLACEHOLDERS = Object.freeze({
    apps: "Search apps and actions",
    workspaces: "Go to a workspace",
    windows: "Go to a window",
    attention: "Go to a window that wants attention",
});

// The tab `step` tabs on from `tab` (Tab is 1, Shift+Tab -1), wrapping.
export function movedTab(tab, step) {
    const i = TABS.indexOf(tab);
    const n = TABS.length;
    return TABS[(((i < 0 ? 0 : i) + step) % n + n) % n];
}

// The switcher after moving from its tab to `next`: {tab, asking,
// checking, session}, `asking` being the power action waiting on your
// confirmation, `checking` one waiting on logind, and `session` the count
// its callbacks check. Leaving a tab cancels both and counts a new session,
// so a check that answers later finds itself stale and does nothing, and
// the new tab starts with nothing of the Apps tab's left on it.
export function tabChanged(state, next) {
    if (next === state.tab) {
        return state;
    }
    return { tab: next, asking: "", checking: false, session: state.session + 1 };
}

// What a key that opens the switcher on `wanted` does (SPEC.md §8.1): opens
// it there, moving to that tab if it's open on another, and closes it if
// it's open there already. {visible, tab}.
export function toggled(visible, tab, wanted) {
    if (!TABS.includes(wanted)) {
        throw new Error(`not a switcher tab: ${wanted}`);
    }
    return visible && tab === wanted ? { visible: false, tab } : { visible: true, tab: wanted };
}

// Rows in the order `query` matches them best, ties keeping `rows`' order;
// all of them, as they are, for an empty query. `fields(row)` gives the
// texts to match, the first being the one whose letters are underlined.
function filtered(rows, query, fields) {
    const q = String(query ?? "");
    if (q.trim() === "") {
        return rows;
    }
    const scored = [];
    rows.forEach((row, i) => {
        let best = null;
        fields(row).forEach((text, f) => {
            const m = match(q, String(text ?? ""));
            if (m && (best === null || m.score > best.score)) {
                best = { score: m.score, positions: f === 0 ? m.positions : [] };
            }
        });
        if (best) {
            scored.push({ row: Object.assign({}, row, { positions: best.positions }), score: best.score, i });
        }
    });
    scored.sort((a, b) => (b.score - a.score) || (a.i - b.i));
    return scored.map((s) => s.row);
}

// The Workspaces tab: every workspace in the bar's order (`list`, from
// workspaces.mjs's barWorkspaces), each with its first window's app as its
// icon, the current one said so. Typing filters by name.
export function workspaceRows(list, query) {
    const rows = list.map((w) => {
        const count = w.count;
        const what = w.state === "current" ? "current"
            : w.id === null ? "not made yet"
            : count === 0 ? "empty"
            : count === 1 ? "1 window" : `${count} windows`;
        return {
            item: {
                kind: "workspace",
                id: w.name,
                name: w.name,
                sub: w.home ? `home · ${what}` : what,
                icon: w.app,
                current: w.state === "current",
                urgent: w.urgent,
            },
            positions: [],
            section: "",
        };
    });
    return filtered(rows, query, (r) => [r.item.name]);
}

// One window's row: its title, and its app and workspace below.
function windowRow(w) {
    return {
        item: {
            kind: "window",
            id: w.address,
            address: w.address,
            name: w.title || w.appName || w.app || "Untitled",
            sub: [w.appName || w.app, w.workspace].filter((s) => s).join(" · "),
            icon: w.app,
        },
        positions: [],
        section: "",
    };
}

// The windows on the tabs that list them: [{address, title, app, appName,
// workspace (its name), focus}], `focus` being the window's place in focus
// order, lower more recent (workspaces.mjs's focusRank). Windows on
// special workspaces are listed too, by their workspace's name.
function byFocus(windows) {
    return windows.map((w, i) => ({ w, i }))
        .sort((a, b) => ((a.w.focus ?? Infinity) - (b.w.focus ?? Infinity)) || (a.i - b.i))
        .map((x) => x.w);
}

// The Windows tab: every window on any workspace, the one used last
// first. Typing filters by title and app name.
export function windowRows(windows, query) {
    return filtered(byFocus(windows).map(windowRow), query, (r) => [r.item.name, r.item.sub]);
}

// The Attention tab: every marked window (SPEC.md §14.4), the most
// recently marked first: the guard's and notifications' marks by when they
// were made (`marks`, from updateMarks), then any Hyprland marked urgent
// itself, the one used last first. Each marked window is its own row.
export function attentionRows(windows, marks, query) {
    const marked = markedWindows({ windows, marks });
    const order = attentionOrder(marks).slice().reverse().filter((a) => marked.has(a));
    const listed = new Set(order);
    const rest = byFocus(windows).filter((w) => marked.has(w.address) && !listed.has(w.address)).map((w) => w.address);
    const at = {};
    for (const w of windows) {
        at[w.address] = w;
    }
    const rows = order.concat(rest).map((a) => windowRow(at[a]));
    return filtered(rows, query, (r) => [r.item.name, r.item.sub]);
}

// What the list says when a tab has no rows.
export function emptyText(tab, query) {
    if (String(query ?? "").trim() !== "") {
        return "Nothing matches";
    }
    return tab === "attention" ? "No window wants attention" : tab === "windows" ? "No windows open" : "";
}
