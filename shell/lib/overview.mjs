// The overview (SPEC.md §8.7): every workspace's windows as cards, grouped
// by workspace. What it shows and what a choice does, apart
// from Overview.qml, which shows it.

import { match } from "./fuzzy.mjs";
import { isMinimizedFromWorkspace, minimizedFrom } from "./minimized.mjs";
import { workspaceOf } from "./span.mjs";
import { sameName } from "./workspacenames.mjs";
import { workspaceOrder } from "./workspaces.mjs";

// The groups, [{name, id, current, windows: [card]}], each card
// {address, title, app, minimized, restoreTo, identifier}: every workspace
// with a window, the current one first, then the rest in the bar's order
// (workspaceOrder). A workspace's minimized windows are in its group,
// marked, with restoreTo the workspace they came back to.
//
// `workspaces` and `windows` are Compositor's, `standing` the standing
// names, `current` the focused monitor's workspace ID, and `monitors` the
// monitors' names in the order their windows come: each monitor's tiled
// windows, then its floating ones, then any on a monitor not listed, each
// in the order `windows` has them.
export function groups({ workspaces, standing = [], windows, current, monitors = [] }) {
    const order = workspaceOrder(workspaces ?? [], standing);
    const here = order.findIndex(w => w.ids.includes(current));
    const listed = here < 0 ? order : [order[here]].concat(order.filter((_, i) => i !== here));
    const all = Array.from(windows ?? []);
    const rank = w => {
        const m = monitors.indexOf(w.monitor);
        return (m < 0 ? monitors.length : m) * 2 + (w.floating ? 1 : 0);
    };
    // A minimized window's workspace may have gone as its last window
    // left (§6.7): it still gets a group, after the bar's, by name.
    const known = listed.map(w => w.name);
    const gone = [];
    for (const w of all) {
        const from = minimizedFrom(w.workspaceName);
        const name = from === null ? null : workspaceOf(from);
        if (name !== null && !known.some(k => sameName(k, name)) && !gone.some(k => sameName(k, name))) {
            gone.push(name);
        }
    }
    gone.sort();
    const out = [];
    for (const ws of listed.concat(gone.map(name => ({ name, id: null, ids: [] })))) {
        const mine = all
            .map((w, i) => ({ w, i }))
            .filter(({ w }) => ws.ids.includes(w.workspace) || isMinimizedFromWorkspace(w.workspaceName, ws.name))
            .sort((a, b) => rank(a.w) - rank(b.w) || a.i - b.i)
            .map(({ w }) => card(w));
        if (mine.length > 0) {
            out.push({ name: ws.name, id: ws.id, current: ws.ids.includes(current), windows: mine });
        }
    }
    return out;
}

function card(w) {
    const from = minimizedFrom(w.workspaceName);
    return {
        address: String(w.address),
        title: String(w.title ?? ""),
        app: String(w.app ?? ""),
        minimized: from !== null,
        restoreTo: from,
        identifier: typeof w.identifier === "string" ? w.identifier : "",
    };
}

// The groups with only the cards whose title or app name (`appName(app)`,
// the app itself without one) match `query` with the launcher's fuzzy
// matcher, each card given `titleAt` and `appAt`, the positions matched
// in either, for highlighting. A group with none left goes. An empty
// query keeps every card.
export function filtered(list, query, appName = app => app) {
    const out = [];
    for (const g of list) {
        const windows = [];
        for (const w of g.windows) {
            const name = appName(w.app) || w.app;
            const title = match(query, w.title);
            const app = match(query, name);
            if (title === null && app === null) {
                continue;
            }
            const byTitle = title !== null && (app === null || title.score >= app.score);
            windows.push(Object.assign({}, w, {
                appName: name,
                titleAt: byTitle ? title.positions : [],
                appAt: byTitle ? [] : app.positions,
            }));
        }
        if (windows.length > 0) {
            out.push(Object.assign({}, g, { windows }));
        }
    }
    return out;
}

// Every card in order, as the arrows step through them.
export function cards(list) {
    return [].concat(...list.map(g => g.windows));
}

// Where the selection starts: the focused window's card, else the first.
export function startAt(list, focused) {
    const i = cards(list).findIndex(w => w.address === String(focused ?? ""));
    return i < 0 ? 0 : i;
}

// What choosing `card` does: {focus: address}, which shows its workspace,
// or for a minimized window, {restore: address, to: name}, which brings it
// back to the workspace it came from (§6.7).
export function choice(card) {
    if (card.minimized && card.restoreTo !== null) {
        return { restore: card.address, to: card.restoreTo };
    }
    return { focus: card.address };
}

// tidewm's window pictures: the file each goes to under `dir`, and the
// one command that takes them all at once, each with `grim -T` by its
// ext-foreign-toplevel-list identifier, as a JPEG, quicker to write than a
// PNG. An identifier a file name couldn't hold safely is left out; null
// with none left.
export function shotFile(dir, identifier) {
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(String(identifier ?? "")) || !dir) {
        return null;
    }
    return `${dir}/${identifier}.jpg`;
}

export function shotsCommand(dir, identifiers) {
    const ids = Array.from(identifiers ?? []).filter(id => shotFile(dir, id) !== null);
    if (ids.length === 0) {
        return null;
    }
    // Every old picture goes first, closed windows' too, and a failed one's
    // after, so a card shows its icon rather than an old picture and the
    // directory holds only this open's; it exits 1 if any failed.
    const script = 'dir=$1; shift; mkdir -p -m 700 "$dir" || exit 1; rm -f "$dir"/*.jpg; pids=; '
        + 'for id; do f="$dir/$id.jpg"; '
        + '( grim -T "$id" -t jpeg "$f" || { rm -f "$f"; exit 1; } ) & pids="$pids $!"; done; '
        + 'failed=0; for p in $pids; do wait "$p" || failed=1; done; exit "$failed"';
    return ["sh", "-c", script, "sh", dir].concat(ids);
}
