// Tests for workspacenames.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    MAX_NAME, DEFAULT_STANDING, DEFAULT_SETTINGS, checkName, sameName, matchName, homeName,
    parseWorkspaceSettings, loadWorkspaceSettings, inAppPatterns, workspacesLua, luaString,
} from "./workspacenames.mjs";

test("a name is one line, trimmed, at most 32 characters", () => {
    assert.equal(MAX_NAME, 32);
    assert.deepEqual(checkName("  PR-12 login "), { name: "PR-12 login" });
    assert.deepEqual(checkName("x".repeat(32)), { name: "x".repeat(32) });
    assert.match(checkName("x".repeat(33)).error, /at most 32/);
    // Characters, not UTF-16 units.
    assert.deepEqual(checkName("🙂".repeat(32)), { name: "🙂".repeat(32) });
    assert.match(checkName("   ").error, /needs a name/);
    assert.match(checkName(undefined).error, /needs a name/);
    assert.match(checkName("a\nb").error, /one line/);
});

test("a typed name matches an existing one without case, keeping its case", () => {
    assert.equal(sameName("PR-12", "pr-12"), true);
    assert.equal(sameName("PR-12", "PR 12"), false);
    assert.equal(matchName(["in", "Docs"], "docs"), "Docs");
    assert.equal(matchName(["in", "Docs"], "doc"), null);
});

test("with no files, the standing workspaces are in, re, oc and me, and in is home", () => {
    assert.deepEqual(DEFAULT_STANDING, ["in", "re", "oc", "me"]);
    const { settings, errors } = loadWorkspaceSettings(null, null);
    assert.deepEqual(errors, []);
    assert.deepEqual(settings, DEFAULT_SETTINGS);
    assert.equal(homeName(settings), "in");
});

test("home is the first standing workspace, whatever it's called", () => {
    const { settings } = loadWorkspaceSettings('{"standing": ["home", "in"]}', null);
    assert.equal(homeName(settings), "home");
    assert.deepEqual(settings.standing, ["home", "in"]);
});

test("each setting is a list, so the local file's replaces the shared one's whole", () => {
    const { settings, errors } = loadWorkspaceSettings(
        '{"standing": ["in", "re"], "inApps": ["thunderbird", "chat.google.com"]}',
        '{"inApps": ["spotify"]}');
    assert.deepEqual(errors, []);
    assert.deepEqual(settings.standing, ["in", "re"]);
    assert.deepEqual(settings.inApps, ["spotify"]);
    assert.deepEqual(settings.namePatterns, []);
});

test("a bad setting is an error at load naming it, and the last good settings stay", () => {
    const good = { standing: ["a"], inApps: [], namePatterns: [] };
    const cases = [
        ['{"standing": []}', /workspaces.json: standing must name at least one/],
        ['{"standing": "in"}', /standing must be a list/],
        ['{"standing": ["in", 3]}', /standing must list text, not 3 at 2/],
        ['{"standing": ["in", "IN"]}', /standing names "IN" twice/],
        ['{"standing": [" in"]}', /standing: " in" has space around it/],
        [`{"standing": ["${"x".repeat(33)}"]}`, /standing: "x+": a workspace's name is at most 32/],
        ['{"inApps": [""]}', /inApps must list text/],
        ['{"inapps": []}', /inapps isn't a setting/],
        ['[]', /expected an object/],
        ['{"standing": ["in"', /line 1/],
    ];
    for (const [text, want] of cases) {
        const { settings, errors } = loadWorkspaceSettings(text, null, good);
        assert.equal(errors.length, 1, text);
        assert.match(errors[0], want, text);
        assert.equal(settings, good);
    }
    const local = loadWorkspaceSettings(null, '{"standing": []}', good);
    assert.match(local.errors[0], /^workspaces.local.json: standing/);
    assert.match(parseWorkspaceSettings('{"standing": []}').error, /standing/);
});

test("an in app matches its class without case, and a bare name a qualified class", () => {
    const [bare, qualified] = inAppPatterns(["Thunderbird", "org.gnome.Calendar.desktop"]);
    const re = (p) => new RegExp(`^(?:${p.replace("(?i)", "")})$`, "i");
    assert.ok(re(bare).test("org.mozilla.Thunderbird"));
    assert.ok(re(bare).test("thunderbird"));
    assert.ok(!re(bare).test("thunderbird-beta"));
    assert.ok(re(qualified).test("org.gnome.Calendar"));
    assert.ok(!re(qualified).test("org-gnome-calendar"));
    assert.ok(bare.startsWith("(?i)"));
});

test("an in app that looks like a site takes that site's --app windows, subdomains included", () => {
    const patterns = inAppPatterns(["google.com"]);
    assert.equal(patterns.length, 2);
    const site = new RegExp(`^(?:${patterns[1].replace("(?i)", "")})$`, "i");
    assert.ok(site.test("chrome-mail.google.com__-Default"));
    assert.ok(site.test("chrome-google.com__mail_-Profile_1"));
    assert.ok(site.test("chromium-calendar.google.com__-Default"));
    assert.ok(!site.test("chrome-notgoogle.com__-Default"));
    assert.ok(!site.test("chrome-google.com.evil.example__-Default"));
    assert.ok(!site.test("firefox"));
});

test("tide-workspaces.lua names home and the classes sent there", () => {
    const lua = workspacesLua({ standing: ["in", "re"], inApps: ["spotify"], namePatterns: [] });
    assert.match(lua, /home = "in",/);
    assert.match(lua, /in_apps = \{\n {8}"\(\?i\)\(\.\*\\\\\.\)\?spotify",\n {4}\},/);
    assert.match(workspacesLua(DEFAULT_SETTINGS), /in_apps = \{\},/);
    assert.equal(luaString('a"b\\c\n'), '"a\\"b\\\\c\\010"');
});
