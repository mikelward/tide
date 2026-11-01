// Tests for tabs.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { activateLine, applied, parseLine, placed, tabRows, tabsNote, titleMatches } from "./tabs.mjs";
import { windowRows } from "./switcher.mjs";

const CHROME = {
    type: "tabs",
    source: "1",
    browser: "Google Chrome",
    windows: [
        { id: 7, focused: true, title: "Docs", tabs: [
            { id: 71, title: "Inbox", url: "https://mail.example.com/u/0", active: false },
            { id: 72, title: "Docs", url: "https://docs.example.com/", active: true },
        ] },
        { id: 8, title: "Gone", tabs: [{ id: 81, title: "Gone", url: "https://example.com/", active: true }] },
    ],
};

const WINDOWS = [
    { address: "0xa", title: "Docs - Google Chrome", app: "google-chrome", workspace: "work", focus: 0 },
    { address: "0xb", title: "notes.md - kitty", app: "kitty", workspace: "work", focus: 1 },
];

test("lines are parsed, and a bad one is said so", () => {
    assert.deepEqual(parseLine('{"type":"ready"}'), { message: { type: "ready" } });
    assert.match(parseLine("nope").error, /isn't JSON/);
    assert.match(parseLine("[1]").error, /without a type/);
});

test("each browser's tabs replace its last, and go when it does", () => {
    let b = applied({}, CHROME);
    b = applied(b, { type: "tabs", source: "2", browser: "Brave", windows: [] });
    assert.deepEqual(Object.keys(b).sort(), ["1", "2"]);
    assert.equal(b["1"].windows[0].tabs[1].title, "Docs");
    b = applied(b, Object.assign({}, CHROME, { windows: [] }));
    assert.deepEqual(b["1"].windows, []);
    b = applied(b, { type: "gone", source: "1" });
    assert.deepEqual(Object.keys(b), ["2"]);
    assert.deepEqual(applied(b, { type: "gone", source: "9" }), b);
    assert.deepEqual(applied(b, { type: "fault", message: "x" }), {});
    assert.deepEqual(applied(b, { type: "ready" }), b);
});

test("a window is found by its active tab's title and its browser's name", () => {
    assert.ok(titleMatches("Docs - Google Chrome", "Docs", "Google Chrome"));
    assert.ok(titleMatches("Docs - Brave", "Docs", "Brave"));
    assert.ok(titleMatches("Docs - Work - Google Chrome", "Docs", "Google Chrome"), "with a profile's name");
    assert.ok(titleMatches("Docs - Google Chrome - Work", "Docs", "Google Chrome"));
    assert.ok(!titleMatches("Docs - Brave", "Docs", "Google Chrome"), "another browser's");
    assert.ok(!titleMatches("Docs - kitty", "Docs", "Google Chrome"), "another app's");
    assert.ok(!titleMatches("Docs2 - Google Chrome", "Docs", "Google Chrome"));
    // A bare title only on a browser's window.
    assert.ok(titleMatches("Docs", "Docs", "Google Chrome", "google-chrome"));
    assert.ok(!titleMatches("Docs", "Docs", "Google Chrome", "kitty"));
    assert.ok(!titleMatches("Anything", "", "Google Chrome"));
});

test("another app's window with the same title doesn't take a browser's tabs", () => {
    const windows = [
        { address: "0xk", title: "Docs - kitty", app: "kitty", workspace: "work" },
        { address: "0xd", title: "Docs", app: "org.gnome.TextEditor", workspace: "work" },
        { address: "0xa", title: "Docs - Google Chrome", app: "google-chrome", workspace: "work" },
    ];
    const tabs = tabRows(applied({}, CHROME), windows);
    assert.deepEqual(Object.keys(tabs).sort(), ["", "0xa"]);
    assert.equal(tabs["0xa"][0].item.address, "0xa");
});

test("a minimized browser's tab brings its window back where it came from", () => {
    const windows = [{ address: "0xa", title: "Docs - Google Chrome", app: "google-chrome", workspace: "special:minimized:work" }];
    const item = tabRows(applied({}, CHROME), windows)["0xa"][0].item;
    assert.equal(item.restoreTo, "work");
    assert.equal(tabRows(applied({}, CHROME), WINDOWS)["0xa"][0].item.restoreTo, null);
});

test("two windows with one title go under the first", () => {
    const b = applied({}, Object.assign({}, CHROME, { windows: [
        { id: 1, title: "Docs", tabs: [] },
        { id: 2, title: "Docs", tabs: [] },
    ] }));
    // One toplevel: both windows find it.
    assert.deepEqual(placed(b, WINDOWS).map((p) => p.address), ["0xa", "0xa"]);
    // Two: each takes its own.
    const two = WINDOWS.concat([{ address: "0xc", title: "Docs - Google Chrome", app: "google-chrome" }]);
    assert.deepEqual(placed(b, two).map((p) => p.address), ["0xa", "0xc"]);
});

test("the Windows tab lists each window's tabs under it, and the rest last", () => {
    const tabs = tabRows(applied({}, CHROME), WINDOWS);
    const rows = windowRows(WINDOWS, "", [], tabs);
    assert.deepEqual(rows.map((r) => [r.item.kind, r.item.name]), [
        ["window", "Docs - Google Chrome"],
        ["tab", "Inbox"],
        ["tab", "Docs"],
        ["window", "notes.md - kitty"],
        ["tab", "Gone"],
    ]);
    const inbox = rows[1].item;
    assert.equal(inbox.sub, "tab · Google Chrome · mail.example.com");
    assert.equal(rows[2].item.sub, "tab · Google Chrome · showing · docs.example.com");
    assert.deepEqual([inbox.source, inbox.tabId, inbox.windowId, inbox.address, inbox.icon], ["1", 71, 7, "0xa", "google-chrome"]);
    assert.equal(rows[4].item.address, null, "a tab whose window isn't found still goes");
    // Typing finds a tab by title or site.
    assert.deepEqual(windowRows(WINDOWS, "inbox", [], tabs).map((r) => r.item.name), ["Inbox"]);
    assert.ok(windowRows(WINDOWS, "mail.example", [], tabs).some((r) => r.item.name === "Inbox"));
    // With no tabs, as before.
    assert.deepEqual(windowRows(WINDOWS, "").map((r) => r.item.kind), ["window", "window"]);
});

test("Enter asks the tab's own browser", () => {
    const item = tabRows(applied({}, CHROME), WINDOWS)["0xa"][0].item;
    assert.deepEqual(JSON.parse(activateLine(item)), { type: "activate", source: "1", tabId: 71, windowId: 7 });
});

test("the tab says why no browser tabs are listed", () => {
    assert.match(tabsNote(false, {}), /tide-tabs isn't running/);
    assert.match(tabsNote(true, {}), /no browser has the tide connector or tileco/);
    assert.equal(tabsNote(true, applied({}, CHROME)), "");
});
