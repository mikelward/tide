// Tests for launcher.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { highlighted, launchCommand, launcherItems, moved, scoreItem, search } from "./launcher.mjs";

const chrome = {
    id: "google-chrome",
    name: "Google Chrome",
    genericName: "Web Browser",
    comment: "Access the Internet",
    icon: "google-chrome",
    keywords: ["web", "internet"],
    command: ["/usr/bin/google-chrome-stable", "%U"],
    runInTerminal: false,
    workingDirectory: "",
    startupClass: "Google-chrome",
    noDisplay: false,
    actions: [
        { id: "new-window", name: "New Window", icon: "", command: ["/usr/bin/google-chrome-stable"] },
        { id: "new-private-window", name: "New Incognito Window", icon: "", command: ["/usr/bin/google-chrome-stable", "--incognito"] },
    ],
};
const kitty = { id: "kitty", name: "kitty", genericName: "Terminal emulator", command: ["kitty"], keywords: [], actions: [] };
const htop = { id: "htop", name: "Htop", comment: "Process viewer", command: ["htop"], runInTerminal: true, actions: [] };
const hidden = { id: "hidden", name: "Hidden", command: ["hidden"], noDisplay: true, actions: [] };
const broken = { id: "broken", name: "Broken", command: [], actions: [] };
const shell = { id: "ssh", name: "Secure Shell", genericName: "SSH", command: ["ssh-app"], actions: [] };

const items = launcherItems([chrome, kitty, htop, hidden, broken, shell]);

test("an entry gives a row, and one per desktop action", () => {
    assert.deepEqual(items.map(i => [i.kind, i.id, i.name, i.sub]), [
        ["app", "google-chrome", "Google Chrome", "Web Browser"],
        ["action", "google-chrome:new-window", "New Window", "Google Chrome"],
        ["action", "google-chrome:new-private-window", "New Incognito Window", "Google Chrome"],
        ["app", "kitty", "kitty", "Terminal emulator"],
        ["app", "htop", "Htop", "Process viewer"],
        ["app", "ssh", "Secure Shell", "SSH"],
    ]);
    assert.equal(items[0].exec, "google-chrome-stable");
    // An action keeps its app's class and icon.
    assert.equal(items[2].appId, "Google-chrome");
    assert.equal(items[2].icon, "google-chrome");
});

test("an entry hidden from menus, or with nothing to run, has no row", () => {
    assert.equal(items.some(i => i.id === "hidden" || i.id === "broken"), false);
});

test("the empty query lists the apps by name, without their actions", () => {
    assert.deepEqual(search(items, "").map(r => r.item.name), ["Google Chrome", "Htop", "kitty", "Secure Shell"]);
    assert.deepEqual(search(items, " ")[0].positions, []);
});

test("a query ranks matching rows best first, and drops the rest", () => {
    const rows = search(items, "inc");
    assert.equal(rows[0].item.name, "New Incognito Window");
    assert.deepEqual(rows[0].positions, [4, 5, 6]);
    assert.equal(rows.some(r => r.item.name === "kitty"), false);
});

test("a match in the name beats one in another field", () => {
    const rows = search(items, "sh");
    assert.equal(rows[0].item.name, "Secure Shell");
});

test("the generic name, keywords and command find an app, unhighlighted", () => {
    assert.deepEqual(scoreItem(items[0], "browser").positions, []);
    assert.notEqual(scoreItem(items[0], "internet"), null);
    assert.notEqual(scoreItem(items[0], "stable"), null);
    assert.equal(scoreItem(items[3], "zzz"), null);
});

test("an app comes before its own actions on an equal score", () => {
    const rows = search(launcherItems([{ ...kitty, actions: [{ id: "k", name: "kitty", command: ["kitty", "-1"] }] }]), "kitty");
    assert.deepEqual(rows.map(r => r.item.kind), ["app", "action"]);
});

test("an app is launched through tide launch, granting its window class", () => {
    assert.deepEqual(launchCommand(items[2]), ["tide", "launch", "--app", "Google-chrome", "--", "/usr/bin/google-chrome-stable", "--incognito"]);
    // With no class named, the command may be a wrapper whose name no
    // window has, so any app's first window may take focus.
    assert.deepEqual(launchCommand(items[3]), ["tide", "launch", "--app", "*", "--", "kitty"]);
});

test("a terminal app runs in the terminal, granting any first window", () => {
    assert.deepEqual(launchCommand(items[4]), ["tide", "launch", "--app", "*", "--", "xdg-terminal-exec", "htop"]);
    // Even when the entry names a class: the window is still the terminal's.
    const named = launcherItems([{ ...htop, startupClass: "htop" }])[0];
    assert.deepEqual(launchCommand(named), ["tide", "launch", "--app", "*", "--", "xdg-terminal-exec", "htop"]);
});

test("the matched letters are underlined, and the rest is escaped", () => {
    assert.equal(highlighted("a<b", [0], "#fff"), '<u><font color="#fff">a</font></u>&lt;b');
    assert.equal(highlighted("x & y", [], "#fff"), "x &amp; y");
});

test("moving the selection stops at the ends", () => {
    assert.equal(moved(0, -1, 3), 0);
    assert.equal(moved(1, 1, 3), 2);
    assert.equal(moved(2, 1, 3), 2);
    assert.equal(moved(0, 1, 0), -1);
});
