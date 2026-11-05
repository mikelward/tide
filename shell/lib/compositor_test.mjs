// Tests for compositor.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { isTidewm, screenNamed, tidewmWorkspaces, tidewmCurrent, tidewmMonitors, tidewmWorkspaceEvent, tidewmGoTo, tidewmRename } from "./compositor.mjs";
import { workspaceOrder } from "./workspaces.mjs";

test("tidewm's session is the one naming tidewm", () => {
    assert.equal(isTidewm("tidewm:tide"), true);
    assert.equal(isTidewm("tide:tidewm"), true, "wherever it's named");
    assert.equal(isTidewm("tidewm"), true);
});

test("anything else is Hyprland's, the default", () => {
    assert.equal(isTidewm("tide:Hyprland"), false);
    assert.equal(isTidewm(""), false);
    assert.equal(isTidewm(undefined), false, "unset");
    assert.equal(isTidewm("tidewmx:tide"), false, "a name that only starts with it");
    assert.equal(isTidewm("TIDEWM:tide"), false, "names are matched as written, as bin/tide does");
});

const screens = [{ name: "DP-1" }, { name: "HDMI-A-1" }];

test("the focused screen is the one named as the focused monitor", () => {
    assert.equal(screenNamed(screens, "HDMI-A-1"), screens[1]);
});

test("no focused monitor, or one no screen shows, is no screen", () => {
    assert.equal(screenNamed(screens, ""), null);
    assert.equal(screenNamed(screens, null), null);
    assert.equal(screenNamed(screens, "DP-2"), null);
    assert.equal(screenNamed([], "DP-1"), null);
    assert.equal(screenNamed(undefined, "DP-1"), null, "before the screens are known");
});

// GET_WORKSPACES objects, as Quickshell's I3 module keeps them.
const listed = [
    { id: 4, name: "1", num: 1, focused: false },
    { id: 9, name: "in", num: -1, focused: true, persistent: true },
    { id: 12, name: "re", num: -1, focused: false },
    { id: 15, name: "3", num: 3, focused: false },
];

test("tidewm's workspaces keep their IDs and are placed as Hyprland's are", () => {
    assert.deepEqual(tidewmWorkspaces(listed), [
        { id: 4, order: 1, name: "1" },
        { id: 9, order: -9, name: "in" },
        { id: 12, order: -12, name: "re" },
        { id: 15, order: 3, name: "3" },
    ]);
});

test("the bar's order follows them: standing first, then named as made, then numbered", () => {
    const order = workspaceOrder(tidewmWorkspaces(listed.concat([{ id: 20, name: "notes", num: -1 }])), ["in"]);
    assert.deepEqual(order.map(w => w.name), ["in", "re", "notes", "1", "3"]);
    assert.deepEqual(order.map(w => w.id), [9, 12, 20, 4, 15]);
});

test("what isn't a workspace is left out", () => {
    assert.deepEqual(tidewmWorkspaces([null, { id: "4", name: "1" }, { id: 5, name: "" }, { id: 6 }]), []);
    assert.deepEqual(tidewmWorkspaces(undefined), []);
});

test("the current workspace is the focused one, on every monitor", () => {
    assert.equal(tidewmCurrent(listed), 9);
    assert.equal(tidewmCurrent([]), null, "before tidewm has said");
    assert.deepEqual(tidewmMonitors(["DP-1", "HDMI-A-1"], 9), [
        { name: "DP-1", workspace: 9 },
        { name: "HDMI-A-1", workspace: 9 },
    ]);
    assert.deepEqual(tidewmMonitors(["DP-1", ""], null), [{ name: "DP-1", workspace: null }]);
});

test("tidewm's workspace events read as Hyprland's do", () => {
    const event = (change, current) => JSON.stringify({ change, current, old: null });
    assert.deepEqual(tidewmWorkspaceEvent(event("init", { id: 20, name: "notes" })), { type: "created", id: 20, name: "notes" });
    assert.deepEqual(tidewmWorkspaceEvent(event("empty", { id: 20, name: "notes" })), { type: "destroyed", id: 20, name: "notes" });
    assert.deepEqual(tidewmWorkspaceEvent(event("rename", { id: 9, name: "inbox" })), { type: "renamed", id: 9, name: "inbox" },
        "the name it has now, under the ID it had");
    assert.deepEqual(tidewmWorkspaceEvent({ change: "init", current: { id: 3, name: "3" } }), { type: "created", id: 3, name: "3" },
        "an event already parsed");
});

test("other workspace events, and what doesn't parse, are nothing", () => {
    assert.equal(tidewmWorkspaceEvent(JSON.stringify({ change: "focus", current: { id: 9, name: "in" } })), null);
    assert.equal(tidewmWorkspaceEvent(JSON.stringify({ change: "urgent", current: { id: 9, name: "in" } })), null);
    assert.equal(tidewmWorkspaceEvent(JSON.stringify({ change: "init", current: null })), null);
    assert.equal(tidewmWorkspaceEvent("{not json"), null);
    assert.equal(tidewmWorkspaceEvent(""), null);
});

test("going to a workspace names it whole", () => {
    assert.equal(tidewmGoTo("in"), "workspace number in");
    assert.equal(tidewmGoTo("Bob's tasks"), "workspace number Bob's tasks", "spaces and all");
    assert.equal(tidewmGoTo("back_and_forth"), "workspace number back_and_forth", "that workspace, not the last one");
    assert.equal(tidewmGoTo("number 9"), "workspace number number 9");
    assert.equal(tidewmGoTo("3"), "workspace number 3");
});

test("a name tidewm would cut short can't be sent", () => {
    assert.equal(tidewmGoTo("a;b"), null, "a ; ends the command");
    assert.equal(tidewmGoTo(""), null);
    assert.equal(tidewmGoTo(" in"), null, "tidewm would trim it");
    assert.equal(tidewmGoTo(null), null);
});

test("a rename names both workspaces", () => {
    assert.equal(tidewmRename("inbox", "in"), "rename workspace inbox to in");
    assert.equal(tidewmRename("my mail", "in"), "rename workspace my mail to in");
});

test("a rename tidewm would split wrongly can't be sent", () => {
    assert.equal(tidewmRename("go to bed", "in"), null, "tidewm splits at the first \" to \"");
    assert.equal(tidewmRename("inbox", "back to in"), "rename workspace inbox to back to in",
        "the new name may have one: the first is the split");
    assert.equal(tidewmRename("to do", "in"), null, "renames the current workspace instead");
    assert.equal(tidewmRename("To", "in"), null);
    assert.equal(tidewmRename("toast", "in"), "rename workspace toast to in", "a name that only starts with to");
    assert.equal(tidewmRename("a;b", "in"), null);
});
