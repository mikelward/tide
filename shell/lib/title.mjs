// The window title in the middle of the bar (SPEC.md §7.1), as a pure
// function the QML binds to. Only the focused window gets a title, on its
// own monitor's bar: the title names where typing goes.

import { normalizeAddress } from "./workspaces.mjs";

// The title is at most about this many characters wide, as waybar's
// max-length had it. The QML caps its width at this many average
// characters and elides the rest, so Qt cuts only between whole
// characters in any script.
export const MAX_TITLE = 60;

// The window the bar on `monitor` (its name) stands for, as
// {address, title}: the focused window when it's on this monitor, wherever
// on it (under an open special workspace, or pinned), else null. Every
// other monitor's bar is blank. `active` is {monitor, address, title}, or
// null when nothing has focus (see hasFocus).
export function barWindow({ monitor, active }) {
    if (!active || monitor == null || active.monitor !== monitor) {
        return null;
    }
    const address = normalizeAddress(active.address);
    return address === null ? null : { address, title: oneLine(active.title) };
}

// The address of the window that has focus, from `hyprctl activewindow -j`
// when the shell starts: Quickshell 0.3 sets its active toplevel only on
// the next activewindowv2 event, so until one arrives this is what has
// focus. Hyprland answers `{}` when nothing has focus, which gives null;
// so does output that isn't JSON, which gives undefined so the caller can
// say the read failed.
export function activeAtStart(text) {
    let window;
    try {
        window = JSON.parse(text);
    } catch (e) {
        // The caller reports it: undefined says the read failed.
        return undefined;
    }
    return normalizeAddress(window?.address);
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
