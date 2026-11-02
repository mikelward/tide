// Tests for workspaces.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { noteOf } from "./mute.mjs";
import {
    MAX_ICONS, BAR_NAME, NO_MARKS, updateMarks, markedWindows, barWorkspaces, scrollTarget,
    workspaceOrder, barName, workspaceEvent, homeIdAfter, homeRenamed,
    normalizeAddress, markEvent, sameApp, visibleWorkspaces, activatedEvent, attentionOrder,
    withFocus, withoutWindow, focusRank,
} from "./workspaces.mjs";

const win = (address, workspace, app, extra = {}) =>
    ({ address, workspace, app, urgent: false, fullscreen: 0, ...extra });

// Nine numbered workspaces, as the tests of marks and icons had before
// workspaces had names: with no standing ones, they're listed by number.
const nine = [1, 2, 3, 4, 5, 6, 7, 8, 9].map((id) => ({ id, name: String(id) }));
const one = { monitor: "DP-1", monitors: [{ name: "DP-1", workspace: 2 }], workspaces: nine };

// Named workspaces as Hyprland numbers them: each new one below the last,
// from -1338 down.
const named = (...names) => names.map((name, i) => ({ id: -1338 - i, name }));
const standing = ["in", "re", "oc", "me"];

test("the bar lists the standing workspaces first, home first, made or not", () => {
    const bar = barWorkspaces({ monitor: "DP-1", monitors: [{ name: "DP-1", workspace: -1338 }],
        workspaces: named("in"), windows: [], standing });
    assert.deepEqual(bar.map((w) => w.name), ["in", "re", "oc", "me"]);
    assert.deepEqual(bar.map((w) => w.id), [-1338, null, null, null]);
    assert.deepEqual(bar.map((w) => w.home), [true, false, false, false]);
    assert.ok(bar.every((w) => w.standing));
    assert.deepEqual(bar.map((w) => w.state), ["current", "empty", "empty", "empty"]);
});

test("home is whichever standing workspace comes first, by any name", () => {
    const order = workspaceOrder(named("work", "x"), ["work", "home"]);
    assert.deepEqual(order.map((w) => [w.name, w.home]), [["work", true], ["home", false], ["x", false]]);
});

test("the other workspaces follow in the order they were made, then numbered ones", () => {
    const workspaces = [{ id: 2, name: "2" }].concat(named("in", "PR-12", "re", "docs"), [{ id: 1, name: "1" }]);
    assert.deepEqual(workspaceOrder(workspaces, standing).map((w) => w.name),
        ["in", "re", "oc", "me", "PR-12", "docs", "1", "2"]);
});

test("a standing name matches a workspace's without case, keeping the workspace's", () => {
    const order = workspaceOrder(named("RE"), standing);
    assert.deepEqual(order.map((w) => w.name), ["in", "RE", "oc", "me"]);
    assert.equal(order[1].id, -1338);
    // An exact match wins over one that differs in case.
    const both = workspaceOrder(named("Re", "re"), standing);
    assert.deepEqual(both.map((w) => [w.name, w.id]).slice(1, 2), [["re", -1339]]);
    assert.equal(both[4].name, "Re");
});

test("special workspaces aren't on the bar", () => {
    const order = workspaceOrder([{ id: -98, name: "special:scratch" }].concat(named("in")), ["in"]);
    assert.deepEqual(order.map((w) => w.name), ["in"]);
});

test("the bar cuts a name past 16 characters with an ellipsis", () => {
    assert.equal(BAR_NAME, 16);
    assert.equal(barName("ABC-123 Fix login"), "ABC-123 Fix log…");
    assert.equal(barName("ABC-123 Fix logi"), "ABC-123 Fix logi");
    assert.equal(barName("🙂".repeat(17)), "🙂".repeat(15) + "…");
    const bar = barWorkspaces({ monitor: "DP-1", monitors: [], workspaces: named("in", "a fairly long name"), windows: [], standing: ["in"] });
    assert.equal(bar[1].label, "a fairly long n…");
    assert.equal(bar[1].name, "a fairly long name");
});

test("scrolling steps through the bar's order and stops at either end", () => {
    const list = workspaceOrder(named("in", "re", "PR-12"), standing);
    // in, re, oc, me, PR-12
    assert.equal(scrollTarget(list, -1338, 1), "re");
    assert.equal(scrollTarget(list, -1338, 2), "oc");
    assert.equal(scrollTarget(list, -1340, -1), "me");
    assert.equal(scrollTarget(list, -1340, 1), null);
    assert.equal(scrollTarget(list, -1338, -1), null);
    assert.equal(scrollTarget(list, -1338, 9), "PR-12");
    assert.equal(scrollTarget(list, -1338, 0), null);
    assert.equal(scrollTarget(list, -1338, 0.5), null);
    assert.equal(scrollTarget(list, -98, 1), null);
    assert.equal(scrollTarget(list, null, 1), null);
    assert.equal(scrollTarget(list, undefined, 1), null);
});

test("workspace events give the ID up to the first comma and the name after it", () => {
    assert.deepEqual(workspaceEvent("createworkspacev2", "-1339,PR-12, login"), { type: "created", id: -1339, name: "PR-12, login" });
    assert.deepEqual(workspaceEvent("destroyworkspacev2", "-1339,a,b"), { type: "destroyed", id: -1339, name: "a,b" });
    assert.deepEqual(workspaceEvent("renameworkspace", "3,x"), { type: "renamed", id: 3, name: "x" });
    assert.equal(workspaceEvent("renameworkspace", "x,y"), null);
    assert.equal(workspaceEvent("renameworkspace", "3"), null);
    assert.equal(workspaceEvent("workspacev2", "3,3"), null);
});

test("home is followed by ID, and a rename of it is undone", () => {
    let id = null;
    id = homeIdAfter(id, workspaceEvent("createworkspacev2", "-1339,other"), "in");
    assert.equal(id, null);
    id = homeIdAfter(id, workspaceEvent("createworkspacev2", "-1338,in"), "in");
    assert.equal(id, -1338);
    const rename = workspaceEvent("renameworkspace", "-1338,mail");
    assert.equal(homeRenamed(id, rename, "in"), true);
    assert.equal(homeIdAfter(id, rename, "in"), -1338);
    // Its own name back, or another workspace's rename, is left alone.
    assert.equal(homeRenamed(id, workspaceEvent("renameworkspace", "-1338,in"), "in"), false);
    assert.equal(homeRenamed(id, workspaceEvent("renameworkspace", "-1339,in2"), "in"), false);
    assert.equal(homeRenamed(null, rename, "in"), false);
    id = homeIdAfter(id, workspaceEvent("destroyworkspacev2", "-1338,in"), "in");
    assert.equal(id, null);
    assert.equal(homeIdAfter(5, null, "in"), 5);
});

test("each workspace is current, elsewhere, occupied or empty", () => {
    const bar = barWorkspaces({
        monitor: "DP-1",
        monitors: [{ name: "DP-1", workspace: 2 }, { name: "eDP-1", workspace: 5 }],
        workspaces: nine,
        windows: [win("a", 3, "kitty"), win("b", 5, "firefox")],
    });
    assert.deepEqual(bar.slice(0, 5).map((w) => w.state),
        ["empty", "current", "occupied", "empty", "elsewhere"]);
    // The other monitor's bar sees the same pair the other way round.
    const other = barWorkspaces({
        monitor: "eDP-1",
        monitors: [{ name: "DP-1", workspace: 2 }, { name: "eDP-1", workspace: 5 }],
        workspaces: nine,
        windows: [],
    });
    assert.equal(other[1].state, "elsewhere");
    assert.equal(other[4].state, "current");
});

test("windows on special workspaces aren't on the bar", () => {
    const bar = barWorkspaces({
        monitor: "DP-1",
        monitors: [{ name: "DP-1", workspace: -98 }],
        workspaces: nine.concat([{ id: -98, name: "special:scratch" }]),
        windows: [win("a", -98, "kitty"), win("b", 12, "kitty")],
    });
    assert.equal(bar.length, 9);
    assert.ok(bar.every((w) => w.state === "empty" && w.icons.length === 0));
});

test("an ordinary window has no icon on the bar, but the workspace counts it", () => {
    const windows = [win("a", 3, "kitty"), win("b", 3, "firefox")];
    const ws = barWorkspaces({ ...one, windows })[2];
    assert.deepEqual(ws.icons, []);
    assert.equal(ws.more, 0);
    assert.equal(ws.state, "occupied");
    assert.equal(ws.count, 2);
    assert.equal(ws.app, "kitty", "the first window's app, for the Workspaces tab");
    const empty = barWorkspaces({ ...one, windows })[3];
    assert.equal(empty.count, 0);
    assert.equal(empty.app, "");
});

test("only windows wanting attention get icons, in window order, up to five then +n", () => {
    const windows = ["a", "b", "c", "d", "e", "f", "g", "h"].map((a) => win(a, 3, `app-${a}`));
    for (const w of windows.slice(1)) {
        w.urgent = true;
    }
    const ws = barWorkspaces({ ...one, windows })[2];
    assert.equal(MAX_ICONS, 5);
    assert.deepEqual(ws.icons.map((i) => i.address), ["b", "c", "d", "e", "f"]);
    assert.ok(ws.icons.every((i) => i.marked));
    assert.equal(ws.more, 2, "the marked windows past five, not the unmarked one");
    windows[6].urgent = false;
    windows[7].urgent = false;
    const two = barWorkspaces({ ...one, windows: windows.slice(0, 3) })[2];
    assert.deepEqual(two.icons.map((i) => i.app), ["app-b", "app-c"]);
    assert.equal(two.more, 0);
});

test("the focus guard's and notifications' marks give icons as Hyprland's urgent flag does", () => {
    let marks = updateMarks(NO_MARKS, { type: "guarded", address: "a" });
    const windows = [win("a", 3, "kitty"), win("b", 3, "chrome"), win("c", 3, "kitty")];
    marks = updateMarks(marks, { type: "notified", id: 1, app: "chrome", windows, visible: new Set([2]) });
    const ws = barWorkspaces({ ...one, windows, marks })[2];
    assert.deepEqual(ws.icons.map((i) => i.address), ["a", "b"]);
    assert.equal(ws.urgent, true);
    const cleared = updateMarks(updateMarks(marks, { type: "focused", address: "a" }), { type: "dismissed", id: 1 });
    assert.deepEqual(barWorkspaces({ ...one, windows, marks: cleared })[2].icons, []);
});

test("a minimized window wanting attention shows on the chip it came from, and a click restores it", () => {
    const windows = [
        win("a", 3, "kitty"),
        win("b", -97, "chat", { workspaceName: "special:minimized:3", urgent: true }),
        win("c", -97, "mail", { workspaceName: "special:minimized:3" }),
        win("d", -96, "music", { workspaceName: "special:minimized:re", urgent: true }),
    ];
    const bar = barWorkspaces({ ...one, windows });
    assert.deepEqual(bar[2].icons, [{ address: "b", app: "chat", marked: true, restoreTo: "3" }]);
    assert.equal(bar[2].urgent, true);
    assert.equal(bar[2].count, 1, "minimized windows aren't counted as on it");
    // A workspace destroyed once its windows were all minimized: a standing
    // one is still on the bar, empty, and shows them.
    const named = barWorkspaces({ monitor: "DP-1", monitors: [{ name: "DP-1", workspace: -1338 }],
        workspaces: [{ id: -1338, name: "in" }], windows, standing: ["in", "re"] });
    assert.equal(named[1].state, "empty");
    assert.deepEqual(named[1].icons.map((i) => [i.address, i.restoreTo]), [["d", "re"]]);
    assert.equal(named[1].urgent, true);
});

test("an ordinary window's icon has nothing to restore", () => {
    const bar = barWorkspaces({ ...one, windows: [win("a", 3, "kitty", { urgent: true, workspaceName: "3" })] });
    assert.equal(bar[2].icons[0].restoreTo, null);
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

// The marks tests read the marks only as the shell does, so they hold
// whatever the marks are kept as (TODO.md, "Recompute attention marks"):
// `shown` is the windows the bar and the Attention tab mark, sorted, and
// `order` the order the focus guard and the Attention tab hear.
const shown = (marks, windows = nautilus, muted = []) => [...markedWindows({ windows, marks, muted })].sort();
const order = (marks, windows = nautilus, muted = []) => attentionOrder(marks, windows, muted);
const marked = shown;
// No mark at all: none shown, and none for the guard to hear.
const unmarked = (marks, windows = nautilus, muted = []) => {
    assert.deepEqual(shown(marks, windows, muted), []);
    assert.deepEqual(order(marks, windows, muted), []);
};

test("an app mark covers the app's windows that weren't visible", () => {
    const bar = barWorkspaces({ ...one, windows: nautilus, marks: notified() });
    // Workspace 2 was on screen, so its window isn't marked.
    assert.deepEqual(bar.map((w) => w.urgent), [false, false, false, true, false, true, false, false, false]);
});

test("an app mark keeps the windows it marked when their workspace comes on screen", () => {
    const marks = notified();
    // The user goes to workspace 4 but focuses nothing marked yet.
    const bar = barWorkspaces({ monitor: "DP-1", monitors: [{ name: "DP-1", workspace: 4 }], workspaces: nine, windows: nautilus, marks });
    assert.equal(bar[3].urgent, true);
    // And a window that was on screen at the time stays unmarked when it's hidden.
    assert.equal(bar[1].urgent, false);
});

test("focusing a marked window clears the marks that covered it", () => {
    unmarked(updateMarks(notified(), { type: "focused", address: "n2" }));
    // Focusing a window the mark didn't cover leaves it.
    assert.deepEqual(marked(updateMarks(notified(), { type: "focused", address: "n1" })), ["n2", "n3"]);
});

test("the app's activation replaces its app-wide mark, whatever came first", () => {
    const activated = updateMarks(notified(), { type: "activated", app: "nautilus" });
    unmarked(activated);
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
    unmarked(updateMarks(notified(), { type: "dismissed", id: 1 }));
    // One naming its window, while the guard marked the same window too.
    const windows = [win("c", 6, "chrome"), win("d", 7, "chrome")];
    const seen = new Set([2]);
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 4, app: "chrome", address: "c", windows, visible: seen });
    marks = updateMarks(marks, { type: "guarded", address: "c" });
    marks = updateMarks(marks, { type: "notified", id: 5, app: "chrome", address: "d", windows, visible: seen });
    assert.deepEqual(marked(updateMarks(marks, { type: "dismissed", id: 5 }), windows), ["c"]);
    const gone = updateMarks(marks, { type: "dismissed", id: 4 });
    assert.deepEqual(marked(gone, windows), ["c", "d"]);
    // c keeps the guard's mark, which a focus clears.
    assert.deepEqual(marked(updateMarks(gone, { type: "dismissed", id: 5 }), windows), ["c"]);
    assert.deepEqual(marked(updateMarks(gone, { type: "focused", address: "c" }), windows), ["d"]);
});

test("a replacement notification keeps what it marked", () => {
    // Workspace 4 comes on screen, then the notification is replaced.
    const replaced = updateMarks(notified(), { type: "notified", id: 1, app: "nautilus", windows: nautilus, visible: new Set([4]) });
    // n2 stays marked, and n1, hidden now, joins it, as the newest.
    assert.deepEqual(order(replaced), ["n2", "n3", "n1"]);
    // All under the one notification.
    unmarked(updateMarks(replaced, { type: "dismissed", id: 1 }));
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
    unmarked(updateMarks(NO_MARKS, { type: "notified", id: 6, app: "nautilus", address: "n1", windows: nautilus, visible: new Set([2]) }));
});

test("an app mark with nothing hidden marks nothing", () => {
    unmarked(notified(NO_MARKS, new Set([2, 4, 6])));
});

test("the guard's mark is by window, and a focus clears it", () => {
    const marks = updateMarks(NO_MARKS, { type: "guarded", address: "b" });
    const windows = [win("a", 5, "kitty"), win("b", 5, "kitty")];
    const bar = barWorkspaces({ ...one, windows, marks });
    assert.deepEqual(bar[4].icons.map((i) => i.address), ["b"]);
    unmarked(updateMarks(marks, { type: "focused", address: "b" }), windows);
});

test("a closed window leaves the marks", () => {
    const marks = updateMarks(updateMarks(notified(), { type: "guarded", address: "n2" }), { type: "closed", address: "n2" });
    const open = nautilus.filter((w) => w.address !== "n2");
    // Neither the guard's mark nor the notification's is left on it, for
    // the bar or for the guard.
    assert.deepEqual(shown(marks, open), ["n3"]);
    assert.deepEqual(order(marks, open), ["n3"]);
    unmarked(updateMarks(marks, { type: "closed", address: "n3" }), open.filter((w) => w.address !== "n3"));
});

test("updateMarks leaves its input alone and rejects unknown events", () => {
    const marks = notified();
    updateMarks(marks, { type: "focused", address: "n2" });
    updateMarks(marks, { type: "closed", address: "n2" });
    assert.deepEqual(shown(marks), ["n2", "n3"]);
    assert.deepEqual(order(marks), ["n2", "n3"]);
    assert.throws(() => updateMarks(marks, { type: "bogus" }), /unknown mark event bogus/);
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

test("the attention cycle's events are gone", () => {
    assert.equal(markEvent("custom", "tide-cycle>>start"), null);
    assert.equal(markEvent("custom", "tide-cycle>>end>>0xa2"), null);
    assert.ok(!("cycling" in NO_MARKS));
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
    unmarked(updateMarks(marks, activatedEvent("n1", windows)), windows);
});

test("a notification naming several apps marks each one's windows", () => {
    // A Chrome site open as an --app window in two profiles.
    const windows = [win("d", 4, "chrome-calendar.google.com__-Default"), win("p", 5, "chrome-calendar.google.com__-Profile_1"), win("k", 6, "kitty")];
    const marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: ["chrome-calendar.google.com__-Default", "chrome-calendar.google.com__-Profile_1"], windows, visible: new Set([2]) });
    assert.deepEqual(marked(marks, windows).sort(), ["d", "p"]);
    // Either one's activation replaces the app-wide marks.
    unmarked(updateMarks(marks, activatedEvent("p", windows)), windows);
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
    assert.deepEqual(marked(marks), ["n1", "n2", "n3"]);
    // The old ID holds none of them now, and dismissing the new one clears
    // them all.
    assert.deepEqual(marked(updateMarks(marks, { type: "dismissed", id: 1 })), ["n1", "n2", "n3"]);
    unmarked(updateMarks(marks, { type: "dismissed", id: 7 }));
});

test("an update that names the app differently is matched by its new name", () => {
    const windows = [win("a", 4, "com.example.chat"), win("b", 6, "org.example.chat")];
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: "com.example.chat", windows, visible: new Set([2]) });
    // Updated in place under another ID for the app.
    marks = updateMarks(marks, { type: "notified", id: 1, app: "org.example.chat", windows, visible: new Set([2]) });
    assert.deepEqual(marked(marks, windows), ["a", "b"]);
    // The app it names now activating replaces the app-wide marks.
    unmarked(updateMarks(marks, activatedEvent("b", windows)), windows);
});

test("the focus guard hears every marked window, oldest mark first", () => {
    const windows = [...nautilus, win("x", 8, "firefox")];
    const marks = updateMarks(notified(), { type: "notified", id: 2, app: "kitty", windows, visible: new Set([2]) });
    assert.deepEqual(order(marks, windows), ["n2", "n3", "k"]);
    // The guard's marks share the clock.
    const held = updateMarks(marks, { type: "guarded", address: "x" });
    assert.deepEqual(order(held, windows), ["n2", "n3", "k", "x"]);
    // A notification marking a window again makes it the newest.
    const again = updateMarks(held, { type: "notified", id: 3, app: "nautilus", address: "n2", windows, visible: new Set([2]) });
    assert.deepEqual(order(again, windows), ["n3", "k", "x", "n2"]);
    // A cleared mark leaves the order.
    assert.deepEqual(order(updateMarks(again, { type: "dismissed", id: 2 }), windows), ["n3", "x", "n2"]);
    // Dismissing the newer of two notes on a window puts it back where the
    // older one had it, before the guard's later mark too.
    assert.deepEqual(order(updateMarks(again, { type: "dismissed", id: 3 }), windows), ["n2", "n3", "k", "x"]);
    // The guard announcing a window again makes it the newest.
    assert.deepEqual(order(updateMarks(again, { type: "guarded", address: "x" }), windows), ["n3", "k", "n2", "x"]);
    assert.deepEqual(order(NO_MARKS, windows), []);
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

test("a minimized window's attention icon finds its standing chip ignoring case", () => {
    const windows = [win("b", -97, "chat", { workspaceName: "special:minimized:Re", urgent: true })];
    const bar = barWorkspaces({ monitor: "DP-1", monitors: [{ name: "DP-1", workspace: -1338 }],
        workspaces: [{ id: -1338, name: "in" }], windows, standing: ["in", "re"] });
    assert.deepEqual(bar[1].icons.map((i) => [i.address, i.restoreTo]), [["b", "Re"]]);
    assert.equal(bar[1].urgent, true);
});

test("a muted app's windows are never marked, however they were", () => {
    let marks = updateMarks(NO_MARKS, { type: "guarded", address: "a" });
    const windows = [win("a", 3, "Slack"), win("b", 3, "chrome-chat.google.com__-Default", { urgent: true }), win("c", 3, "kitty", { urgent: true })];
    marks = updateMarks(marks, { type: "notified", id: 1, app: "Slack", windows, visible: new Set([2]) });
    const muted = ["slack", "site:chat.google.com"];
    assert.deepEqual([...markedWindows({ windows, marks, muted })], ["c"]);
    const ws = barWorkspaces({ ...one, windows, marks, muted })[2];
    assert.deepEqual(ws.icons.map((i) => i.address), ["c"], "no chip icon");
    assert.equal(barWorkspaces({ ...one, windows: windows.slice(0, 2), marks, muted })[2].urgent, false);
});

test("muting one window's site clears only its marks, not a shared notification's on another window", () => {
    const windows = [win("chat", 3, "chrome-chat.google.com__-Default"), win("mail", 4, "chrome-mail.google.com__-Default")];
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: windows.map((w) => w.app), windows, visible: new Set([2]) });
    assert.deepEqual([...markedWindows({ windows, marks })].sort(), ["chat", "mail"]);
    const muted = ["site:chat.google.com"];
    marks = updateMarks(marks, { type: "muted", muted, windows });
    assert.deepEqual(shown(marks, windows, muted), ["mail"], "Mail keeps its mark");
    assert.deepEqual(order(marks, windows, muted), ["mail"]);
});

test("a muted window never holds a notification's or the guard's mark, so unmuting brings none back", () => {
    const windows = [win("chat", 3, "chrome-chat.google.com__-Default"), win("mail", 4, "chrome-mail.google.com__-Default")];
    const muted = ["site:chat.google.com"];
    // google.com isn't muted, but reaches both windows; Chat's is muted.
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: windows.map((w) => w.app), windows, visible: new Set([2]), muted });
    marks = updateMarks(marks, { type: "notified", id: 2, app: "x", address: "chat", windows, visible: new Set([2]), muted });
    marks = updateMarks(marks, { type: "guarded", address: "chat", app: windows[0].app, muted });
    assert.deepEqual(shown(marks, windows, muted), ["mail"]);
    // Unmuted, Chat has no mark to come back, the guard's or either
    // notification's.
    marks = updateMarks(marks, { type: "muted", muted: [], windows });
    assert.deepEqual(shown(marks, windows), ["mail"]);
    assert.deepEqual(order(marks, windows), ["mail"]);
    // And dismissing the one that reached Mail leaves nothing.
    unmarked(updateMarks(marks, { type: "dismissed", id: 1 }), windows);
});

test("muting a site clears its notification's marks on plain browser windows, and keeps others'", () => {
    // No --app window for chat.google.com, so its notification marked the
    // plain Chrome window; Slack's marked Slack's.
    const windows = [win("chrome", 3, "google-chrome"), win("slack", 4, "Slack")];
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: ["google-chrome"], windows, visible: new Set([2]),
        sender: noteOf("google-chrome", "Google Chrome", "chat.google.com") });
    marks = updateMarks(marks, { type: "notified", id: 2, app: "Slack", windows, visible: new Set([2]),
        sender: noteOf("", "Slack", "") });
    assert.deepEqual([...markedWindows({ windows, marks })].sort(), ["chrome", "slack"]);
    marks = updateMarks(marks, { type: "muted", muted: ["site:chat.google.com"], windows });
    assert.deepEqual(shown(marks, windows, ["site:chat.google.com"]), ["slack"], "another notification's mark stays");
    // The site's notification's marks are gone, not hidden: unmuting
    // brings none back.
    marks = updateMarks(marks, { type: "muted", muted: [], windows });
    assert.deepEqual(shown(marks, windows), ["slack"]);
    assert.deepEqual(order(marks, windows), ["slack"]);
});

test("muting an app clears its windows' marks from any notification, and the guard's", () => {
    const windows = [win("chat", 3, "chrome-chat.google.com__-Default"), win("mail", 4, "chrome-mail.google.com__-Default")];
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: windows.map((w) => w.app), windows, visible: new Set([2]),
        sender: noteOf("google-chrome", "", "google.com") });
    marks = updateMarks(marks, { type: "guarded", address: "chat", app: windows[0].app });
    marks = updateMarks(marks, { type: "muted", muted: ["site:chat.google.com"], windows });
    assert.deepEqual(shown(marks, windows, ["site:chat.google.com"]), ["mail"], "google.com isn't muted, so Mail keeps its mark");
    // Chat's marks, the guard's and the notification's, are gone for good.
    marks = updateMarks(marks, { type: "muted", muted: [], windows });
    assert.deepEqual(shown(marks, windows), ["mail"]);
    assert.deepEqual(order(marks, windows), ["mail"]);
});

test("an update that moves a notification to a muted site drops its marks", () => {
    const windows = [win("mail", 3, "chrome-mail.google.com__-Default"), win("slack", 4, "Slack")];
    const muted = ["site:chat.google.com"];
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: [windows[0].app], windows, visible: new Set([2]), muted,
        sender: noteOf("google-chrome", "", "mail.google.com") });
    marks = updateMarks(marks, { type: "notified", id: 2, app: "Slack", windows, visible: new Set([2]), muted,
        sender: noteOf("", "Slack", "") });
    assert.deepEqual(shown(marks, windows, muted), ["mail", "slack"]);
    // The same notification, updated to come from the muted site.
    marks = updateMarks(marks, { type: "notified", id: 1, app: [windows[0].app], windows, visible: new Set([2]), muted,
        sender: noteOf("google-chrome", "", "chat.google.com") });
    assert.deepEqual(shown(marks, windows, muted), ["slack"], "its marks go, another notification's stay");
    assert.deepEqual(order(marks, windows, muted), ["slack"]);
});

test("muting clears the marks it had, so unmuting brings none back", () => {
    const windows = [win("a", 3, "Slack")];
    let marks = updateMarks(NO_MARKS, { type: "guarded", address: "a" });
    marks = updateMarks(marks, { type: "notified", id: 1, app: "Slack", windows, visible: new Set([2]) });
    marks = updateMarks(marks, { type: "muted", muted: ["slack"], windows });
    unmarked(marks, windows, ["slack"]);
    unmarked(updateMarks(marks, { type: "muted", muted: [], windows }), windows);
});

// Two monitors, the workspaces spanning both (SPEC.md §6.5, Monitors):
// eDP-1 is main, so DP-2's parts are NAME@DP-2.
function spanning() {
    return {
        monitors: [{ name: "eDP-1", workspace: -1340 }, { name: "DP-2", workspace: -1341 }],
        workspaces: [
            { id: -1338, name: "in" },
            { id: -1339, name: "in@DP-2" },
            { id: -1340, name: "re" },
            { id: -1341, name: "re@DP-2" },
            { id: -1342, name: "docs@DP-2" },
        ],
        windows: [
            { address: "a", workspace: -1340, workspaceName: "re", app: "kitty", urgent: false, fullscreen: 0 },
            { address: "b", workspace: -1341, workspaceName: "re@DP-2", app: "chrome", urgent: false, fullscreen: 0 },
            { address: "c", workspace: -1342, workspaceName: "docs@DP-2", app: "chrome", urgent: false, fullscreen: 0 },
        ],
    };
}

test("a workspace spanning monitors is one entry, with every part's ID", () => {
    const order = workspaceOrder(spanning().workspaces, ["in", "re"]);
    assert.deepEqual(order.map((w) => [w.name, w.id, w.ids]), [
        ["in", -1338, [-1338, -1339]],
        ["re", -1340, [-1340, -1341]],
        ["docs", -1342, [-1342]],
    ]);
});

test("each monitor's bar marks the workspace whose part it shows as current, with no outline", () => {
    const s = spanning();
    for (const monitor of ["eDP-1", "DP-2"]) {
        const bar = barWorkspaces({ monitor, ...s, standing: ["in", "re"] });
        assert.deepEqual(bar.map((w) => [w.name, w.state]), [["in", "empty"], ["re", "current"], ["docs", "occupied"]], monitor);
        const re = bar.find((w) => w.name === "re");
        assert.equal(re.count, 2, "both parts' windows count");
    }
});

test("scrolling steps from the workspace whose part a monitor shows", () => {
    const s = spanning();
    const bar = barWorkspaces({ monitor: "DP-2", ...s, standing: ["in", "re"] });
    assert.equal(scrollTarget(bar, -1341, 1), "docs");
    assert.equal(scrollTarget(bar, -1341, -1), "in");
});

test("a main part made again doesn't move its workspace on the bar", () => {
    // alpha was made before beta, and kept windows on DP-2 only; going
    // back to it made its main part again, newer than beta.
    const order = workspaceOrder([
        { id: -1340, name: "alpha@DP-2" },
        { id: -1342, name: "beta" },
        { id: -1344, name: "alpha" },
    ], []);
    assert.deepEqual(order.map((w) => [w.name, w.id]), [["alpha", -1344], ["beta", -1342]]);
});

test("a window minimized from a monitor's part shows on its workspace's chip", () => {
    const s = spanning();
    s.windows.push({ address: "m", workspace: -98, workspaceName: "special:minimized:re@DP-2", app: "mail", urgent: true, fullscreen: 0 });
    const bar = barWorkspaces({ monitor: "eDP-1", ...s, standing: ["in", "re"] });
    const re = bar.find((w) => w.name === "re");
    assert.equal(re.urgent, true);
    assert.deepEqual(re.icons.map((i) => [i.address, i.restoreTo]), [["m", "re@DP-2"]]);
});

test("a mark made after an unmute stands, though one made before the mute never comes back", () => {
    const windows = [win("a", 3, "Slack")];
    let marks = updateMarks(NO_MARKS, { type: "notified", id: 1, app: "Slack", windows, visible: new Set([2]) });
    marks = updateMarks(marks, { type: "muted", muted: ["slack"], windows });
    marks = updateMarks(marks, { type: "muted", muted: [], windows });
    unmarked(marks, windows);
    marks = updateMarks(marks, { type: "notified", id: 2, app: "Slack", windows, visible: new Set([2]) });
    assert.deepEqual(shown(marks, windows), ["a"]);
    // The old one updated is news too, and marks again.
    marks = updateMarks(marks, { type: "dismissed", id: 2 });
    marks = updateMarks(marks, { type: "notified", id: 1, app: "Slack", windows, visible: new Set([2]) });
    assert.deepEqual(order(marks, windows), ["a"]);
});

test("a notification updated after its window was focused marks it again", () => {
    let marks = updateMarks(notified(), { type: "focused", address: "n2" });
    unmarked(marks);
    marks = notified(marks);
    assert.deepEqual(shown(marks), ["n2", "n3"]);
});

test("an app's activation keeps its notifications' app-wide marks cleared, however many activations follow", () => {
    let marks = updateMarks(notified(), activatedEvent("n2", nautilus));
    for (let i = 0; i < 60; i++) {
        marks = updateMarks(marks, activatedEvent("k", nautilus));
    }
    unmarked(marks);
});

test("a focus that attended to a notification keeps all its marks cleared when that window closes", () => {
    let marks = updateMarks(notified(), { type: "focused", address: "n2" });
    marks = updateMarks(marks, { type: "closed", address: "n2" });
    unmarked(marks, nautilus.filter((w) => w.address !== "n2"));
});

test("an update re-marking the focused window doesn't bring back the others' cleared marks", () => {
    let marks = updateMarks(notified(), { type: "focused", address: "n2" });
    // Updated while n2 is hidden and n3 is on screen: only n2 is marked again.
    marks = updateMarks(marks, { type: "notified", id: 1, app: "nautilus", windows: nautilus, visible: new Set([2, 6]) });
    assert.deepEqual(shown(marks), ["n2"]);
    assert.deepEqual(order(marks), ["n2"]);
});
