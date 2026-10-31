// What a click on the bar hits and what it does to an open popover
// (SPEC.md §7.1), as pure functions the QML binds to.
//
// A popover's focus grab takes in every bar (PopoverGrab.qml), so a press
// on the bar reaches the bar rather than only ending the grab. The press
// then closes the open popover unless it's on the target that opened it,
// whose tap closes it instead; a tap elsewhere opens its own.

// How far a target reaches past its ends where it has no clickable
// neighbor to share the gap with.
export const PAD = 4;

// The popover open after a tap on `target`'s opener: none if it was the one
// open, else it.
export function toggled(open, target) {
    return open === target ? null : target;
}

// Whether a press on the bar closes the open popover there and then: yes,
// unless it's on the target that opened it.
export function closesOnPress(open, onOpener) {
    return open && !onOpener;
}

// The bar's top-level clickable spans, left to right, as {left, right,
// shown} in bar coordinates, to how far each reaches past its ends:
// [{left, right}]. Neighbors split the gap between them, so no gap is
// dead; an end with no neighbor reaches `pad`, the last one to `end`
// (the bar's right edge) if that's given.
export function chainReaches(spans, { pad = PAD, end = null } = {}) {
    const shown = spans.map((s) => s.shown && s.right > s.left);
    return spans.map((s, i) => {
        if (!shown[i]) {
            return { left: 0, right: 0 };
        }
        let prev = -1;
        for (let j = i - 1; j >= 0; j--) {
            if (shown[j]) {
                prev = j;
                break;
            }
        }
        let next = -1;
        for (let j = i + 1; j < spans.length; j++) {
            if (shown[j]) {
                next = j;
                break;
            }
        }
        const left = prev >= 0 ? Math.max(0, s.left - spans[prev].right) / 2 : pad;
        const right = next >= 0 ? Math.max(0, spans[next].left - s.right) / 2
            : end !== null ? Math.max(0, end - s.right) : pad;
        return { left, right };
    });
}

// How far an item in a group's Row reaches: half the Row's spacing toward
// a neighbor, and the group's own reach at its ends, where the first item
// starts at 0 and the last ends at the Row's width.
export function groupReach({ x, width, groupWidth, spacing, left, right }) {
    const first = x <= 0.5;
    const last = x + width >= groupWidth - 0.5;
    return {
        left: first ? left : spacing / 2,
        right: last ? right : spacing / 2,
    };
}

// The click target of a span `width` by `height`, vertically centered in a
// bar `barHeight` tall, in the span's coordinates: its whole width plus
// its reach each side, and the bar's full height.
export function hitRect({ width, height, barHeight, left, right }) {
    return {
        x: -left,
        y: -(barHeight - height) / 2,
        width: width + left + right,
        height: barHeight,
    };
}
