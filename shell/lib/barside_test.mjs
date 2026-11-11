// Tests for barside.mjs, and that what hangs from the bar follows its edge.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { hangEdge, hangMargins, aboveBar, barChoiceAt, steppedBarChoice } from "./barside.mjs";
import { BAR_CHOICES, DEFAULTS, loadAppearance } from "./appearance.mjs";

const SHELL = join(dirname(fileURLToPath(import.meta.url)), "..");

test("popovers open below a top bar and above a bottom one", () => {
    assert.equal(hangEdge(false), "bottom");
    assert.equal(hangEdge(true), "top");
    assert.deepEqual(hangMargins(false, 10), { top: 0, bottom: -10 }, "the gap below the item");
    assert.deepEqual(hangMargins(true, 10), { top: -10, bottom: 0 }, "the gap above it");
});

test("what sits at the bottom edge clears a bottom bar, and stays put under a top one", () => {
    assert.equal(aboveBar(false, 36, 60), 60);
    assert.equal(aboveBar(true, 36, 60), 96);
});

test("the Bar page's Position row shows where the bar is and steps between top and bottom, stopping at either end", () => {
    assert.equal(BAR_CHOICES[barChoiceAt(DEFAULTS)].label, "Top", "top when unset");
    const bottom = loadAppearance('{"barPosition": "bottom"}', null).settings;
    assert.equal(BAR_CHOICES[barChoiceAt(bottom)].label, "Bottom");
    assert.equal(steppedBarChoice(0, 1), 1);
    assert.equal(steppedBarChoice(1, 1), 1);
    assert.equal(steppedBarChoice(1, -1), 0);
    assert.equal(steppedBarChoice(0, -1), 0);
});

// A popup that hangs from the bar with a fixed edge would open off the
// screen, or over the bar, once the bar is at the bottom. Only the
// minimized tray's tip, which sits at the bottom edge whatever the bar
// does, opens upward by itself.
test("every popup hung from the bar takes its edge and gap from Theme", () => {
    const files = readdirSync(SHELL).filter(f => f.endsWith(".qml") && f !== "MinimizedTray.qml");
    const hung = [];
    for (const file of files) {
        const text = readFileSync(join(SHELL, file), "utf8");
        for (const line of text.split("\n")) {
            const m = line.match(/^\s*anchor\.(edges|gravity|margins\.(?:top|bottom)):\s*(.*)$/);
            if (m === null) {
                continue;
            }
            hung.push(file);
            assert.match(m[2], /Theme\.(hangEdge|hang\()/, `${file}: ${line.trim()}`);
        }
    }
    for (const file of ["BarTip.qml", "BatteryPopover.qml", "BluetoothPopover.qml", "ClocksPopover.qml",
        "MicPopover.qml", "NetworkPopover.qml", "SessionMenu.qml", "SharingPopover.qml", "SysmonPopover.qml",
        "TrayMenu.qml", "VolumePopover.qml", "WindowTitle.qml"]) {
        assert.ok(hung.includes(file), `${file} hangs a popup from the bar`);
    }
});
