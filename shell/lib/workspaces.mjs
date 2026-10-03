// The bar's workspaces (SPEC.md §6.5, §7.2, §14.4), as pure functions the
// QML binds to. The QML turns Quickshell.Hyprland's monitors and toplevels
// into the plain objects these take, and maps app IDs to icons.

export const FIRST = 1;
export const LAST = 9;
// Icons shown per workspace before the rest collapse into "+n".
export const MAX_ICONS = 5;

// Attention marks (§14.4), kept as events arrive. A snapshot can't say
// which came first or what was on screen when a notification arrived, so
// the QML feeds Hyprland's and the notification daemon's events through
// updateMarks and hands the result to barWorkspaces. The state is
//
//   {guard: [address], guardAt, notes: {id: {app, wide: [address], direct: [address], at}}, cycling}
//
// where `guard` holds the windows the focus guard kept from focus, and
// `notes` each notification's marks by its ID, so dismissing one clears
// exactly what it marked. A note's `wide` windows came from marking its
// whole app and `direct` ones from naming the window; only the app's own
// activation tells them apart. `guardAt` and each note's `at` say when each
// window was last marked ({address: n}, larger is later, one clock for
// both), so Super+Tab's order comes from the marks still standing
// (attentionOrder). Hyprland's own urgent flag lives on the window.
export const NO_MARKS = Object.freeze({ guard: Object.freeze([]), guardAt: Object.freeze({}), notes: Object.freeze({}), cycling: false });

// The marks after one event, without changing `marks`. Events:
//
//   {type: "notified", id, app, windows, visible}  an app-wide mark: the
//       app's windows on workspaces not on screen right now (`visible` is a
//       Set of workspace IDs), and only those, until it clears. A
//       replacement (the same ID again) keeps what it marked before.
//   {type: "notified", id, app, address, windows, visible}  a notification
//       naming its window: marked only if that window's workspace isn't on
//       screen, like an app-wide mark.
//   Either may name `replaces`, the ID of a notification it took the place
//       of under another ID (Chrome's per-conversation sync key): it takes
//       over that one's marks, as a replacement under the same ID would.
//   {type: "guarded", address}   the focus guard kept a new window from focus.
//   {type: "activated", app}     urgent>>ADDRESS: the app's own activation
//       replaces its app-wide marks (activatedEvent).
//
// A notification's `app` is the desktop entry or app name it gave
// (notifications.mjs's grantId), matched to window classes by sameApp.
//   {type: "focused", address}   the window was attended to: the guard's
//       mark on it clears, and so does every notification's that covered it.
//   {type: "dismissed", id}      the notification was dismissed.
//   {type: "closed", address}    the window is gone.
//   {type: "cycleStart"}         Super+Tab started stepping through the
//       marked windows: focusing one doesn't clear anything (`cycling`)...
//   {type: "cycleEnd", address}  ...until Super is released, which clears
//       only the window the cycle landed on (null for none).
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
    if (event.type === "cycleStart") {
        return Object.assign({}, marks, { cycling: true });
    }
    if (event.type === "cycleEnd") {
        const ended = Object.assign({}, marks, { cycling: false });
        return event.address ? updateMarks(ended, { type: "focused", address: event.address }) : ended;
    }
    if (event.type === "focused" && marks.cycling) {
        return marks;
    }
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
        // It keeps what it marked before, under the app it names now.
        const note = Object.assign({ wide: [], direct: [], at: {} }, notes[event.id] ?? notes[event.replaces], { app: event.app });
        delete notes[event.id];
        delete notes[event.replaces];
        const stamped = (addresses) => Object.assign({}, note.at, fromEntries(addresses.map((a) => [a, now])));
        if (event.address !== undefined) {
            const named = event.windows.find((w) => w.address === event.address);
            const hidden = named !== undefined && !event.visible.has(named.workspace);
            put(event.id, hidden
                ? Object.assign({}, note, { direct: [...new Set([...note.direct, event.address])], at: stamped([event.address]) })
                : note);
        } else {
            const hidden = event.windows
                .filter((w) => sameApp(w.app, event.app) && !event.visible.has(w.workspace))
                .map((w) => w.address);
            put(event.id, Object.assign({}, note, { wide: [...new Set([...note.wide, ...hidden])], at: stamped(hidden) }));
        }
        break;
    }
    case "guarded":
        Object.assign(notes, marks.notes);
        // Announced again, it's the newest.
        guard = [...without(guard, event.address), event.address];
        guardAt = Object.assign({}, guardAt, { [event.address]: now });
        break;
    case "activated":
        for (const [id, note] of Object.entries(marks.notes)) {
            put(id, sameApp(note.app, event.app) ? Object.assign({}, note, { wide: [] }) : note);
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
    // A rebuilt guard has no cycle running.
    return { guard, guardAt, notes, cycling: event.type !== "guardReset" && (marks.cycling ?? false) };
}

// Whether a window class and a notification's app name the same app, as
// the focus guard matches them (hypr/tide/focus.lua's same_id):
// case-insensitively, without a `.desktop` suffix, and with a bare name
// matching the last part of a qualified one, so `nautilus` matches
// `org.gnome.Nautilus`, while `org.example.chat` and `com.example.chat`
// stay apart.
export function sameApp(a, b) {
    const norm = (id) => String(id ?? "").toLowerCase().replace(/\.desktop$/, "");
    const x = norm(a);
    const y = norm(b);
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

// The mark event a Hyprland socket event means, or null: the focus guard
// keeping a window from focus (custom>>tide-attention>>ADDRESS,
// SPEC.md §14.3), a window being focused, one closing, a window asking for
// focus (`urgent`, which the QML turns into activatedEvent once it knows
// the window's app), Super+Tab's cycle starting or ending
// (custom>>tide-cycle>>start, custom>>tide-cycle>>end>>ADDRESS),
// or a config reload rebuilding the guard.
// Notifications' events come from the notification server instead.
export function markEvent(name, data) {
    if (name === "configreloaded") {
        return { type: "guardReset" };
    }
    if (name === "custom" && String(data) === "tide-cycle>>start") {
        return { type: "cycleStart" };
    }
    if (name === "custom" && String(data).startsWith("tide-cycle>>end>>")) {
        return { type: "cycleEnd", address: normalizeAddress(String(data).slice("tide-cycle>>end>>".length)) };
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
// guard's Super+Tab (tide_focus.set_order): the guard's own and
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

// Which windows are marked: Hyprland's urgent flag, plus `marks`.
export function markedWindows({ windows, marks = NO_MARKS }) {
    const marked = new Set([].concat(marks.guard, ...Object.values(marks.notes).map((n) => n.wide.concat(n.direct))));
    for (const w of windows) {
        if (w.urgent === true) {
            marked.add(w.address);
        }
    }
    // A mark for a window that has since closed isn't on the bar.
    const open = new Set(windows.map((w) => w.address));
    return new Set([...marked].filter((a) => open.has(a)));
}

// The icons one workspace shows, in window order: at most MAX_ICONS, with
// marked windows kept in view ahead of unmarked ones, so a ringed icon is
// never folded into "+n".
function icons(windows, marked) {
    const keep = new Set();
    for (const w of windows) {
        if (keep.size < MAX_ICONS && marked.has(w.address)) {
            keep.add(w.address);
        }
    }
    for (const w of windows) {
        if (keep.size < MAX_ICONS) {
            keep.add(w.address);
        }
    }
    const shown = windows.filter((w) => keep.has(w.address))
        .map((w) => ({ address: w.address, app: w.app, marked: marked.has(w.address) }));
    return { icons: shown, more: windows.length - shown.length };
}

// What one monitor's bar shows: workspaces FIRST to LAST, always all nine
// (§7.1), each as
//
//   {id, state, urgent, big, icons: [{address, app, marked}], more}
//
// where state is "current" (this monitor's workspace), "elsewhere" (shown
// on another monitor), "occupied" or "empty"; urgent is any marked window
// on it; and big is a maximized or fullscreen window on it (§6.3).
//
// `monitors` is [{name, workspace}], each monitor's active workspace ID.
// `windows` is [{address, workspace, app, urgent, fullscreen}] in the order
// their icons should appear, fullscreen being the client's `fullscreen`
// state from `hyprctl clients` (0 none, 1 maximized, 2 fullscreen, 3 both),
// not the 0/1 argument the `fullscreen` dispatcher takes (SPEC.md §6.3). Special workspaces (negative IDs) and
// any outside FIRST..LAST aren't on the bar. `marks` comes from updateMarks.
export function barWorkspaces({ monitor, monitors, windows, marks = NO_MARKS }) {
    const current = monitors.find((m) => m.name === monitor)?.workspace;
    const elsewhere = new Set(monitors.filter((m) => m.name !== monitor).map((m) => m.workspace));
    const marked = markedWindows({ windows, marks });
    const list = [];
    for (let id = FIRST; id <= LAST; id++) {
        const here = windows.filter((w) => w.workspace === id);
        let state = here.length > 0 ? "occupied" : "empty";
        if (id === current) {
            state = "current";
        } else if (elsewhere.has(id)) {
            state = "elsewhere";
        }
        list.push(Object.assign({
            id,
            state,
            urgent: here.some((w) => marked.has(w.address)),
            big: here.some((w) => w.fullscreen > 0),
        }, icons(here, marked)));
    }
    return list;
}

// The workspace `notches` of scrolling over the bar go to from `current`:
// one step per notch, toward the next workspace for a positive count and
// the previous for a negative one, stopping at FIRST and LAST as
// Super+Left/Right do. null means stay: no whole notch, already at the end,
// or on a special workspace, which has no neighbors.
export function scrollTarget(current, notches) {
    const steps = Math.trunc(notches);
    if (!Number.isInteger(current) || current < FIRST || current > LAST || !steps) {
        return null;
    }
    const target = Math.min(LAST, Math.max(FIRST, current + steps));
    return target === current ? null : target;
}
