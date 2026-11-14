// Tests for settings.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { GROUPS, PAGES, SECTIONS, advancedFor, keptPages, movedPage, opened, pageIndex, pageTerms, searchedSection, searchedSidebar, sidebarRows } from "./settings.mjs";

test("the pages come in the sidebar's order, each with a label and an icon", () => {
    assert.deepEqual(PAGES.map(p => p.id), [
        "displays", "sound", "network", "bluetooth", "mouse", "touchpad", "keyboard", "power",
        "layouts", "workspaces", "floating",
        "appearance", "bar", "notifications", "clipboard", "clocks", "idle", "startup",
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

test("each page links out to the app SPEC.md §16 names, and Idle, Mouse, Touchpad, Keyboard, Clocks, Layouts, Appearance, Bar, Start at login, Notifications, Clipboard, Power, Workspaces and Floating to none", () => {
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
        bar: null,
        displays: ["nwg-displays"],
        startup: null,
        notifications: null,
        clipboard: null,
        power: null,
        workspaces: null,
        floating: null,
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
        windows: ["layouts", "workspaces", "floating"],
        general: ["appearance", "bar", "notifications", "clipboard", "clocks", "idle", "startup"],
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
        "# Windows", "layouts", "workspaces", "floating",
        "# General", "appearance", "bar", "notifications", "clipboard", "clocks", "idle", "startup",
    ]);
    assert.ok(rows.filter(r => r.heading !== "").every(r => r.page === -1));
    // Every page is a row once, so stepping from one to the next skips the headings.
    assert.deepEqual(rows.filter(r => r.heading === "").map(r => r.page), PAGES.map((_, i) => i));
    assert.equal(movedPage(pageIndex("power"), 1), pageIndex("layouts"));
    assert.equal(movedPage(pageIndex("appearance"), -1), pageIndex("floating"));
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

// The ids and headings a search's sidebar shows, top to bottom.
function shown(query) {
    return searchedSidebar(query).map(r => (r.heading !== "" ? `# ${r.heading}` : PAGES[r.page].id));
}

test("a page is found by its label and keywords, and its sections'", () => {
    assert.deepEqual(pageTerms(pageIndex("sound")), ["Sound", "audio", "volume", "speakers", "headphones", "microphone"]);
    assert.ok(pageTerms(pageIndex("keyboard")).includes("Keyboard shortcuts"));
    assert.ok(pageTerms(pageIndex("keyboard")).includes("hotkeys"));
    // A page with no keywords is found by its label.
    for (const [index, page] of PAGES.entries()) {
        assert.ok(pageTerms(index).includes(page.label), `${page.id} is found by its label`);
    }
});

test("searching keeps the pages found, under their headings, and drops headings left empty", () => {
    assert.deepEqual(shown("sound"), ["# Hardware", "sound"]);
    assert.deepEqual(shown("shortcuts"), ["# Hardware", "keyboard"]);
    assert.deepEqual(shown("CLIP"), ["# General", "clipboard"]);
    assert.deepEqual(shown("bar"), ["# General", "bar"]);
    assert.deepEqual(shown("bottom"), ["# General", "bar"], "where the bar goes finds its page");
    assert.deepEqual(shown("tray"), ["# General", "bar"], "so do the bar's icons");
    assert.deepEqual(shown("zzz"), []);
    // An empty or blank query shows every page.
    assert.deepEqual(searchedSidebar(""), sidebarRows());
    assert.deepEqual(searchedSidebar("  "), sidebarRows());
});

test("Up and Down move among the pages a search keeps, stopping at either end", () => {
    const kept = keptPages(searchedSidebar("c"));
    assert.deepEqual(kept.map(i => PAGES[i].id), ["touchpad", "appearance", "clipboard", "clocks"]);
    assert.equal(movedPage(kept[0], 1, kept), kept[1]);
    assert.equal(movedPage(kept[1], -1, kept), kept[0]);
    assert.equal(movedPage(kept[0], -1, kept), kept[0]);
    assert.equal(movedPage(kept[kept.length - 1], 1, kept), kept[kept.length - 1]);
    const two = [pageIndex("sound"), pageIndex("clocks")];
    assert.equal(movedPage(pageIndex("sound"), 1, two), pageIndex("clocks"));
    // From a page the search dropped, the first kept; with none kept, stay.
    assert.equal(movedPage(pageIndex("mouse"), 1, two), pageIndex("sound"));
    assert.equal(movedPage(pageIndex("mouse"), 1, []), pageIndex("mouse"));
});

test("a page found only by a section scrolls to it", () => {
    const keyboard = pageIndex("keyboard");
    assert.equal(searchedSection(keyboard, "shortcuts"), "keys");
    assert.equal(searchedSection(keyboard, "keyboard bindings"), "keys");
    assert.equal(searchedSection(keyboard, "repeat shortcuts"), "keys", "a page's word and a section's together find the section");
    assert.equal(searchedSection(keyboard, "keyboard"), "");
    assert.equal(searchedSection(keyboard, "layout"), "");
    assert.equal(searchedSection(keyboard, ""), "");
    assert.equal(searchedSection(pageIndex("sound"), "shortcuts"), "");
});

test("on tidewm, nwg-displays saves where conf's tidewm config reads it, its directory made first", () => {
    const page = id => PAGES.find(p => p.id === id);
    assert.deepEqual(advancedFor(page("displays"), false, "/home/u").command, ["nwg-displays"]);
    assert.equal(advancedFor(page("displays"), false, "/home/u").dirs, undefined);
    assert.deepEqual(advancedFor(page("displays"), true, "/home/u"), {
        label: "Arrange displays",
        command: ["nwg-displays", "--outputs_path", "/home/u/.config/sway/outputs"],
        dirs: ["/home/u/.config/sway"],
    });
    // nwg-displays looks for sway's directory under XDG_CONFIG_HOME
    assert.deepEqual(advancedFor(page("displays"), true, "/home/u", "/cfg").dirs,
        ["/home/u/.config/sway", "/cfg/sway"]);
    assert.deepEqual(advancedFor(page("displays"), true, "/home/u", "/home/u/.config").dirs,
        ["/home/u/.config/sway"]);
    assert.deepEqual(advancedFor(page("sound"), true, "/home/u").command, ["pavucontrol"]);
    assert.equal(advancedFor(page("idle"), true, "/home/u"), null);
    assert.equal(advancedFor(undefined, true, "/home/u"), null);
});
