// Tests for workspacenames.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    MAX_NAME, DEFAULT_STANDING, DEFAULT_SETTINGS, checkName, sameName, matchName, homeName,
    parseWorkspaceSettings, loadWorkspaceSettings, inAppPatterns, workspacesLua, luaString,
    checkPatterns, cleanTitle, firstWord, shortName, isHomeApp, homeAppEntry, homeAppPrograms, homeAppLaunches, NO_UNCOVERED, uncoveredOpened, uncoveredClosed, homeSweep, promptWanted, clientAt, normalizeAppId, checkMuteEntry,
    promptRows, promptChoice, NO_PROMPTS, promptQueued, promptDone, promptWindowGone,
    promptHeading, promptAnswer, promptCancel,
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

test("with no match the name is the cleaned title's first word", () => {
    assert.equal(shortName("ABC-123: Fix login - Tracker - Google Chrome", "Google Chrome", []), "ABC-123");
    assert.equal(shortName("Inbox  (3) - Mozilla Firefox", "Mozilla Firefox", []), "Inbox");
    assert.equal(shortName("notes, draft | Docs", "", []), "notes");
    // A word left with no letter or digit is passed over.
    assert.equal(shortName("— | Docs", "", []), "Docs");
    assert.equal(firstWord("Café: menu"), "Café");
    assert.equal(firstWord("v1.2."), "v1.2");
    // Punctuation inside a word stays.
    assert.equal(firstWord("PR-12/login"), "PR-12/login");
    // Nothing to name it from gives an empty name, so the prompt starts empty.
    assert.equal(shortName("", "kitty", []), "");
    assert.equal(shortName("  -  ", "", []), "");
    assert.equal(shortName(undefined, "", []), "");
    // The name is still at most 32 characters.
    assert.equal(shortName("x".repeat(40) + " y", "", []), "x".repeat(32));
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

// Regression: a web address in inApps was taken for a window class, so
// its --app window went nowhere near home (SPEC.md §6.5).
test("a web address in inApps takes its site's --app windows home", () => {
    const apps = ["https://mail.google.com/mail/u/0/", "http://calendar.google.com"];
    assert.equal(isHomeApp("chrome-mail.google.com__mail_u_0_-Default", apps), true);
    assert.equal(isHomeApp("chrome-calendar.google.com__-Profile 1", apps), true);
    assert.equal(isHomeApp("chromium-calendar.google.com__-Default", apps), true);
    assert.equal(isHomeApp("chrome-chat.google.com__-Default", apps), false);
    assert.equal(isHomeApp("https://mail.google.com/mail/u/0/", apps), false, "not a class of its own");
    assert.deepEqual(inAppPatterns(["https://mail.google.com"]), ["(?i)(chrome|chromium)-([^_]*\\.)?mail\\.google\\.com_.*-[^-]+"]);
});

// Regression: a launcher script in inApps matched only a window of its
// own name, never the Chrome --app window it opens.
test("a launcher script in inApps takes the windows its grant finds home", () => {
    const apps = ["google-calendar", "gmail"];
    const resolved = { "google-calendar": ["google-calendar", "chrome-calendar.google.com__-Default"], gmail: ["org.example.Mail"] };
    assert.equal(isHomeApp("chrome-calendar.google.com__-Default", apps, resolved), true);
    assert.equal(isHomeApp("chrome-calendar.google.com__-Profile 2", apps, resolved), true, "in any profile");
    assert.equal(isHomeApp("org.example.Mail", apps, resolved), true, "a desktop entry's class");
    assert.equal(isHomeApp("google-calendar", apps, resolved), true, "its own name, as a key's launch names it");
    assert.equal(isHomeApp("chrome-calendar.google.com__-Default", apps), false, "not before it's looked up");
    assert.equal(isHomeApp("chrome-chat.google.com__-Default", apps, resolved), false);
    assert.equal(promptWanted({ class: "chrome-calendar.google.com__-Default", title: "Calendar", workspace: { name: "in" } }, "in", apps, resolved), false);
    assert.match(workspacesLua({ standing: ["in"], inApps: apps }, resolved), /calendar\\\\.google\\\\.com_/);
});

test("an inApps entry is a web address, a program, a class or a site", () => {
    assert.deepEqual(homeAppEntry(" https://Mail.google.com/x "), { kind: "url", url: "https://Mail.google.com/x", host: "mail.google.com" });
    assert.deepEqual(homeAppEntry("google-calendar"), { kind: "program", app: "google-calendar", word: "google-calendar" });
    assert.deepEqual(homeAppEntry(" Thunderbird "), { kind: "program", app: "thunderbird", word: "Thunderbird" });
    assert.deepEqual(homeAppEntry("calendar.google.com"), { kind: "site", app: "calendar.google.com", host: "calendar.google.com" });
    assert.deepEqual(homeAppEntry("Steam Big Picture"), { kind: "class", app: "steam big picture" });
    assert.equal(homeAppEntry("https://").kind, "class", "no host, so no site");
    assert.equal(homeAppEntry("  "), null);
    assert.deepEqual(homeAppPrograms(["gmail", "https://x.example", "Gmail", "a.b"]), [{ app: "gmail", word: "gmail" }]);
    // Regression: the lookup was given the lowercased name, which on a
    // case-sensitive filesystem is another file, or none.
    assert.deepEqual(homeAppPrograms(["MyCalendar"]), [{ app: "mycalendar", word: "MyCalendar" }]);
});

test("home starts its web addresses and programs at login, and nothing for a class or site", () => {
    assert.deepEqual(homeAppLaunches(["gmail", "https://music.youtube.com", "calendar.google.com", "org.gnome.Calendar", "gmail"]), [
        { name: "gmail", argv: ["tide", "launch", "--background", "--unless-running", "--", "gmail"], program: "gmail" },
        { name: "https://music.youtube.com", argv: ["tide", "launch", "--background", "--", "tide", "web-app", "https://music.youtube.com"], program: null },
    ]);
    assert.deepEqual(homeAppLaunches([]), []);
});

// Regression: home's apps start at login without waiting for their
// classes, so a launcher's window can open before a rule covers it, and
// stay on the wrong workspace. It's noted, and sent home by the first
// apply whose rules cover it, whatever order the lookup and apply ran in.
test("a home app's window that opened before its rule is sent home once, by the apply that covers it", () => {
    const apps = ["google-calendar", "https://mail.google.com"];
    const before = { inApps: apps, resolved: {} };
    const looked = { inApps: apps, resolved: { "google-calendar": ["chrome-calendar.google.com__-Default"] } };
    const cal = "chrome-calendar.google.com__-Default";
    let list = NO_UNCOVERED;
    // Calendar opens on re while only the web address's rule is in; Gmail
    // opens under its rule, and a terminal under none.
    list = uncoveredOpened(list, "a1", cal, before);
    list = uncoveredOpened(list, "a2", "chrome-mail.google.com__-Default", before);
    list = uncoveredOpened(list, "a3", "kitty", before);
    assert.deepEqual(list, ["a3", "a1"], "a window under a rule isn't noted");
    let windows = [
        { address: "a1", app: cal, workspace: "re" },
        { address: "a2", app: "chrome-mail.google.com__-Default", workspace: "docs" },
        { address: "a3", app: "kitty", workspace: "re" },
    ];
    // Codex's gap: the lookup is in, but an apply of the old rules
    // finishes first. It covers nothing new, so nothing moves or is lost.
    let r = homeSweep(list, windows, "in", before);
    assert.deepEqual(r, { list: ["a3", "a1"], move: [] });
    // The apply with the new classes sends Calendar home, once.
    r = homeSweep(r.list, windows, "in", looked);
    assert.deepEqual(r, { list: ["a3"], move: ["a1"] });
    // Moved out of home later, it isn't pulled back by another apply, and
    // Gmail, which its rule placed and you moved, never is.
    windows = windows.map((w) => w.address === "a1" ? Object.assign({}, w, { workspace: "work" }) : w);
    assert.deepEqual(homeSweep(r.list, windows, "in", looked).move, []);
});

test("a noted window that closed, is minimized, or is already home moves nowhere", () => {
    const rules = { inApps: ["https://mail.google.com"], resolved: {} };
    const mail = "chrome-mail.google.com__-Default";
    const none = { inApps: [], resolved: {} };
    let list = ["b1", "b2", "b3"].reduce((l, a) => uncoveredOpened(l, a, mail, none), NO_UNCOVERED);
    list = uncoveredClosed(list, "b3");
    const windows = [
        { address: "b1", app: mail, workspace: "special:minimized:re" },
        { address: "b2", app: mail, workspace: "in" },
        { address: "b3", app: mail, workspace: "re" },
    ];
    assert.deepEqual(homeSweep(list, windows, "in", rules), { list: [], move: [] });
    assert.deepEqual(homeSweep(["gone"], [], "in", rules), { list: [], move: [] });
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

test("Super+Return asks with no window at all, and Enter goes there, moving nothing", () => {
    // No address: nothing about it depends on a focused window.
    const s = promptQueued(NO_PROMPTS, { kind: "go", allowHome: true });
    const go = s.queue[0];
    assert.equal(go.address, undefined);
    assert.equal(promptHeading(go.kind), "Go to the workspace named");
    // An existing name, and a new one, which Hyprland makes on going there.
    const rows = promptRows({ names, typed: "notes", home: "in", allowHome: go.allowHome });
    assert.deepEqual(rows[0], { name: "notes", isNew: true, positions: [] });
    assert.deepEqual(promptAnswer(go, promptChoice({ rows, selected: 0, typed: "notes", home: "in" }).name), { go: "notes" });
    assert.deepEqual(promptAnswer(go, "docs"), { go: "docs" });
    // Home is a place to go, so it's offered.
    assert.equal(promptRows({ names, typed: "in", home: "in", allowHome: go.allowHome })[0].name, "in");
    // Esc stays where you are.
    assert.deepEqual(promptCancel(go), {});
    // A second press while it's up is the same question.
    assert.deepEqual(promptQueued(s, { kind: "go", allowHome: true }), s);
    // A window closing doesn't take it away.
    assert.deepEqual(promptWindowGone(s, "0x1"), s);
});

test("Super+Shift+Return moves its window, and Esc leaves it be", () => {
    const move = { kind: "move", address: "0x5", id: 1 };
    assert.equal(promptHeading("move"), "Move this window to the workspace named");
    assert.deepEqual(promptAnswer(move, "docs"), { move: "0x5", name: "docs" });
    assert.deepEqual(promptCancel(move), {});
    // A move waiting doesn't stop a go, nor a go a move.
    let s = promptQueued(NO_PROMPTS, move);
    s = promptQueued(s, { kind: "go" });
    s = promptQueued(s, { kind: "move", address: "0x6" });
    assert.deepEqual(s.queue.map((r) => r.kind), ["move", "go", "move"]);
});

test("a new window's and a launch's Enter and Esc", () => {
    const win = { kind: "window", address: "0x7" };
    assert.equal(promptHeading("window"), "This window goes to the workspace named");
    assert.deepEqual(promptAnswer(win, "docs"), { move: "0x7", name: "docs" });
    assert.deepEqual(promptCancel(win), { close: "0x7" });
    const waiting = { kind: "launch", answer: "/run/fifo" };
    assert.equal(promptHeading("launch"), "Open on the workspace named");
    assert.deepEqual(promptAnswer(waiting, "docs"), { reply: "workspace docs", answer: "/run/fifo" });
    assert.deepEqual(promptCancel(waiting), { reply: "cancel", answer: "/run/fifo" });
    const ctrlEnter = { kind: "launch", argv: ["--", "kitty"], cwd: "/home/user" };
    assert.deepEqual(promptAnswer(ctrlEnter, "docs"), { launch: ["--", "kitty"], cwd: "/home/user", name: "docs" });
    assert.deepEqual(promptCancel(ctrlEnter), {});
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
