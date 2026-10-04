// Tests for history.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_ENTRIES, GROUP_SHOWN, record, appOf, groups, clearApp, apply, shownItems, age, unread, serialize, parse, clickTarget } from "./history.mjs";

// A history after a sequence of changes.
const replay = (state, changes) => changes.reduce(apply, state);

const note = (key, app, summary, extra = {}) => ({ key, app, icon: "", entry: "", summary, body: "", critical: false, ...extra });

test("a notification goes on top, with the time it arrived", () => {
    let h = record([], note("1", "Mail", "a"), 100);
    h = record(h, note("2", "Chat", "b"), 200);
    assert.deepEqual(h.map(e => [e.key, e.summary, e.time]), [["2", "b", 200], ["1", "a", 100]]);
    assert.deepEqual(Object.keys(h[0]).sort(), ["app", "body", "critical", "entry", "icon", "key", "summary", "time"]);
});

test("an update in place replaces its entry and comes back to the top", () => {
    let h = record([], note("1", "Mail", "old"), 100);
    h = record(h, note("2", "Chat", "b"), 200);
    h = record(h, note("1", "Mail", "new"), 300);
    assert.deepEqual(h.map(e => [e.key, e.summary]), [["1", "new"], ["2", "b"]]);
});

test("a synchronous replacement takes the place of the one it replaced", () => {
    let h = record([], note("1", "Player", "track 1"), 100);
    h = record(h, note("2", "Player", "track 2", { replaces: "1" }), 200);
    assert.deepEqual(h.map(e => e.key), ["2"]);
});

test("a transient notification stays out of the history", () => {
    const h = record([], note("1", "Mail", "a"), 100);
    assert.equal(record(h, note("2", "Mail", "b", { transient: true }), 200), h);
});

test("an update that makes a notification transient takes it out", () => {
    let h = record([], note("1", "Mail", "a"), 100);
    h = record(h, note("2", "Chat", "b"), 200);
    assert.deepEqual(record(h, note("1", "Mail", "a", { transient: true }), 300).map(e => e.key), ["2"]);
});

test("the history keeps the newest 200", () => {
    let h = [];
    for (let i = 0; i < MAX_ENTRIES + 5; i++) {
        h = record(h, note(String(i), "Mail", "x"), i);
    }
    assert.equal(h.length, MAX_ENTRIES);
    assert.equal(h[0].key, String(MAX_ENTRIES + 4));
    assert.equal(h.at(-1).key, "5");
});

test("entries group by app, the group with the newest first", () => {
    let h = record([], note("1", "Mail", "m1"), 100);
    h = record(h, note("2", "Chat", "c1"), 200);
    h = record(h, note("3", "Mail", "m2"), 300);
    h = record(h, note("4", "", "x", { entry: "org.example.Tool" }), 400);
    assert.deepEqual(groups(h).map(g => [g.app, g.items.map(e => e.summary)]), [
        ["org.example.Tool", ["x"]],
        ["Mail", ["m2", "m1"]],
        ["Chat", ["c1"]],
    ]);
    assert.equal(appOf(note("5", "", "y")), "Notifications");
    assert.deepEqual(groups([]), []);
});

test("a group's ✕ clears only that app", () => {
    let h = record([], note("1", "Mail", "m1"), 100);
    h = record(h, note("2", "Chat", "c1"), 200);
    assert.deepEqual(clearApp(h, "Mail").map(e => e.key), ["2"]);
});

test("changes apply to the loaded history, in order", () => {
    let entries = record([], note("1", "Mail", "old mail"), 100);
    entries = record(entries, note("2", "Chat", "old chat"), 200);
    const loaded = { entries, unread: [] };
    const keys = state => state.entries.map(e => e.key);
    const arrived = { op: "record", item: note("3", "Mail", "new"), time: 300 };
    // An arrival goes on top of what was on disk.
    assert.deepEqual(keys(replay(loaded, [arrived])), ["3", "2", "1"]);
    // A Clear all clears what was on disk too, and order matters.
    assert.deepEqual(keys(replay(loaded, [arrived, { op: "clearAll" }])), []);
    assert.deepEqual(keys(replay(loaded, [{ op: "clearAll" }, arrived])), ["3"]);
    // As does a group's ✕.
    assert.deepEqual(keys(replay(loaded, [arrived, { op: "clearApp", app: "Mail" }])), ["2"]);
    // Opening the center marks what was on disk seen.
    assert.deepEqual(replay({ entries, unread: ["1"] }, [{ op: "seen" }]).unread, []);
    assert.equal(replay(loaded, []), loaded);
    assert.throws(() => apply(loaded, { op: "bogus" }), /unknown history change bogus/);
});

test("a notification carried over a reload is recorded only if it's missing", () => {
    const empty = { entries: [], unread: [] };
    const mail = { op: "record", item: note("1", "Mail", "a"), time: 100 };
    const carried = { op: "record", item: note("1", "Mail", "a"), time: 500, carried: true };
    // Already there (it was saved): left as it was, not moved or made unread.
    const saved = replay(empty, [mail, { op: "seen" }]);
    assert.equal(replay(saved, [carried]), saved);
    // Missing (it was never saved): kept.
    const kept = replay(empty, [carried]);
    assert.deepEqual(kept.entries.map(e => [e.key, e.time]), [["1", 500]]);
    assert.deepEqual(kept.unread, ["1"]);
});

test("a group shows three, and the rest behind Show N more", () => {
    assert.equal(GROUP_SHOWN, 3);
    const items = ["a", "b", "c", "d", "e"];
    assert.deepEqual(shownItems(items, false), { items: ["a", "b", "c"], more: 2 });
    assert.deepEqual(shownItems(items, true), { items, more: 0 });
    assert.deepEqual(shownItems(["a", "b", "c"], false), { items: ["a", "b", "c"], more: 0 });
});

test("ages read now, minutes, hours, then days", () => {
    const min = 60000;
    assert.equal(age(1000, 1000 + 59000), "now");
    assert.equal(age(0, 11 * min), "11 min");
    assert.equal(age(0, 59 * min), "59 min");
    assert.equal(age(0, 60 * min), "1 h");
    assert.equal(age(0, 47 * 60 * min), "1 d");
    // A clock that went back is "now", not a negative age.
    assert.equal(age(5000, 1000), "now");
});

test("the bell's dot is for what arrived since the center was open, in order", () => {
    const empty = { entries: [], unread: [] };
    const mail = { op: "record", item: note("1", "Mail", "a"), time: 100 };
    const seen = { op: "seen" };
    assert.equal(unread(replay(empty, [mail])), true);
    assert.equal(unread(replay(empty, [mail, seen])), false);
    // An arrival after the center was open counts, even with an earlier
    // clock or the same millisecond.
    const late = { op: "record", item: note("2", "Mail", "b"), time: 50 };
    assert.equal(unread(replay(empty, [mail, seen, late])), true);
    // A transient one adds nothing to read.
    const transient = { op: "record", item: note("3", "Mail", "c", { transient: true }), time: 200 };
    assert.equal(unread(replay(empty, [mail, seen, transient])), false);
    // Nothing left after a clear, so no dot.
    assert.equal(unread(replay(empty, [mail, { op: "clearAll" }])), false);
    // An unread arrival made transient by an update stops counting, even
    // with an older, seen entry still there.
    const chat = { op: "record", item: note("4", "Chat", "d"), time: 300 };
    const chatTransient = { op: "record", item: note("4", "Chat", "d", { transient: true }), time: 310 };
    assert.equal(unread(replay(empty, [mail, seen, chat, chatTransient])), false);
    // As does one whose group is cleared, while another unread one stays.
    const clearChat = { op: "clearApp", app: "Chat" };
    assert.deepEqual(replay(empty, [mail, seen, chat, clearChat]).unread, []);
    assert.deepEqual(replay(empty, [mail, chat, clearChat]).unread, ["1"]);
    assert.equal(unread(empty), false);
});

test("the history survives a round trip through the file", () => {
    let h = record([], note("1", "Mail", "a", { body: "<b>hi</b>", critical: true, icon: "mail" }), 100);
    h = record(h, note("2", "Chat", "b"), 200);
    assert.deepEqual(parse(serialize({ entries: h, unread: ["2"] })), { entries: h, unread: ["2"], errors: [] });
    // An unread key with no entry is dropped.
    assert.deepEqual(parse(serialize({ entries: h, unread: ["2", "9"] })).unread, ["2"]);
});

test("no file yet is an empty history, not an error", () => {
    assert.deepEqual(parse(null), { entries: [], unread: [], errors: [] });
    assert.deepEqual(parse(""), { entries: [], unread: [], errors: [] });
});

test("a damaged file is reported, keeping what can be read", () => {
    const bad = parse("{nope");
    assert.deepEqual(bad.entries, []);
    assert.match(bad.errors[0], /^not JSON/);
    assert.deepEqual(parse('{"version": 2, "entries": []}').errors, ["not a version 1 history"]);
    assert.deepEqual(parse("[]").errors, ["not a version 1 history"]);

    const good = { key: "1", app: "Mail", icon: "", entry: "", summary: "a", body: "", critical: false, time: 100 };
    const newer = { ...good, key: "2", time: 200 };
    const mixed = parse(JSON.stringify({ version: 1, unread: "x", entries: [good, { key: 3 }, null, newer] }));
    // Sorted newest first whatever the file's order.
    assert.deepEqual(mixed.entries, [newer, good]);
    assert.deepEqual(mixed.unread, []);
    assert.deepEqual(mixed.errors, ["2 unreadable entries left out"]);
});

test("a file past the cap is cut to the newest 200", () => {
    const entries = [];
    for (let i = 0; i < MAX_ENTRIES + 3; i++) {
        entries.push({ key: String(i), app: "Mail", icon: "", entry: "", summary: "", body: "", critical: false, time: i });
    }
    const h = parse(JSON.stringify({ version: 1, unread: [], entries }));
    assert.equal(h.entries.length, MAX_ENTRIES);
    assert.equal(h.entries[0].key, String(MAX_ENTRIES + 2));
});

const byDefault = actions => actions.find(a => a.identifier === "default") ?? null;

test("a click on a live entry runs its default action", () => {
    const open = { identifier: "default", text: "Open" };
    const live = { actions: [{ identifier: "reply", text: "Reply" }, open] };
    assert.deepEqual(clickTarget(note("1", "Chat", "hi", { entry: "org.example.Chat" }), live, byDefault), { action: open });
});

test("a click on an entry whose notification is gone brings up its app", () => {
    assert.deepEqual(clickTarget(note("1", "Chat", "hi", { entry: "org.example.Chat" }), null, byDefault), { app: "org.example.Chat" });
    assert.deepEqual(clickTarget(note("1", "Chat", "hi"), null, byDefault), { app: "Chat" });
});

test("a live entry without a default action is dismissed, as its popup would be", () => {
    const live = { actions: [{ identifier: "reply", text: "Reply" }] };
    assert.deepEqual(clickTarget(note("1", "Chat", "hi"), live, byDefault), { dismiss: true });
    assert.deepEqual(clickTarget(note("1", "", "hi"), { actions: [] }, byDefault), { dismiss: true });
});

test("a gone entry names its app by desktop entry, else app name", () => {
    assert.deepEqual(clickTarget(note("1", "Chat", "hi", { entry: " " }), null, byDefault), { app: "Chat" });
});

test("an entry that names no app has nothing to bring up", () => {
    assert.equal(clickTarget(note("1", "", "hi"), null, byDefault), null);
});
