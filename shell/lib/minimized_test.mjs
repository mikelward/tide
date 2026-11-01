// Tests for minimized.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PREFIX, minimizedWorkspace, minimizedFrom, isMinimizedFrom, isMinimizedFromWorkspace, minimizeFrom, trayWindows } from "./minimized.mjs";

test("a minimized window's workspace names the one it came from", () => {
    assert.equal(PREFIX, "special:minimized:");
    assert.equal(minimizedWorkspace("re"), "special:minimized:re");
    assert.equal(minimizedFrom("special:minimized:re"), "re");
    assert.equal(minimizedFrom(minimizedWorkspace("PR-12, login")), "PR-12, login");
});

test("only tide's minimize workspaces hold minimized windows", () => {
    assert.equal(minimizedFrom("re"), null);
    assert.equal(minimizedFrom("special:scratch"), null, "another special workspace");
    assert.equal(minimizedFrom("special:minimized:"), null, "no workspace after the prefix");
    assert.equal(minimizedFrom(undefined), null);
});

test("Super+Z minimizes the focused window from its workspace", () => {
    assert.deepEqual(minimizeFrom({ address: "55aa01", workspace: "re" }), { name: "re" });
});

test("Super+Z leaves alone a window it can't minimize, saying why", () => {
    assert.deepEqual(minimizeFrom(null), { error: "no window to minimize" });
    assert.deepEqual(minimizeFrom({ address: "55aa01", workspace: "special:minimized:re" }), { error: "the window is minimized already" });
    assert.deepEqual(minimizeFrom({ address: "55aa01", workspace: "special:scratch" }), { error: "the window is on a special workspace" });
    assert.deepEqual(minimizeFrom({ address: "55aa01", workspace: "" }), { error: "the window is on no workspace" });
});

const windows = [
    { address: "a", app: "chat", title: "#tide-dev", workspace: "special:minimized:re", focus: 1 },
    { address: "b", app: "kitty", title: "~/tide", workspace: "re", focus: 0 },
    { address: "c", app: "mail", title: "Inbox", workspace: "special:minimized:re", focus: 3 },
    { address: "d", app: "music", title: "", workspace: "special:minimized:in", focus: 2 },
];

test("a monitor's tray holds the windows minimized from the workspace it shows, the latest used last", () => {
    assert.deepEqual(trayWindows(windows, "re"), [
        { address: "c", app: "mail", title: "Inbox" },
        { address: "a", app: "chat", title: "#tide-dev" },
    ]);
    assert.deepEqual(trayWindows(windows, "in"), [{ address: "d", app: "music", title: "music" }], "an untitled window goes by its app");
});

test("a workspace with nothing minimized from it has an empty tray", () => {
    assert.deepEqual(trayWindows(windows, "oc"), []);
    assert.deepEqual(trayWindows(windows, ""), [], "a monitor showing no workspace");
    assert.deepEqual(trayWindows(windows, "special:minimized:re"), [], "nor does a minimize workspace itself");
});

test("a window minimized from a workspace matches it ignoring case, as the bar's standing names do", () => {
    assert.equal(isMinimizedFrom("special:minimized:Re", "re"), true);
    assert.equal(isMinimizedFrom("special:minimized:re", "oc"), false);
    assert.equal(isMinimizedFrom("re", "re"), false, "not minimized at all");
    const ws = [{ address: "a", app: "chat", title: "Chat", workspace: "special:minimized:Re", focus: 0 }];
    assert.deepEqual(trayWindows(ws, "re").map((w) => w.address), ["a"]);
    assert.deepEqual(trayWindows(ws, "RE").map((w) => w.address), ["a"]);
});

test("a window minimized from a monitor's part is its workspace's on the bar, and that part's in the tray", () => {
    const from = minimizedWorkspace("re@DP-2");
    assert.equal(minimizedFrom(from), "re@DP-2", "restoring it goes back to that part");
    assert.equal(isMinimizedFromWorkspace(from, "re"), true);
    assert.equal(isMinimizedFromWorkspace(from, "Re"), true, "ignoring case");
    assert.equal(isMinimizedFromWorkspace(minimizedWorkspace("re"), "re"), true);
    assert.equal(isMinimizedFromWorkspace(from, "oc"), false);
    const windows = [
        { address: "a", app: "kitty", title: "a", workspace: from, focus: 0 },
        { address: "b", app: "kitty", title: "b", workspace: minimizedWorkspace("re"), focus: 1 },
    ];
    assert.deepEqual(trayWindows(windows, "re@DP-2").map((w) => w.address), ["a"], "DP-2's tray");
    assert.deepEqual(trayWindows(windows, "re").map((w) => w.address), ["b"], "the main monitor's tray");
});
