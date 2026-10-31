// Tests for workspacenames.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    MAX_NAME, DEFAULT_STANDING, DEFAULT_SETTINGS, checkName, sameName, matchName, homeName,
    parseWorkspaceSettings, loadWorkspaceSettings, inAppPatterns, workspacesLua, luaString,
    checkPatterns, cleanTitle, shortName, isHomeApp, promptWanted, clientAt, normalizeAppId, checkMuteEntry,
    promptRows, promptChoice, NO_PROMPTS, promptQueued, promptDone, promptWindowGone,
    NO_WINDOWS, windowOpened, windowFocused, windowClosed, windowAnswered, checkMuted, withMuted,
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

test("a name can't hold quotes, backslashes or control characters", () => {
    for (const bad of ['team "x"', "it's", "a`b", "a\\b", "a\tb", "a\u007fb"]) {
        assert.match(checkName(bad).error, /can't have quotes, backslashes or control characters/, bad);
    }
    assert.deepEqual(checkName("PR-12, login (2) — draft"), { name: "PR-12, login (2) — draft" });
    // A configured one is an error at load naming it.
    const { errors } = loadWorkspaceSettings('{"standing": ["in", "team \\"x\\""]}', null);
    assert.match(errors[0], /standing: "team \\"x\\"": a workspace's name can't have quotes/);
    // A short name drops them, so the prompt never starts with one.
    assert.equal(cleanTitle('Say "hi" to `it` \\ now - Google Chrome', "Google Chrome"), "Say hi to it now");
    assert.equal(shortName('Re: "PR-12"', "", checkPatterns(['"(PR-[0-9]+)"']).patterns), "PR-12");
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
    assert.match(lua, /standing = \{\n {8}"in",\n {8}"re",\n {4}\},/);
    assert.ok(lua.includes('in_apps = {\n        "(?i)(.*\\\\.)?spotify(\\\\.desktop)?",\n    },'), lua);
    assert.match(workspacesLua(DEFAULT_SETTINGS), /in_apps = \{\},/);
    assert.equal(luaString('a"b\\c\n'), '"a\\"b\\\\c\\010"');
});

const compiled = (list) => checkPatterns(list).patterns;

test("the first title pattern that matches gives its first group as the name", () => {
    const patterns = compiled(["\\b([A-Z]+-[0-9]+)\\b", "^Review: (.*)$"]);
    assert.equal(shortName("ABC-123: Fix login - Tracker - Google Chrome", "Google Chrome", patterns), "ABC-123");
    assert.equal(shortName("Review: the login page", "Google Chrome", patterns), "the login page");
});

test("a pattern whose group matched empty is passed over", () => {
    const patterns = compiled(["^x(y*)", "(login)"]);
    assert.equal(shortName("x then login", "", patterns), "login");
});

test("with no match the name is the title cleaned up", () => {
    assert.equal(shortName("Inbox  (3) - Mozilla Firefox", "Mozilla Firefox", []), "Inbox (3)");
    assert.equal(cleanTitle("Docs — Google Chrome", "Google Chrome"), "Docs");
    // Only the app's own name goes, and only at the end.
    assert.equal(cleanTitle("Google Chrome - notes", "Google Chrome"), "Google Chrome - notes");
    assert.equal(cleanTitle("Fix the login page for everyone who uses it", ""), "Fix the login page for everyone");
    assert.equal(cleanTitle("x".repeat(40), ""), "x".repeat(32));
    assert.equal(cleanTitle("", "kitty"), "");
});

test("a pattern that can't be used is an error at load naming it", () => {
    const cases = [
        ["(unclosed", /namePatterns: "\(unclosed" doesn't compile/],
        ["[A-Z]+-[0-9]+", /namePatterns: "\[A-Z\]\+-\[0-9\]\+" has no capture group/],
        ["(?<=x)(y)", /uses a lookbehind/],
        ["(?<id>x)", /uses a named group/],
        ["(\\p{L}+)", /uses a Unicode property escape/],
        // Compiles only with the `|` the group count appends.
        ["(.*)|\\", /namePatterns: "\(\.\*\)\|\\\\" doesn't compile/],
    ];
    for (const [p, want] of cases) {
        assert.match(checkPatterns([p]).error, want, p);
        const { errors } = loadWorkspaceSettings(JSON.stringify({ namePatterns: [p] }), null);
        assert.match(errors[0], /^workspaces.json: namePatterns: /, p);
    }
    assert.equal(checkPatterns(["(?:a)(b)"]).patterns.length, 1);
});

test("home's apps are told apart by class, as conf's rules send them", () => {
    const apps = ["thunderbird", "chat.google.com"];
    assert.equal(isHomeApp("org.mozilla.Thunderbird", apps), true);
    assert.equal(isHomeApp("chrome-chat.google.com__-Default", apps), true);
    assert.equal(isHomeApp("kitty", apps), false);
    assert.equal(isHomeApp("", apps), false);
});

test("the window judged is the one at its address, wherever focus is now", () => {
    const clients = [{ address: "0x55aa01", class: "kitty" }, { address: "0x55aa03", class: "firefox" }];
    assert.equal(clientAt(clients, "55aa03").class, "firefox");
    assert.equal(clientAt(clients, "55aa09"), null);
    assert.equal(clientAt(null, "55aa03"), null);
});

test("a window first focused on home asks for a name, unless it shouldn't", () => {
    const client = (extra) => Object.assign({ address: "0x1", class: "kitty", title: "~", floating: false, workspace: { id: -1338, name: "in" } }, extra);
    assert.equal(promptWanted(client({}), "in", []), true);
    assert.equal(promptWanted(client({ workspace: { id: -1339, name: "docs" } }), "in", []), false, "elsewhere");
    assert.equal(promptWanted(client({ floating: true }), "in", []), false, "a dialog");
    assert.equal(promptWanted(client({ class: "", title: "" }), "in", []), false, "a status popup");
    assert.equal(promptWanted(client({ class: "chrome-chat.google.com__-Default" }), "in", ["chat.google.com"]), false, "a home app");
    assert.equal(promptWanted(null, "in", []), false);
});

const names = ["in", "re", "oc", "me", "PR-12", "docs"];

test("the prompt offers the typed name first, then the matching workspaces", () => {
    const rows = promptRows({ names, typed: "do", home: "in" });
    assert.deepEqual(rows.map((r) => [r.name, r.isNew]), [["do", true], ["docs", false]]);
    // An empty prompt lists every workspace but home.
    assert.deepEqual(promptRows({ names, typed: "", home: "in" }).map((r) => r.name), ["re", "oc", "me", "PR-12", "docs"]);
});

test("a typed name that's a workspace's, in any case, offers that one first", () => {
    const rows = promptRows({ names, typed: "RE", home: "in" });
    assert.equal(rows[0].name, "re");
    assert.equal(rows[0].isNew, false);
    assert.ok(!rows.some((r) => r.isNew));
    assert.deepEqual(promptChoice({ rows, selected: 0, typed: "RE", home: "in" }), { name: "re" });
});

test("home isn't offered for another app's window, and typing its name is refused", () => {
    const rows = promptRows({ names, typed: "IN", home: "in" });
    assert.ok(!rows.some((r) => r.name.toLowerCase() === "in"));
    assert.match(promptChoice({ rows: [], selected: 0, typed: "IN", home: "in" }).error, /in is home/);
    // A home app's window may go back home.
    assert.equal(promptRows({ names, typed: "in", home: "in", allowHome: true })[0].name, "in");
});

test("Enter takes the selected row, and says why when there's none", () => {
    const rows = promptRows({ names, typed: "docs", home: "in" });
    assert.deepEqual(promptChoice({ rows, selected: 0, typed: "docs", home: "in" }), { name: "docs" });
    assert.match(promptChoice({ rows: [], selected: -1, typed: "  ", home: "in" }).error, /needs a name/);
    assert.match(promptChoice({ rows: [], selected: -1, typed: "x".repeat(33), home: "in" }).error, /at most 32/);
});

test("prompts wait their turn, and one coming doesn't answer the one shown", () => {
    let s = promptQueued(NO_PROMPTS, { kind: "window", address: "a" });
    s = promptQueued(s, { kind: "launch", argv: ["kitty"] });
    s = promptQueued(s, { kind: "window", address: "a" });
    assert.deepEqual(s.queue.map((r) => [r.kind, r.id]), [["window", 1], ["launch", 2]]);
    s = promptDone(s, 1);
    assert.deepEqual(s.queue.map((r) => r.kind), ["launch"]);
    s = promptQueued(s, { kind: "window", address: "b" });
    s = promptWindowGone(s, "b");
    assert.deepEqual(s.queue.map((r) => r.id), [2]);
    // Answering one already gone changes nothing.
    assert.deepEqual(promptDone(s, 9), s);
});

test("a window's first focus asks about it once", () => {
    let s = windowOpened(NO_WINDOWS, "a");
    const first = windowFocused(s, "a");
    assert.equal(first.lookup, true);
    s = first.state;
    assert.equal(windowFocused(s, "a").lookup, false, "not on a second focus");
    assert.equal(windowFocused(NO_WINDOWS, "b").lookup, false, "nor for a window from before the shell");
    const answered = windowAnswered(s, "a");
    assert.equal(answered.live, true);
    assert.deepEqual(answered.state, NO_WINDOWS);
});

test("a lookup that answers after its window closed asks nothing", () => {
    // Hyprland's client list was taken while the window was open, and the
    // answer comes after closewindow.
    let s = windowFocused(windowOpened(NO_WINDOWS, "a"), "a").state;
    let prompts = NO_PROMPTS;
    s = windowClosed(s, "a");
    prompts = promptWindowGone(prompts, "a");
    const answered = windowAnswered(s, "a");
    assert.equal(answered.live, false, "the window is gone");
    const snapshot = [{ address: "0xa", class: "kitty", title: "~", floating: false, workspace: { name: "in" } }];
    const client = answered.live ? clientAt(snapshot, "a") : null;
    assert.equal(promptWanted(client, "in", []), false);
    assert.deepEqual(prompts.queue, [], "no prompt for a window that's gone");
});

test("a window closed before it was focused is forgotten", () => {
    const s = windowClosed(windowOpened(NO_WINDOWS, "a"), "a");
    assert.equal(windowFocused(s, "a").lookup, false);
});

test("muted is empty by default", () => {
    assert.deepEqual(loadWorkspaceSettings(null, null).settings.muted, []);
});

test("a bad muted entry is an error naming it, and the rest still apply", () => {
    const { settings, errors, warnings } = loadWorkspaceSettings(
        JSON.stringify({ standing: ["in", "re"], muted: ["slack", "", "site:", 7, "site:chat.google.com", "bad\u0007bell"] }), null);
    assert.deepEqual(errors, [], "the file isn't refused");
    assert.deepEqual(settings.standing, ["in", "re"]);
    assert.deepEqual(settings.muted, ["slack", "site:chat.google.com"]);
    assert.deepEqual(warnings, [
        'workspaces.json: muted: "" at 2 isn\'t an app or a site',
        'workspaces.json: muted: "site:" at 3 names no host',
        "workspaces.json: muted: 7 at 4 isn't an app or a site",
        'workspaces.json: muted: "bad\\u0007bell" at 6 isn\'t an app ID',
    ]);
    assert.deepEqual(checkMuted([" slack "]).entries, ["slack"], "space around an entry is trimmed");
});

test("muted that isn't a list is the file's error", () => {
    const { errors } = loadWorkspaceSettings('{"muted": "slack"}', null);
    assert.match(errors[0], /workspaces.json: muted must be a list/);
});

test("the local file's muted replaces the shared one's whole", () => {
    const { settings } = loadWorkspaceSettings('{"muted": ["slack"]}', '{"muted": ["site:chat.google.com"]}');
    assert.deepEqual(settings.muted, ["site:chat.google.com"]);
});

test("muting writes workspaces.local.json, keeping its other settings", () => {
    const r = withMuted('{"standing": ["in"]}', ["slack"]);
    assert.deepEqual(JSON.parse(r.text), { standing: ["in"], muted: ["slack"] });
    assert.deepEqual(JSON.parse(withMuted(null, ["slack"]).text), { muted: ["slack"] }, "a file made where there was none");
    assert.match(withMuted("{oops", ["slack"]).error, /workspaces.local.json/, "a broken hand edit isn't overwritten");
    assert.match(withMuted("[]", ["slack"]).error, /expected an object/);
});

test("one normalization for app IDs: trimmed, lowercase, no .desktop", () => {
    assert.equal(normalizeAppId(" Org.Telegram.desktop "), "org.telegram");
    assert.equal(normalizeAppId("Example App"), "example app");
    assert.equal(normalizeAppId(undefined), "");
});

test("a home app whose own ID ends in .desktop matches its class, in the shell and in Hyprland's rule", () => {
    assert.equal(isHomeApp("org.telegram.desktop", ["org.telegram.desktop"]), true);
    assert.equal(isHomeApp("org.telegram.desktop", ["org.telegram"]), true);
    assert.equal(isHomeApp("org.telegram", ["org.telegram.desktop"]), true);
    const [rule] = inAppPatterns(["org.telegram.desktop"]);
    const re = new RegExp(`^(?:${rule.replace("(?i)", "")})$`, "i");
    assert.ok(re.test("org.telegram.desktop"), "the raw class, which a rule can't normalize");
    assert.ok(re.test("org.telegram"));
});

test("a muted entry that's only .desktop is refused, since it would match nothing", () => {
    assert.match(checkMuteEntry(".desktop").error, /isn't an app ID/);
    assert.deepEqual(checkMuteEntry(" org.telegram.desktop "), { entry: "org.telegram.desktop" });
});
