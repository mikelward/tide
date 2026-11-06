// Tests for barsettings.mjs, and that the bar's items name their pages.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { BAR_SETTINGS, opened, page } from "./barsettings.mjs";
import { PAGES } from "./settings.mjs";

const SHELL = join(dirname(fileURLToPath(import.meta.url)), "..");

test("each bar item opens a settings page, or the first page", () => {
    const ids = new Set(PAGES.map((p) => p.id));
    for (const [item, id] of Object.entries(BAR_SETTINGS)) {
        assert.ok(id === "" || ids.has(id), `${item} opens ${id}, which isn't a page`);
    }
});

test("each bar item opens its own page", () => {
    assert.equal(page("clocks"), "clocks");
    assert.equal(page("workspaces"), "workspaces");
    assert.equal(page("volume"), "sound");
    assert.equal(page("sysmon"), "");
});

test("the first page opens by name, so an open panel turns to it", () => {
    assert.equal(opened(page("sysmon"), PAGES), PAGES[0].id);
    assert.equal(opened(page("clocks"), PAGES), "clocks");
});

test("an unknown bar item is an error, naming it", () => {
    assert.throws(() => page("tray"), /no bar item tray/);
});

// Every bar item's click target names its page, so a right-click opens
// it, but the tray's, whose right-click is the app's menu; and every item
// in the map is on the bar.
test("every bar item but the tray takes a right-click to its settings", () => {
    const missing = [];
    const used = new Set();
    for (const file of readdirSync(SHELL).filter((f) => f.endsWith(".qml"))) {
        const lines = readFileSync(join(SHELL, file), "utf8").split("\n");
        lines.forEach((line, i) => {
            const named = /BarSettings\.page\("(\w+)"\)/g;
            for (let m = named.exec(line); m; m = named.exec(line)) {
                page(m[1]);
                used.add(m[1]);
            }
            if (/^\s*BarHit\s*\{\s*$/.test(line) && file !== "Tray.qml"
                && !/^\s*settings: BarSettings\.page\("\w+"\)\s*$/.test(lines[i + 1] ?? "")) {
                missing.push(`${file}:${i + 1}`);
            }
        });
    }
    assert.deepEqual(missing, []);
    assert.deepEqual(Object.keys(BAR_SETTINGS).filter((item) => !used.has(item)), []);
});
