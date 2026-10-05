// Tests for appearance.mjs. Local times are New York's, so daylight saving
// changes are real ones (2026: March 8 and November 1).
process.env.TZ = "America/New_York";

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DEFAULTS, LOCAL, parseTime, parseAppearance, loadAppearance, sunDown,
    scheduled, themeAt, flip, settingsKey, clockTime, schemeCommands, schemeIsDark,
} from "./appearance.mjs";

const at = (y, m, d, h, min = 0) => LOCAL.time(y, m, d, h, min);
const MIN = 60 * 1000;

test("the time zone took", () => {
    assert.equal(new Date(Date.UTC(2026, 6, 1, 12)).getHours(), 8);
});

test("times are 24-hour HH:MM", () => {
    assert.deepEqual(parseTime("07:00"), { h: 7, min: 0 });
    assert.deepEqual(parseTime("7:30"), { h: 7, min: 30 });
    assert.deepEqual(parseTime("23:59"), { h: 23, min: 59 });
    for (const bad of ["24:00", "7", "07:60", "7pm", "", 700, null]) {
        assert.equal(parseTime(bad), null, String(bad));
    }
});

test("a file's settings are checked one by one", () => {
    assert.deepEqual(parseAppearance('{"mode": "sun", "latitude": 51.5, "longitude": -0.1}'),
        { settings: { mode: "sun", latitude: 51.5, longitude: -0.1 } });
    assert.deepEqual(parseAppearance("{}"), { settings: {} });
    assert.match(parseAppearance('{"mode": "auto"}').error, /^mode must be one of "schedule"/);
    assert.match(parseAppearance('{"light": "7am"}').error, /^light must be a time/);
    assert.match(parseAppearance('{"latitude": 91}').error, /^latitude/);
    assert.match(parseAppearance('{"longitude": "0"}').error, /^longitude/);
    assert.equal(parseAppearance('{"moed": "dark"}').error, 'unknown setting "moed"');
    assert.equal(parseAppearance("[]").error, "expected an object of settings");
    assert.match(parseAppearance('{\n"mode": "dark",\n}').error, /^line 3: /);
});

test("no files is the defaults", () => {
    assert.deepEqual(loadAppearance(null, null), { settings: DEFAULTS, errors: [] });
});

test("the local file replaces settings one by one", () => {
    const r = loadAppearance('{"light": "06:30", "dark": "20:00"}', '{"dark": "21:00"}');
    assert.deepEqual(r, { settings: { mode: "schedule", light: "06:30", dark: "21:00" }, errors: [] });
});

test("a bad file keeps the last good settings and names every problem", () => {
    const good = { mode: "dark" };
    const r = loadAppearance('{"mode": 1}', '{"light": "x"}', good);
    assert.equal(r.settings, good);
    assert.deepEqual(r.errors, [
        'appearance.json: mode must be one of "schedule", "sun", "light", "dark"',
        'appearance.local.json: light must be a time like "07:00"',
    ]);
});

test("settings that don't work together are an error at load", () => {
    assert.deepEqual(loadAppearance('{"mode": "sun"}', null).errors,
        ['appearance.json: mode "sun" needs latitude and longitude']);
    assert.deepEqual(loadAppearance('{"mode": "sun"}', '{"latitude": 1}').errors,
        ['appearance.local.json: mode "sun" needs latitude and longitude']);
    assert.deepEqual(loadAppearance('{"light": "08:00", "dark": "08:00"}', null).errors,
        ["appearance.json: light and dark must be different times"]);
    assert.deepEqual(loadAppearance('{"mode": "sun"}', '{"latitude": 51.5, "longitude": -0.1}').errors, []);
});

// Checked against NOAA's solar calculator, to the minute it gives.
function near(actual, expected, what) {
    assert.ok(Math.abs(actual - expected) <= 2 * MIN,
        `${what}: ${new Date(actual).toISOString()}, expected ${new Date(expected).toISOString()}`);
}

const sunAt = (latitude, longitude) => ({ mode: "sun", latitude, longitude });

test("sunrise and sunset in London at midsummer", () => {
    const s = sunAt(51.5074, -0.1278);
    near(scheduled(s, Date.UTC(2026, 5, 21, 1)).next, Date.UTC(2026, 5, 21, 3, 43), "rise");
    near(scheduled(s, Date.UTC(2026, 5, 21, 12)).next, Date.UTC(2026, 5, 21, 20, 21), "set");
});

test("sunrise and sunset in San Francisco at midwinter, setting after midnight UTC", () => {
    const s = sunAt(37.7749, -122.4194);
    near(scheduled(s, Date.UTC(2026, 11, 21, 12)).next, Date.UTC(2026, 11, 21, 15, 21), "rise");
    near(scheduled(s, Date.UTC(2026, 11, 21, 20)).next, Date.UTC(2026, 11, 22, 0, 54), "set");
});

test("sunrise and sunset south of the equator", () => {
    const s = sunAt(-33.8688, 151.2093);
    near(scheduled(s, Date.UTC(2026, 11, 20, 12)).next, Date.UTC(2026, 11, 20, 18, 41), "rise");
    near(scheduled(s, Date.UTC(2026, 11, 21, 0)).next, Date.UTC(2026, 11, 21, 9, 6), "set");
});

test("the sun at the poles", () => {
    assert.equal(sunDown(Date.UTC(2026, 5, 21, 0), 78.2, 15.6), false);
    assert.equal(sunDown(Date.UTC(2026, 11, 21, 12), 78.2, 15.6), true);
});

test("the default schedule is light from 07:00 to 19:00", () => {
    assert.deepEqual(scheduled(DEFAULTS, at(2026, 10, 5, 12)), { dark: false, next: at(2026, 10, 5, 19) });
    assert.deepEqual(scheduled(DEFAULTS, at(2026, 10, 5, 19)), { dark: true, next: at(2026, 10, 6, 7) });
    assert.deepEqual(scheduled(DEFAULTS, at(2026, 10, 6, 6, 59)), { dark: true, next: at(2026, 10, 6, 7) });
    assert.deepEqual(scheduled(DEFAULTS, at(2026, 10, 6, 0, 30)), { dark: true, next: at(2026, 10, 6, 7) });
});

test("a schedule that's dark through the middle of the day still works", () => {
    const s = { mode: "schedule", light: "20:00", dark: "06:00" };
    assert.deepEqual(scheduled(s, at(2026, 10, 5, 12)), { dark: true, next: at(2026, 10, 5, 20) });
    assert.deepEqual(scheduled(s, at(2026, 10, 5, 23)), { dark: false, next: at(2026, 10, 6, 6) });
});

test("the schedule keeps wall time over daylight saving changes", () => {
    // The night clocks go forward, and the night they go back.
    assert.equal(scheduled(DEFAULTS, at(2026, 3, 7, 20)).next, at(2026, 3, 8, 7));
    assert.equal(at(2026, 3, 8, 7) - at(2026, 3, 7, 19), 11 * 60 * MIN);
    assert.equal(scheduled(DEFAULTS, at(2026, 10, 31, 20)).next, at(2026, 11, 1, 7));
    assert.equal(at(2026, 11, 1, 7) - at(2026, 10, 31, 19), 13 * 60 * MIN);
    assert.equal(new Date(at(2026, 11, 1, 7)).getHours(), 7);
});

test("fixed modes never change", () => {
    assert.deepEqual(scheduled({ mode: "dark" }, at(2026, 10, 5, 12)), { dark: true, next: null });
    assert.deepEqual(scheduled({ mode: "light" }, at(2026, 10, 5, 23)), { dark: false, next: null });
});

test("sun mode follows sunrise and sunset", () => {
    const s = sunAt(40.7128, -74.006);
    const noon = scheduled(s, at(2026, 6, 21, 12));
    assert.equal(noon.dark, false);
    near(noon.next, Date.UTC(2026, 5, 22, 0, 31), "sunset");
    const night = scheduled(s, at(2026, 6, 21, 23));
    assert.equal(night.dark, true);
    near(night.next, Date.UTC(2026, 5, 22, 9, 25), "sunrise");
    assert.equal(scheduled(s, at(2026, 6, 22, 3)).dark, true);
});

test("sun mode through polar day and night finds the change months away", () => {
    const s = { mode: "sun", latitude: 78.2, longitude: 15.6 };
    const summer = scheduled(s, at(2026, 6, 21, 12));
    assert.equal(summer.dark, false);
    // The midnight sun there ends late in August.
    assert.ok(summer.next > at(2026, 8, 15, 0) && summer.next < at(2026, 9, 1, 0), new Date(summer.next).toISOString());
    const winter = scheduled(s, at(2026, 12, 21, 12));
    assert.equal(winter.dark, true);
    // And the polar night in the middle of February.
    assert.ok(winter.next > at(2027, 2, 1, 0) && winter.next < at(2027, 3, 1, 0), new Date(winter.next).toISOString());
});

test("the first days of a polar day stay light after the last sunset", () => {
    // At 78.2°N the sun last sets just after midnight on April 19, 2026,
    // local time (UTC+2), and then stays up for months.
    const s = sunAt(78.2, 15.6);
    for (let h = 4; h < 24 * 7; h++) {
        const t = Date.UTC(2026, 3, 19, h);
        assert.equal(scheduled(s, t).dark, false, new Date(t).toISOString());
    }
    assert.ok(scheduled(s, Date.UTC(2026, 3, 19, 4)).next > Date.UTC(2026, 7, 1));
});

test("a flip in a polar day ends when the sun first sets", () => {
    const s = { mode: "sun", latitude: 78.2, longitude: 15.6 };
    const o = flip(s, at(2026, 6, 21, 12), null);
    assert.equal(o.dark, true);
    assert.equal(o.until, scheduled(s, at(2026, 6, 21, 12)).next);
    assert.equal(themeAt(s, o.until + MIN, o).override, null);
});

test("a flip lasts until the schedule's next change", () => {
    const noon = at(2026, 10, 5, 12);
    const o = flip(DEFAULTS, noon, null);
    assert.deepEqual(o, { dark: true, until: at(2026, 10, 5, 19), settings: settingsKey(DEFAULTS) });
    assert.deepEqual(themeAt(DEFAULTS, noon, o), { dark: true, next: at(2026, 10, 5, 19), override: o });
    assert.deepEqual(themeAt(DEFAULTS, at(2026, 10, 5, 18, 59), o).dark, true);
    // At the change, the schedule (dark) takes over, and the flip goes.
    assert.deepEqual(themeAt(DEFAULTS, at(2026, 10, 5, 19), o), { dark: true, next: at(2026, 10, 6, 7), override: null });
    assert.equal(themeAt(DEFAULTS, at(2026, 10, 6, 8), o).dark, false);
});

test("flipping back to the schedule drops the flip", () => {
    const noon = at(2026, 10, 5, 12);
    const o = flip(DEFAULTS, noon, null);
    assert.equal(flip(DEFAULTS, noon + MIN, o), null);
    assert.equal(themeAt(DEFAULTS, noon + MIN, null).dark, false);
});

test("a flip in a fixed mode holds until the settings change", () => {
    const s = { mode: "light" };
    const o = flip(s, at(2026, 10, 5, 12), null);
    assert.deepEqual(o, { dark: true, until: null, settings: settingsKey(s) });
    assert.equal(themeAt(s, at(2027, 1, 1, 12), o).dark, true);
    assert.equal(themeAt({ mode: "light", light: "08:00" }, at(2026, 10, 5, 13), o).dark, false);
});

test("a flip made under other settings is dropped", () => {
    const o = flip(DEFAULTS, at(2026, 10, 5, 12), null);
    const later = { mode: "schedule", light: "07:00", dark: "20:00" };
    assert.deepEqual(themeAt(later, at(2026, 10, 5, 13), o).override, null);
    assert.equal(themeAt(later, at(2026, 10, 5, 13), o).dark, false);
});

test("the settings key ignores order", () => {
    assert.equal(settingsKey({ dark: "19:00", mode: "schedule", light: "07:00" }), settingsKey(DEFAULTS));
});

test("clock times are local HH:MM", () => {
    assert.equal(clockTime(at(2026, 10, 5, 7, 5)), "07:05");
    assert.equal(clockTime(at(2026, 10, 5, 19)), "19:00");
});

test("gsettings output names the scheme", () => {
    assert.equal(schemeIsDark("color-scheme: 'prefer-dark'"), true);
    assert.equal(schemeIsDark("color-scheme: 'prefer-light'"), false);
    assert.equal(schemeIsDark("'prefer-dark'\n"), true);
    assert.equal(schemeIsDark("'default'"), false);
    assert.equal(schemeIsDark("gtk-theme: 'Adwaita-dark'"), null);
    assert.equal(schemeIsDark(""), null);
    assert.equal(schemeIsDark(undefined), null);
});

test("the color scheme and GTK theme tell apps", () => {
    assert.deepEqual(schemeCommands(true), [
        ["gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-dark"],
        ["gsettings", "set", "org.gnome.desktop.interface", "gtk-theme", "Adwaita-dark"],
    ]);
    assert.deepEqual(schemeCommands(false).map(c => c[4]), ["prefer-light", "Adwaita"]);
});
