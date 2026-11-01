// Minimized windows (SPEC.md §6.7), as pure functions the QML binds to.
// Hyprland has no minimize, so a minimized window lives on a special
// workspace named after the workspace it came from. Only tide puts windows
// there, so that name is the whole of the state: a restarted shell reads
// it back from Hyprland.

import { sameName } from "./workspacenames.mjs";
import { workspaceOf } from "./span.mjs";

// The start of a minimize workspace's name; the rest is the workspace the
// window came from.
export const PREFIX = "special:minimized:";

// The special workspace a window minimized from workspace `name` goes to.
export function minimizedWorkspace(name) {
    return PREFIX + name;
}

// The workspace a window on workspace `workspaceName` was minimized from,
// or null when that isn't a minimize workspace, so the window isn't
// minimized.
export function minimizedFrom(workspaceName) {
    const s = String(workspaceName ?? "");
    return s.startsWith(PREFIX) && s.length > PREFIX.length ? s.slice(PREFIX.length) : null;
}

// Whether a window on workspace `workspaceName` was minimized from the
// workspace named `name`. Names match ignoring case, as the bar matches a
// standing workspace to the one made under it (workspaces.mjs's
// workspaceOrder), so a window minimized from `Re` belongs to standing `re`.
export function isMinimizedFrom(workspaceName, name) {
    const from = minimizedFrom(workspaceName);
    return from !== null && sameName(from, name);
}

// The same, with any monitor's part of workspace `name` counting as it
// (span.mjs, SPEC.md §6.5, Monitors): whether the bar shows the window
// with workspace `name`. A tray (trayWindows) shows only its own part's.
export function isMinimizedFromWorkspace(workspaceName, name) {
    const from = minimizedFrom(workspaceName);
    return from !== null && sameName(workspaceOf(from), name);
}

// What Super+Z does with the focused window, `active` being
// {address, workspace (its name)}, or null with none: {name}, the workspace
// to minimize it from, or {error} saying why it stays. A window on a
// special workspace, a minimized one included, isn't on the layout, so
// there's nothing to minimize it from.
export function minimizeFrom(active) {
    if (!active || !active.address) {
        return { error: "no window to minimize" };
    }
    const name = String(active.workspace ?? "");
    if (name === "") {
        return { error: "the window is on no workspace" };
    }
    if (name.startsWith("special:")) {
        return { error: minimizedFrom(name) !== null ? "the window is minimized already" : "the window is on a special workspace" };
    }
    return { name };
}

// One monitor's tray: the windows minimized from `workspace`, the name of
// the workspace that monitor shows, as [{address, app, title}], in the
// order they were last used, the latest last, which the tray draws
// nearest the corner. `windows` is [{address, app, title, workspace (its
// name), focus}], focus being workspaces.mjs's focusRank, lower more
// recent; ties keep the windows' order.
export function trayWindows(windows, workspace) {
    if (!workspace) {
        return [];
    }
    return windows.map((w, i) => ({ w, i }))
        .filter((x) => isMinimizedFrom(x.w.workspace, workspace))
        .sort((a, b) => ((b.w.focus ?? Infinity) - (a.w.focus ?? Infinity)) || (a.i - b.i))
        .map((x) => ({ address: x.w.address, app: x.w.app, title: x.w.title || x.w.app || "Untitled" }));
}
