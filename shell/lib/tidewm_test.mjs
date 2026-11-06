// Tests for tidewm.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    NO_WINDOWS, treeWindows, refreshed, windowEvent, asksForTree, markEvents, appOf, shellWindows, activeWindow,
    promptEvent, homeEvent, bindingFloats, keyFloated, sendCommand, floatCommand, focusCommand, moveAndFocusCommand, closeCommand, minimizeCommand, maximizeCommand, shortcutCommand,
} from "./tidewm.mjs";
import { minimizedFrom, trayWindows } from "./minimized.mjs";
import { promptWanted } from "./workspacenames.mjs";

// A container as tidewm's IPC gives one.
function con(id, fields = {}) {
    return Object.assign({ id, type: "con", name: `title ${id}`, app_id: `app${id}`, pid: 100 + id,
        focused: false, urgent: false, fullscreen_mode: 0, maximized: false,
        workspace: "in", output: "DP-1" }, fields);
}

const tree = {
    id: 1, type: "root", nodes: [
        { id: 2, type: "output", name: "DP-1", nodes: [
            { id: 3, type: "workspace", name: "in", nodes: [con(10), con(11, { focused: true })],
                floating_nodes: [con(12, { type: "floating_con" })] },
        ] },
        { id: 4, type: "output", name: "HDMI-A-1", nodes: [
            { id: 5, type: "workspace", name: "in", nodes: [con(13, { output: "HDMI-A-1" })], floating_nodes: [] },
        ] },
    ],
};

test("the tree's windows are every output's, tiled and floating, the focused one first in the order", () => {
    const s = treeWindows(JSON.stringify(tree));
    assert.deepEqual(s.list.map(c => c.id), [10, 11, 12, 13]);
    assert.deepEqual(s.order, [11]);
});

test("a tree with nothing focused has no order yet", () => {
    assert.deepEqual(treeWindows({ id: 1, type: "root", nodes: [] }), { list: [], order: [] });
});

test("a reply that isn't a tree is null", () => {
    assert.equal(treeWindows("{not json"), null);
    assert.equal(treeWindows("[]"), null);
    assert.equal(treeWindows(null), null);
});

const event = (change, container) => JSON.stringify({ change, container });

test("a tree asked for again keeps the focus history of the windows still there", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("focus", con(10, { focused: true })));
    s = windowEvent(s, event("focus", con(13, { focused: true, output: "HDMI-A-1" })));
    s = windowEvent(s, event("focus", con(12, { type: "floating_con", focused: true })));
    assert.deepEqual(s.order, [12, 13, 10, 11]);
    // 13 has closed meanwhile, and 12 has focus, as the tree says
    const again = { id: 1, type: "root", nodes: [{ id: 3, type: "workspace", name: "inbox",
        nodes: [con(10, { workspace: "inbox" }), con(11, { workspace: "inbox" })],
        floating_nodes: [con(12, { type: "floating_con", workspace: "inbox", focused: true })] }] };
    const r = refreshed(s, JSON.stringify(again));
    assert.deepEqual(r.order, [12, 10, 11]);
    assert.deepEqual(r.list.map(c => c.workspace), ["inbox", "inbox", "inbox"], "the tree's containers, renamed workspace and all");
});

test("a refreshed tree's focused window goes first, even one the shell didn't know had focus", () => {
    const s = { list: [con(10), con(11)], order: [10, 11] };
    const again = { id: 1, type: "root", nodes: [con(10), con(11, { focused: true })] };
    assert.deepEqual(refreshed(s, again).order, [11, 10]);
    const none = { id: 1, type: "root", nodes: [con(10), con(11)] };
    assert.deepEqual(refreshed(s, none).order, [10, 11], "with nothing focused, the order as it was");
    assert.equal(refreshed(s, "{not json"), null);
});

test("events heard while the tree is on its way, put on the windows and replayed on the tree, land once", () => {
    // Heard before the tree came: 14 opened and was focused, 11 retitled
    let live = NO_WINDOWS;
    const heard = [event("new", con(14)), event("focus", con(14, { focused: true })), event("title", con(11, { name: "Chat (1)" }))];
    for (const e of heard) {
        live = windowEvent(live, e);
    }
    assert.equal(live.list.find(c => c.id === 11).workspace, "in", "judged meanwhile by the event's own container");
    // The tree predates them all
    let s = refreshed(live, tree);
    for (const e of heard) {
        s = windowEvent(s, e);
    }
    assert.deepEqual(s.list.map(c => c.id), [10, 11, 12, 13, 14]);
    assert.deepEqual(s.order, [14, 11]);
    assert.equal(s.list.find(c => c.id === 11).name, "Chat (1)");
});

test("a new window joins the list, and a closed one leaves it and the order", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("new", con(14)));
    assert.deepEqual(s.list.map(c => c.id), [10, 11, 12, 13, 14]);
    s = windowEvent(s, event("close", con(11)));
    assert.deepEqual(s.list.map(c => c.id), [10, 12, 13, 14]);
    assert.deepEqual(s.order, []);
});

test("a focused window goes first in the order, and only it is focused", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("focus", con(10, { focused: true })));
    s = windowEvent(s, event("focus", con(13, { focused: true, output: "HDMI-A-1" })));
    assert.deepEqual(s.order, [13, 10, 11]);
    assert.deepEqual(s.list.filter(c => c.focused).map(c => c.id), [13]);
});

test("any other change takes the container whole", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("title", con(10, { name: "new title" })));
    s = windowEvent(s, event("move", con(12, { type: "floating_con", workspace: "re" })));
    s = windowEvent(s, event("maximize", con(13, { maximized: true, output: "HDMI-A-1" })));
    assert.equal(s.list.find(c => c.id === 10).name, "new title");
    assert.equal(s.list.find(c => c.id === 12).workspace, "re");
    assert.equal(s.list.find(c => c.id === 13).maximized, true);
});

test("events heard before the tree they're in change nothing when replayed on it", () => {
    const s = treeWindows(tree);
    const again = windowEvent(windowEvent(s, event("new", con(10))), event("close", con(99)));
    assert.deepEqual(again.list.map(c => c.id), [10, 11, 12, 13]);
    assert.deepEqual(again.order, [11]);
});

test("what isn't a window event leaves the state as it was", () => {
    const s = treeWindows(tree);
    assert.equal(windowEvent(s, "{not json"), s);
    assert.equal(windowEvent(s, JSON.stringify({ change: "new" })), s);
    assert.equal(windowEvent(s, JSON.stringify({ change: "new", container: { id: 3, type: "workspace" } })), s);
    assert.equal(windowEvent(NO_WINDOWS, null), NO_WINDOWS);
});

test("the listener connecting asks for the tree, as does a workspace renamed under its windows", () => {
    assert.equal(asksForTree("tick", JSON.stringify({ first: true, payload: "" })), true);
    assert.equal(asksForTree("workspace", JSON.stringify({ change: "rename", current: { id: 9, name: "inbox" }, old: null })), true);
});

test("nothing else does", () => {
    assert.equal(asksForTree("tick", JSON.stringify({ first: false, payload: "x" })), false, "someone else's tick");
    assert.equal(asksForTree("workspace", JSON.stringify({ change: "focus", current: { id: 9, name: "in" } })), false);
    assert.equal(asksForTree("workspace", JSON.stringify({ change: "init", current: { id: 9, name: "in" } })), false);
    assert.equal(asksForTree("window", event("new", con(10))), false);
    assert.equal(asksForTree("tick", "{not json"), false);
});

test("a window focused or closed is a mark event, as Hyprland's are", () => {
    assert.deepEqual(markEvents(event("focus", con(10, { focused: true }))), [{ type: "focused", address: "10" }]);
    assert.deepEqual(markEvents(event("close", con(10))), [{ type: "closed", address: "10" }]);
});

test("a window tidewm marks urgent is the guard's, until it's focused", () => {
    assert.deepEqual(markEvents(event("urgent", con(10, { urgent: true }))), [{ type: "guarded", address: "10" }]);
    assert.deepEqual(markEvents(event("urgent", con(10, { urgent: false }))), [], "urgency taken away, as focusing does");
});

test("other window events, and what isn't one, mark nothing", () => {
    assert.deepEqual(markEvents(event("new", con(10, { urgent: true }))), [], "the urgent event that follows marks it");
    assert.deepEqual(markEvents(event("move", con(10))), []);
    assert.deepEqual(markEvents(event("title", con(10, { name: "Chat (3)" }))), [], "a title marks nothing, as on Hyprland");
    assert.deepEqual(markEvents(event("fullscreen_mode", con(10))), []);
    assert.deepEqual(markEvents("{not json"), []);
    assert.deepEqual(markEvents(JSON.stringify({ change: "focus", container: { id: 3, type: "workspace" } })), []);
});

test("an app is its app ID, or an X11 window's class", () => {
    assert.equal(appOf(con(1)), "app1");
    assert.equal(appOf(con(1, { app_id: null, window_properties: { class: "Gimp", instance: "gimp" } })), "Gimp");
    assert.equal(appOf(con(1, { app_id: null })), "");
});

const workspaces = [{ id: 30, name: "in" }, { id: 31, name: "re" }];

test("a window opened, closed or focused is the name prompt's, with the window as Hyprland's clients have it", () => {
    assert.deepEqual(promptEvent(event("new", con(10, { name: "~", app_id: "kitty", workspace: "re" }))), {
        change: "new", address: "10", client: { class: "kitty", title: "~", workspace: { name: "re" }, floating: false },
    });
    assert.equal(promptEvent(event("close", con(10))).change, "close");
    assert.equal(promptEvent(event("focus", con(10))).address, "10");
    const x11 = con(12, { type: "floating_con", app_id: null, window_properties: { class: "Gimp" } });
    assert.deepEqual(promptEvent(event("focus", x11)).client, { class: "Gimp", title: "title 12", workspace: { name: "in" }, floating: true });
});

test("the name prompt asks about a tiled window on a workspace that asks, and not a floating one", () => {
    const settings = { standing: ["in", "re"], inApps: ["gmail"], workspaceSettings: { re: { askForName: true } } };
    const client = c => promptEvent(event("focus", c)).client;
    assert.equal(promptWanted(client(con(10, { workspace: "re" })), settings), true);
    assert.equal(promptWanted(client(con(10, { workspace: "re", type: "floating_con" })), settings), false, "a dialog");
    assert.equal(promptWanted(client(con(10, { workspace: "re", app_id: "gmail" })), settings), false, "one of home's apps");
    assert.equal(promptWanted(client(con(10, { workspace: "re", name: "", app_id: null })), settings), false, "a status popup");
});

test("other window events, and what isn't one, are nothing to the name prompt", () => {
    for (const change of ["title", "urgent", "move", "fullscreen_mode", "floating", "maximize"]) {
        assert.equal(promptEvent(event(change, con(10))), null, change);
    }
    assert.equal(promptEvent("{not json"), null);
    assert.equal(promptEvent({ change: "new", container: { id: 3, type: "workspace" } }), null);
});

test("the shell's windows are shaped as Hyprland's", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("fullscreen_mode", con(10, { fullscreen_mode: 1, maximized: true })));
    s = windowEvent(s, event("urgent", con(13, { urgent: true, output: "HDMI-A-1", workspace: "gone" })));
    const w = shellWindows(s, workspaces);
    assert.deepEqual(w[0], { address: "10", title: "title 10", app: "app10", workspace: 30, workspaceName: "in",
        monitor: "DP-1", urgent: false, fullscreen: 3, floating: false, focusHistoryID: -1, identifier: "" });
    assert.equal(w[1].focusHistoryID, 0, "the focused window");
    assert.equal(w[2].floating, true);
    assert.deepEqual([w[3].urgent, w[3].workspace, w[3].workspaceName, w[3].monitor], [true, null, "gone", "HDMI-A-1"],
        "a workspace the list doesn't have yet has no ID");
});

test("a window keeps the identifier xdg-desktop-portal-wlr shares it by", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("title", con(10, { foreign_toplevel_identifier: "a1b2" })));
    assert.equal(shellWindows(s, workspaces)[0].identifier, "a1b2");
    assert.equal(shellWindows(s, workspaces)[1].identifier, "", "none given");
});

test("a minimized window is on its workspace's minimize workspace, as on Hyprland", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("minimize", con(10, { minimized: true, visible: false })));
    const w = shellWindows(s, workspaces);
    assert.deepEqual([w[0].workspace, w[0].workspaceName, minimizedFrom(w[0].workspaceName)], [null, "special:minimized:in", "in"]);
    assert.equal(w[1].workspaceName, "in", "the others are where they are");
    assert.deepEqual(trayWindows(w.map(x => ({ address: x.address, app: x.app, title: x.title, workspace: x.workspaceName })), "in"),
        [{ address: "10", app: "app10", title: "title 10" }], "the tray shows it");
    s = windowEvent(s, event("minimize", con(10, { minimized: false })));
    assert.equal(shellWindows(s, workspaces)[0].workspaceName, "in", "brought back");
});

test("a minimized window is never the focused one, though it was last focused", () => {
    let s = treeWindows(tree);
    s = windowEvent(s, event("minimize", con(11, { minimized: true, focused: false })));
    assert.equal(activeWindow(shellWindows(s, workspaces), "in"), null);
});

test("the focused window is the one first in the order, while it's on the current workspace", () => {
    const w = shellWindows(treeWindows(tree), workspaces);
    assert.equal(activeWindow(w, "in").address, "11");
    assert.equal(activeWindow(w, "re"), null, "focus went to an empty workspace");
    assert.equal(activeWindow(shellWindows(NO_WINDOWS, workspaces), "in"), null);
});

test("a window's commands name it by its container ID", () => {
    assert.equal(focusCommand("11"), "[con_id=11] focus");
    assert.equal(moveAndFocusCommand("11", "my mail"), "[con_id=11] move to workspace number my mail; [con_id=11] focus");
    assert.equal(closeCommand("11"), "[con_id=11] kill");
    assert.equal(minimizeCommand("11"), "[con_id=11] minimize enable");
    assert.equal(maximizeCommand("11"), "[con_id=11] maximize toggle");
});

test("a window moved to a workspace with a ; names it in quotes", () => {
    assert.equal(moveAndFocusCommand("11", "a;b"), '[con_id=11] move to workspace number "a;b"; [con_id=11] focus');
});

test("an address that isn't a container ID, or a name tidewm can't take, sends nothing", () => {
    assert.equal(focusCommand("5a3f"), null, "a Hyprland address");
    assert.equal(focusCommand(""), null);
    assert.equal(focusCommand("1] kill; [con_id=2"), null);
    assert.equal(moveAndFocusCommand("11", 'say "hi"'), null, "tidewm's quotes can't hold a \"");
    assert.equal(closeCommand("0x5a3f"), null);
    assert.equal(minimizeCommand("a;b"), null);
    assert.equal(maximizeCommand(undefined), null);
});

test("a window opening or closing on tidewm reads as home's apps need it", () => {
    const open = { change: "new", container: { id: 42, type: "con", app_id: "chrome-mail.google.com__-Default", workspace: "re", nodes: [], floating_nodes: [] } };
    assert.deepEqual(homeEvent(open), { change: "new", address: "42", app: "chrome-mail.google.com__-Default", workspace: "re" });
    assert.deepEqual(homeEvent(JSON.stringify({ ...open, change: "close" })), { change: "close", address: "42", app: "chrome-mail.google.com__-Default", workspace: "re" });
    assert.equal(homeEvent({ ...open, change: "focus" }), null, "only opens and closes");
    assert.equal(homeEvent({ change: "new", container: { id: 3, type: "workspace", nodes: [], floating_nodes: [] } }), null, "not a window");
});

test("a window is sent home without following it", () => {
    assert.equal(sendCommand("42", "in"), "[con_id=42] move to workspace number in");
    assert.equal(sendCommand("42", "a;b"), '[con_id=42] move to workspace number "a;b"', "in quotes, or the ; would end the command");
    assert.equal(sendCommand("42", 'say "hi"'), null, "tidewm's quotes can't hold a \"");
    assert.equal(sendCommand("0xabc", "in"), null, "not a container ID");
});

test("a window a new floating rule covers is floated by its container ID", () => {
    assert.equal(floatCommand("42"), "[con_id=42] floating enable");
    assert.equal(floatCommand("0xabc"), null);
});

test("the picker's paste is tidewm's send_shortcut, in its spelling", () => {
    assert.equal(shortcutCommand("42", "CTRL", "V"), "[con_id=42] send_shortcut ctrl+v");
    assert.equal(shortcutCommand("42", "CTRL SHIFT", "V"), "[con_id=42] send_shortcut ctrl+shift+v");
    assert.equal(shortcutCommand("0xabc", "CTRL", "V"), null);
    assert.throws(() => shortcutCommand("42", "ctrl; kill", "V"), /not modifiers/);
    assert.throws(() => shortcutCommand("42", "CTRL", "v; kill"), /not a key/);
});

// A binding event as tidewm sends one, before it runs the command.
function binding(command) {
    return { change: "run", binding: { command, event_state_mask: ["Mod4", "Shift"], input_code: 0, symbol: "f", input_type: "keyboard" } };
}

test("conf's float keys are a binding that toggles or enables floating on the focused window", () => {
    assert.equal(bindingFloats(binding("floating toggle")), true);
    assert.equal(bindingFloats(JSON.stringify(binding("floating enable"))), true, "its JSON too");
    assert.equal(bindingFloats(binding("  Floating  Toggle ")), true, "as tidewm reads it, ignoring case");
    assert.equal(bindingFloats(binding("nop; floating toggle")), true, "one of its commands");
});

test("any other binding isn't a float key", () => {
    assert.equal(bindingFloats(binding("floating disable")), false);
    assert.equal(bindingFloats(binding("[con_id=3] floating toggle")), false, "another window");
    assert.equal(bindingFloats(binding("workspace \"a; floating toggle\"")), false, "a ; in quotes is the name's");
    assert.equal(bindingFloats(binding("exec tide launcher")), false);
    assert.equal(bindingFloats({ change: "run" }), false);
    assert.equal(bindingFloats("not json"), false);
});

test("after a float key, the focused window's floating event with it floating is the key's", () => {
    const floated = { change: "floating", container: con(12, { type: "floating_con", focused: true, name: "Calculator", app_id: "org.gnome.Calculator" }) };
    assert.deepEqual(keyFloated(true, floated), { address: "12", class: "org.gnome.Calculator", title: "Calculator" });
    assert.deepEqual(keyFloated(true, JSON.stringify(floated)), { address: "12", class: "org.gnome.Calculator", title: "Calculator" });
    const x11 = { change: "floating", container: con(13, { type: "floating_con", focused: true, app_id: null, window_properties: { class: "XTerm" } }) };
    assert.equal(keyFloated(true, x11).class, "XTerm", "an X11 window by its class");
});

test("any other window event, or one with no float key before it, isn't", () => {
    const floated = { change: "floating", container: con(12, { type: "floating_con", focused: true }) };
    assert.equal(keyFloated(false, floated), null, "no float key, as a rule's or the shell's own");
    assert.equal(keyFloated(true, { change: "floating", container: con(12, { focused: true }) }), null, "tiled again");
    assert.equal(keyFloated(true, { change: "floating", container: con(12, { type: "floating_con" }) }), null, "not the focused window");
    assert.equal(keyFloated(true, { change: "focus", container: con(12, { type: "floating_con", focused: true }) }), null);
    assert.equal(keyFloated(true, "not json"), null);
});
