// The window title in the middle of the bar (SPEC.md §7.1), as a pure
// function the QML binds to. Each monitor's bar shows its own workspace's
// window, as waybar's hyprland/window does with separate-outputs.

import { normalizeAddress } from "./workspaces.mjs";

// The title is at most about this many characters wide, as waybar's
// max-length had it. The QML caps its width at this many average
// characters and elides the rest, so Qt cuts only between whole
// characters in any script.
export const MAX_TITLE = 60;

// The workspace a monitor shows: its open special workspace (Hyprland's
// `specialWorkspace.id`, 0 when none), which covers the regular one, or
// else its active one. IDs, or null.
export function shownWorkspace(active, special) {
    return special ? special : active ?? null;
}

// The window the bar on `monitor` (its name) stands for, showing
// `workspace` (its ID, from shownWorkspace), as {address, title}:
//   - the focused window, when it's on this monitor: on the shown
//     workspace, under an open special one, or pinned;
//   - otherwise that workspace's last focused window (`lastWindow`, the
//     address Hyprland reports for it), if it's still there;
//   - otherwise null: an empty workspace, or one whose last window left.
// `active` is {monitor, address, title}, or null when nothing has focus
// (see hasFocus); `windows` are [{address, workspace, title}].
export function barWindow({ monitor, workspace, active, lastWindow, windows }) {
    if (workspace == null) {
        return null;
    }
    if (active && monitor != null && active.monitor === monitor) {
        return { address: normalizeAddress(active.address), title: oneLine(active.title) };
    }
    const address = normalizeAddress(lastWindow);
    const last = address === null ? null
        : windows.find(w => normalizeAddress(w.address) === address && w.workspace === workspace);
    return last ? { address, title: oneLine(last.title) } : null;
}

// That window's title, or nothing.
export function barTitle(data) {
    return barWindow(data)?.title ?? "";
}

// Whether an activewindowv2 event's data names a window. Hyprland sends an
// empty address when focus moves to an empty workspace, and Quickshell
// 0.3 ignores that event, leaving its active toplevel on the last window.
export function hasFocus(data) {
    return normalizeAddress(String(data ?? "").split(",")[0]) !== null;
}

// The title on one line, whitespace collapsed. It's not cut here: the QML
// elides it to its width.
function oneLine(title) {
    return String(title ?? "").replace(/\s+/g, " ").trim();
}

// How wide the bar's centered title may be: its own width, at most `max`,
// and no wider than twice the room between the bar's middle and the
// nearer of the left group's end (`left`) and the right group's start
// (`right`), less `gap`, so it stays centered. The right group starts at
// the first of the privacy pills, then the tray.
export function titleWidth({ implicit, max, barWidth, left, right, gap }) {
    const room = Math.min(barWidth / 2 - left, right - barWidth / 2);
    return Math.max(0, Math.min(implicit, max, 2 * room - gap));
}

// Below this much room, the centered title counts as squeezed.
export const MIN_TITLE_ROOM = 200;

// Whether the bar collapses its clocks to local alone (SPEC.md §7.3): when
// the room titleWidth would give the title with every clock showing is
// under MIN_TITLE_ROOM, and the right side is the short one. `right` is
// the right group's start as laid out now, with the clocks `clocksWidth`
// wide; `fullClocksWidth` is what every clock would take. The full
// layout's start is worked back from those, so the answer never depends
// on whether the clocks are collapsed now, and can't flip on its own result.
export function collapseClocks({ barWidth, left, right, gap, clocksWidth, fullClocksWidth }) {
    const fullRight = right + clocksWidth - fullClocksWidth;
    const leftRoom = barWidth / 2 - left;
    const rightRoom = fullRight - barWidth / 2;
    // Hiding clocks only helps when the right side is what's short.
    return rightRoom < leftRoom && 2 * rightRoom - gap < MIN_TITLE_ROOM;
}

// Whether an activewindowv2 event's data says the window at `address`
// (as barWindow gives it) now has focus. A double-click on another
// monitor's title focuses that window first, and maximizes it only once
// this says so: Quickshell sends each dispatch on its own socket, so a
// maximize sent straight after the focus could reach the window that had
// focus before.
export function focusReached(address, data) {
    const focused = normalizeAddress(String(data ?? "").split(",")[0]);
    return address != null && focused !== null && focused === normalizeAddress(address);
}
