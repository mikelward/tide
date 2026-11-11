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
});

test("the bar itself, and the items no other page fits, open the Bar page", () => {
    for (const item of ["bar", "logo", "sharing", "sysmon"]) {
        assert.equal(page(item), "bar", item);
    }
    assert.ok(PAGES.some(p => p.id === "bar" && p.label === "Bar"));
});

test("the first page opens by name, so an open panel turns to it", () => {
    assert.equal(opened("", PAGES), PAGES[0].id);
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

// Each bar item's dropdown, but the tray's menu, which is the app's own.
const DROPDOWNS = Object.freeze({
    "BatteryPopover.qml": "battery",
    "BluetoothPopover.qml": "bluetooth",
    "ClocksPopover.qml": "clocks",
    "MicPopover.qml": "mic",
    "NetworkPopover.qml": "network",
    "SessionMenu.qml": "session",
    "SharingPopover.qml": "sharing",
    "SysmonPopover.qml": "sysmon",
    "VolumePopover.qml": "volume",
});

// A dropdown ends in Settings… (SettingsRow.qml), for its item's page, but
// one whose item has none, whose right-click opens the Bar page (or the
// first page): there, Settings… would open a page about something else. Every dropdown is
// listed, so a new one is too. integration_test.sh clicks the clocks'.
test("every dropdown with a page of its own ends in Settings… for that page", () => {
    const dropdowns = readdirSync(SHELL).filter((f) => f.endsWith(".qml")
        && /PopoverData\.toggle\(/.test(readFileSync(join(SHELL, f), "utf8")) && f !== "TrayMenu.qml");
    assert.deepEqual(dropdowns.sort(), Object.keys(DROPDOWNS).sort());
    const wrong = [];
    for (const [file, item] of Object.entries(DROPDOWNS)) {
        const text = readFileSync(join(SHELL, file), "utf8");
        const rows = [];
        const row = /SettingsRow\s*\{[^}]*?\bitem:\s*"(\w+)"/g;
        for (let m = row.exec(text); m; m = row.exec(text)) {
            rows.push(m[1]);
        }
        const want = page(item) === "" || page(item) === "bar" ? [] : [item];
        if (JSON.stringify(rows) !== JSON.stringify(want)) {
            wrong.push(`${file} has Settings… for ${JSON.stringify(rows)}, not ${JSON.stringify(want)}`);
        }
    }
    assert.deepEqual(wrong, []);
});
