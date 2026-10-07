// Tests for appearance.mjs. Local times are New York's, so daylight saving
// changes are real ones (2026: March 8 and November 1).
process.env.TZ = "America/New_York";

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DEFAULTS, LOCAL, parseTime, parseAppearance, loadAppearance, sunDown,
    scheduled, themeAt, flip, settingsKey, clockTime, schemeCommands, schemeIsDark,
    hookCommand, TELL_IDLE, tellNext, MODE_CHOICES, steppedModeAt, steppedTime, steppedTimePast, parseCoordinate, withSetting,
} from "./appearance.mjs";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

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
        ["timeout", "--verbose", "--kill-after=5", "10", "gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-dark"],
        ["timeout", "--verbose", "--kill-after=5", "10", "gsettings", "set", "org.gnome.desktop.interface", "gtk-theme", "Adwaita-dark"],
    ]);
    assert.deepEqual(schemeCommands(false).map(c => c[c.length - 1]), ["prefer-light", "Adwaita"]);
});

// A gsettings that never returns (dconf not answering) mustn't hold up the
// switches queued behind it.
test("a scheme command that hangs is stopped", () => {
    const dir = mkdtempSync(join(tmpdir(), "scheme-"));
    writeFileSync(join(dir, "gsettings"), "#!/bin/sh\nexec sleep 60\n", { mode: 0o755 });
    const [cmd, ...args] = schemeCommands(true, 1)[0];
    const started = Date.now();
    const r = spawnSync(cmd, args, { env: { ...process.env, LC_ALL: "C", PATH: `${dir}:${process.env.PATH}` } });
    assert.equal(r.status, 124);
    assert.match(r.stderr.toString(), /timeout: sending signal TERM to command .gsettings./);
    assert.ok(Date.now() - started < 10000);
    rmSync(dir, { recursive: true });
});

// Runs hookCommand's command for real, as Launcher would. In the C locale,
// so the messages matched below are timeout's untranslated ones.
function runHook(dir, seconds) {
    const [cmd, ...args] = hookCommand(dir, seconds);
    return spawnSync(cmd, args, { encoding: "utf8", env: { ...process.env, LC_ALL: "C" } });
}

test("no appearance hook is nothing to run", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-hook-"));
    try {
        const r = runHook(dir);
        assert.equal(r.status, 0);
        assert.equal(r.stderr, "");
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("the appearance hook runs with no arguments", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-hook-"));
    try {
        writeFileSync(join(dir, "appearance-hook"), `#!/bin/sh\necho "ran $#" > "${dir}/out"\n`);
        chmodSync(join(dir, "appearance-hook"), 0o755);
        assert.equal(runHook(dir).status, 0);
        assert.equal(readFileSync(join(dir, "out"), "utf8"), "ran 0\n");
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("an appearance hook that can't run says so", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-hook-"));
    try {
        writeFileSync(join(dir, "appearance-hook"), "#!/bin/sh\n");
        chmodSync(join(dir, "appearance-hook"), 0o644);
        const r = runHook(dir);
        assert.equal(r.status, 1);
        assert.match(r.stderr, /appearance-hook is not executable/);
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("telling apps runs one run at a time, and the last tells the latest", () => {
    let r = tellNext(TELL_IDLE, "change");
    assert.equal(r.start, true);
    // Two changes during a run make one more run, after it.
    r = tellNext(r.state, "change");
    assert.equal(r.start, false);
    r = tellNext(r.state, "change");
    assert.equal(r.start, false);
    r = tellNext(r.state, "done");
    assert.equal(r.start, true);
    r = tellNext(r.state, "done");
    assert.equal(r.start, false);
    assert.deepEqual(r.state, TELL_IDLE);
    assert.throws(() => tellNext(TELL_IDLE, "bogus"), /unknown tell event/);
});

test("an appearance hook that hangs is stopped, and says so", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-hook-"));
    try {
        writeFileSync(join(dir, "appearance-hook"), "#!/bin/sh\nexec sleep 30\n");
        chmodSync(join(dir, "appearance-hook"), 0o755);
        const started = Date.now();
        const r = runHook(dir, 1);
        assert.ok(Date.now() - started < 10000);
        assert.equal(r.status, 124);
        assert.match(r.stderr, /timeout: sending signal TERM to command .*appearance-hook/);
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("an appearance hook that links to nothing says so", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-hook-"));
    try {
        symlinkSync(join(dir, "gone"), join(dir, "appearance-hook"));
        const r = runHook(dir, 1);
        assert.equal(r.status, 1);
        assert.match(r.stderr, /appearance-hook is a link to nothing/);
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("an appearance hook that exits 124 itself isn't reported as stopped", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-hook-"));
    try {
        writeFileSync(join(dir, "appearance-hook"), "#!/bin/sh\nexit 124\n");
        chmodSync(join(dir, "appearance-hook"), 0o755);
        const r = runHook(dir, 1);
        assert.equal(r.status, 124);
        assert.doesNotMatch(r.stderr, /sending signal/);
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("an appearance hook that ignores TERM is killed", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-hook-"));
    try {
        writeFileSync(join(dir, "appearance-hook"), "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n");
        chmodSync(join(dir, "appearance-hook"), 0o755);
        const started = Date.now();
        const r = runHook(dir, 1);
        assert.ok(Date.now() - started < 15000);
        assert.equal(r.status, 137);
        assert.match(r.stderr, /timeout: sending signal KILL to command .*appearance-hook/);
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("the Appearance page offers every mode, in order", () => {
    assert.deepEqual(MODE_CHOICES.map(c => c.mode), ["schedule", "sun", "light", "dark"]);
    for (const c of MODE_CHOICES) {
        assert.deepEqual(parseAppearance(JSON.stringify({ mode: c.mode })).error, undefined, c.mode);
    }
});

test("the mode steps past sunrise and sunset until there's a location", () => {
    const at = mode => MODE_CHOICES.findIndex(c => c.mode === mode);
    const nowhere = {};
    assert.equal(steppedModeAt(nowhere, at("schedule"), 1), at("light"), "› skips sun");
    assert.equal(steppedModeAt(nowhere, at("light"), -1), at("schedule"), "‹ skips sun");
    assert.equal(steppedModeAt(nowhere, at("schedule"), -1), at("schedule"), "stops at the start");
    assert.equal(steppedModeAt(nowhere, at("dark"), 1), at("dark"), "stops at the end");
    const located = { latitude: 51.5, longitude: -0.1 };
    assert.equal(steppedModeAt(located, at("schedule"), 1), at("sun"));
    assert.equal(steppedModeAt(located, at("light"), -1), at("sun"));
    assert.equal(steppedModeAt({ latitude: 51.5 }, at("schedule"), 1), at("light"), "half a location is none");
    // What it steps to is a setting withSetting takes.
    for (const mode of ["schedule", "sun", "light", "dark"]) {
        const next = MODE_CHOICES[steppedModeAt(nowhere, at(mode), 1)].mode;
        assert.equal(withSetting(null, "mode", next).error, undefined, `${mode} → ${next}`);
    }
});

test("a time moves a quarter hour a step, stopping at either end of the day", () => {
    assert.equal(steppedTime("07:00", 1), "07:15");
    assert.equal(steppedTime("07:00", -1), "06:45");
    assert.equal(steppedTime("07:00", 4), "08:00");
    // Off a quarter hour, the first step lands on one.
    assert.equal(steppedTime("07:10", 1), "07:15");
    assert.equal(steppedTime("07:10", -1), "07:00");
    assert.equal(steppedTime("07:10", 2), "07:30");
    assert.equal(steppedTime("23:45", 1), "23:45");
    // Past the last quarter hour, + stays and − comes back to it.
    assert.equal(steppedTime("23:50", 1), "23:50");
    assert.equal(steppedTime("23:59", 2), "23:59");
    assert.equal(steppedTime("23:50", -1), "23:45");
    assert.equal(steppedTime("00:00", -1), "00:00");
    assert.equal(steppedTime("07:00", 0), "07:00");
    // What steppedTime is given always parses back.
    assert.notEqual(parseTime(steppedTime("19:00", -1)), null);
});

test("a typed latitude or longitude is a number in range", () => {
    assert.deepEqual(parseCoordinate("latitude", " 37.77 "), { value: 37.77 });
    assert.deepEqual(parseCoordinate("longitude", "-122.42"), { value: -122.42 });
    assert.deepEqual(parseCoordinate("longitude", "+151"), { value: 151 });
    assert.match(parseCoordinate("latitude", "91").error, /latitude must be a number from -90 to 90/);
    assert.match(parseCoordinate("longitude", "200").error, /longitude must be a number from -180 to 180/);
    for (const text of ["", "north", "37,77", "1e2", "0x10", "37.", ".5"]) {
        assert.match(parseCoordinate("latitude", text).error, /latitude must be a number in decimal degrees/, JSON.stringify(text));
    }
});

test("a setting goes into appearance.local.json, keeping the rest", () => {
    assert.equal(withSetting(null, "mode", "dark").text, '{\n  "mode": "dark"\n}\n');
    const local = '{\n  "light": "06:30"\n}\n';
    assert.deepEqual(JSON.parse(withSetting(local, "dark", "20:00").text), { light: "06:30", dark: "20:00" });
    // In KEYS order, whatever order they're set in.
    assert.deepEqual(Object.keys(JSON.parse(withSetting('{"longitude": 1}', "latitude", 2).text)), ["latitude", "longitude"]);
});

test("a setting that wouldn't work with the rest is refused, the shared file's included", () => {
    assert.deepEqual(withSetting(null, "mode", "sun"), { error: 'mode "sun" needs latitude and longitude' });
    // With a location in either file, it's taken.
    assert.equal(JSON.parse(withSetting(null, "mode", "sun", '{"latitude": 51.5, "longitude": -0.1}').text).mode, "sun");
    assert.equal(JSON.parse(withSetting('{"latitude": 51.5, "longitude": -0.1}', "mode", "sun").text).mode, "sun");
    assert.deepEqual(withSetting(null, "light", "19:00"), { error: "light and dark must be different times" });
});

test("a bad value or a file that doesn't parse is refused, never overwritten", () => {
    assert.match(withSetting(null, "mode", "auto").error, /^mode must be one of/);
    assert.match(withSetting(null, "light", "7am").error, /^light must be a time like/);
    assert.match(withSetting(null, "wallpaper", "x").error, /^unknown setting "wallpaper"/);
    assert.match(withSetting("{", "mode", "dark").error, /^appearance\.local\.json: line 1: /);
    assert.match(withSetting(null, "mode", "dark", "[]").error, /^appearance\.json: expected an object/);
});

test("a time steps past the other one, so light and dark can cross", () => {
    // From 07:00 and 19:00, light can go later than dark.
    assert.equal(steppedTimePast("18:45", 1, "19:00"), "19:15");
    assert.equal(steppedTimePast("19:15", -1, "19:00"), "18:45");
    assert.equal(steppedTimePast("07:00", 1, "19:00"), "07:15", "anywhere else, one step");
    // With nowhere past it, it stays.
    assert.equal(steppedTimePast("23:30", 1, "23:45"), "23:30");
    assert.equal(steppedTimePast("00:15", -1, "00:00"), "00:15");
    // What it gives is never the other time, so withSetting takes it.
    assert.equal(withSetting('{"light": "18:45"}', "light", steppedTimePast("18:45", 1, "19:00")).error, undefined);
});
