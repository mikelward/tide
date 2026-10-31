// Tests for workspacepage.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { editedList, itemNote, movedItem, withItem, withoutItem } from "./workspacepage.mjs";

const SHARED = '{"standing": ["in", "re", "oc", "me"], "inApps": ["mail.google.com"]}';

test("the first change to a list copies the shared one into the local file, keeping its other settings", () => {
    const r = editedList(SHARED, '{"muted": ["slack"]}', "standing", l => withItem(l, " docs "));
    assert.deepEqual(r.list, ["in", "re", "oc", "me", "docs"]);
    assert.deepEqual(JSON.parse(r.text), { muted: ["slack"], standing: ["in", "re", "oc", "me", "docs"] });
});

test("moving a workspace first makes it home", () => {
    const r = editedList(SHARED, null, "standing", l => movedItem(l, 2, "oc", -2));
    assert.deepEqual(r.list, ["oc", "in", "re", "me"]);
    assert.equal(itemNote("standing", 0), "home");
    assert.equal(itemNote("inApps", 0), "");
});

test("a list the files wouldn't take is refused, saying why", () => {
    assert.match(editedList(SHARED, null, "standing", l => withItem(l, "RE")).error, /RE is listed already/);
    assert.match(editedList(SHARED, null, "standing", l => withItem(l, 'say "hi"')).error, /^standing: /);
    assert.match(editedList('{"standing": ["in"]}', null, "standing", l => withoutItem(l, 0, "in")).error, /standing must name at least one workspace/);
    assert.match(editedList(SHARED, null, "namePatterns", l => withItem(l, "[A-Z]+")).error, /has no capture group/);
    assert.match(editedList(SHARED, null, "namePatterns", l => withItem(l, "(")).error, /doesn't compile/);
    assert.match(editedList(SHARED, null, "inApps", l => withItem(l, "  ")).error, /type something/);
});

test("a pattern with a capture group is added, and home's apps take a site", () => {
    assert.deepEqual(editedList(SHARED, null, "namePatterns", l => withItem(l, "\\b([A-Z]+-[0-9]+)\\b")).list, ["\\b([A-Z]+-[0-9]+)\\b"]);
    assert.deepEqual(editedList(SHARED, null, "inApps", l => withItem(l, "calendar.google.com")).list, ["mail.google.com", "calendar.google.com"]);
});

test("a change names its entry by place and text, so a hand edit since is refused", () => {
    assert.match(editedList(SHARED, null, "standing", l => withoutItem(l, 0, "re")).error, /entry 1 isn't re/);
    assert.match(editedList(SHARED, null, "inApps", l => withoutItem(l, undefined, "x")).error, /x isn't listed/);
});

test("a file that doesn't load, or a list that isn't the page's, changes nothing", () => {
    assert.match(editedList(SHARED, "{", "inApps", l => ({ list: l })).error, /^workspaces\.local\.json: /);
    assert.match(editedList(SHARED, null, "muted", l => ({ list: l })).error, /muted isn't one of the page's lists/);
});
