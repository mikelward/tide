// Tests for settings.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PAGES, movedPage } from "./settings.mjs";

test("the pages come in the sidebar's order, each with a link out", () => {
    assert.deepEqual(PAGES.map(p => p.id), ["sound", "network", "bluetooth"]);
    for (const page of PAGES) {
        assert.ok(page.label, `${page.id} has a label`);
        assert.ok(page.icon.endsWith("-symbolic"), `${page.id}'s icon is symbolic`);
        assert.equal(typeof page.about, "string", `${page.id} says what the bar does, or ""`);
        assert.ok(page.advanced.label, `${page.id}'s link out has a label`);
        assert.ok(page.advanced.command.length > 0, `${page.id}'s link out has a command`);
    }
});

test("each page links out to the app SPEC.md §16 names", () => {
    const commands = {};
    for (const page of PAGES) {
        commands[page.id] = page.advanced.command;
    }
    assert.deepEqual(commands, {
        sound: ["pavucontrol"],
        network: ["nm-connection-editor"],
        bluetooth: ["blueman-manager"],
    });
});

test("moving between pages stops at either end", () => {
    assert.equal(movedPage(0, 1), 1);
    assert.equal(movedPage(1, -1), 0);
    assert.equal(movedPage(0, -1), 0);
    assert.equal(movedPage(PAGES.length - 1, 1), PAGES.length - 1);
});
