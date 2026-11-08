// tidewm's windows (its docs/ipc.md), for TidewmData.qml: the windows its
// GET_TREE lists, kept up to date by its window events, and the shape the
// shell takes from Hyprland's toplevels (Compositor.qml's windows). Pure
// functions over plain data, so they're tested here.
//
// The state is {list, order}: `list` is tidewm's containers, by its order
// of appearing, and `order` their IDs, most recently focused first, which
// tidewm doesn't give, so it's kept from focus events. Hyprland's
// focusHistoryID is a window's place in it.

import { tidewmName } from "./compositor.mjs";
import { minimizedWorkspace } from "./minimized.mjs";
import { DEFAULT_LAYOUTS, defaultMode, layoutSymbol } from "./layouts.mjs";

export const NO_WINDOWS = Object.freeze({ list: Object.freeze([]), order: Object.freeze([]) });

function parsed(data) {
    if (typeof data !== "string") {
        return data ?? null;
    }
    try {
        return JSON.parse(data);
    } catch (e) {
        return null;
    }
}

function isWindow(node) {
    return node !== null && typeof node === "object" && Number.isInteger(node.id)
        && (node.type === "con" || node.type === "floating_con");
}

// The windows in GET_TREE's reply, its JSON or already parsed, with the
// focused one first in the order: tidewm gives nothing of what came
// before. null for a reply that isn't a tree.
export function treeWindows(tree) {
    const root = parsed(tree);
    if (root === null || typeof root !== "object" || Array.isArray(root)) {
        return null;
    }
    const list = [];
    const walk = node => {
        if (node === null || typeof node !== "object") {
            return;
        }
        if (isWindow(node)) {
            list.push(node);
        }
        for (const child of [].concat(node.nodes ?? [], node.floating_nodes ?? [])) {
            walk(child);
        }
    };
    walk(root);
    const focused = list.find(c => c.focused === true);
    return { list, order: focused ? [focused.id] : [] };
}

// The state a tree asked for again (treeWindows) makes of `before`: the
// tree's windows, in the order they were focused as far as the shell
// knows, so a refresh keeps the focus history of every window still there,
// with the tree's focused window first. null for a tree that wasn't one.
export function refreshed(before, tree) {
    const next = treeWindows(tree);
    if (next === null) {
        return null;
    }
    const ids = new Set(next.list.map(c => c.id));
    const kept = before.order.filter(id => ids.has(id));
    const order = next.order.length > 0 ? next.order.concat(kept.filter(id => id !== next.order[0])) : kept;
    return { list: next.list, order };
}

// The state after a window event, its JSON or already parsed: a new window
// joins the list, a closed one leaves it and the order, a focused one goes
// first in the order, and any other change takes the container as the
// event gives it, whole. An event for a window the list doesn't have adds
// it, so one heard before the tree it's in, and replayed on it, changes
// nothing. What isn't a window event leaves the state as it was.
export function windowEvent(state, data) {
    const event = parsed(data);
    const con = event?.container;
    if (typeof event?.change !== "string" || !isWindow(con)) {
        return state;
    }
    if (event.change === "close") {
        return {
            list: state.list.filter(c => c.id !== con.id),
            order: state.order.filter(id => id !== con.id),
        };
    }
    const at = state.list.findIndex(c => c.id === con.id);
    let list = at < 0 ? state.list.concat([con]) : state.list.map((c, i) => (i === at ? con : c));
    let order = state.order;
    if (event.change === "focus") {
        // Only one window has focus; the others' containers still say
        // they did, until their own events.
        list = list.map(c => (c.id !== con.id && c.focused ? Object.assign({}, c, { focused: false }) : c));
        order = [con.id].concat(order.filter(id => id !== con.id));
    }
    return { list, order };
}

// Whether an event, of `type` ("tick", "workspace" or "window") and its
// JSON, calls for the tree again: the listener's first tick, which says it
// has connected, so its picture starts afresh; or a workspace renamed,
// since every container holds its workspace's name, and tidewm sends no
// window event for one renamed under it.
export function asksForTree(type, data) {
    const event = parsed(data);
    if (type === "tick") {
        return event?.first === true;
    }
    return type === "workspace" && event?.change === "rename";
}

// The mark events (workspaces.mjs's updateMarks) a window event means, as
// workspaces.mjs's markEvent reads Hyprland's: a window focused or
// closed, and one tidewm marks urgent, which is its focus guard
// holding the window, as Hyprland's tide-attention says, or the window
// asking for focus. tidewm doesn't tell the two apart, so it's "guarded"
// either way: its mark lasts until the window is focused. [] for any
// other event, and for urgency taken away, which focusing the window
// does and which clears the mark anyway.
export function markEvents(data) {
    const event = parsed(data);
    const con = event?.container;
    if (typeof event?.change !== "string" || !isWindow(con)) {
        return [];
    }
    const address = String(con.id);
    switch (event.change) {
    case "focus":
        return [{ type: "focused", address }];
    case "close":
        return [{ type: "closed", address }];
    case "urgent":
        return con.urgent === true ? [{ type: "guarded", address }] : [];
    default:
        return [];
    }
}

// Whether a binding event, its JSON or already parsed, is one of conf's
// float keys (SPEC.md §6.4): a config binding whose commands toggle or
// enable floating on the focused window, as tidewm runs them, each at a
// ; outside double quotes. tidewm sends it before it runs the command, so
// the window's floating event, if the window floats, comes next
// (keyFloated).
export function bindingFloats(data) {
    const event = parsed(data);
    const command = event?.change === "run" ? event.binding?.command : null;
    if (typeof command !== "string") {
        return false;
    }
    const commands = [];
    let current = "";
    let quoted = false;
    for (const c of command) {
        if (c === '"') {
            quoted = !quoted;
        } else if (c === ";" && !quoted) {
            commands.push(current);
            current = "";
            continue;
        }
        current += c;
    }
    commands.push(current);
    return commands.some(c => /^\s*floating\s+(toggle|enable)\s*$/i.test(c));
}

// The window a float key floated, by a window event that came after a
// float key's binding (`armed`, bindingFloats): {address, class, title},
// as FloatingData asks about one, when the event is the focused window's
// `floating` with it floating now, or null.
// Any window event after the binding settles it, so a float key that
// floated nothing, as on a fullscreen window, leaves no later floating
// event, as a rule's or the shell's own, to be taken for it.
export function keyFloated(armed, data) {
    const event = parsed(data);
    const con = event?.container;
    if (!armed || event?.change !== "floating" || !isWindow(con) || con.type !== "floating_con" || con.focused !== true) {
        return null;
    }
    return { address: String(con.id), class: appOf(con), title: con.name ?? "" };
}

// A window's app: its Wayland app ID, or an X11 window's class.
export function appOf(con) {
    return con?.app_id || con?.window_properties?.class || "";
}

// What a window event, its JSON or already parsed, means to the name
// prompt (PromptData.qml), as Hyprland's openwindow, closewindow and
// activewindowv2 do: {change, address, client}, `change` "new", "close"
// or "focus", `address` the container ID as a string, and `client` the
// window as workspacenames.mjs's promptWanted reads Hyprland's clients,
// {class, title, workspace: {name}, floating}, since the event carries
// it and there's nothing to look up. null for any other event.
export function promptEvent(data) {
    const event = parsed(data);
    const con = event?.container;
    if (!["new", "close", "focus"].includes(event?.change) || !isWindow(con)) {
        return null;
    }
    return {
        change: event.change,
        address: String(con.id),
        client: {
            class: appOf(con),
            title: con.name ?? "",
            workspace: { name: typeof con.workspace === "string" ? con.workspace : "" },
            floating: con.type === "floating_con",
        },
    };
}

// What a window event, its JSON or already parsed, means to home's apps
// (WorkspacesData.qml): {change, address, app, workspace} for a window
// opened ("new") or closed, `workspace` its workspace's name or "" when
// the event doesn't say; null for any other event.
export function homeEvent(data) {
    const event = parsed(data);
    const c = event?.container;
    if (!["new", "close"].includes(event?.change) || !isWindow(c)) {
        return null;
    }
    return { change: event.change, address: String(c.id), app: appOf(c), workspace: typeof c.workspace === "string" ? c.workspace : "" };
}

// The windows as Compositor.qml gives Hyprland's: [{address, title, app,
// workspace, workspaceName, monitor, urgent, fullscreen, floating,
// focusHistoryID}]. `address` is tidewm's container ID, as a string, which
// the shell only compares and hands back. `workspace` is the ID of the
// workspace in `workspaces` ([{id, name}], Compositor.workspaces) of its
// name, or null. A window tidewm has minimized is on no workspace, and its
// workspaceName is the minimize workspace Hyprland's would be on
// (minimized.mjs), which is all the shell reads to know it's minimized and
// from where. `fullscreen` is as Hyprland gives it, 0 none, 1
// maximized, 2 fullscreen, 3 both. `focusHistoryID` is its place in the
// order, 0 the focused window, or -1 for one never focused since the
// shell started, as Hyprland's -1.
export function shellWindows(state, workspaces) {
    const ids = new Map(Array.from(workspaces ?? []).map(w => [w.name, w.id]));
    return state.list.map(c => {
        const name = typeof c.workspace === "string" ? c.workspace : "";
        const minimized = c.minimized === true && name !== "";
        return {
            address: String(c.id),
            title: c.name ?? "",
            app: appOf(c),
            workspace: !minimized && ids.has(name) ? ids.get(name) : null,
            workspaceName: minimized ? minimizedWorkspace(name) : name,
            monitor: c.output ?? "",
            urgent: c.urgent === true,
            fullscreen: (c.fullscreen_mode ? 2 : 0) + (c.maximized ? 1 : 0),
            floating: c.type === "floating_con",
            focusHistoryID: state.order.indexOf(c.id),
            // ext-foreign-toplevel-list's, which xdg-desktop-portal-wlr
            // names a window it can share by (SharePicker.qml).
            identifier: typeof c.foreign_toplevel_identifier === "string" ? c.foreign_toplevel_identifier : "",
            // tidewm's own keep_open: kill leaves it open (keepOpenCommand).
            keepOpen: c.keep_open === true,
        };
    });
}

// The focused window of `windows` (shellWindows), or null: the one first
// in the order, while it's on the current workspace, named `current`,
// which every monitor shows. tidewm says nothing of a window losing focus
// to an empty workspace, but that's a workspace focus event, and the
// window is then elsewhere.
export function activeWindow(windows, current) {
    const first = windows.find(w => w.focusHistoryID === 0);
    return first && first.workspaceName === current ? first : null;
}

// Commands for one window, by its address (container ID): focusing it,
// which shows its workspace, and brings it back if it's minimized; moving
// it to the workspace named `name` and focusing it there; asking it to
// close, as Super+Backspace does; minimizing it; and toggling its
// maximize. null for an address that isn't a container ID,
// or a name tidewm can't take.
function con(address) {
    const s = String(address ?? "");
    return /^[0-9]+$/.test(s) ? `[con_id=${s}]` : null;
}

// Moving the window at `address` to the workspace named `name` without
// following it: a home app's window sent home as it opens.
export function sendCommand(address, name) {
    const c = con(address);
    const n = tidewmName(name);
    return c === null || n === null ? null : `${c} move to workspace number ${n}`;
}

export function focusCommand(address) {
    const c = con(address);
    return c === null ? null : `${c} focus`;
}

export function moveAndFocusCommand(address, name) {
    const c = con(address);
    const n = tidewmName(name);
    return c === null || n === null ? null : `${c} move to workspace number ${n}; ${c} focus`;
}

export function closeCommand(address) {
    const c = con(address);
    return c === null ? null : `${c} kill`;
}

export function floatCommand(address) {
    const c = con(address);
    return c === null ? null : `${c} floating enable`;
}

export function minimizeCommand(address) {
    const c = con(address);
    return c === null ? null : `${c} minimize enable`;
}

// Sending the window at `address` the shortcut `mods` + `key`, as
// dispatch.mjs's sendShortcut takes them, Hyprland's spelling, "CTRL
// SHIFT" and "V": tidewm's own send_shortcut, the picker's paste (SPEC.md
// §8.4).
export function shortcutCommand(address, mods, key) {
    const c = con(address);
    if (!/^[A-Z]+( [A-Z]+)*$/.test(String(mods ?? ""))) {
        throw new Error(`not modifiers: ${mods}`);
    }
    if (!/^[A-Za-z0-9]+$/.test(String(key ?? ""))) {
        throw new Error(`not a key: ${key}`);
    }
    return c === null ? null : `${c} send_shortcut ${[...mods.split(" "), key].join("+").toLowerCase()}`;
}

export function maximizeCommand(address) {
    const c = con(address);
    return c === null ? null : `${c} maximize toggle`;
}

// The command that has tidewm keep open the windows pinned where they are
// (SPEC.md §6.5), and no others: `[con_id=N] keep_open enable` or
// `disable` for each of `windows` (shellWindows) whose keepOpen isn't
// yet what `pinned(window)` says, joined with "; ", or "" for none.
// tidewm's `keep_open` window event says each change, which puts the
// window as it now is.
export function keepOpenCommand(windows, pinned) {
    const commands = [];
    for (const w of windows ?? []) {
        const c = con(w?.address);
        const want = c !== null && pinned(w) === true;
        if (c !== null && want !== (w.keepOpen === true)) {
            commands.push(`${c} keep_open ${want ? "enable" : "disable"}`);
        }
    }
    return commands.join("; ");
}

// The window, its address, that a close_refused event says tidewm left
// open, as it's kept open (a pinned window's Super+Backspace, or its
// app's close keys); null for any other event.
export function closeRefused(data) {
    const event = parsed(data);
    return event?.change === "close_refused" && isWindow(event.container) ? String(event.container.id) : null;
}

// The bar's layout symbol (SPEC.md §6.1, §7.1) on tidewm, which keeps a
// layout for each workspace's part on each monitor and says it in its
// own layout event, for a monitor as its part changes layout or the
// current workspace changes. What's heard is {OUTPUT: {workspace,
// layout}}, the last event for each output. The event's own symbol
// isn't kept: monocle's `[n]` in it is stale once a window opens or
// closes, which sends no layout event.

// `heard` with the layout event in `data`, its JSON or already parsed;
// `heard` itself for anything else.
export function heardLayout(heard, data) {
    const event = parsed(data);
    if (event?.change !== "layout" || typeof event.output !== "string" || event.output === ""
        || typeof event.workspace !== "string" || typeof event.layout !== "string") {
        return heard;
    }
    return Object.assign({}, heard, { [event.output]: { workspace: event.workspace, layout: event.layout } });
}

// config.h's symbol for tidewm's floating layout, which Hyprland's tide
// has no mode for.
const FLOATING_SYMBOL = "><>";

// What the bar on `output` (its GET_OUTPUTS object) shows for the
// current workspace, `current` (its GET_WORKSPACES object), with `tiled`
// tiled windows on its part: the layout tidewm last said for it, or
// until it says, as after the shell restarts, GET_WORKSPACES' `layout`
// on the focused monitor, which is that one's part, and on another the
// layout tidewm starts a part in for its shape, by `layouts` (the
// Layouts page's settings in effect, which tidewm reads too). That
// shape is GET_OUTPUTS' `rect`, already rotated, and all of it, as
// tidewm judges it. "" before there's an output or a current workspace.
export function barSymbol({ heard, output, current, tiled, layouts = DEFAULT_LAYOUTS }) {
    if (!output || typeof output.name !== "string" || !current || typeof current.name !== "string") {
        return "";
    }
    const said = heard?.[output.name];
    let layout;
    if (said && said.workspace === current.name) {
        layout = said.layout;
    } else if (output.focused === true && typeof current.layout === "string") {
        layout = current.layout;
    } else {
        layout = defaultMode({ width: output.rect?.width ?? 0, height: output.rect?.height ?? 0 }, 0, layouts);
    }
    return layout === "floating" ? FLOATING_SYMBOL : layoutSymbol(layout, tiled);
}

// How many of `windows` (shellWindows) are tiled on `output`'s part of
// the workspace named `workspace`: not floating, and not minimized,
// which leaves them on no workspace.
export function tiledOn(windows, workspace, output) {
    return Array.from(windows ?? []).filter(w => w.workspace !== null && w.workspaceName === workspace
        && w.monitor === output && !w.floating).length;
}
