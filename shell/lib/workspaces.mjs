// The bar's workspaces (SPEC.md §6.5, §7.2, §14.4), as pure functions the
// QML binds to. The QML turns Quickshell.Hyprland's monitors and toplevels
// into the plain objects these take, and maps app IDs to icons.

import { normalizeAppId, sameName } from "./workspacenames.mjs";
import { isMinimizedFrom, minimizedFrom } from "./minimized.mjs";
import { noteMuted, windowMuted } from "./mute.mjs";
import { workspaceOf } from "./span.mjs";

// Icons shown per workspace before the rest collapse into "+n".
export const MAX_ICONS = 5;
// The most of a name the bar shows before an ellipsis (§7.2).
export const BAR_NAME = 16;

// Attention marks (§14.4), kept as events arrive. A snapshot can't say
// which came first or what was on screen when a notification arrived, so
// the QML feeds Hyprland's and the notification daemon's events through
// updateMarks and hands the result to barWorkspaces. The state is
//
//   {guard: [address], guardAt, notes: {id: {app, wide: [address], direct: [address], at}}}
//
// where `guard` holds the windows the focus guard kept from focus, and
// `notes` each notification's marks by its ID, so dismissing one clears
// exactly what it marked. A note's `wide` windows came from marking its
// whole app and `direct` ones from naming the window; only the app's own
// activation tells them apart. `guardAt` and each note's `at` say when each
// window was last marked ({address: n}, larger is later, one clock for
// both), so the Attention tab's order comes from the marks still standing
// (attentionOrder). Hyprland's own urgent flag lives on the window.
export const NO_MARKS = Object.freeze({ guard: Object.freeze([]), guardAt: Object.freeze({}), notes: Object.freeze({}) });

// The marks after one event, without changing `marks`. Events:
//
//   {type: "notified", id, app, windows, visible}  an app-wide mark: the
//       app's windows on workspaces not on screen right now (`visible` is a
//       Set of workspace IDs), and only those, until it clears. A
//       replacement (the same ID again) keeps what it marked before.
//   {type: "notified", id, app, address, windows, visible}  a notification
//       naming its window: marked only if that window's workspace isn't on
//       screen, like an app-wide mark.
//   Either may carry `sender`, what the notification is muted by
//       (mute.mjs's noteOf), which the note keeps for the "muted" event.
//   Either may carry `muted`, the muted list: a muted app's window is never
//       a target, so no mark on it is ever recorded (SPEC.md §9, Muted apps).
//   Either may name `replaces`, the ID of a notification it took the place
//       of under another ID (Chrome's per-conversation sync key): it takes
//       over that one's marks, as a replacement under the same ID would.
//   {type: "guarded", address, app, muted}   the focus guard kept a new
//       window from focus; a muted app's (`app` its class) isn't marked.
//   {type: "activated", app}     urgent>>ADDRESS: the app's own activation
//       replaces its app-wide marks (activatedEvent).
//
// A notification's `app` is the desktop entry or app name it gave
// (notifications.mjs's targetApps): one or a list, matched to window
// classes by sameApp.
//   {type: "focused", address}   the window was attended to: the guard's
//       mark on it clears, and so does every notification's that covered it.
//   {type: "muted", muted, windows}   the muted list changed: the marks of
//       every notification whose `sender` is now muted go, and every mark
//       on a muted app's window, in one pass.
//   {type: "dismissed", id}      the notification was dismissed.
//   {type: "closed", address}    the window is gone.
//   {type: "guardReset"}         the focus guard's state was rebuilt (a
//       Hyprland config reload runs focus.lua afresh): its marks go, and
//       the shell asks it to announce what still waits.
// Object.fromEntries, which Qt's JavaScript engine doesn't have.
function fromEntries(pairs) {
    const out = {};
    for (const [key, value] of pairs) {
        out[key] = value;
    }
    return out;
}

export function updateMarks(marks, event) {
    let guard = marks.guard;
    let guardAt = marks.guardAt ?? {};
    const notes = {};
    // Later than any mark standing now.
    const now = 1 + Math.max(0, ...Object.values(guardAt),
        ...[].concat(...Object.values(marks.notes).map((n) => Object.values(n.at ?? {}))));
    const put = (id, note) => {
        if (note.wide.length + note.direct.length > 0) {
            notes[id] = note;
        }
    };
    const covers = (note, address) => note.wide.includes(address) || note.direct.includes(address);
    const without = (list, address) => list.filter((a) => a !== address);
    switch (event.type) {
    case "notified": {
        Object.assign(notes, marks.notes);
        // A muted app's window is never a target, so it never holds a
        // mark to come back when it's unmuted (SPEC.md §9, Muted apps).
        const windows = event.windows.filter((w) => !windowMuted(w.app, event.muted));
        // It keeps what it marked before, under the app it names now.
        const note = Object.assign({ wide: [], direct: [], at: {} }, notes[event.id] ?? notes[event.replaces], { app: event.app },
            event.sender !== undefined ? { sender: event.sender } : {});
        delete notes[event.id];
        delete notes[event.replaces];
        // A muted sender marks nothing, and an update that makes one muted
        // (its site changed to a muted one) drops what it marked before.
        if (event.sender !== undefined && noteMuted(event.sender, event.muted)) {
            break;
        }
        const stamped = (addresses) => Object.assign({}, note.at, fromEntries(addresses.map((a) => [a, now])));
        if (event.address !== undefined) {
            const named = windows.find((w) => w.address === event.address);
            const hidden = named !== undefined && !event.visible.has(named.workspace);
            put(event.id, hidden
                ? Object.assign({}, note, { direct: [...new Set([...note.direct, event.address])], at: stamped([event.address]) })
                : note);
        } else {
            const hidden = windows
                .filter((w) => anyApp(event.app, w.app) && !event.visible.has(w.workspace))
                .map((w) => w.address);
            put(event.id, Object.assign({}, note, { wide: [...new Set([...note.wide, ...hidden])], at: stamped(hidden) }));
        }
        break;
    }
    case "guarded":
        Object.assign(notes, marks.notes);
        if (windowMuted(event.app, event.muted)) {
            break;
        }
        // Announced again, it's the newest.
        guard = [...without(guard, event.address), event.address];
        guardAt = Object.assign({}, guardAt, { [event.address]: now });
        break;
    case "activated":
        for (const [id, note] of Object.entries(marks.notes)) {
            put(id, anyApp(note.app, event.app) ? Object.assign({}, note, { wide: [] }) : note);
        }
        break;
    case "muted":
        // The muted list changed: in one pass, every mark from a notification
        // whose sender or site is now muted goes, whichever windows it
        // marked (a site's notification with no --app window open marks
        // plain browser windows), and so does every mark on a muted app's
        // window. Other notifications' marks stay.
        {
            const mutedWindow = new Set(event.windows.filter((w) => windowMuted(w.app, event.muted)).map((w) => w.address));
            guard = guard.filter((a) => !mutedWindow.has(a));
            for (const [id, note] of Object.entries(marks.notes)) {
                if (note.sender !== undefined && noteMuted(note.sender, event.muted)) {
                    continue;
                }
                const at = Object.assign({}, note.at ?? {});
                for (const a of mutedWindow) {
                    delete at[a];
                }
                put(id, Object.assign({}, note, {
                    wide: note.wide.filter((a) => !mutedWindow.has(a)),
                    direct: note.direct.filter((a) => !mutedWindow.has(a)),
                    at,
                }));
            }
        }
        break;
    case "focused":
        guard = without(guard, event.address);
        for (const [id, note] of Object.entries(marks.notes)) {
            if (!covers(note, event.address)) {
                notes[id] = note;
            }
        }
        break;
    case "dismissed":
        Object.assign(notes, marks.notes);
        delete notes[event.id];
        break;
    case "guardReset":
        Object.assign(notes, marks.notes);
        guard = [];
        break;
    case "closed":
        guard = without(guard, event.address);
        for (const [id, note] of Object.entries(marks.notes)) {
            put(id, Object.assign({}, note, { wide: without(note.wide, event.address), direct: without(note.direct, event.address) }));
        }
        break;
    default:
        throw new Error(`unknown mark event ${event.type}`);
    }
    guardAt = fromEntries(guard.map((a) => [a, guardAt[a] ?? 0]));
    return { guard, guardAt, notes };
}

// Whether `app` matches any of `apps`, an app or a list of them (sameApp):
// a notification from a Chrome site open as an `--app` window in two
// profiles names both classes.
export function anyApp(apps, app) {
    return (Array.isArray(apps) ? apps : [apps]).some((a) => sameApp(a, app));
}

// Whether a window class and a notification's app name the same app, as
// the focus guard matches them (hypr/tide/focus.lua's same_id):
// case-insensitively, without a `.desktop` suffix, and with a bare name
// matching the last part of a qualified one, so `nautilus` matches
// `org.gnome.Nautilus`, while `org.example.chat` and `com.example.chat`
// stay apart.
export function sameApp(a, b) {
    const x = normalizeAppId(a);
    const y = normalizeAppId(b);
    if (x === "" || y === "") {
        return false;
    }
    if (x === y) {
        return true;
    }
    const xBare = !x.includes(".");
    if (xBare === !y.includes(".")) {
        return false;
    }
    const [bare, qualified] = xBare ? [x, y] : [y, x];
    return qualified.split(".").pop() === bare;
}

// The workspaces on screen: each monitor's open special workspace, which
// covers its regular one, or else its active one. `monitors` is
// [{workspace, special}], special being 0 or absent when none is open.
export function visibleWorkspaces(monitors) {
    return new Set(monitors.map((m) => (m.special ? m.special : m.workspace)).filter((id) => id != null));
}

// The "activated" event an urgent>>ADDRESS means: the app whose window
// asked for focus, from `windows` ([{address, app}]). Null for a window
// the list doesn't have or one with no class.
export function activatedEvent(address, windows) {
    const app = windows.find((w) => w.address === address)?.app;
    return app ? { type: "activated", app } : null;
}

// A window address as Quickshell spells it (lowercase hex, no 0x, no
// leading zeros), from whatever form an event or the focus guard used.
export function normalizeAddress(address) {
    const hex = String(address ?? "").trim().toLowerCase().replace(/^0x/, "").replace(/^0+(?=.)/, "");
    return /^[0-9a-f]+$/.test(hex) ? hex : null;
}

// The windows focused since the shell started, newest first, as addresses
// (normalizeAddress), after `address` takes focus. Hyprland's own order
// (a client's focusHistoryID) is only as fresh as the shell's last client
// list, which focus changes don't refresh, so the shell keeps this from
// activewindowv2 itself (§14.4). It keeps the most recent 100.
export function withFocus(order, address) {
    if (address === null || address === undefined) {
        return order;
    }
    return [address, ...order.filter((a) => a !== address)].slice(0, 100);
}

// The order without a window that closed.
export function withoutWindow(order, address) {
    return order.filter((a) => a !== address);
}

// A window's place in focus order, lower being more recent: its place in
// `order` if it was focused since the shell started, else after all of
// those, by the focusHistoryID Hyprland gave when the shell last listed
// clients (0 was last focused, -1 never). Infinity when neither says.
export function focusRank(order, address, historyId) {
    const i = order.indexOf(address);
    if (i >= 0) {
        return i;
    }
    return Number.isInteger(historyId) && historyId >= 0 ? order.length + historyId : Infinity;
}

// The mark event a Hyprland socket event means, or null: the focus guard
// keeping a window from focus (custom>>tide-attention>>ADDRESS,
// SPEC.md §14.3), a window being focused, one closing, a window asking for
// focus (`urgent`, which the QML turns into activatedEvent once it knows
// the window's app), or a config reload rebuilding the guard.
// Notifications' events come from the notification server instead.
export function markEvent(name, data) {
    if (name === "configreloaded") {
        return { type: "guardReset" };
    }
    let type;
    let raw;
    if (name === "custom" && String(data).startsWith("tide-attention>>")) {
        type = "guarded";
        raw = String(data).slice("tide-attention>>".length);
    } else if (name === "activewindowv2") {
        type = "focused";
        raw = data;
    } else if (name === "closewindow") {
        type = "closed";
        raw = data;
    } else if (name === "urgent") {
        type = "urgent";
        raw = data;
    } else {
        return null;
    }
    const address = normalizeAddress(raw);
    return address === null ? null : { type, address };
}

// Every window marked for attention, oldest mark first, for the focus
// guard (tide_focus.set_order) and the Attention tab: the guard's own and
// notifications', each placed by its latest mark still standing. So
// dismissing a newer notification puts a window back where an older mark
// had it, and a guard hearing the whole list at once, after a reload,
// orders it as it was marked.
export function attentionOrder(marks) {
    const latest = new Map();
    const mark = (address, at) => latest.set(address, Math.max(latest.get(address) ?? 0, at ?? 0));
    for (const address of marks.guard) {
        mark(address, marks.guardAt?.[address]);
    }
    for (const note of Object.values(marks.notes)) {
        for (const address of [...note.wide, ...note.direct]) {
            mark(address, note.at?.[address]);
        }
    }
    return [...latest.keys()].sort((a, b) => latest.get(a) - latest.get(b));
}

// Which windows are marked: Hyprland's urgent flag, plus `marks`, but
// never a muted app's (`muted`, SPEC.md §9, Muted apps). `marks` holds none
// of those, since updateMarks never records one; the urgent flag is
// Hyprland's, so it's left out here.
export function markedWindows({ windows, marks = NO_MARKS, muted = [] }) {
    const marked = new Set([].concat(marks.guard, ...Object.values(marks.notes).map((n) => n.wide.concat(n.direct))));
    for (const w of windows) {
        if (w.urgent === true) {
            marked.add(w.address);
        }
    }
    // A mark for a window that has since closed isn't on the bar.
    const open = new Set(windows.filter((w) => !windowMuted(w.app, muted)).map((w) => w.address));
    return new Set([...marked].filter((a) => open.has(a)));
}

// The icons one workspace shows (§7.2): only its windows wanting
// attention, those markedWindows gives, in window order, at most MAX_ICONS
// and then "+n". An ordinary window has no icon on the bar. A minimized
// one's `restoreTo` names the workspace a click puts it back on (§6.7);
// any other's is null.
function icons(windows, marked) {
    const wanting = windows.filter((w) => marked.has(w.address));
    const shown = wanting.slice(0, MAX_ICONS)
        .map((w) => ({ address: w.address, app: w.app, marked: true, restoreTo: minimizedFrom(w.workspaceName) }));
    return { icons: shown, more: wanting.length - shown.length };
}

// The bar's workspaces in its order (§6.5, §7.1): the standing ones as
// `standing` lists them, the first being home, whether Hyprland has them
// yet or not; then the rest, named ones in the order they were made, which
// is their falling IDs, and any numbered one (a second monitor's, before
// anything names it) after them by number. `workspaces` is Hyprland's,
// [{id, name}]; special workspaces aren't on the bar. Each is
// {id, ids, name, standing, home}, id being null for a standing one that
// isn't made yet. A standing name matches a workspace's without case, as
// one typed at the prompt does, so `In` made by hand is still home's place.
//
// A workspace spanning several monitors has a Hyprland workspace for each
// monitor's part, NAME@OUT on all but the main one (span.mjs, SPEC.md
// §6.5, Monitors). The bar lists it once: `ids` are all its parts' IDs,
// and `id` is the main part's, or the part made first (the highest ID)
// while it has none. It takes its place in the order from its oldest part
// (the highest ID), so a main part made again when you go back, with a
// newer ID, doesn't move it.
export function workspaceOrder(workspaces, standing) {
    const byName = new Map();
    for (const w of workspaces) {
        const raw = String(w.name ?? "");
        if (!Number.isInteger(w.id) || raw.startsWith("special:")) {
            continue;
        }
        const name = workspaceOf(raw);
        const main = raw === name;
        const ws = byName.get(name);
        if (!ws) {
            byName.set(name, { id: w.id, ids: [w.id], name, main, order: w.id });
            continue;
        }
        ws.ids.push(w.id);
        ws.order = Math.max(ws.order, w.id);
        if ((main && !ws.main) || (main === ws.main && w.id > ws.id)) {
            ws.id = w.id;
            ws.main = main;
        }
    }
    const real = [...byName.values()];
    const taken = new Set();
    const out = [];
    standing.forEach((name, i) => {
        const exact = real.find((w) => w.name === name && !taken.has(w.id));
        const found = exact ?? real.find((w) => sameName(w.name, name) && !taken.has(w.id));
        if (found) {
            taken.add(found.id);
        }
        out.push({
            id: found ? found.id : null,
            ids: found ? found.ids : [],
            name: found ? found.name : name,
            standing: true,
            home: i === 0,
        });
    });
    const rest = real.filter((w) => !taken.has(w.id));
    const named = rest.filter((w) => w.order < 0).sort((a, b) => b.order - a.order);
    const numbered = rest.filter((w) => w.order > 0).sort((a, b) => a.order - b.order);
    for (const w of named.concat(numbered)) {
        out.push({ id: w.id, ids: w.ids, name: String(w.name || w.id), standing: false, home: false });
    }
    return out;
}

// A name as the bar shows it: cut with an ellipsis past BAR_NAME
// characters, never inside one.
export function barName(name) {
    const chars = [...String(name ?? "")];
    return chars.length > BAR_NAME ? chars.slice(0, BAR_NAME - 1).join("") + "…" : chars.join("");
}

// What one monitor's bar shows: every workspace in workspaceOrder's order,
// each as
//
//   {id, ids, name, label, standing, home, state, urgent, big, count, app,
//    icons: [{address, app, marked, restoreTo}], more}
//
// where ids are its parts' IDs (workspaceOrder); label is the name as the
// bar shows it (barName); state is "current" (this monitor's workspace, or
// its part of one spanning monitors), "elsewhere" (shown on another monitor
// only, as when workspaces don't span them), "occupied" or "empty", which a standing workspace not made yet
// always is; urgent is any marked window on it; big is a maximized or
// fullscreen window on it (§6.3); count is how many windows it has, and
// app the first one's app, for the switcher's Workspaces tab; and icons
// are its marked windows' alone, which is all the bar shows (icons).
//
// `monitors` is [{name, workspace}], each monitor's active workspace ID.
// `workspaces` is Hyprland's, [{id, name}], and `standing` the standing
// names. `windows` is [{address, workspace, workspaceName, app, urgent,
// fullscreen}] in the order their icons should appear, workspace being its
// ID and workspaceName its name, which says whether it's minimized and from
// where (minimized.mjs), fullscreen
// being the client's `fullscreen` state from `hyprctl clients` (0 none, 1
// maximized, 2 fullscreen, 3 both), not the 0/1 argument the `fullscreen`
// dispatcher takes (SPEC.md §6.3). `marks` comes from updateMarks, and
// `muted` is the muted list, whose apps' windows are never marked.
export function barWorkspaces({ monitor, monitors, workspaces, windows, marks = NO_MARKS, standing = [], muted = [] }) {
    const current = monitors.find((m) => m.name === monitor)?.workspace;
    const elsewhere = new Set(monitors.filter((m) => m.name !== monitor).map((m) => m.workspace));
    const marked = markedWindows({ windows, marks, muted });
    return workspaceOrder(workspaces, standing).map((ws) => {
        const here = windows.filter((w) => ws.ids.includes(w.workspace));
        // Its minimized windows are on a special workspace, but one wanting
        // attention still shows here (§6.7), made or not.
        const minimized = windows.filter((w) => isMinimizedFrom(w.workspaceName, ws.name));
        let state = here.length > 0 ? "occupied" : "empty";
        if (ws.ids.includes(current)) {
            state = "current";
        } else if (ws.ids.some((id) => elsewhere.has(id))) {
            state = "elsewhere";
        }
        return Object.assign({
            id: ws.id,
            ids: ws.ids,
            name: ws.name,
            label: barName(ws.name),
            standing: ws.standing,
            home: ws.home,
            state,
            urgent: here.concat(minimized).some((w) => marked.has(w.address)),
            big: here.some((w) => w.fullscreen > 0),
            count: here.length,
            app: here.length > 0 ? here[0].app : "",
        }, icons(here.concat(minimized), marked));
    });
}

// The name of the workspace `notches` of scrolling over the bar go to from
// the one with ID `current`, in the bar's order (`list`, from
// barWorkspaces or workspaceOrder): one step per notch, toward the next
// for a positive count and the previous for a negative one, stopping at
// either end as Super+PgUp/PgDn do. null means stay: no whole notch,
// already at the end, or on a workspace the bar doesn't list (a special
// one), which has no neighbors.
export function scrollTarget(list, current, notches) {
    const steps = Math.trunc(notches);
    const i = list.findIndex((w) => (w.ids ?? (w.id === null ? [] : [w.id])).includes(current));
    if (i < 0 || !steps) {
        return null;
    }
    const target = Math.min(list.length - 1, Math.max(0, i + steps));
    return target === i ? null : list[target].name;
}

// What a workspace event on Hyprland's socket says, or null for any other
// event: {type: "created" | "destroyed" | "renamed", id, name}. A name
// may hold a comma, so the ID runs to the first one and the name is the
// rest (§6.5).
export function workspaceEvent(name, data) {
    const types = { createworkspacev2: "created", destroyworkspacev2: "destroyed", renameworkspace: "renamed" };
    const type = types[name];
    if (type === undefined) {
        return null;
    }
    const text = String(data ?? "");
    const comma = text.indexOf(",");
    if (comma < 0 || !/^-?\d+$/.test(text.slice(0, comma))) {
        return null;
    }
    return { type, id: Number(text.slice(0, comma)), name: text.slice(comma + 1) };
}

// The home workspace's ID after `event` (workspaceEvent), from `id`, the
// one before (null while it isn't made): a workspace made under home's
// name is home, and home destroyed is gone. A rename doesn't move it: the
// shell renames it back (homeRenamed).
export function homeIdAfter(id, event, home) {
    if (event === null) {
        return id;
    }
    if (event.type === "created" && event.name === home) {
        return event.id;
    }
    if (event.type === "destroyed" && event.id === id) {
        return null;
    }
    return id;
}

// Whether `event` renamed the home workspace (ID `id`) away from `home`,
// which the shell undoes: home can't be renamed (§6.5).
export function homeRenamed(id, event, home) {
    return event !== null && event.type === "renamed" && id !== null && event.id === id && event.name !== home;
}
