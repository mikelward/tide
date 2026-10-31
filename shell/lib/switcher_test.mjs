// Tests for switcher.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    TABS, TAB_NAMES, PLACEHOLDERS, footerKeys, movedTab, toggled, logoTapped, tabChanged, workspaceRows, windowRows, attentionRows, emptyText,
} from "./switcher.mjs";
import { NO_MARKS, updateMarks, barWorkspaces } from "./workspaces.mjs";

test("four tabs, in the spec's order, each named", () => {
    assert.deepEqual([...TABS], ["apps", "workspaces", "windows", "attention"]);
    for (const t of TABS) {
        assert.ok(TAB_NAMES[t] && PLACEHOLDERS[t], t);
    }
});

test("Tab and Shift+Tab move between tabs, and wrap", () => {
    assert.equal(movedTab("apps", 1), "workspaces");
    assert.equal(movedTab("attention", 1), "apps");
    assert.equal(movedTab("apps", -1), "attention");
    assert.equal(movedTab("windows", -1), "workspaces");
});

test("the footer names only the keys that work on the tab, Tab as next tab", () => {
    const keys = (tab) => footerKeys(tab).map(([k]) => k);
    const said = (tab, key) => (footerKeys(tab).find(([k]) => k === key) ?? [])[1];
    for (const t of TABS) {
        assert.equal(said(t, "Tab"), "next tab", t);
        assert.equal(said(t, "Esc"), "close", t);
    }
    assert.deepEqual(keys("apps"), ["↑↓", "↵", "Ctrl+↵", "PgDn", "Tab", "Esc"]);
    assert.equal(said("apps", "↵"), "run");
    assert.deepEqual(keys("workspaces"), ["↑↓", "↵", "Tab", "Esc"], "Ctrl+Enter and sections are the Apps tab's");
    assert.equal(said("workspaces", "↵"), "go");
    assert.deepEqual(keys("windows"), ["↑↓", "↵", "Ctrl+M", "Tab", "Esc"]);
    assert.deepEqual(keys("attention"), ["↑↓", "↵", "Ctrl+M", "Tab", "Esc"]);
});

test("each key opens its own tab, and the same key again closes it", () => {
    assert.deepEqual(toggled(false, "apps", "workspaces"), { visible: true, tab: "workspaces" });
    assert.deepEqual(toggled(true, "workspaces", "workspaces"), { visible: false, tab: "workspaces" });
    assert.deepEqual(toggled(true, "apps", "attention"), { visible: true, tab: "attention" }, "another key moves to its tab");
    assert.throws(() => toggled(false, "apps", "tabs"), /not a switcher tab/);
});

const named = (...names) => names.map((name, i) => ({ id: -1338 - i, name }));
const win = (address, workspace, app, extra = {}) => Object.assign({ address, workspace, app, urgent: false, fullscreen: 0 }, extra);

test("the Workspaces tab lists the bar's workspaces, current one said so", () => {
    const list = barWorkspaces({
        monitor: "DP-1",
        monitors: [{ name: "DP-1", workspace: -1339 }],
        workspaces: named("in", "PR-12"),
        windows: [win("a", -1338, "thunderbird"), win("b", -1339, "kitty"), win("c", -1339, "firefox")],
        standing: ["in", "re"],
    });
    const rows = workspaceRows(list, "");
    assert.deepEqual(rows.map((r) => r.item.name), ["in", "re", "PR-12"]);
    assert.deepEqual(rows.map((r) => r.item.sub), ["home · 1 window", "not made yet", "current"]);
    assert.equal(rows[0].item.icon, "thunderbird");
    assert.equal(rows[2].item.icon, "kitty", "its first window's, though the bar shows no icon for it");
    assert.equal(rows[2].item.current, true);
    assert.equal(rows[0].item.kind, "workspace");
    // Typing filters by name.
    assert.deepEqual(workspaceRows(list, "pr").map((r) => r.item.name), ["PR-12"]);
    assert.deepEqual(workspaceRows(list, "pr")[0].positions, [0, 1]);
});

const windows = [
    { address: "a", title: "Inbox", app: "thunderbird", appName: "Thunderbird", workspace: "in", focus: 2 },
    { address: "b", title: "~/src", app: "kitty", appName: "kitty", workspace: "PR-12", focus: 0 },
    { address: "c", title: "Docs", app: "firefox", appName: "Firefox", workspace: "docs", focus: 1 },
];

test("the Windows tab lists every window, the one used last first, with its app and workspace", () => {
    const rows = windowRows(windows, "");
    assert.deepEqual(rows.map((r) => r.item.address), ["b", "c", "a"]);
    assert.equal(rows[0].item.sub, "kitty · PR-12");
    assert.equal(rows[0].item.kind, "window");
});

test("typing on the Windows tab matches titles and app names", () => {
    assert.deepEqual(windowRows(windows, "inbox").map((r) => r.item.address), ["a"]);
    assert.deepEqual(windowRows(windows, "fire").map((r) => r.item.address), ["c"], "by app name");
    assert.deepEqual(windowRows(windows, "fire")[0].positions, [], "only the title's letters are underlined");
    assert.deepEqual(windowRows(windows, "zzz"), []);
});

test("the Attention tab lists the marked windows, the latest mark first", () => {
    let marks = updateMarks(NO_MARKS, { type: "guarded", address: "a" });
    marks = updateMarks(marks, { type: "guarded", address: "b" });
    const rows = attentionRows(windows.map((w) => Object.assign({}, w, { urgent: w.address === "c" })), marks, "");
    assert.deepEqual(rows.map((r) => r.item.address), ["b", "a", "c"], "the guard's newest first, then Hyprland's urgent one");
    // Focusing one clears its mark, and it leaves the tab.
    const after = updateMarks(marks, { type: "focused", address: "b" });
    assert.deepEqual(attentionRows(windows, after, "").map((r) => r.item.address), ["a"]);
});

test("a tab with nothing to show says so", () => {
    assert.deepEqual(attentionRows(windows, NO_MARKS, ""), []);
    assert.equal(emptyText("attention", ""), "No window wants attention");
    assert.equal(emptyText("windows", ""), "No windows open");
    assert.equal(emptyText("workspaces", "x"), "Nothing matches");
});

test("leaving the Apps tab cancels a power action's confirmation, and its pending check", () => {
    const waiting = { tab: "apps", asking: "reboot", checking: true, session: 4 };
    const moved = tabChanged(waiting, "workspaces");
    assert.deepEqual(moved, { tab: "workspaces", asking: "", checking: false, session: 5 });
    // The check started in session 4 answers now: it's stale, so it acts on nothing.
    const token = waiting.session;
    assert.notEqual(token, moved.session);
    // Staying on the tab changes nothing.
    assert.equal(tabChanged(waiting, "apps"), waiting);
});

test("a minimized window is listed under the workspace it came from, and Enter restores it there", () => {
    const rows = windowRows([
        { address: "a", title: "Inbox", app: "thunderbird", appName: "Thunderbird", workspace: "special:minimized:re", focus: 0 },
        { address: "b", title: "~/src", app: "kitty", appName: "kitty", workspace: "re", focus: 1 },
    ], "");
    assert.equal(rows[0].item.sub, "Thunderbird · re · minimized");
    assert.equal(rows[0].item.restoreTo, "re");
    assert.equal(rows[1].item.sub, "kitty · re");
    assert.equal(rows[1].item.restoreTo, null, "an ordinary window is gone to, not restored");
});

test("a minimized window wanting attention is restored from the Attention tab too", () => {
    const marks = updateMarks(NO_MARKS, { type: "guarded", address: "a" });
    const rows = attentionRows([{ address: "a", title: "Chat", app: "chat", appName: "Chat", workspace: "special:minimized:in", focus: 0 }], marks, "");
    assert.equal(rows[0].item.restoreTo, "in");
});

test("muted rows say so, and say what Ctrl+M adds", () => {
    const rows = windowRows([
        { address: "a", title: "Chat", app: "chrome-chat.google.com__-Default", appName: "Chat", workspace: "in", focus: 0 },
        { address: "b", title: "~/src", app: "kitty", appName: "kitty", workspace: "re", focus: 1 },
    ], "", ["site:chat.google.com"]);
    assert.deepEqual(rows.map((r) => [r.item.muted, r.item.muteEntry]), [[true, "site:chat.google.com"], [false, "kitty"]]);
    assert.equal(rows[0].item.sub, "Chat · in · muted");
    assert.equal(rows[1].item.sub, "kitty · re");
});

test("the Attention tab leaves out a muted app's windows", () => {
    const marks = updateMarks(NO_MARKS, { type: "guarded", address: "a" });
    const rows = [{ address: "a", title: "Slack", app: "Slack", appName: "Slack", workspace: "in", focus: 0 }];
    assert.equal(attentionRows(rows, marks, "").length, 1);
    assert.deepEqual(attentionRows(rows, marks, "", ["slack"]), []);
});

test("the logo opens Apps, closes it on its own monitor, and moves it from another", () => {
    assert.deepEqual(logoTapped(false, "workspaces", false), { visible: true, tab: "apps", move: false });
    // On the logo's monitor the backdrop takes the tap and closes it, on any tab.
    assert.deepEqual(logoTapped(true, "apps", false), { visible: false, tab: "apps", move: false });
    assert.deepEqual(logoTapped(true, "windows", false), { visible: false, tab: "windows", move: false });
    // Open on another monitor, on any tab: Apps, on the logo's monitor.
    assert.deepEqual(logoTapped(true, "attention", true), { visible: true, tab: "apps", move: true });
    assert.deepEqual(logoTapped(true, "apps", true), { visible: true, tab: "apps", move: true });
});
