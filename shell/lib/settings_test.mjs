// Tests for settings.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { GROUPS, PAGES, SECTIONS, movedPage, opened, pageIndex, sidebarRows } from "./settings.mjs";

test("the pages come in the sidebar's order, each with a label and an icon", () => {
    assert.deepEqual(PAGES.map(p => p.id), [
        "displays", "sound", "network", "bluetooth", "mouse", "touchpad", "keyboard", "power",
        "layouts", "workspaces",
        "appearance", "notifications", "clipboard", "clocks", "idle", "startup",
    ]);
    for (const page of PAGES) {
        assert.ok(page.label, `${page.id} has a label`);
        assert.ok(page.icon.endsWith("-symbolic"), `${page.id}'s icon is symbolic`);
        assert.equal(typeof page.about, "string", `${page.id} says what to know first, or ""`);
        if (page.advanced !== null) {
            assert.ok(page.advanced.label, `${page.id}'s link out has a label`);
            assert.ok(page.advanced.command.length > 0, `${page.id}'s link out has a command`);
        }
    }
});

test("each page links out to the app SPEC.md §16 names, and Idle, Mouse, Touchpad, Keyboard, Clocks, Layouts, Appearance, Start at login, Notifications, Clipboard, Power and Workspaces to none", () => {
    const commands = {};
    for (const page of PAGES) {
        commands[page.id] = page.advanced === null ? null : page.advanced.command;
    }
    assert.deepEqual(commands, {
        idle: null,
        sound: ["pavucontrol"],
        network: ["nm-connection-editor"],
        bluetooth: ["blueman-manager"],
        mouse: null,
        touchpad: null,
        keyboard: null,
        clocks: null,
        layouts: null,
        appearance: null,
        displays: ["nwg-displays"],
        startup: null,
        notifications: null,
        clipboard: null,
        power: null,
        workspaces: null,
    });
});

test("moving between pages stops at either end", () => {
    assert.equal(movedPage(0, 1), 1);
    assert.equal(movedPage(1, -1), 0);
    assert.equal(movedPage(0, -1), 0);
    assert.equal(movedPage(PAGES.length - 1, 1), PAGES.length - 1);
});

test("the sidebar groups the pages under Hardware, Windows and General, each page in one group and a group's pages together", () => {
    assert.deepEqual(GROUPS.map(g => g.label), ["Hardware", "Windows", "General"]);
    const grouped = {};
    for (const group of GROUPS) {
        grouped[group.id] = PAGES.filter(p => p.group === group.id).map(p => p.id);
    }
    assert.deepEqual(grouped, {
        hardware: ["displays", "sound", "network", "bluetooth", "mouse", "touchpad", "keyboard", "power"],
        windows: ["layouts", "workspaces"],
        general: ["appearance", "notifications", "clipboard", "clocks", "idle", "startup"],
    });
    for (const page of PAGES) {
        assert.equal(GROUPS.filter(g => g.id === page.group).length, 1, `${page.id} is in exactly one group`);
    }
    // In PAGES' order too, so Up and Down, which step through PAGES, go
    // down the sidebar.
    assert.deepEqual(PAGES.map(p => p.id), [].concat(...Object.values(grouped)));
});

test("the sidebar is each group's heading, then its pages, and only pages can be chosen", () => {
    const rows = sidebarRows();
    assert.deepEqual(rows.map(r => (r.heading !== "" ? `# ${r.heading}` : PAGES[r.page].id)), [
        "# Hardware", "displays", "sound", "network", "bluetooth", "mouse", "touchpad", "keyboard", "power",
        "# Windows", "layouts", "workspaces",
        "# General", "appearance", "notifications", "clipboard", "clocks", "idle", "startup",
    ]);
    assert.ok(rows.filter(r => r.heading !== "").every(r => r.page === -1));
    // Every page is a row once, so stepping from one to the next skips the headings.
    assert.deepEqual(rows.filter(r => r.heading === "").map(r => r.page), PAGES.map((_, i) => i));
    assert.equal(movedPage(pageIndex("power"), 1), pageIndex("layouts"));
    assert.equal(movedPage(pageIndex("appearance"), -1), pageIndex("workspaces"));
});

test("a page's id opens it, and keys, Keys' old page, opens Keyboard at its shortcuts", () => {
    assert.deepEqual(opened("mouse"), { index: pageIndex("mouse"), section: "" });
    assert.deepEqual(opened("keys"), { index: pageIndex("keyboard"), section: "keys" });
    assert.equal(opened("nope"), null);
    assert.equal(pageIndex("keys"), -1);
    for (const section of SECTIONS) {
        assert.ok(pageIndex(section.page) >= 0, `${section.id} is on a page`);
        assert.equal(pageIndex(section.id), -1, `${section.id} isn't a page's id too`);
        assert.ok(section.icon.endsWith("-symbolic"), `${section.id}'s icon is symbolic`);
    }
});
