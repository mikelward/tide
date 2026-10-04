// Tests for status.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    batteryView, volumeIcon, volumeText, scrolledVolume, formatDuration, batteryStatus, profileChoices, degradedText,
} from "./status.mjs";

test("the battery shows its percentage and level icon", () => {
    assert.deepEqual(batteryView({ present: true, percentage: 0.82, state: 2 }),
        { visible: true, text: "82%", icon: "battery-level-80-symbolic", low: false });
    assert.equal(batteryView({ present: true, percentage: 0.86, state: 2 }).icon, "battery-level-90-symbolic");
    assert.equal(batteryView({ present: true, percentage: 0.04, state: 2 }).icon, "battery-level-0-symbolic");
});

test("a charging battery says so", () => {
    assert.equal(batteryView({ present: true, percentage: 0.5, state: 1 }).icon, "battery-level-50-charging-symbolic");
    assert.equal(batteryView({ present: true, percentage: 0.5, state: 5 }).icon, "battery-level-50-charging-symbolic");
    assert.equal(batteryView({ present: true, percentage: 1, state: 4 }).icon, "battery-level-100-charged-symbolic");
});

test("the battery is red below 15% unless it's charging", () => {
    assert.equal(batteryView({ present: true, percentage: 0.14, state: 2 }).low, true);
    assert.equal(batteryView({ present: true, percentage: 0.15, state: 2 }).low, false);
    assert.equal(batteryView({ present: true, percentage: 0.09, state: 1 }).low, false);
});

test("no battery shows nothing", () => {
    assert.equal(batteryView({ present: false, percentage: 0.5, state: 2 }).visible, false);
    assert.equal(batteryView({ present: true, percentage: NaN, state: 0 }).visible, false);
});

test("the volume icon follows mute and level", () => {
    assert.equal(volumeIcon({ muted: true, volume: 0.8 }), "audio-volume-muted-symbolic");
    assert.equal(volumeIcon({ muted: false, volume: 0 }), "audio-volume-muted-symbolic");
    assert.equal(volumeIcon({ muted: false, volume: 0.2 }), "audio-volume-low-symbolic");
    assert.equal(volumeIcon({ muted: false, volume: 0.5 }), "audio-volume-medium-symbolic");
    assert.equal(volumeIcon({ muted: false, volume: 0.9 }), "audio-volume-high-symbolic");
    assert.equal(volumeIcon({ muted: false, volume: undefined }), "audio-volume-muted-symbolic");
});

test("scrolling changes the volume by 5% a notch, from 0 to 100%", () => {
    assert.equal(scrolledVolume(0.5, 1), 0.55);
    assert.equal(scrolledVolume(0.5, -2), 0.4);
    assert.equal(scrolledVolume(0.98, 1), 1);
    assert.equal(scrolledVolume(0.02, -1), 0);
    assert.equal(scrolledVolume(0.42, 1), 0.47);
    assert.equal(scrolledVolume(0.42, -1), 0.37);
    assert.equal(scrolledVolume(0.1, 2), 0.2);
    assert.equal(scrolledVolume(undefined, 1), 0.05);
});

test("scrolling up leaves a volume above 100% alone, and down brings it back", () => {
    assert.equal(scrolledVolume(1.3, 1), 1.3);
    assert.equal(scrolledVolume(1.3, -1), 1);
});

test("durations read in hours and minutes", () => {
    assert.equal(formatDuration(0), "");
    assert.equal(formatDuration(NaN), "");
    assert.equal(formatDuration(20), "under a minute");
    assert.equal(formatDuration(45 * 60), "45 min");
    assert.equal(formatDuration(3 * 3600), "3 h");
    assert.equal(formatDuration(3 * 3600 + 20 * 60 + 10), "3 h 20 min");
});

test("the battery status says what it's doing and for how long", () => {
    assert.equal(batteryStatus({ state: 2, timeToEmpty: 12000, timeToFull: 0 }), "3 h 20 min left");
    assert.equal(batteryStatus({ state: 2, timeToEmpty: 0, timeToFull: 0 }), "On battery");
    assert.equal(batteryStatus({ state: 1, timeToEmpty: 0, timeToFull: 3900 }), "Charging, full in 1 h 5 min");
    assert.equal(batteryStatus({ state: 1, timeToEmpty: 0, timeToFull: 0 }), "Charging");
    assert.equal(batteryStatus({ state: 4, timeToEmpty: 0, timeToFull: 0 }), "Fully charged");
    assert.equal(batteryStatus({ state: 5, timeToEmpty: 0, timeToFull: 0 }), "Plugged in, not charging");
});

test("performance is offered only where the machine has it", () => {
    assert.deepEqual(profileChoices(true).map(p => [p.profile, p.label]), [[2, "Performance"], [1, "Balanced"], [0, "Power saver"]]);
    assert.deepEqual(profileChoices(false).map(p => p.label), ["Balanced", "Power saver"]);
});

test("a degraded performance says why", () => {
    assert.equal(degradedText(0), "");
    assert.match(degradedText(1), /on a lap/);
    assert.match(degradedText(2), /hot/);
});

test("a battery charging at 100% uses the charged icon, as Adwaita has no 100-charging", () => {
    assert.equal(batteryView({ present: true, percentage: 0.97, state: 1 }).icon, "battery-level-100-charged-symbolic");
    assert.equal(batteryView({ present: true, percentage: 1, state: 5 }).icon, "battery-level-100-charged-symbolic");
    assert.equal(batteryView({ present: true, percentage: 0.94, state: 1 }).icon, "battery-level-90-charging-symbolic");
});

test("the volume reads as a percentage", () => {
    assert.equal(volumeText(0.453), "45%");
    assert.equal(volumeText(0), "0%");
    assert.equal(volumeText(1.3), "130%");
    assert.equal(volumeText(undefined), "");
});
