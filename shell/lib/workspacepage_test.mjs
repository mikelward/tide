// Tests for workspacepage.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    editedList, editedWorkspace, itemNote, movedItem, withAskForName, withItem, withoutItem, withoutPinned, withPinned,
    workspaceHeading,
} from "./workspacepage.mjs";
import { loadWorkspaceSettings, workspaceSetting } from "./workspacenames.mjs";

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

test("a workspace's switch and pinned apps go to the local file, the settings in effect copied first", () => {
    const r = editedWorkspace(SHARED, '{"muted": ["slack"]}', "re", w => withAskForName(w, true));
    assert.deepEqual(JSON.parse(r.text), {
        muted: ["slack"],
        workspaceSettings: { in: { askForName: true }, re: { askForName: true, pinnedApps: [] } },
    }, "home keeps asking, as it did with no workspaceSettings");
    const settings = loadWorkspaceSettings(SHARED, r.text).settings;
    assert.equal(workspaceSetting(settings, "re").askForName, true);
    const off = editedWorkspace(SHARED, r.text, "IN", w => withAskForName(w, false));
    assert.deepEqual(JSON.parse(off.text).workspaceSettings.in, { askForName: false, pinnedApps: [] }, "matched ignoring case, keeping its own");
    const pinned = editedWorkspace(SHARED, off.text, "in", w => withPinned(w, " gmail "));
    assert.deepEqual(pinned.setting, { askForName: false, pinnedApps: ["gmail"] });
    assert.match(editedWorkspace(SHARED, pinned.text, "in", w => withPinned(w, "Gmail")).error, /Gmail is listed already/);
    assert.deepEqual(editedWorkspace(SHARED, pinned.text, "in", w => withoutPinned(w, 0, "gmail")).setting.pinnedApps, []);
    assert.match(editedWorkspace(SHARED, pinned.text, "in", w => withoutPinned(w, 0, "x")).error, /entry 1 isn't x/);
    assert.match(editedWorkspace(SHARED, "{", "in", w => withAskForName(w, true)).error, /workspaces.local.json/);
    assert.match(editedWorkspace(SHARED, null, "a@b", w => withAskForName(w, true)).error, /workspaceSettings: "a@b"/);
    assert.equal(workspaceHeading("in", 0), "in · home");
    assert.equal(workspaceHeading("re", 1), "re");
});
