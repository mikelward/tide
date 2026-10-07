// Tests for settings.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PAGES, movedPage } from "./settings.mjs";

test("the pages come in the sidebar's order, each with a label and an icon", () => {
    assert.deepEqual(PAGES.map(p => p.id), ["idle", "sound", "network", "bluetooth", "mouse", "touchpad", "keyboard", "clocks", "keys", "layouts"]);
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

test("each page links out to the app SPEC.md §16 names, and Idle, Mouse, Touchpad, Keyboard, Clocks, Keys and Layouts to none", () => {
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
        keys: null,
        layouts: null,
    });
});

test("moving between pages stops at either end", () => {
    assert.equal(movedPage(0, 1), 1);
    assert.equal(movedPage(1, -1), 0);
    assert.equal(movedPage(0, -1), 0);
    assert.equal(movedPage(PAGES.length - 1, 1), PAGES.length - 1);
});
