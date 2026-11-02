// The switcher (SPEC.md §8.1): one overlay with five tabs, the launcher
// being the first, as pure functions the QML binds to. Each tab's rows have
// the launcher's shape ({item: {kind, id, name, sub, icon}, positions,
// section}), so one list draws them all.

import { match } from "./fuzzy.mjs";
import { attentionOrder, markedWindows } from "./workspaces.mjs";
import { minimizedFrom } from "./minimized.mjs";
import { windowEntry, windowMuted } from "./mute.mjs";

// The tabs, in order.
export const TABS = Object.freeze(["apps", "workspaces", "windows", "attention", "actions"]);

export const TAB_NAMES = Object.freeze({
    apps: "Apps",
    workspaces: "Workspaces",
    windows: "Windows",
    attention: "Attention",
    actions: "Actions",
});

// What each tab's empty field says.
export const PLACEHOLDERS = Object.freeze({
    apps: "Search apps and settings",
    workspaces: "Go to a workspace",
    windows: "Go to a window",
    attention: "Go to a window that wants attention",
    actions: "Run an action",
});

// The footer's key hints on `tab`, as [key, what it does]. Ctrl+Enter
// (§8.2) and PgDn's sections are the Apps tab's alone, Ctrl+M (§9) the
// Windows and Attention tabs'; Enter runs on Apps and Actions and goes on
// the tabs that list places.
export function footerKeys(tab) {
    const apps = tab === "apps";
    return [["↑↓", "select"], ["↵", apps || tab === "actions" ? "run" : "go"]]
        .concat(apps ? [["Ctrl+↵", "new workspace"], ["PgDn", "next section"]] : [])
        .concat(tab === "windows" || tab === "attention" ? [["Ctrl+M", "mute"]] : [])
        .concat([["Tab", "next tab"], ["Esc", "close"]]);
}

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

// After a tap on the bar's wave logo (SPEC.md §7.1), with the switcher
// `visible` on `tab`, and open on another monitor than the logo's if
// `elsewhere`. Shut, it opens on Apps. Open on the logo's monitor, it
// closes, on any tab: its backdrop covers that monitor's bar, so the tap is
// the backdrop's, which closes it. Open elsewhere, it's `move`d to the
// logo's monitor, on Apps.
export function logoTapped(visible, tab, elsewhere) {
    if (!visible) {
        return { visible: true, tab: "apps", move: false };
    }
    if (elsewhere) {
        return { visible: true, tab: "apps", move: true };
    }
    return { visible: false, tab, move: false };
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

// One window's row: its title, and its app and workspace below. A
// minimized window (SPEC.md §6.7) is under the workspace it came from,
// said so, and `restoreTo` names that workspace, where Enter puts it back.
// `muted` says its app is muted (`muted`, the list), and `muteEntry` is
// what Ctrl+M adds to the list to mute it (SPEC.md §9, Muted apps).
function windowRow(w, muted) {
    const from = minimizedFrom(w.workspace);
    return {
        item: {
            kind: "window",
            id: w.address,
            address: w.address,
            name: w.title || w.appName || w.app || "Untitled",
            sub: [w.appName || w.app, from ?? w.workspace, from !== null ? "minimized" : "", windowMuted(w.app, muted) ? "muted" : ""]
                .filter((s) => s).join(" · "),
            icon: w.app,
            restoreTo: from,
            muted: windowMuted(w.app, muted),
            muteEntry: windowEntry(w.app),
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
// first, each browser window's tabs under it (SPEC.md §8.3; `tabs`, from
// tabs.mjs's tabRows), and tabs whose window wasn't found last. Typing
// filters by title and app name, and a tab by its title, browser and site.
export function windowRows(windows, query, muted = [], tabs = {}) {
    const rows = [];
    for (const w of byFocus(windows)) {
        rows.push(windowRow(w, muted));
        rows.push(...(tabs[w.address] ?? []));
    }
    rows.push(...(tabs[""] ?? []));
    return filtered(rows, query, (r) => [r.item.name, r.item.sub]);
}

// The Attention tab: every marked window (SPEC.md §14.4), the most
// recently marked first: the guard's and notifications' marks by when they
// were made (`marks`, from updateMarks), then any Hyprland marked urgent
// itself, the one used last first. Each marked window is its own row. A
// muted app's windows are never marked (`muted`).
export function attentionRows(windows, marks, query, muted = []) {
    const marked = markedWindows({ windows, marks, muted });
    const order = attentionOrder(marks, windows, muted).slice().reverse().filter((a) => marked.has(a));
    const listed = new Set(order);
    const rest = byFocus(windows).filter((w) => marked.has(w.address) && !listed.has(w.address)).map((w) => w.address);
    const at = {};
    for (const w of windows) {
        at[w.address] = w;
    }
    const rows = order.concat(rest).map((a) => windowRow(at[a], muted));
    return filtered(rows, query, (r) => [r.item.name, r.item.sub]);
}

// What the list says when a tab has no rows.
export function emptyText(tab, query) {
    if (String(query ?? "").trim() !== "") {
        return "Nothing matches";
    }
    return tab === "attention" ? "No window wants attention" : tab === "windows" ? "No windows open" : "";
}
