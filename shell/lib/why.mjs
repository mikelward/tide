// Why the workspace or the focused window changed (SPEC.md §5.4,
// Reporting a bug): one journal line for each, starting `tide why:`, which
// `tide report-bug` collects. The shell writes a line for each move it
// asks for, saying what asked (the bar, the switcher, a key), and one for
// each workspace it sees come up, and on tidewm each window it sees take
// focus, since tidewm's own reasons aren't tide's to log. Hyprland's focus
// guard and workspace keys write theirs from Lua (hypr/tide/focus.lua,
// hypr/hyprland.lua), with Hyprland's reason for each focus change.

export const PREFIX = "tide why:";

// One line, however `s` is spelled: a name or title with a line break in
// it would split the entry.
function oneLine(s) {
    return String(s ?? "").replace(/[\r\n]+/g, " ").trim();
}

// `tide why: WHAT: CAUSE`, or without a cause, `tide why: WHAT`.
export function line(what, cause) {
    const c = oneLine(cause);
    return `${PREFIX} ${oneLine(what)}${c === "" ? "" : `: ${c}`}`;
}

// The line for a workspace that has come up, or null when it hasn't
// changed or there's none (`name` "", as before the first one shows).
export function workspaceShown(before, name) {
    if (name === before || !name) {
        return null;
    }
    return line(`workspace ${name} shows`, "");
}

// The line for focus moving to `window` ({address, app}) or to nothing,
// from `before`, the window that had it or null; null when it hasn't
// moved. `workspace` is the workspace showing.
export function focusMoved(before, window, workspace) {
    const was = before ? before.address : null;
    const now = window ? window.address : null;
    if (was === now) {
        return null;
    }
    const where = workspace ? ` on ${workspace}` : "";
    if (!window) {
        return line(`no window has focus${where}`, "");
    }
    return line(`${window.app || "a window"} (${window.address}) has focus${where}`, "");
}
