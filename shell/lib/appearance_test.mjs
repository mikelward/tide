// Tests for appearance.mjs. Local times are New York's, so daylight saving
// changes are real ones (2026: March 8 and November 1).
process.env.TZ = "America/New_York";

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DEFAULTS, LOCAL, parseTime, parseAppearance, loadAppearance, sunDown,
    scheduled, themeAt, flip, settingsKey, clockTime, schemeCommands, schemeIsDark,
    hookCommand, TELL_IDLE, tellNext, MODE_CHOICES, steppedModeAt, steppedTime, steppedTimePast, parseCoordinate, withSetting,
    DIM_STRENGTH, dimStrength, steppedDim, formatDim, appearanceLua,
    expandHome, pickCommand, galleryFolders, galleryCommand, galleryImages, fitsScreens, galleryRows, galleryCollection, galleryCollections, distroName, galleryModeFor, galleryFiltered, GALLERY_MODES, UNSPLASH, moreWallpapers, openCommand, pickedWallpaper, wallpaperCandidates, fileUrl, findCommand, drawableCandidates, wallpaperRecord, recordedWallpaper,
    wallpaperColor, lockColor, WALLPAPER_COLORS,
    wallpaperFrame, framingCaption, previewScreens, previewLayout, previewCandidates,
    POSITIONS, POSITION_CHOICES, wallpaperPosition, wallpaperPlacement, positionAt, steppedPositionAt, appearanceConf,
    LOOK_ROOT, lookDir, lookCommand, lookWriteCommand, lookCopied, lookJson, parseLook, lookAt
} from "./appearance.mjs";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, statSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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

test("a flip outlives a change to the dim", () => {
    const noon = at(2026, 10, 5, 12);
    const o = flip(DEFAULTS, noon, null);
    const dimmer = Object.assign({}, DEFAULTS, { dimStrength: 0.12 });
    assert.deepEqual(themeAt(dimmer, noon + MIN, o), { dark: true, next: at(2026, 10, 5, 19), override: o });
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

test("the dim strength is a number from 0 to 1, conf's 0.12 until it's set", () => {
    assert.deepEqual(parseAppearance('{"dimStrength": 0.12}'), { settings: { dimStrength: 0.12 } });
    assert.equal(parseAppearance('{"dimStrength": 1.5}').error, "dimStrength must be a number from 0 to 1");
    assert.equal(parseAppearance('{"dimStrength": "strong"}').error, "dimStrength must be a number from 0 to 1");
    assert.equal(DIM_STRENGTH, 0.12);
    assert.equal(dimStrength(DEFAULTS), 0.12);
    assert.equal(dimStrength(loadAppearance(null, '{"dimStrength": 0}').settings), 0, "none at all is a strength");
    assert.equal(dimStrength(loadAppearance('{"dimStrength": 0.2}', '{"dimStrength": 0.1}').settings), 0.1, "the local file's wins");
});

test("the dim strength goes into appearance.local.json, keeping the rest", () => {
    assert.deepEqual(JSON.parse(withSetting('{"dark": "20:00"}', "dimStrength", 0.12).text), { dark: "20:00", dimStrength: 0.12 });
    assert.match(withSetting(null, "dimStrength", 2).error, /^dimStrength must be/);
});

test("− and + step the dim a point at a time, from none to half", () => {
    assert.equal(steppedDim(0.07, 1), 0.08);
    assert.equal(steppedDim(0.07, -1), 0.06);
    assert.equal(steppedDim(0, -1), 0, "none is the bottom");
    assert.equal(steppedDim(0.5, 1), 0.5, "half is the top");
    assert.equal(steppedDim(0.075, 1), 0.08, "off a point, onto the next");
    assert.equal(steppedDim(0.8, -1), 0.5, "set past the top by hand, − comes back into range");
    assert.equal(steppedDim(0.8, 1), 0.8, "and + stays");
    assert.equal(formatDim(0.07), "7%");
    assert.equal(formatDim(0.125), "13%");
});

test("only a dim that's set reaches Hyprland", () => {
    const body = lua => lua.split("\n").slice(3).join("\n");
    assert.equal(body(appearanceLua(DEFAULTS)), "return {\n}\n");
    assert.equal(body(appearanceLua({ mode: "dark", dimStrength: 0.12 })), "return {\n    dim_strength = 0.12,\n}\n");
    // It's Lua that loads as data, as conf's hyprland.lua loads it.
    const script = `
        local t = assert(load(io.read("a"), "tide-appearance.lua", "t", {}))()
        print(t.dim_strength)
    `;
    for (const lua of [process.env.LUA, "lua5.5", "lua5.4", "lua"].filter(Boolean)) {
        const r = spawnSync(lua, ["-e", script], { input: appearanceLua({ dimStrength: 0.12 }), encoding: "utf8" });
        if (r.error && r.error.code === "ENOENT") {
            continue;
        }
        assert.equal(r.status, 0, `${lua}: ${r.stderr}`);
        assert.equal(r.stdout.trim(), "0.12");
        return;
    }
    assert.fail("no lua5.5, lua5.4 or lua on PATH");
});

test("a wallpaper is a file's path, absolute or from ~/, or empty for the default", () => {
    assert.deepEqual(parseAppearance('{"lightWallpaper": "~/Pictures/day.jpg", "darkWallpaper": "/srv/night.png"}').settings,
        { lightWallpaper: "~/Pictures/day.jpg", darkWallpaper: "/srv/night.png" });
    assert.deepEqual(parseAppearance('{"darkWallpaper": ""}').settings, { darkWallpaper: "" });
    for (const bad of ["day.jpg", "~user/day.jpg", "/a\nb.jpg", 5, null]) {
        assert.match(parseAppearance(JSON.stringify({ lightWallpaper: bad })).error, /^lightWallpaper must be a file's path/, JSON.stringify(bad));
    }
    assert.deepEqual(JSON.parse(withSetting('{"dark": "20:00"}', "darkWallpaper", "~/night.jpg").text), { dark: "20:00", darkWallpaper: "~/night.jpg" });
});

test("the wallpaper is the mode's own, then $TIDE_WALLPAPER, then conf's", () => {
    const home = "/home/user";
    assert.deepEqual(wallpaperCandidates({ lightWallpaper: "~/day.jpg", darkWallpaper: "/srv/night.png" }, true, home), [
        "/srv/night.png",
        "/home/user/.config/hypr/wallpaper-dark.jpg",
        "/home/user/.config/hypr/wallpaper.jpg",
    ]);
    assert.deepEqual(wallpaperCandidates({ lightWallpaper: "~/day.jpg" }, false, home, "/srv/both.jpg"), [
        "/home/user/day.jpg",
        "/srv/both.jpg",
        "/home/user/.config/hypr/wallpaper-light.jpg",
        "/home/user/.config/hypr/wallpaper.jpg",
    ]);
    assert.deepEqual(wallpaperCandidates({ darkWallpaper: "" }, true, home), [
        "/home/user/.config/hypr/wallpaper-dark.jpg",
        "/home/user/.config/hypr/wallpaper.jpg",
    ], "empty is the default");
    assert.deepEqual(wallpaperCandidates({ lightWallpaper: "~/.config/hypr/wallpaper.jpg" }, false, home), [
        "/home/user/.config/hypr/wallpaper.jpg",
        "/home/user/.config/hypr/wallpaper-light.jpg",
    ], "each once");
    assert.equal(expandHome("~/a", home), "/home/user/a");
    assert.equal(expandHome("/a/~/b", home), "/a/~/b");
});

test("a wallpaper's path is escaped in its URL", () => {
    assert.equal(fileUrl("/home/user/My Pictures/#1?.jpg"), "file:///home/user/My%20Pictures/%231%3F.jpg");
});

test("a flip outlives a change to a wallpaper", () => {
    const noon = at(2026, 10, 5, 12);
    const o = flip(DEFAULTS, noon, null);
    const pictured = Object.assign({}, DEFAULTS, { darkWallpaper: "~/night.jpg" });
    assert.equal(themeAt(pictured, noon + MIN, o).override, o);
});

test("the wallpaper is the first candidate that's a file it can read, not a directory", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-wallpaper-"));
    try {
        mkdirSync(join(dir, "folder.jpg"));
        writeFileSync(join(dir, "day.jpg"), "");
        const run = paths => {
            const [cmd, ...args] = findCommand(paths);
            return execFileSync(cmd, args, { encoding: "utf8" });
        };
        assert.equal(run([join(dir, "missing.jpg"), join(dir, "folder.jpg"), join(dir, "day.jpg")]), join(dir, "day.jpg"));
        assert.throws(() => run([join(dir, "folder.jpg")]), e => e.status === 1, "a directory alone is none");
    } finally {
        rmSync(dir, { recursive: true });
    }
});

test("a wallpaper the shell couldn't draw is passed over for the next", () => {
    assert.deepEqual(drawableCandidates(["/a.jpg", "/b.jpg", "/c.jpg"], ["/a.jpg"]), ["/b.jpg", "/c.jpg"]);
    assert.deepEqual(drawableCandidates(["/a.jpg"], []), ["/a.jpg"]);
});

test("the shell records the wallpaper it draws for the lock, which reads it back", () => {
    assert.equal(wallpaperRecord("/home/user/Pictures/day 1.jpg"), "/home/user/Pictures/day 1.jpg\nfill\n");
    assert.equal(wallpaperRecord(""), "\nfill\n", "none, as an empty line, which a missing file's FileView can still write");
    assert.deepEqual(recordedWallpaper(wallpaperRecord("")), { path: "", color: "", position: "fill" });
    assert.deepEqual(recordedWallpaper(wallpaperRecord("/home/user/Pictures/day 1.jpg")), { path: "/home/user/Pictures/day 1.jpg", color: "", position: "fill" });
    assert.deepEqual(recordedWallpaper(""), { path: "", color: "", position: "fill" });
    assert.deepEqual(recordedWallpaper("/srv/night.png"), { path: "/srv/night.png", color: "", position: "fill" }, "with no newline");
    assert.match(recordedWallpaper("Pictures/day.jpg\n").error, /absolute path/);
    assert.equal(recordedWallpaper("Pictures/day.jpg\n").path, "");
    assert.match(recordedWallpaper("/a.jpg\nfill\n/b.jpg\n").error, /on a line of its own/);
});

test("the record carries the position, so the lock frames a picture as the shell does", () => {
    for (const position of ["fill", "fill-top", "fill-bottom", "fit"]) {
        assert.equal(wallpaperRecord("/srv/day.jpg", position), `/srv/day.jpg\n${position}\n`);
        assert.deepEqual(recordedWallpaper(wallpaperRecord("/srv/day.jpg", position)), { path: "/srv/day.jpg", color: "", position });
    }
    assert.deepEqual(recordedWallpaper(wallpaperRecord("#1a1d2e", "fit")), { path: "", color: "#1a1d2e", position: "fit" });
    // Written before positions: the wallpaper's line alone, drawn as fill.
    assert.deepEqual(recordedWallpaper("/home/user/day.jpg\n"), { path: "/home/user/day.jpg", color: "", position: "fill" });
    for (const bad of ["/srv/day.jpg\ncenter\n", "#1a1d2e\n/a.jpg\n", "/srv/day.jpg\n\n"]) {
        const r = recordedWallpaper(bad);
        assert.match(r.error, /expected a position, one of fill, fill-top, fill-bottom, fit/, JSON.stringify(bad));
        assert.deepEqual([r.path, r.color, r.position], ["", "", "fill"], "none, as a bad wallpaper is");
    }
});

test("a color wallpaper is recorded for the lock as its color, and old records still read", () => {
    assert.equal(wallpaperRecord("#1a1d2e"), "#1a1d2e\nfill\n");
    assert.deepEqual(recordedWallpaper(wallpaperRecord("#1a1d2e")), { path: "", color: "#1a1d2e", position: "fill" });
    assert.deepEqual(recordedWallpaper("#ABC\n"), { path: "", color: "#aabbcc", position: "fill" });
    // Written before colors: a path, or none, reads as it did.
    assert.deepEqual(recordedWallpaper("/home/user/day.jpg\n"), { path: "/home/user/day.jpg", color: "", position: "fill" });
    assert.deepEqual(recordedWallpaper("\n"), { path: "", color: "", position: "fill" });
    for (const bad of ["#12345\n", "red\n"]) {
        const r = recordedWallpaper(bad);
        assert.match(r.error, /absolute path or a color/, JSON.stringify(bad));
        assert.equal(r.path, "");
        assert.equal(r.color, "");
    }
});

test("a wallpaper can be a color, #rrggbb or #rgb", () => {
    assert.deepEqual(parseAppearance('{"lightWallpaper": "#ECECF0", "darkWallpaper": "#123"}').settings,
        { lightWallpaper: "#ECECF0", darkWallpaper: "#123" });
    for (const bad of ["#", "#12", "#1234", "#12345", "#1234567", "#1a1d2eff", "#ggg", "# 1a1d2e", "#1a1d2e\n"]) {
        assert.match(parseAppearance(JSON.stringify({ darkWallpaper: bad })).error, /^darkWallpaper must be a color as #rrggbb or #rgb/, JSON.stringify(bad));
    }
    // Not a color, nor a path.
    assert.match(parseAppearance('{"darkWallpaper": "red"}').error, /^darkWallpaper must be a file's path, such as "~\/Pictures\/day.jpg", a color/);
    assert.equal(withSetting("{}", "darkWallpaper", "#1a1d2e").error, undefined, "as the page's swatch sets it");
    assert.equal(wallpaperColor("#ECECF0"), "#ececf0");
    assert.equal(wallpaperColor("#1aF"), "#11aaff");
    assert.equal(wallpaperColor("~/day.jpg"), "");
    assert.equal(wallpaperColor(""), "");
    assert.equal(wallpaperColor(undefined), "");
    assert.equal(wallpaperColor(5), "");
});

test("a color set for the mode wins, and the fallbacks are only for none", () => {
    const home = "/home/user";
    assert.deepEqual(wallpaperCandidates({ darkWallpaper: "#1A1D2E" }, true, home, "/srv/both.jpg"), ["#1a1d2e"]);
    assert.deepEqual(wallpaperCandidates({ lightWallpaper: "#fff", darkWallpaper: "~/night.jpg" }, false, home), ["#ffffff"]);
    // The other mode's color is no matter.
    assert.deepEqual(wallpaperCandidates({ lightWallpaper: "#fff", darkWallpaper: "~/night.jpg" }, true, home), [
        "/home/user/night.jpg",
        "/home/user/.config/hypr/wallpaper-dark.jpg",
        "/home/user/.config/hypr/wallpaper.jpg",
    ]);
    assert.deepEqual(wallpaperCandidates({ lightWallpaper: "#fff" }, true, home, "/srv/both.jpg"), [
        "/srv/both.jpg",
        "/home/user/.config/hypr/wallpaper-dark.jpg",
        "/home/user/.config/hypr/wallpaper.jpg",
    ]);
});

test("the lock darkens a color wallpaper as it does a picture", () => {
    assert.equal(lockColor("#ececf0"), "#acacb0");
    assert.equal(lockColor("#1a1d2e"), "#000000", "not below black");
    assert.equal(lockColor("#FFF"), "#bfbfbf");
    assert.equal(lockColor(""), "");
    assert.equal(lockColor("/a.jpg"), "");
});

test("the page offers a handful of distinct colors, each a wallpaper", () => {
    assert.ok(WALLPAPER_COLORS.length >= 6 && WALLPAPER_COLORS.length <= 8);
    for (const c of WALLPAPER_COLORS) {
        assert.equal(wallpaperColor(c.color), c.color, c.label);
        assert.equal(withSetting("{}", "lightWallpaper", c.color).error, undefined, c.label);
        assert.notEqual(c.label, "");
    }
    assert.equal(new Set(WALLPAPER_COLORS.map(c => c.color)).size, WALLPAPER_COLORS.length);
});

// The shell keeps a flip across a config reload as JSON text
// (AppearanceData.qml), so a flip must read back as it was.
test("a flip reads back from JSON as it was", () => {
    const kept = o => JSON.parse(JSON.stringify(o));
    const noon = at(2026, 10, 5, 12);
    for (const s of [DEFAULTS, { mode: "light" }, { mode: "sun", latitude: 78.2, longitude: 15.6 }]) {
        const o = flip(s, noon, null);
        for (const t of [noon, noon + MIN, at(2026, 10, 5, 19), at(2026, 10, 6, 8), at(2027, 1, 1, 12)]) {
            assert.deepEqual(themeAt(s, t, kept(o)), themeAt(s, t, o));
        }
        assert.deepEqual(flip(s, noon + MIN, kept(o)), flip(s, noon + MIN, o));
    }
    assert.equal(kept(null), null);
});

test("a wallpaper's chooser offers images, opening where its file is", () => {
    const home = "/home/u";
    assert.deepEqual(pickCommand("Light wallpaper", "~/Pictures/day.jpg", home),
        ["tide-pick", "--images", "--title", "Light wallpaper", "--folder", "/home/u/Pictures"]);
    assert.deepEqual(pickCommand("Dark wallpaper", "/srv/night.png", home),
        ["tide-pick", "--images", "--title", "Dark wallpaper", "--folder", "/srv"]);
    // The default, or none set, opens where the chooser likes.
    assert.deepEqual(pickCommand("Dark wallpaper", "", home), ["tide-pick", "--images", "--title", "Dark wallpaper"]);
    assert.deepEqual(pickCommand("Dark wallpaper", undefined, home), ["tide-pick", "--images", "--title", "Dark wallpaper"]);
    // Nor does a color, which has no folder.
    assert.deepEqual(pickCommand("Dark wallpaper", "#1a1d2e", home), ["tide-pick", "--images", "--title", "Dark wallpaper"]);
});

test("the wallpaper grid shows the distro's collections, then yours", () => {
    assert.deepEqual(galleryFolders("/home/u"),
        ["/usr/share/backgrounds", "/usr/share/wallpapers", "/home/u/Pictures/wallpapers"]);
});

test("the wallpaper grid lists its pictures with their sizes", () => {
    // tide-pick --list itself is tested in cmd/tide-pick.
    assert.deepEqual(galleryCommand(["/usr/share/backgrounds", "/home/u/Pictures/wallpapers"]),
        ["tide-pick", "--list", "/usr/share/backgrounds", "/home/u/Pictures/wallpapers"]);
});

test("the grid finds more wallpapers on Unsplash and Wallhaven", () => {
    const [unsplash, wallhaven] = moreWallpapers([{ name: "DP-1", width: 3440, height: 1440 }, { name: "eDP-1", width: 2880, height: 1800 }]);
    assert.equal(unsplash.site, "Unsplash");
    assert.equal(unsplash.url, UNSPLASH);
    const u = new URL(UNSPLASH);
    assert.equal(u.hostname, "unsplash.com");
    assert.equal(u.searchParams.get("license"), "free");
    assert.equal(u.searchParams.get("orientation"), "landscape");

    assert.equal(wallhaven.site, "Wallhaven");
    const w = new URL(wallhaven.url);
    assert.equal(w.hostname, "wallhaven.cc");
    // General and safe for work only.
    assert.equal(w.searchParams.get("categories"), "100");
    assert.equal(w.searchParams.get("purity"), "100");
    // The widest monitor's size and shape, though the laptop has more
    // pixels: 3440×1440 is 21:9.
    assert.equal(w.searchParams.get("atleast"), "3440x1440");
    assert.equal(w.searchParams.get("ratios"), "21x9");
    const ratios = screen => new URL(moreWallpapers([screen])[1].url).searchParams.get("ratios");
    assert.equal(ratios({ width: 1920, height: 1080 }), "16x9");
    assert.equal(ratios({ width: 2560, height: 1600 }), "16x10");
    assert.equal(ratios({ width: 1440, height: 2560 }), "9x16");
    // A shape it doesn't name is landscape or portrait.
    assert.equal(ratios({ width: 2560, height: 1700 }), "3x2");
    assert.equal(ratios({ width: 3000, height: 1200 }), "landscape");
    // No monitor, no size.
    const none = new URL(moreWallpapers([])[1].url);
    assert.equal(none.searchParams.get("atleast"), null);
    assert.equal(none.searchParams.get("ratios"), null);
    assert.deepEqual(openCommand(UNSPLASH), ["xdg-open", UNSPLASH]);
});

test("the wallpaper grid shows each Plasma wallpaper once, at its largest, by name", () => {
    const text = [
        "1920\t1080\t/usr/share/wallpapers/Mountain/contents/images/1920x1080.png",
        "5120\t2880\t/usr/share/wallpapers/Mountain/contents/images/5120x2880.png",
        "3840\t2160\t/usr/share/wallpapers/Mountain/contents/images/3840x2160.png",
        "400\t250\t/usr/share/wallpapers/Mountain/contents/screenshot.png",
        "4096\t4096\t/usr/share/backgrounds/gnome/blobs-l.jxl",
        "0\t0\t/usr/share/backgrounds/gnome/adwaita.xml",
        "1920\t1080\t/usr/share/backgrounds/gnome/pills-l.svg",
        "0\t0\t/home/u/Pictures/wallpapers/Aurora.JPG",
        "1\t1\trelative.jpg",
        "/usr/share/backgrounds/no-size.jpg",
        "",
    ].join("\n");
    assert.deepEqual(galleryImages(text, "/home/u", "Ubuntu"), [
        { path: "/home/u/Pictures/wallpapers/Aurora.JPG", name: "Aurora", width: 0, height: 0, mode: "", collection: "Yours" },
        { path: "/usr/share/backgrounds/gnome/blobs-l.jxl", name: "blobs-l", width: 4096, height: 4096, mode: "", collection: "GNOME" },
        { path: "/usr/share/wallpapers/Mountain/contents/images/5120x2880.png", name: "Mountain", width: 5120, height: 2880, mode: "", collection: "Plasma" },
        { path: "/usr/share/backgrounds/gnome/pills-l.svg", name: "pills-l", width: 1920, height: 1080, mode: "", collection: "GNOME" },
    ]);
    assert.deepEqual(galleryImages(""), []);
    assert.deepEqual(galleryImages(undefined), []);
});

test("the wallpaper grid knows the light and the dark one of a pair", () => {
    const text = [
        "/usr/share/wallpapers/Mountain/contents/images/1920x1080.png",
        "/usr/share/wallpapers/Mountain/contents/images_dark/1920x1080.png",
        "/usr/share/wallpapers/Mountain/contents/images_dark/3840x2160.png",
        "/usr/share/backgrounds/gnome/blobs-l.svg",
        "/usr/share/backgrounds/gnome/blobs-d.svg",
        // No partner, so -l is just its name.
        "/usr/share/backgrounds/gnome/lonely-l.png",
        "/usr/share/backgrounds/Fuwafuwa_by_amaral-dark.png",
        "/usr/share/backgrounds/Fuwafuwa_by_amaral-light.png",
        "/usr/share/backgrounds/Numbat_wallpaper_dimmed_3480x2160.png",
        "/usr/share/backgrounds/Numbat_wallpaper_light_3480x2160.png",
        "/usr/share/backgrounds/f40/default/f40-01-day.jxl",
        "/usr/share/backgrounds/f40/default/f40-01-night.jxl",
        "/usr/share/backgrounds/Clouds.jpg",
        // Alone, a name that says dark, light, night or day is just its
        // name, so it shows for either.
        "/home/u/Pictures/wallpapers/city-night.jpg",
        "/home/u/Pictures/wallpapers/sea_light.png",
        "/home/u/Pictures/wallpapers/hills-day.jpg",
    ].map(p => `1\t1\t${p}`).join("\n");
    const modes = {};
    for (const i of galleryImages(text, "/home/u")) {
        modes[i.path] = i.mode;
    }
    assert.deepEqual(modes, {
        "/usr/share/wallpapers/Mountain/contents/images/1920x1080.png": "light",
        "/usr/share/wallpapers/Mountain/contents/images_dark/3840x2160.png": "dark",
        "/usr/share/backgrounds/gnome/blobs-l.svg": "light",
        "/usr/share/backgrounds/gnome/blobs-d.svg": "dark",
        "/usr/share/backgrounds/gnome/lonely-l.png": "",
        "/usr/share/backgrounds/Fuwafuwa_by_amaral-dark.png": "dark",
        "/usr/share/backgrounds/Fuwafuwa_by_amaral-light.png": "light",
        "/usr/share/backgrounds/Numbat_wallpaper_dimmed_3480x2160.png": "dark",
        "/usr/share/backgrounds/Numbat_wallpaper_light_3480x2160.png": "light",
        "/usr/share/backgrounds/f40/default/f40-01-day.jxl": "light",
        "/usr/share/backgrounds/f40/default/f40-01-night.jxl": "dark",
        "/usr/share/backgrounds/Clouds.jpg": "",
        "/home/u/Pictures/wallpapers/city-night.jpg": "",
        "/home/u/Pictures/wallpapers/sea_light.png": "",
        "/home/u/Pictures/wallpapers/hills-day.jpg": "",
    });
});

test("each wallpaper is in a collection, for the grid's chips", () => {
    assert.equal(galleryCollection("/home/u/Pictures/wallpapers/a/b.jpg", "/home/u", "Ubuntu"), "Yours");
    assert.equal(galleryCollection("/usr/share/wallpapers/Next/contents/images/1x1.png", "/home/u", "Ubuntu"), "Plasma");
    assert.equal(galleryCollection("/usr/share/backgrounds/gnome/blobs-l.svg", "/home/u", "Ubuntu"), "GNOME");
    assert.equal(galleryCollection("/usr/share/backgrounds/f40/default/f40-01-day.jxl", "/home/u"), "Fedora 40");
    assert.equal(galleryCollection("/usr/share/backgrounds/fedora-workstation/x.png", "/home/u"), "Fedora Workstation");
    // Ubuntu puts its own loose in backgrounds.
    assert.equal(galleryCollection("/usr/share/backgrounds/Clouds.jpg", "/home/u", "Ubuntu"), "Ubuntu");
    assert.equal(galleryCollection("/usr/share/backgrounds/Clouds.jpg", "/home/u", ""), "Other");
    assert.equal(galleryCollection("/srv/x.jpg", "/home/u", "Ubuntu"), "Other");
    // Not /home/uv, which only starts like home.
    assert.equal(galleryCollection("/home/uv/Pictures/wallpapers/x.jpg", "/home/u", "Ubuntu"), "Other");

    assert.equal(distroName('ID=ubuntu\nNAME="Ubuntu"\n'), "Ubuntu");
    assert.equal(distroName('NAME="Fedora Linux"\n'), "Fedora");
    assert.equal(distroName("NAME='Debian GNU/Linux'\n"), "Debian");
    assert.equal(distroName("NAME=Arch Linux\n"), "Arch");
    assert.equal(distroName("ID=x\n"), "");
    assert.equal(distroName(undefined), "");

    const pic = collection => ({ collection });
    assert.deepEqual(galleryCollections([pic("Yours"), pic("Ubuntu"), pic("GNOME"), pic("Ubuntu")]), ["GNOME", "Ubuntu", "Yours"]);
    // One collection needs no chips.
    assert.deepEqual(galleryCollections([pic("GNOME"), pic("GNOME")]), []);
    assert.deepEqual(galleryCollections([]), []);
});

test("the wallpaper grid filters by light or dark, opening on the setting's", () => {
    assert.deepEqual(GALLERY_MODES, ["light", "dark", "any"]);
    assert.equal(galleryModeFor("lightWallpaper"), "light");
    assert.equal(galleryModeFor("darkWallpaper"), "dark");
    assert.equal(galleryModeFor(""), "any");
    const pic = (name, mode, collection) => ({ name, mode, collection });
    const images = [pic("a", "light", "GNOME"), pic("b", "dark", "GNOME"), pic("c", "", "GNOME"), pic("d", "dark", "Yours")];
    const names = list => list.map(i => i.name);
    // One that isn't one of a pair shows for either.
    assert.deepEqual(names(galleryFiltered(images, "light", "")), ["a", "c"]);
    assert.deepEqual(names(galleryFiltered(images, "dark", "")), ["b", "c", "d"]);
    assert.deepEqual(names(galleryFiltered(images, "any", "")), ["a", "b", "c", "d"]);
    assert.deepEqual(names(galleryFiltered(images, "dark", "Yours")), ["d"]);
    assert.deepEqual(names(galleryFiltered(images, "any", "Plasma")), []);
});

test("a picture fits a monitor of its shape, near enough", () => {
    const wide = [{ name: "DP-1", width: 3440, height: 1440 }];
    assert.equal(fitsScreens({ width: 3440, height: 1440 }, wide), true);
    assert.equal(fitsScreens({ width: 6880, height: 2880 }, wide), true);
    // 2560×1080 trims under 1% of it.
    assert.equal(fitsScreens({ width: 2560, height: 1080 }, wide), true);
    assert.equal(fitsScreens({ width: 3840, height: 2160 }, wide), false);
    assert.equal(fitsScreens({ width: 1440, height: 3440 }, wide), false);
    // 16:10 on 16:9 trims 10%.
    assert.equal(fitsScreens({ width: 2560, height: 1600 }, [{ width: 1920, height: 1080 }]), false);
    assert.equal(fitsScreens({ width: 1366, height: 768 }, [{ width: 1920, height: 1080 }]), true);
    // Any one monitor will do.
    assert.equal(fitsScreens({ width: 3840, height: 2160 }, [...wide, { width: 1920, height: 1080 }]), true);
    // A size unknown fits none, as nothing fits no monitors.
    assert.equal(fitsScreens({ width: 0, height: 0 }, wide), false);
    assert.equal(fitsScreens({ width: 3440, height: 1440 }, []), false);
});

test("the wallpaper grid puts your monitors' shape first, in rows", () => {
    const screens = [{ name: "DP-1", width: 3440, height: 1440 }];
    const pic = (name, width, height) => ({ path: `/p/${name}.jpg`, name, width, height });
    const images = [pic("a", 3840, 2160), pic("b", 3440, 1440), pic("c", 0, 0), pic("d", 5120, 2160), pic("e", 1920, 1080), pic("f", 2560, 1080)];
    const rows = galleryRows(images, screens, 2);
    assert.deepEqual(rows.map(r => [r.section, r.heading, r.images.map(i => i.name)]), [
        ["fits", "Fits your screen", ["b", "d"]],
        ["fits", "", ["f"]],
        ["others", "Other shapes", ["a", "c"]],
        ["others", "", ["e"]],
    ]);
    const two = [...screens, { name: "eDP-1", width: 1920, height: 1080 }];
    assert.deepEqual(galleryRows(images, two, 4).map(r => [r.heading, r.images.map(i => i.name)]), [
        ["Fits one of your screens", ["a", "b", "d", "e"]],
        ["", ["f"]],
        ["Other shapes", ["c"]],
    ]);
    // With none that fit, it says so, as the grid would look unsorted.
    assert.deepEqual(galleryRows([pic("a", 3840, 2160), pic("c", 0, 0)], screens, 1).map(r => r.heading),
        ["None of these fit your 3440×1440 screen", ""]);
    assert.deepEqual(galleryRows([pic("a", 3840, 2160)], two, 4).map(r => r.heading), [""]);
    assert.equal(galleryRows([pic("e", 3000, 3000)], two, 4)[0].heading, "None of these fit your screens");
    // With no monitor known, or every picture fitting, there's no heading.
    assert.deepEqual(galleryRows([pic("a", 3840, 2160)], [], 4),
        [{ section: "others", heading: "", images: [pic("a", 3840, 2160)] }]);
    assert.deepEqual(galleryRows([pic("b", 3440, 1440)], screens, 4),
        [{ section: "fits", heading: "", images: [pic("b", 3440, 1440)] }]);
    assert.deepEqual(galleryRows([], screens, 4), []);
});

test("the chosen file is the setting, from ~/ when it's home's", () => {
    const home = "/home/u";
    assert.equal(pickedWallpaper("/home/u/Pictures/Day one.jpg\n", home), "~/Pictures/Day one.jpg");
    assert.equal(pickedWallpaper("/srv/night.png\n", home), "/srv/night.png");
    // Not /home/uv, which only starts like home.
    assert.equal(pickedWallpaper("/home/uv/a.png\n", home), "/home/uv/a.png");
    // Cancelled, the chooser printed nothing; anything else isn't a path.
    assert.equal(pickedWallpaper("", home), "");
    assert.equal(pickedWallpaper("a.png\n", home), "");
    assert.equal(pickedWallpaper("/a\n/b\n", home), "");
    // As the page's field would set it.
    for (const v of ["~/Pictures/Day one.jpg", "/srv/night.png"]) {
        assert.equal(withSetting("{}", "lightWallpaper", v).error, undefined, v);
    }
});

// The user's case: a 16:10 picture on a 21:9 monitor.
const PICTURE = { width: 3840, height: 2400 };
const ULTRAWIDE = { width: 3440, height: 1440 };
const close = (actual, expected, what) => assert.ok(Math.abs(actual - expected) < 1e-6, `${what}: ${actual}, expected ${expected}`);

test("a picture fills the monitor, centered, trimming what's left over", () => {
    const f = wallpaperFrame(PICTURE, ULTRAWIDE);
    close(f.scale, 3440 / 3840, "scale");
    assert.equal(Math.round(f.shown.width), 3440);
    assert.equal(Math.round(f.shown.height), 2150);
    close(f.frame.x, 0, "frame x");
    close(f.frame.width, 3840, "frame width");
    close(f.frame.height, 1440 * 3840 / 3440, "frame height");
    close(f.frame.y, (2400 - f.frame.height) / 2, "frame y");
    for (const k of ["x", "y", "width", "height"]) {
        close(f.visible[k], f.frame[k], `all of the frame is on the picture: ${k}`);
    }
    close(f.trimmed.top, f.trimmed.bottom, "the same off the top and the bottom");
    close(f.trimmed.top + f.trimmed.bottom, 1 - 1440 / 2150, "a third of the height");
    assert.equal(f.trimmed.left, 0);
    assert.equal(f.trimmed.right, 0);
});

test("a picture wider than the monitor is trimmed at the sides", () => {
    const f = wallpaperFrame({ width: 5120, height: 1440 }, { width: 2560, height: 1440 });
    close(f.scale, 1, "scale");
    close(f.trimmed.left, 0.25, "left");
    close(f.trimmed.right, 0.25, "right");
    assert.equal(f.trimmed.top, 0);
    assert.deepEqual(f.visible, { x: 1280, y: 0, width: 2560, height: 1440 });
});

test("a picture the monitor's shape is shown whole, scaled", () => {
    const f = wallpaperFrame({ width: 1920, height: 1200 }, { width: 2560, height: 1600 });
    close(f.scale, 4 / 3, "scale up");
    assert.deepEqual(f.trimmed, { top: 0, bottom: 0, left: 0, right: 0 });
});

test("there's no frame until both sizes are known", () => {
    assert.equal(wallpaperFrame({ width: 0, height: 0 }, ULTRAWIDE), null, "an image still loading");
    assert.equal(wallpaperFrame(PICTURE, { width: 0, height: 1440 }), null);
    assert.equal(wallpaperFrame(null, ULTRAWIDE), null);
});

test("the caption gives the numbers in the monitor's pixels", () => {
    assert.equal(framingCaption("DP-1", PICTURE, ULTRAWIDE), "DP-1, 3440×1440: scaled to 3440×2150, trims 33% of its height (355 px top, 355 px bottom)");
    assert.equal(framingCaption("HDMI-A-1", { width: 5120, height: 1440 }, { width: 2560, height: 1440 }), "HDMI-A-1, 2560×1440: scaled to 5120×1440, trims 50% of its width (1280 px left, 1280 px right)");
    assert.equal(framingCaption("eDP-1", { width: 1920, height: 1200 }, { width: 2560, height: 1600 }), "eDP-1, 2560×1600: shows all of it, scaled to 2560×1600");
    assert.equal(framingCaption("DP-1", { width: 0, height: 0 }, ULTRAWIDE), "", "none while it loads");
});

test("monitors alike share a preview, sized in pixels", () => {
    assert.deepEqual(previewScreens([
        { name: "DP-1", width: 3440, height: 1440, devicePixelRatio: 1 },
        { name: "eDP-1", width: 1280, height: 800, devicePixelRatio: 2 },
        { name: "DP-2", width: 3440, height: 1440, devicePixelRatio: 1 },
        { name: "gone", width: 0, height: 0, devicePixelRatio: 1 },
    ]), [
        { name: "DP-1, DP-2", width: 3440, height: 1440 },
        { name: "eDP-1", width: 2560, height: 1600 },
    ]);
});

test("the preview fits the picture in its box and dims what the monitor trims", () => {
    const l = previewLayout(PICTURE, ULTRAWIDE, "fill", 240, 160);
    assert.equal(l.width, 240);
    assert.equal(l.height, 150);
    assert.deepEqual(l.image, { x: 0, y: 0, width: 240, height: 150 });
    close(l.frame.height, 240 * 1440 / 3440, "the frame is the monitor's shape");
    close(l.frame.y, (150 - l.frame.height) / 2, "centered");
    assert.equal(l.dims.length, 2, "a band above the frame and one below");
    close(l.dims[0].height, l.frame.y, "above");
    close(l.dims[1].y, l.frame.y + l.frame.height, "below");
    const tall = previewLayout({ width: 1200, height: 1600 }, ULTRAWIDE, "fill", 240, 160);
    assert.equal(tall.height, 160, "a portrait picture is held to the box's height");
    assert.equal(tall.width, 120);
    assert.equal(previewLayout({ width: 0, height: 0 }, ULTRAWIDE, "fill", 240, 160), null);
});

test("the page previews what the shell draws now, or the other mode's candidates", () => {
    const s = { lightWallpaper: "~/day.jpg", darkWallpaper: "#1a1d2e" };
    assert.deepEqual(previewCandidates(s, false, false, "/home/user/day.jpg", "/home/user"), ["/home/user/day.jpg"]);
    assert.deepEqual(previewCandidates(s, false, false, "", "/home/user"), [], "none drawn, none shown");
    assert.deepEqual(previewCandidates(s, true, false, "/home/user/day.jpg", "/home/user"), [], "a color isn't previewed");
    assert.deepEqual(previewCandidates({}, true, false, "/home/user/day.jpg", "/home/user", "/srv/w.png"),
        ["/srv/w.png", "/home/user/.config/hypr/wallpaper-dark.jpg", "/home/user/.config/hypr/wallpaper.jpg"]);
    assert.deepEqual(previewCandidates(s, false, true, "", "/home/user"),
        ["/home/user/day.jpg", "/home/user/.config/hypr/wallpaper-light.jpg", "/home/user/.config/hypr/wallpaper.jpg"]);
});

const ONE = '"fill", "fill-top", "fill-bottom", "fit", "stretch"';

test("each mode's position is one of the positions, and wallpaperPosition is both modes'", () => {
    for (const key of ["lightWallpaperPosition", "darkWallpaperPosition", "wallpaperPosition"]) {
        for (const p of POSITIONS) {
            assert.deepEqual(parseAppearance(JSON.stringify({ [key]: p })), { settings: { [key]: p } });
        }
        for (const bad of ["center", "", "FILL", 1, null]) {
            assert.equal(parseAppearance(JSON.stringify({ [key]: bad })).error,
                `${key} must be one of ${ONE}`, `${key} ${JSON.stringify(bad)}`);
        }
    }
    const loaded = loadAppearance('{"darkWallpaperPosition": "middle"}', null);
    assert.deepEqual(loaded.errors, [`appearance.json: darkWallpaperPosition must be one of ${ONE}`], "fails at load, naming it");
    assert.equal(wallpaperPosition(DEFAULTS, false), "fill", "fill when unset, as before");
    assert.equal(wallpaperPosition(DEFAULTS, true), "fill");
    const own = loadAppearance('{"lightWallpaperPosition": "fit"}', '{"darkWallpaperPosition": "stretch"}').settings;
    assert.equal(wallpaperPosition(own, false), "fit", "light's own");
    assert.equal(wallpaperPosition(own, true), "stretch", "dark's own, from the local file");
    const both = loadAppearance('{"wallpaperPosition": "fill-top", "darkWallpaperPosition": "fit"}', null).settings;
    assert.equal(wallpaperPosition(both, false), "fill-top", "wallpaperPosition where a mode sets none");
    assert.equal(wallpaperPosition(both, true), "fit", "a mode's own wins over wallpaperPosition");
    assert.equal(wallpaperPosition(loadAppearance('{"lightWallpaperPosition": "fit"}', '{"lightWallpaperPosition": "fill-top"}').settings, false), "fill-top", "the local file's wins");
    assert.deepEqual(JSON.parse(withSetting(null, "darkWallpaperPosition", "fill-bottom").text), { darkWallpaperPosition: "fill-bottom" });
    assert.match(withSetting(null, "lightWallpaperPosition", "left").error, /lightWallpaperPosition must be one of/);
});

test("stretch fills the monitor with the whole picture, out of its shape", () => {
    const f = wallpaperFrame(PICTURE, ULTRAWIDE, "stretch");
    assert.deepEqual(f.frame, { x: 0, y: 0, width: 3840, height: 2400 }, "the monitor shows all of it");
    assert.deepEqual(f.visible, { x: 0, y: 0, width: 3840, height: 2400 });
    assert.deepEqual(f.trimmed, { top: 0, bottom: 0, left: 0, right: 0 });
    assert.deepEqual(f.bars, { x: 0, y: 0 }, "no bars");
    assert.deepEqual(f.shown, { width: 3440, height: 1440 }, "the monitor's size");
    close(f.scale, 3440 / 3840, "across");
    close(f.scaleY, 1440 / 2400, "and down, not the same");
    assert.equal(framingCaption("DP-1", PICTURE, ULTRAWIDE, "stretch"), "DP-1, 3440×1440: stretches all of it to 3440×1440, 49% wider");
    assert.equal(framingCaption("eDP-1", PICTURE, { width: 1440, height: 2560 }, "stretch"), "eDP-1, 1440×2560: stretches all of it to 1440×2560, 184% taller");
    assert.equal(framingCaption("eDP-1", { width: 1920, height: 1200 }, { width: 2560, height: 1600 }, "stretch"), "eDP-1, 2560×1600: shows all of it, scaled to 2560×1600", "the monitor's shape: just scaled");
    for (const p of ["fill", "fill-top", "fill-bottom", "fit"]) {
        const g = wallpaperFrame(PICTURE, ULTRAWIDE, p);
        assert.equal(g.scaleY, g.scale, `${p} keeps the picture's shape`);
    }
});

test("the preview of a stretch draws the whole picture in the monitor's shape", () => {
    const l = previewLayout(PICTURE, ULTRAWIDE, "stretch", 240, 160);
    close(l.width, 240, "the monitor is the wider");
    close(l.height, 240 * 1440 / 3440, "the monitor's shape, not the picture's");
    assert.deepEqual(l.image, { x: 0, y: 0, width: l.width, height: l.height }, "the picture fills it");
    assert.deepEqual(l.frame, l.image);
    assert.deepEqual(l.dims, [], "nothing trimmed, so nothing dimmed");
});

test("fill-top keeps the top of a tall picture and trims the bottom", () => {
    const f = wallpaperFrame(PICTURE, ULTRAWIDE, "fill-top");
    assert.equal(f.frame.y, 0);
    assert.equal(f.trimmed.top, 0);
    close(f.trimmed.bottom, 1 - 1440 / 2150, "a third off the bottom");
    assert.equal(framingCaption("DP-1", PICTURE, ULTRAWIDE, "fill-top"), "DP-1, 3440×1440: scaled to 3440×2150, trims 33% of its height (710 px bottom)");
});

test("fill-bottom keeps the bottom and trims the top", () => {
    const f = wallpaperFrame(PICTURE, ULTRAWIDE, "fill-bottom");
    close(f.frame.y + f.frame.height, 2400, "down to the bottom edge");
    assert.equal(f.trimmed.bottom, 0);
    close(f.trimmed.top, 1 - 1440 / 2150, "a third off the top");
    assert.equal(framingCaption("DP-1", PICTURE, ULTRAWIDE, "fill-bottom"), "DP-1, 3440×1440: scaled to 3440×2150, trims 33% of its height (710 px top)");
});

test("a picture wider than the monitor stays centered whichever edge a fill keeps", () => {
    const wide = { width: 5120, height: 1440 };
    const screen = { width: 2560, height: 1440 };
    for (const p of ["fill", "fill-top", "fill-bottom"]) {
        const f = wallpaperFrame(wide, screen, p);
        assert.deepEqual(f.visible, { x: 1280, y: 0, width: 2560, height: 1440 }, p);
        assert.deepEqual(f.trimmed, { top: 0, bottom: 0, left: 0.25, right: 0.25 }, p);
    }
});

test("fit shows the whole picture, with bars where it doesn't reach", () => {
    const f = wallpaperFrame(PICTURE, ULTRAWIDE, "fit");
    close(f.scale, 0.6, "scaled to the height");
    assert.deepEqual(f.visible, { x: 0, y: 0, width: 3840, height: 2400 });
    assert.deepEqual(f.trimmed, { top: 0, bottom: 0, left: 0, right: 0 });
    close(f.bars.x, (3440 - 2304) / 2, "bars at the sides");
    assert.equal(f.bars.y, 0);
    assert.equal(framingCaption("DP-1", PICTURE, ULTRAWIDE, "fit"), "DP-1, 3440×1440: shows all of it at 2304×1440, with 568 px bars left and right");
    const wide = wallpaperFrame({ width: 5120, height: 1440 }, { width: 2560, height: 1440 }, "fit");
    close(wide.bars.y, 360, "a wide picture's bars are above and below");
    assert.equal(framingCaption("DP-1", { width: 5120, height: 1440 }, { width: 2560, height: 1440 }, "fit"), "DP-1, 2560×1440: shows all of it at 2560×720, with 360 px bars top and bottom");
    assert.equal(wallpaperFrame({ width: 1920, height: 1200 }, { width: 2560, height: 1600 }, "fit").bars.x, 0, "none for a picture the monitor's shape");
    assert.equal(wallpaperFrame(PICTURE, ULTRAWIDE, "fill").bars.x, 0, "none in a fill");
    assert.throws(() => wallpaperFrame(PICTURE, ULTRAWIDE, "middle"), /unknown wallpaper position: middle/);
});

test("the preview of a fit draws the monitor whole, the picture inside it", () => {
    const l = previewLayout(PICTURE, ULTRAWIDE, "fit", 240, 160);
    assert.deepEqual(l.frame, { x: 0, y: 0, width: l.width, height: l.height });
    close(l.width, 240, "the monitor is the wider");
    close(l.height, 240 * 1440 / 3440, "the monitor's shape");
    close(l.image.height, l.height, "the picture's full height");
    close(l.image.x, (240 - l.image.width) / 2, "centered");
    assert.deepEqual(l.dims, [], "nothing trimmed, so nothing dimmed");
    const top = previewLayout(PICTURE, ULTRAWIDE, "fill-top", 240, 160);
    assert.equal(top.frame.y, 0);
    assert.equal(top.dims.length, 1, "only below");
});

test("the shell and the lock place a picture as wallpaperFrame says", () => {
    assert.deepEqual(wallpaperPlacement("fill"), { fit: false, stretch: false, vertical: "center" });
    assert.deepEqual(wallpaperPlacement("fill-top"), { fit: false, stretch: false, vertical: "top" });
    assert.deepEqual(wallpaperPlacement("fill-bottom"), { fit: false, stretch: false, vertical: "bottom" });
    assert.deepEqual(wallpaperPlacement("fit"), { fit: true, stretch: false, vertical: "center" });
    assert.deepEqual(wallpaperPlacement("stretch"), { fit: false, stretch: true, vertical: "center" });
});

test("the page's ‹ and › step through each mode's positions, stopping at either end", () => {
    assert.deepEqual(POSITION_CHOICES.map(c => c.position), POSITIONS);
    assert.equal(POSITION_CHOICES[POSITION_CHOICES.length - 1].label, "Stretch to fill");
    assert.equal(positionAt({}, false), 0);
    assert.equal(positionAt({ lightWallpaperPosition: "fit" }, false), 3);
    assert.equal(positionAt({ lightWallpaperPosition: "fit" }, true), 0, "dark's is its own");
    assert.equal(positionAt({ wallpaperPosition: "stretch" }, true), 4, "wallpaperPosition where a mode sets none");
    assert.equal(steppedPositionAt(0, -1), 0);
    assert.equal(steppedPositionAt(0, 1), 1);
    assert.equal(steppedPositionAt(4, 1), 4);
});

test("tidewm's file has the dim strength as its dim_inactive, and only what's set", () => {
    const text = appearanceConf({ dimStrength: 0.12, mode: "dark" });
    assert.ok(text.startsWith("# Written by tide from appearance.json"), text);
    assert.ok(text.endsWith("\ndim_inactive 0.12\n"), text);
    assert.ok(appearanceConf({ mode: "dark" }).split("\n").every(line => line === "" || line.startsWith("#")));
    assert.ok(appearanceConf({ dimStrength: 0 }).includes("\ndim_inactive 0\n"), "none at all");
});

// The greeter's copy of the look (SPEC.md §11).
test("the look's folder is the user's under the root, and none for a name that couldn't be one", () => {
    assert.equal(lookDir("", "mikel"), `${LOOK_ROOT}/mikel`);
    assert.equal(LOOK_ROOT, "/var/lib/tide/look");
    assert.equal(lookDir("/tmp/look", "mikel"), "/tmp/look/mikel");
    for (const bad of ["", ".", "..", "a/b", undefined]) {
        assert.equal(lookDir("", bad), "");
    }
});

function runLook(dir, light, dark) {
    const [cmd, ...args] = lookCommand(dir, light, dark);
    return spawnSync(cmd, args, { encoding: "utf8" });
}

test("the look's copies are each mode's first readable picture, and none goes when there's none", () => {
    const tmp = mkdtempSync(join(tmpdir(), "tide-look-"));
    try {
        const dir = join(tmp, "look");
        mkdirSync(dir);
        writeFileSync(join(tmp, "day.jpg"), "day");
        writeFileSync(join(tmp, "night.png"), "night");
        mkdirSync(join(tmp, "folder.jpg"));
        let r = runLook(dir, [join(tmp, "missing.jpg"), join(tmp, "folder.jpg"), join(tmp, "day.jpg")], [join(tmp, "night.png")]);
        assert.equal(r.status, 0, r.stderr);
        assert.deepEqual(lookCopied(r.stdout), { light: true, dark: true });
        assert.equal(readFileSync(join(dir, "light"), "utf8"), "day");
        assert.equal(readFileSync(join(dir, "dark"), "utf8"), "night");
        // Readable by the greeter's user.
        assert.equal(statSync(join(dir, "dark")).mode & 0o777, 0o644);
        // A color for dark, now: nothing to copy, and the old copy goes.
        r = runLook(dir, [join(tmp, "day.jpg")], ["#102030"]);
        assert.equal(r.status, 0, r.stderr);
        assert.deepEqual(lookCopied(r.stdout), { light: true, dark: false });
        assert.equal(spawnSync("test", ["-e", join(dir, "dark")]).status, 1);
        assert.deepEqual(lookCommand(dir, ["#abcdef"], []).slice(4), [dir, "--"]);
    } finally {
        rmSync(tmp, { recursive: true });
    }
});

test("with no look folder, setup hasn't made one, which the script says by its status", () => {
    const tmp = mkdtempSync(join(tmpdir(), "tide-look-"));
    try {
        const r = runLook(join(tmp, "none"), [], []);
        assert.equal(r.status, 2);
        assert.equal(r.stdout, "");
    } finally {
        rmSync(tmp, { recursive: true });
    }
});

test("the look file has the schedule's settings and each mode's wallpaper, and reads back", () => {
    const settings = Object.assign({}, DEFAULTS, {
        mode: "sun", latitude: 40.7, longitude: -74, dimStrength: 0.2,
        darkWallpaper: "#102030", lightWallpaper: "~/day.jpg", lightWallpaperPosition: "fit",
    });
    const text = lookJson(settings, ["/home/u/day.jpg"], ["#102030"], { light: true, dark: false });
    const json = JSON.parse(text);
    // Only what the greeter needs: no dim, no paths into the home.
    assert.deepEqual(Object.keys(json).sort(), ["dark", "darkWallpaper", "latitude", "light", "lightWallpaper", "longitude", "mode"]);
    assert.deepEqual(json.lightWallpaper, { color: "", image: true, position: "fit" });
    assert.deepEqual(json.darkWallpaper, { color: "#102030", image: false, position: "fill" });
    const read = parseLook(text);
    assert.equal(read.error, undefined);
    assert.equal(read.look.settings.mode, "sun");
    assert.deepEqual(read.look.darkWallpaper, { color: "#102030", image: false, position: "fill" });
    // No picture found for light: the greeter draws its own background.
    assert.equal(JSON.parse(lookJson(settings, ["/home/u/day.jpg"], ["#102030"], { light: false, dark: false })).lightWallpaper.image, false);
});

test("a look file that's wrong is an error, not a look", () => {
    assert.match(parseLook("{").error, /./);
    assert.match(parseLook("[]").error, /object/);
    assert.match(parseLook('{"mode": "sun"}').error, /latitude/);
    assert.match(parseLook('{"lightWallpaper": {"color": "red"}}').error, /lightWallpaper.color/);
    assert.match(parseLook('{"darkWallpaper": {"position": "tile"}}').error, /darkWallpaper.position/);
    // An empty one is the default schedule and no wallpaper.
    assert.deepEqual(parseLook("{}").look.lightWallpaper, { color: "", image: false, position: "fill" });
});

test("the greeter shows the mode the user's schedule gives now, with that mode's wallpaper", () => {
    const look = parseLook(lookJson(DEFAULTS, ["/h/day.jpg"], ["#102030"], { light: true, dark: false })).look;
    const noon = lookAt(look, at(2026, 6, 1, 12), "/var/lib/tide/look/u");
    assert.equal(noon.dark, false);
    assert.equal(noon.path, "/var/lib/tide/look/u/light");
    assert.equal(noon.next, at(2026, 6, 1, 19));
    const night = lookAt(look, at(2026, 6, 1, 22), "/var/lib/tide/look/u");
    assert.equal(night.dark, true);
    assert.equal(night.path, "");
    assert.equal(night.color, "#102030");
});

test("the lock's record says light or dark, which the lock's face follows", () => {
    assert.equal(wallpaperRecord("/srv/day.jpg", "fit", false), "/srv/day.jpg\nfit\nlight\n");
    assert.deepEqual(recordedWallpaper(wallpaperRecord("/srv/day.jpg", "fit", false)), { path: "/srv/day.jpg", color: "", position: "fit", dark: false });
    assert.deepEqual(recordedWallpaper(wallpaperRecord("", "fill", true)), { path: "", color: "", position: "fill", dark: true });
    // An older record says neither, and the lock stays dark.
    assert.equal("dark" in recordedWallpaper("/srv/day.jpg\nfill\n"), false);
    assert.match(recordedWallpaper("/srv/day.jpg\nfill\ndusk\n").error, /dark or light/);
});

test("a color wallpaper is lightened behind the light face, as it's darkened behind the dark one", () => {
    assert.equal(lockColor("#808080", true), "#404040");
    assert.equal(lockColor("#808080", false), "#c0c0c0");
    assert.equal(lockColor("#f0f0f0", false), "#ffffff", "held at white");
});

test("look.json is written readable by all, whatever the umask, and replaced whole", () => {
    const tmp = mkdtempSync(join(tmpdir(), "tide-look-"));
    try {
        const [cmd, ...args] = lookWriteCommand(tmp, '{"mode": "schedule"}\n');
        const r = spawnSync("sh", ["-c", 'umask 077; exec "$@"', "sh", cmd, ...args], { encoding: "utf8" });
        assert.equal(r.status, 0, r.stderr);
        assert.equal(readFileSync(join(tmp, "look.json"), "utf8"), '{"mode": "schedule"}\n');
        assert.equal(statSync(join(tmp, "look.json")).mode & 0o777, 0o644);
        assert.equal(spawnSync("test", ["-e", join(tmp, ".look.json.tmp")]).status, 1);
        // A folder it can't write is a failure.
        const [c2, ...a2] = lookWriteCommand(join(tmp, "none"), "{}");
        assert.notEqual(spawnSync(c2, a2).status, 0);
    } finally {
        rmSync(tmp, { recursive: true });
    }
});
