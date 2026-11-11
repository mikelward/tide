// Which edge the bar runs along (SPEC.md §7.1), as what hangs from it or
// sits by it needs to know: popovers and tips open away from that edge,
// toward the windows; the notification center hangs from the bar's corner;
// and what sits at the bottom edge clears a bottom bar. Theme.qml binds to
// it.

import { BAR_CHOICES } from "./appearance.mjs";

// The edge of a bar item that its popovers and tips hang from, "bottom"
// under a top bar and "top" over a bottom one.
export function hangEdge(atBottom) {
    return atBottom ? "top" : "bottom";
}

// A PopupWindow's anchor margins that leave `gap` px between a bar item
// and what hangs from it, on the side it hangs from. Quickshell grows the
// anchor's rect by a negative margin, so the popup opens past it.
export function hangMargins(atBottom, gap) {
    return atBottom ? { top: -gap, bottom: 0 } : { top: 0, bottom: -gap };
}

// How far from the screen's bottom edge to put something that ignores
// exclusive zones (the OSD, the minimized tray) and was `margin` px up, so
// a bottom bar `barHeight` tall doesn't cover it.
export function aboveBar(atBottom, barHeight, margin) {
    return margin + (atBottom ? barHeight : 0);
}

// The index in BAR_CHOICES of where `settings` put the bar.
export function barChoiceAt(settings) {
    return Math.max(0, BAR_CHOICES.findIndex(c => c.position === settings.barPosition));
}

// The index `steps` steps through BAR_CHOICES from `at`, stopping at
// either end.
export function steppedBarChoice(at, steps) {
    return Math.max(0, Math.min(BAR_CHOICES.length - 1, at + steps));
}
