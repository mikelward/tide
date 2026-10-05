// Tests for workspaces.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    FIRST, LAST, MAX_ICONS, NO_MARKS, updateMarks, markedWindows, barWorkspaces, scrollTarget,
    normalizeAddress, markEvent, sameApp, visibleWorkspaces, activatedEvent, attentionOrder,
    withFocus, withoutWindow, focusRank,
} from "./workspaces.mjs";

const win = (address, workspace, app, extra = {}) =>
    ({ address, workspace, app, urgent: false, fullscreen: 0, ...extra });

const one = { monitor: "DP-1", monitors: [{ name: "DP-1", workspace: 2 }] };

test("the bar always lists workspaces 1 to 9", () => {
    const bar = barWorkspaces({ ...one, windows: [] });
    assert.deepEqual(bar.map((w) => w.id), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    assert.equal(FIRST, 1);
    assert.equal(LAST, 9);
});

test("each workspace is current, elsewhere, occupied or empty", () => {
    const bar = barWorkspaces({
        monitor: "DP-1",
        monitors: [{ name: "DP-1", workspace: 2 }, { name: "eDP-1", workspace: 5 }],
        windows: [win("a", 3, "kitty"), win("b", 5, "firefox")],
    });
    assert.deepEqual(bar.slice(0, 5).map((w) => w.state),
        ["empty", "current", "occupied", "empty", "elsewhere"]);
    // The other monitor's bar sees the same pair the other way round.
    const other = barWorkspaces({
        monitor: "eDP-1",
        monitors: [{ name: "DP-1", workspace: 2 }, { name: "eDP-1", workspace: 5 }],
        windows: [],
    });
    assert.equal(other[1].state, "elsewhere");
    assert.equal(other[4].state, "current");
});

test("special workspaces and windows on them aren't on the bar", () => {
    const bar = barWorkspaces({
        monitor: "DP-1",
        monitors: [{ name: "DP-1", workspace: -98 }],
        windows: [win("a", -98, "kitty"), win("b", 12, "kitty")],
    });
    assert.equal(bar.length, 9);
    assert.ok(bar.every((w) => w.state === "empty" && w.icons.length === 0));
});

test("one icon per window, in window order, up to five then +n", () => {
    const windows = ["a", "b", "c", "d", "e", "f", "g"].map((a) => win(a, 3, `app-${a}`));
    const ws = barWorkspaces({ ...one, windows })[2];
    assert.equal(MAX_ICONS, 5);
    assert.deepEqual(ws.icons.map((i) => i.address), ["a", "b", "c", "d", "e"]);
    assert.equal(ws.more, 2);
    const two = barWorkspaces({ ...one, windows: windows.slice(0, 2) })[2];
    assert.deepEqual(two.icons.map((i) => i.app), ["app-a", "app-b"]);
    assert.equal(two.more, 0);
});

test("a marked window's icon is never folded into +n", () => {
    const windows = ["a", "b", "c", "d", "e", "f", "g"].map((a) => win(a, 3, "kitty"));
    windows[6].urgent = true;
    const ws = barWorkspaces({ ...one, windows })[2];
    assert.deepEqual(ws.icons.map((i) => i.address), ["a", "b", "c", "d", "g"]);
    assert.deepEqual(ws.icons.map((i) => i.marked), [false, false, false, false, true]);
    assert.equal(ws.more, 2);
});

test("an urgent window makes its workspace urgent", () => {
    const bar = barWorkspaces({ ...one, windows: [win("a", 4, "kitty", { urgent: true }), win("b", 6, "kitty")] });
    assert.equal(bar[3].urgent, true);
    assert.equal(bar[5].urgent, false);
    assert.equal(bar[3].icons[0].marked, true);
});

test("a maximized or fullscreen window marks its workspace big", () => {
    const bar = barWorkspaces({
        ...one,
        windows: [win("a", 3, "mpv", { fullscreen: 2 }), win("b", 4, "kitty", { fullscreen: 1 }), win("c", 5, "kitty")],
    });
    assert.deepEqual(bar.slice(2, 5).map((w) => w.big), [true, true, false]);
});

// §14.4: a notification marks an app, and every workspace holding one of
// that app's windows that isn't visible turns urgent.
const nautilus = [win("n1", 2, "nautilus"), win("n2", 4, "nautilus"), win("n3", 6, "nautilus"), win("k", 7, "kitty")];
const notified = (marks = NO_MARKS, visible = new Set([2])) =>
    updateMarks(marks, { type: "notified", id: 1, app: "nautilus", windows: nautilus, visible });
const marked = (marks, windows = nautilus) => [...markedWindows({ windows, marks })].sort();

test("an app mark covers the app's windows that weren't visible", () => {
    const bar = barWorkspaces({ ...one, windows: nautilus, marks: notified() });
    // Workspace 2 was on screen, so its window isn't marked.
    assert.deepEqual(bar.map((w) => w.urgent), [false, false, false, true, false, true, false, false, false]);
});

test("an app mark keeps the windows it marked when their workspace comes on screen", () => {
    const marks = notified();
    // The user goes to workspace 4 but focuses nothing marked yet.
    const bar = barWorkspaces({ monitor: "DP-1", monitors: [{ name: "DP-1", workspace: 4 }], windows: nautilus, marks });
    assert.equal(bar[3].urgent, true);
    // And a window that was on screen at the time stays unmarked when it's hidden.
    assert.equal(bar[1].urgent, false);
});

test("focusing a marked window clears the marks that covered it", () => {
    assert.deepEqual(updateMarks(notified(), { type: "focused", address: "n2" }), NO_MARKS);
    // Focusing a window the mark didn't cover leaves it.
    assert.deepEqual(marked(updateMarks(notified(), { type: "focused", address: "n1" })), ["n2", "n3"]);
});

test("the app's activation replaces its app-wide mark, whatever came first", () => {
    const activated = updateMarks(notified(), { type: "activated", app: "nautilus" });
    assert.deepEqual(activated, NO_MARKS);
    // A notification after an activation marks the app again, though the
    // activated window is still flagged urgent.
    const windows = nautilus.map((w) => (w.address === "n3" ? { ...w, urgent: true } : w));
    const again = updateMarks(activated, { type: "notified", id: 2, app: "nautilus", windows, visible: new Set([2]) });
    assert.deepEqual(marked(again, windows), ["n2", "n3"]);
    // A notification naming its window isn't app-wide, so activation keeps it.
    const named = updateMarks(NO_MARKS, { type: "notified", id: 3, app: "nautilus", address: "n2", windows: nautilus, visible: new Set([2]) });
    assert.deepEqual(marked(updateMarks(named, { type: "activated", app: "nautilus" })), ["n2"]);
});

test("dismissing a notification clears just its marks", () => {
    assert.deepEqual(updateMarks(notified(), { type: "dismissed", id: 1 }), NO_MARKS);
    // One naming its window, while the guard marked the same window too.
    const windows = [win("c", 6, "chrome"), win("d", 7, "chrome")];
    const seen = new Set([2]);
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 4, app: "chrome", address: "c", windows, visible: seen });
    marks = updateMarks(marks, { type: "guarded", address: "c" });
    marks = updateMarks(marks, { type: "notified", id: 5, app: "chrome", address: "d", windows, visible: seen });
    assert.deepEqual(marked(updateMarks(marks, { type: "dismissed", id: 5 }), windows), ["c"]);
    const gone = updateMarks(marks, { type: "dismissed", id: 4 });
    assert.deepEqual(marked(gone, windows), ["c", "d"]);
    assert.deepEqual(gone.guard, ["c"]);
});

test("a replacement notification keeps what it marked", () => {
    // Workspace 4 comes on screen, then the notification is replaced.
    const replaced = updateMarks(notified(), { type: "notified", id: 1, app: "nautilus", windows: nautilus, visible: new Set([4]) });
    // n2 stays marked, and n1, hidden now, joins it.
    assert.deepEqual(replaced.notes[1].wide, ["n2", "n3", "n1"]);
});

test("a replacement that changes form keeps each mark's kind", () => {
    // App-wide, then replaced by one naming its window: activation clears
    // the app-wide marks and keeps the named one.
    const named = updateMarks(notified(), { type: "notified", id: 1, app: "nautilus", address: "n1", windows: nautilus, visible: new Set([4]) });
    assert.deepEqual(marked(updateMarks(named, { type: "activated", app: "nautilus" })), ["n1"]);
    // The other way round: the named mark survives activation too.
    let other = updateMarks(NO_MARKS, { type: "notified", id: 2, app: "nautilus", address: "n1", windows: nautilus, visible: new Set([4]) });
    other = updateMarks(other, { type: "notified", id: 2, app: "nautilus", windows: nautilus, visible: new Set([2]) });
    assert.deepEqual(marked(other), ["n1", "n2", "n3"]);
    assert.deepEqual(marked(updateMarks(other, { type: "activated", app: "nautilus" })), ["n1"]);
});

test("a notification naming a window on screen marks nothing", () => {
    const marks = updateMarks(NO_MARKS, { type: "notified", id: 6, app: "nautilus", address: "n1", windows: nautilus, visible: new Set([2]) });
    assert.deepEqual(marks, NO_MARKS);
});

test("an app mark with nothing hidden marks nothing", () => {
    assert.deepEqual(notified(NO_MARKS, new Set([2, 4, 6])), NO_MARKS);
});

test("the guard's mark is by window, and a focus clears it", () => {
    const marks = updateMarks(NO_MARKS, { type: "guarded", address: "b" });
    const windows = [win("a", 5, "kitty"), win("b", 5, "kitty")];
    const bar = barWorkspaces({ ...one, windows, marks });
    assert.deepEqual(bar[4].icons.map((i) => i.marked), [false, true]);
    assert.deepEqual(updateMarks(marks, { type: "focused", address: "b" }), NO_MARKS);
});

test("a closed window leaves the marks", () => {
    const marks = updateMarks(updateMarks(notified(), { type: "guarded", address: "n2" }), { type: "closed", address: "n2" });
    assert.deepEqual(marks.guard, []);
    assert.deepEqual(marks.notes[1].wide, ["n3"]);
    assert.deepEqual(updateMarks(marks, { type: "closed", address: "n3" }), NO_MARKS);
});

test("updateMarks leaves its input alone and rejects unknown events", () => {
    const marks = notified();
    updateMarks(marks, { type: "focused", address: "n2" });
    updateMarks(marks, { type: "closed", address: "n2" });
    assert.deepEqual(marks.notes[1].wide, ["n2", "n3"]);
    assert.throws(() => updateMarks(marks, { type: "bogus" }), /unknown mark event bogus/);
});

test("scrolling steps one workspace per notch and stops at 1 and 9", () => {
    assert.equal(scrollTarget(4, 1), 5);
    assert.equal(scrollTarget(4, -1), 3);
    assert.equal(scrollTarget(4, 3), 7);
    assert.equal(scrollTarget(7, 5), 9);
    assert.equal(scrollTarget(2, -4), 1);
    assert.equal(scrollTarget(9, 1), null);
    assert.equal(scrollTarget(1, -1), null);
    assert.equal(scrollTarget(4, 0), null);
    assert.equal(scrollTarget(4, 0.5), null);
    assert.equal(scrollTarget(-98, 1), null);
    assert.equal(scrollTarget(undefined, 1), null);
});

test("addresses are compared the way Quickshell spells them", () => {
    assert.equal(normalizeAddress("0x55D3A1B2C0"), "55d3a1b2c0");
    assert.equal(normalizeAddress("55d3a1b2c0"), "55d3a1b2c0");
    assert.equal(normalizeAddress("0x0000abc"), "abc");
    assert.equal(normalizeAddress("0"), "0");
    assert.equal(normalizeAddress(""), null);
    assert.equal(normalizeAddress("nope"), null);
    assert.equal(normalizeAddress(undefined), null);
});

test("Hyprland events become mark events", () => {
    assert.deepEqual(markEvent("custom", "tide-attention>>0x55d3a1b2c0"), { type: "guarded", address: "55d3a1b2c0" });
    assert.deepEqual(markEvent("activewindowv2", "55d3a1b2c0"), { type: "focused", address: "55d3a1b2c0" });
    assert.deepEqual(markEvent("closewindow", "55d3a1b2c0"), { type: "closed", address: "55d3a1b2c0" });
});

test("other events, and ones with no window, mark nothing", () => {
    assert.equal(markEvent("custom", "something-else>>abc"), null);
    assert.equal(markEvent("activewindowv2", ""), null);
    assert.equal(markEvent("openwindow", "abc,1,app,title"), null);
});

test("a guarded window marks its workspace until it's focused", () => {
    const windows = [win("abc", 4, "chat")];
    let marks = updateMarks(NO_MARKS, markEvent("custom", "tide-attention>>0xabc"));
    assert.deepEqual([...markedWindows({ windows, marks })], ["abc"]);
    marks = updateMarks(marks, markEvent("activewindowv2", "abc"));
    assert.deepEqual([...markedWindows({ windows, marks })], []);
});

test("a config reload drops the guard's marks and keeps notifications'", () => {
    const windows = [win("abc", 4, "chat"), win("def", 5, "mail")];
    let marks = updateMarks(NO_MARKS, { type: "guarded", address: "abc" });
    marks = updateMarks(marks, { type: "notified", id: 7, app: "mail", windows, visible: new Set([2]) });
    assert.deepEqual(markEvent("configreloaded", ""), { type: "guardReset" });
    marks = updateMarks(marks, markEvent("configreloaded", ""));
    assert.deepEqual([...markedWindows({ windows, marks })], ["def"]);
});

test("a notification's app matches window classes as the focus guard does", () => {
    assert.equal(sameApp("org.gnome.Nautilus", "org.gnome.Nautilus.desktop"), true);
    assert.equal(sameApp("google-chrome", "Google-Chrome"), true);
    assert.equal(sameApp("org.gnome.Nautilus", "nautilus"), true, "a bare name matches the last part");
    assert.equal(sameApp("org.example.chat", "com.example.chat"), false, "qualified IDs match in full");
    assert.equal(sameApp("kitty", "nautilus"), false);
    assert.equal(sameApp("", ""), false);
    assert.equal(sameApp(null, "kitty"), false);
});

test("a notification marks the app's windows whatever case or form its ID takes", () => {
    const windows = [win("n1", 4, "org.gnome.Nautilus"), win("k", 6, "kitty")];
    const marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: "nautilus", windows, visible: new Set([2]) });
    assert.deepEqual(marked(marks, windows), ["n1"]);
    // And the app's activation, by its window's class, replaces the mark.
    assert.deepEqual(updateMarks(marks, activatedEvent("n1", windows)), NO_MARKS);
});

test("the workspaces on screen are each monitor's open special one, or else its active one", () => {
    const visible = visibleWorkspaces([{ workspace: 2, special: -98 }, { workspace: 5, special: 0 }, { workspace: null }]);
    assert.deepEqual([...visible].sort(), [-98, 5]);
    // So a notification marks a window under an open special workspace.
    const windows = [win("n1", 2, "nautilus")];
    const marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: "nautilus", windows, visible });
    assert.deepEqual(marked(marks, windows), ["n1"]);
});

test("an urgent event names its window, and the app comes from the window list", () => {
    assert.deepEqual(markEvent("urgent", "0x55d3a1b2c0"), { type: "urgent", address: "55d3a1b2c0" });
    const windows = [win("55d3a1b2c0", 4, "nautilus")];
    assert.deepEqual(activatedEvent("55d3a1b2c0", windows), { type: "activated", app: "nautilus" });
    assert.equal(activatedEvent("abc", windows), null, "a window the list doesn't have");
    assert.equal(activatedEvent("abc", [win("abc", 4, "")]), null, "a window with no class");
});

test("a notification that takes another's place under a new ID takes over its marks", () => {
    // Workspace 4 comes on screen, then a new ID replaces notification 1.
    const marks = updateMarks(notified(), { type: "notified", id: 7, replaces: 1, app: "nautilus", windows: nautilus, visible: new Set([4]) });
    assert.deepEqual(Object.keys(marks.notes), ["7"]);
    assert.deepEqual(marked(marks), ["n1", "n2", "n3"]);
    // So dismissing the new one clears them all.
    assert.deepEqual(updateMarks(marks, { type: "dismissed", id: 7 }), NO_MARKS);
});

test("an update that names the app differently is matched by its new name", () => {
    const windows = [win("a", 4, "com.example.chat"), win("b", 6, "org.example.chat")];
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: "com.example.chat", windows, visible: new Set([2]) });
    // Updated in place under another ID for the app.
    marks = updateMarks(marks, { type: "notified", id: 1, app: "org.example.chat", windows, visible: new Set([2]) });
    assert.deepEqual(marked(marks, windows), ["a", "b"]);
    // The app it names now activating replaces the app-wide marks.
    assert.deepEqual(updateMarks(marks, activatedEvent("b", windows)), NO_MARKS);
});

test("Super+Tab's cycle keeps every mark until Super is released, then clears only where it landed", () => {
    assert.deepEqual(markEvent("custom", "tide-cycle>>start"), { type: "cycleStart" });
    assert.deepEqual(markEvent("custom", "tide-cycle>>end>>0x00A2"), { type: "cycleEnd", address: "a2" });
    assert.deepEqual(markEvent("custom", "tide-cycle>>end>>"), { type: "cycleEnd", address: null });
    let marks = updateMarks(notified(), { type: "guarded", address: "k" });
    marks = updateMarks(marks, markEvent("custom", "tide-cycle>>start"));
    // Stepping focuses each marked window in turn.
    for (const address of ["k", "n3", "n2"]) {
        marks = updateMarks(marks, { type: "focused", address });
    }
    assert.deepEqual(marked(marks, [...nautilus]), ["k", "n2", "n3"], "nothing cleared while stepping");
    marks = updateMarks(marks, { type: "cycleEnd", address: "n2" });
    assert.equal(marks.cycling, false);
    // n2 and n3 were one app-wide mark, so landing on n2 clears it; the
    // guard's mark on k stays.
    assert.deepEqual(marked(marks, [...nautilus]), ["k"]);
    // A focus after the cycle clears as usual.
    assert.deepEqual(updateMarks(marks, { type: "focused", address: "k" }), NO_MARKS);
    // A cycle that ended on nothing clears nothing.
    const none = updateMarks(updateMarks(notified(), { type: "cycleStart" }), { type: "cycleEnd", address: null });
    assert.deepEqual(none, notified());
});

test("the focus guard hears every marked window, oldest mark first", () => {
    const marks = updateMarks(notified(), { type: "notified", id: 2, app: "kitty", windows: nautilus, visible: new Set([2]) });
    assert.deepEqual(attentionOrder(marks), ["n2", "n3", "k"]);
    // The guard's marks share the clock.
    const held = updateMarks(marks, { type: "guarded", address: "x" });
    assert.deepEqual(attentionOrder(held), ["n2", "n3", "k", "x"]);
    // A notification marking a window again makes it the newest.
    const again = updateMarks(held, { type: "notified", id: 3, app: "nautilus", address: "n2", windows: nautilus, visible: new Set([2]) });
    assert.deepEqual(attentionOrder(again), ["n3", "k", "x", "n2"]);
    // A cleared mark leaves the order.
    assert.deepEqual(attentionOrder(updateMarks(again, { type: "dismissed", id: 2 })), ["n3", "x", "n2"]);
    // Dismissing the newer of two notes on a window puts it back where the
    // older one had it, before the guard's later mark too.
    assert.deepEqual(attentionOrder(updateMarks(again, { type: "dismissed", id: 3 })), ["n2", "n3", "k", "x"]);
    // The guard announcing a window again makes it the newest.
    assert.deepEqual(attentionOrder(updateMarks(again, { type: "guarded", address: "x" })), ["n3", "k", "n2", "x"]);
    assert.deepEqual(attentionOrder(NO_MARKS), []);
});
test("a rebuilt guard ends any cycle the shell thought was running", () => {
    const marks = updateMarks(updateMarks(notified(), { type: "cycleStart" }), { type: "guardReset" });
    assert.equal(marks.cycling, false);
    assert.deepEqual(updateMarks(marks, { type: "focused", address: "n2" }), NO_MARKS, "a focus clears again");
});

test("focus order follows focus events, newest first, without repeats", () => {
    let order = withFocus([], "a1");
    order = withFocus(order, "b2");
    order = withFocus(order, "a1");
    assert.deepEqual(order, ["a1", "b2"]);
    assert.deepEqual(withFocus(order, null), order);
    assert.deepEqual(withoutWindow(order, "a1"), ["b2"]);
    const many = Array.from({ length: 120 }, (_, i) => `${i + 1}`).reduce(withFocus, []);
    assert.equal(many.length, 100);
    assert.equal(many[0], "120");
});

test("a window focused since the shell started ranks above the startup order", () => {
    const order = ["b2"];
    assert.equal(focusRank(order, "b2", 7), 0);
    // a1 was last focused when the shell listed clients, but b2 since.
    assert.equal(focusRank(order, "a1", 0), 1);
    assert.equal(focusRank(order, "c3", 2), 3);
    assert.equal(focusRank(order, "d4", -1), Infinity);
    assert.equal(focusRank(order, "e5", undefined), Infinity);
});
