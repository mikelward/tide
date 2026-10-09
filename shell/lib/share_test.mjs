// Tests for share.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { isShareNode, shareLinks, liveShares, holdsPopups, sharingPill, PAIRING, PAIR_MS, chose, nodesSeen, settle, settleIn, kindOf, shareRows } from "./share.mjs";

const ACTIVE = 4;
const PAUSED = 3;

test("xdph's screencast nodes are shares, and nothing else is", () => {
    assert.equal(isShareNode({ name: "xdph-streaming-0" }), true);
    assert.equal(isShareNode({ name: "alsa_output.pci-0000_00_1f.3.analog-stereo" }), false);
    assert.equal(isShareNode({ name: "" }), false);
    assert.equal(isShareNode({}), false);
    assert.equal(isShareNode(null), false);
});

test("a share is live while something actively consumes it", () => {
    const share = { id: 40, name: "xdph-streaming-0" };
    const idle = { id: 41, name: "xdph-streaming-1" };
    const mic = { id: 50, name: "alsa_input.usb" };
    const chrome = { id: 60, name: "chrome" };
    const links = [
        { source: share, target: chrome, state: ACTIVE },
        { source: idle, target: chrome, state: PAUSED },
        { source: mic, target: chrome, state: ACTIVE },
        { source: null, target: chrome, state: ACTIVE },
    ];
    assert.deepEqual(liveShares([share, idle, mic, chrome], links, ACTIVE), [share]);
    assert.deepEqual(liveShares([share], [], ACTIVE), []);
});

// Runs steps from PAIRING, settling after each as ShareData does:
// ["chose", kind, time, label], ["nodes", ids, time] or
// ["settle", null, time].
function pair(steps) {
    let state = PAIRING;
    for (const [what, arg, time, label] of steps) {
        if (what === "chose") {
            state = chose(state, arg, time, label);
        } else if (what === "nodes") {
            state = nodesSeen(state, arg, time);
        }
        state = settle(state, time);
    }
    return state;
}

// Past the 5 s a pairing at `time` waits for a second node.
const settled = time => ["settle", null, time + PAIR_MS + 1];

const share = id => ({ id: id, name: `xdph-streaming-${id}` });

test("a share the picker didn't name holds popups", () => {
    assert.equal(holdsPopups([], PAIRING), false);
    assert.equal(holdsPopups([share(40)], PAIRING), true);
    assert.equal(kindOf(PAIRING, 40), "screen");
});

test("a window chosen, then its stream, holds no popups once 5 s pass", () => {
    const steps = [["nodes", [], 0], ["chose", "window", 1000], ["nodes", [40], 2000]];
    let s = pair(steps);
    // The choice is used up, and the pairing waits for a second node.
    assert.deepEqual(s.waiting, []);
    assert.equal(kindOf(s, 40), "screen");
    assert.equal(holdsPopups([share(40)], s), true);
    assert.equal(settleIn(s, 2000), PAIR_MS + 1);
    assert.equal(settle(s, 2000 + PAIR_MS), s);
    s = pair(steps.concat([settled(2000)]));
    assert.equal(kindOf(s, 40), "window");
    assert.equal(holdsPopups([share(40)], s), false);
    assert.deepEqual(s.pending, {});
    assert.equal(settleIn(s, 9000), null);
});

test("an unrelated stream that comes first while a window choice waits stays held", () => {
    const s = pair([["chose", "window", 1000], ["nodes", [40], 1500]]);
    assert.equal(holdsPopups([share(40)], s), true);
    // The window's own stream undoes the pairing, so neither shows popups.
    const t = pair([["chose", "window", 1000], ["nodes", [40], 1500], ["nodes", [40, 41], 2500], settled(2500)]);
    assert.equal(kindOf(t, 40), "screen");
    assert.equal(kindOf(t, 41), "screen");
});

test("a screen or area chosen holds popups", () => {
    for (const kind of ["screen", "region"]) {
        const s = pair([["chose", kind, 1000], ["nodes", [40], 2000], settled(2000)]);
        assert.equal(kindOf(s, 40), kind);
        assert.equal(holdsPopups([share(40)], s), true, kind);
    }
});

test("a window share alongside an unnamed one still holds popups", () => {
    const s = pair([["chose", "window", 1000], ["nodes", [40], 2000], ["nodes", [40, 41], 2000 + PAIR_MS + 1]]);
    assert.equal(kindOf(s, 40), "window");
    assert.equal(kindOf(s, 41), "screen");
    assert.equal(holdsPopups([share(40)], s), false);
    assert.equal(holdsPopups([share(40), share(41)], s), true);
});

test("a choice older than 5 s pairs with nothing", () => {
    const s = pair([["chose", "window", 1000], ["nodes", [40], 1001 + PAIR_MS]]);
    assert.equal(kindOf(s, 40), "screen");
});

test("two choices waiting pair with nothing", () => {
    const s = pair([["chose", "window", 1000], ["chose", "window", 2000], ["nodes", [40], 3000]]);
    assert.equal(kindOf(s, 40), "screen");
});

test("two new streams at once pair with nothing", () => {
    const s = pair([["chose", "window", 1000], ["nodes", [40, 41], 2000]]);
    assert.equal(kindOf(s, 40), "screen");
    assert.equal(kindOf(s, 41), "screen");
});

test("a choice two new streams left unpaired doesn't pair with a later one", () => {
    const s = pair([["chose", "window", 1000], ["nodes", [40, 41], 2000], ["nodes", [], 3000], ["nodes", [42], 4000]]);
    assert.equal(kindOf(s, 42), "screen");
});

test("a second stream soon after a pairing undoes it", () => {
    const s = pair([["chose", "window", 1000], ["nodes", [40], 2000], ["nodes", [40, 41], 3000]]);
    assert.equal(kindOf(s, 40), "screen");
    assert.equal(kindOf(s, 41), "screen");
});

test("a stream that comes soon after an unnamed one pairs with nothing", () => {
    const s = pair([["nodes", [40], 1000], ["chose", "window", 2000], ["nodes", [40, 41], 3000]]);
    assert.equal(kindOf(s, 41), "screen");
});

test("a stream with no choice is a screen share, and the next choice waits for its own", () => {
    const s = pair([["nodes", [40], 1000], ["chose", "window", 1000 + PAIR_MS + 1], ["nodes", [40, 41], 2000 + PAIR_MS], settled(2000 + PAIR_MS)]);
    assert.equal(kindOf(s, 40), "screen");
    assert.equal(kindOf(s, 41), "window");
});

test("a stream that ends is forgotten, and its id coming back is new", () => {
    let s = pair([["chose", "window", 1000], ["nodes", [40], 2000], ["nodes", [], 3000]]);
    assert.deepEqual(s.seen, []);
    assert.deepEqual(s.pending, {});
    assert.deepEqual(s.kinds, {});
    s = nodesSeen(s, [40], 3000 + PAIR_MS + 1);
    assert.equal(kindOf(s, 40), "screen");
});

test("the same streams seen again change nothing", () => {
    const s = pair([["chose", "window", 1000], ["nodes", [40], 2000]]);
    assert.deepEqual(nodesSeen(s, [40], 2500), s);
});

test("only the links out of share nodes are bound", () => {
    const share = { id: 40, name: "xdph-streaming-0" };
    const mic = { id: 50, name: "alsa_input.usb" };
    const chrome = { id: 60, name: "chrome" };
    const out = { source: share, target: chrome };
    assert.deepEqual(shareLinks([out, { source: mic, target: chrome }, { source: null, target: chrome }]), [out]);
});

test("the Sharing pill shows while any share is live", () => {
    assert.equal(sharingPill([]), false);
    assert.equal(sharingPill([{ id: 40, name: "xdph-streaming-0" }]), true);
});

test("the Sharing pill's popover names what each share is", () => {
    const s = pair([
        ["chose", "window", 1000, "Meet - Design review"], ["nodes", [40], 2000],
        ["chose", "region", 20000, "16:9 in the middle of DP-1"], ["nodes", [40, 41], 21000],
        ["chose", "screen", 40000, "eDP-1"], ["nodes", [40, 41, 42], 41000],
        settled(41000),
    ]);
    assert.deepEqual(shareRows([share(40), share(41), share(42)], s), [
        { icon: "focus-windows-symbolic", label: "Window: Meet - Design review" },
        { icon: "selection-mode-symbolic", label: "Area: 16:9 in the middle of DP-1" },
        { icon: "video-display-symbolic", label: "Screen: eDP-1" },
    ]);
});

test("a share the picker didn't name says so in the popover", () => {
    assert.deepEqual(shareRows([share(40)], PAIRING), [
        { icon: "video-display-symbolic", label: "Not chosen in tide's picker" },
    ]);
    // Nor has a pairing that hasn't settled, nor a choice with no label.
    const pending = pair([["chose", "window", 1000, "Meet"], ["nodes", [40], 2000]]);
    assert.equal(shareRows([share(40)], pending)[0].label, "Not chosen in tide's picker");
    const bare = pair([["chose", "window", 1000], ["nodes", [40], 2000], settled(2000)]);
    assert.deepEqual(shareRows([share(40)], bare), [{ icon: "focus-windows-symbolic", label: "A window" }]);
    assert.deepEqual(shareRows([], PAIRING), []);
});
