// Tests for barclick.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PAD, toggled, shownState, closesOnPress, chainReaches, groupReach, hitRect } from "./barclick.mjs";

const a = { name: "a" };
const b = { name: "b" };

test("a tap opens its popover, and closes it when it's the one open", () => {
    assert.equal(toggled(null, a), a);
    assert.equal(toggled(a, a), null);
    // Another's tap opens its own; the press before it closed the first.
    assert.equal(toggled(a, b), b);
});

test("a popover showing hides the open one, and open moves straight to it", () => {
    const opener = { name: "b's icon" };
    // The layout hears whether any is open, so open never passes through none.
    assert.deepEqual(shownState({ open: a, opener }, b, true), { open: b, opener, hide: a });
    assert.deepEqual(shownState({ open: null, opener }, b, true), { open: b, opener, hide: null });
    // The one hidden then reports itself hidden, and that changes nothing,
    // the new one's opener included.
    assert.deepEqual(shownState({ open: b, opener }, a, false), { open: b, opener, hide: null });
});

test("the open popover hiding, or going away, leaves none open", () => {
    assert.deepEqual(shownState({ open: a, opener: {} }, a, false), { open: null, opener: null, hide: null });
    assert.deepEqual(shownState({ open: null, opener: null }, a, false), { open: null, opener: null, hide: null });
});

test("a press on another target closes the open popover, so its tap opens the next", () => {
    // The first click on another icon used to only end the popover's grab.
    assert.equal(closesOnPress(true, false), true);
    // Its own target's tap closes it instead; closing on the press too
    // would have the tap reopen it.
    assert.equal(closesOnPress(true, true), false);
    assert.equal(closesOnPress(false, false), false);
});

test("a press on any bar but the bell closes the notification center", () => {
    // Every bar is in the center's grab, so another monitor's bar sees the
    // press and closes it; the bell's own tap closes or moves it instead.
    assert.equal(closesOnPress(true, false), true);
    assert.equal(closesOnPress(true, true), false);
});

test("neighbors split the gap between them, leaving none dead", () => {
    const spans = [
        { left: 100, right: 130, shown: true },
        { left: 140, right: 200, shown: true },
        { left: 212, right: 300, shown: true },
    ];
    const r = chainReaches(spans, { end: 306 });
    assert.deepEqual(r, [
        { left: PAD, right: 5 },
        { left: 5, right: 6 },
        { left: 6, right: 6 },
    ]);
    for (let i = 1; i < spans.length; i++) {
        assert.equal(spans[i - 1].right + r[i - 1].right, spans[i].left - r[i].left);
    }
});

test("a hidden span is skipped, so its neighbors share the gap across it", () => {
    const r = chainReaches([
        { left: 100, right: 130, shown: true },
        { left: 130, right: 130, shown: false },
        { left: 140, right: 160, shown: true },
        { left: 160, right: 160, shown: true },
    ]);
    assert.deepEqual(r, [
        { left: PAD, right: 5 },
        { left: 0, right: 0 },
        { left: 5, right: PAD },
        { left: 0, right: 0 },
    ]);
});

test("in a group, items split its spacing and its ends take the group's reach", () => {
    const group = { groupWidth: 100, spacing: 10, left: 7, right: 6 };
    assert.deepEqual(groupReach({ ...group, x: 0, width: 16 }), { left: 7, right: 5 });
    assert.deepEqual(groupReach({ ...group, x: 26, width: 40 }), { left: 5, right: 5 });
    assert.deepEqual(groupReach({ ...group, x: 76, width: 24 }), { left: 5, right: 6 });
    // Alone in its group, both ends are the group's.
    assert.deepEqual(groupReach({ ...group, x: 0, width: 100 }), { left: 7, right: 6 });
});

test("the target is the whole span plus its reach, the bar's full height", () => {
    // An icon 16 high in a bar 36 high reaches 10 above and below it.
    assert.deepEqual(hitRect({ width: 40, height: 16, barHeight: 36, left: 5, right: 6 }),
        { x: -5, y: -10, width: 51, height: 36 });
});

test("adjacent targets in a group tile with no gap and no overlap", () => {
    const spacing = 10;
    const items = [{ x: 0, width: 16 }, { x: 26, width: 50 }, { x: 86, width: 14 }];
    const rects = items.map((it) => {
        const reach = groupReach({ ...it, groupWidth: 100, spacing, left: 3, right: 3 });
        const r = hitRect({ width: it.width, height: 16, barHeight: 36, ...reach });
        return { from: it.x + r.x, to: it.x + r.x + r.width };
    });
    for (let i = 1; i < rects.length; i++) {
        assert.equal(rects[i - 1].to, rects[i].from);
    }
});
