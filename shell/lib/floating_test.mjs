// Tests for floating.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    CLASSES,
    checkRule,
    checkTitle,
    covers,
    coveringRule,
    editedFloating,
    floatingLua,
    floatingNow,
    hyprlandMatch,
    loadFloating,
    MAX_RULES,
    movedRule,
    newlyCovered,
    parseFloatingFile,
    literalTitle,
    prefilled,
    withoutRule,
    sweptPath,
    titleMatch,
    translateTitle,
    sweptRules,
    sweptText,
    windowOf,
    withRule,
} from "./floating.mjs";

const calc = { class: "org.gnome.Calculator" };
const library = { class: "firefox", title: "^Library$" };

test("a rule is a class and, optionally, a title pattern", () => {
    assert.deepEqual(checkRule({ class: " org.gnome.Calculator " }), { rule: calc });
    assert.deepEqual(checkRule({ class: "firefox", title: "^Library$" }), { rule: library });
    assert.deepEqual(checkRule({ class: "kitty", title: "  " }), { rule: { class: "kitty" } }, "a blank title is none");
});

test("a rule with no class, an unknown key or a bad title is refused, saying why", () => {
    assert.match(checkRule({ title: "x" }).error, /needs a window class/);
    assert.match(checkRule({ class: "a\nb" }).error, /control character/);
    assert.match(checkRule({ class: "kitty", workspace: "2" }).error, /workspace isn't part of a rule/);
    assert.match(checkRule("kitty", 3).error, /^rules entry 3: a rule is an object/);
    assert.match(checkTitle("(").error, /doesn't compile/);
});

test("a title pattern Hyprland would read differently is refused, naming what", () => {
    assert.match(checkTitle("foo(?=bar)").error, /lookahead/);
    assert.match(checkTitle("(?<!x)y").error, /lookahead or lookbehind/);
    assert.match(checkTitle("(?<n>x)").error, /named group/);
    assert.match(checkTitle("(a)\\1").error, /backreference/);
    assert.match(checkTitle("\\u00e9").error, /\\u escape/);
    assert.deepEqual(checkTitle("^(Open|Save) \\w+$"), { title: "^(Open|Save) \\w+$" });
});

test("a title pattern outside what JavaScript and Hyprland's RE2 both read is refused, naming what", () => {
    assert.match(checkTitle("\\q").error, /\\q, which Hyprland's patterns read differently/, "JavaScript takes \\q as q; RE2 refuses it");
    assert.match(checkTitle("a{1001}").error, /a count over 1000/);
    assert.match(checkTitle("a{2,1001}").error, /a count over 1000/);
    assert.match(checkTitle("x{").error, /isn't a count/);
    assert.match(checkTitle("[[:alpha:]]").error, /\[:…:\] class name/);
    assert.match(checkTitle("[^]").error, /an empty class/);
    assert.match(checkTitle("a\\ b").error, /\\ , which/, "RE2 escapes only punctuation");
    assert.match(checkTitle("[\\b]").error, /\\b, which/, "a backspace in a class");
    for (const ok of ["a{2}", "a{2,}", "a{2,1000}", "\\x41", "[a-z\\d\\]]+", "\\bword\\b", "(?:a|b)*?", "\\.\\(\\)\\[", "^$", "\\t\\n"]) {
        assert.deepEqual(checkTitle(ok), { title: ok }, ok);
    }
});

test("a file's rules are an error at load naming the setting, and the last good rules stay", () => {
    assert.deepEqual(parseFloatingFile('{"rules": [{"class": "org.gnome.Calculator"}]}'), { rules: [calc] });
    assert.deepEqual(parseFloatingFile("{}"), { rules: undefined });
    assert.match(parseFloatingFile('{"rule": []}').error, /rule isn't a setting \(rules\)/);
    assert.match(parseFloatingFile('{"rules": {}}').error, /rules must be a list/);
    assert.match(parseFloatingFile('{"rules": [{"class": "a"}, {"class": "A"}]}').error, /rules entry 2: A is listed already/);
    assert.match(parseFloatingFile('{"rules": [{"class": " a"}]}').error, /rules entry 1: .* has space around it/);
    assert.match(parseFloatingFile('{"rules": [{"class": "a", "title": "("}]}').error, /rules entry 1: title "\(" doesn't compile/);
    assert.match(parseFloatingFile('{"rules": [{"class": "a", "title": "a{1001}"}]}').error, /rules entry 1: title "a\{1001\}" uses a count over 1000/, "an error at load, naming the rule");
    assert.match(parseFloatingFile('{"rules": [').error, /^line 1/);
    const many = JSON.stringify({ rules: Array.from({ length: MAX_RULES + 1 }, (_, i) => ({ class: `c${i}` })) });
    assert.match(parseFloatingFile(many).error, new RegExp(`more than ${MAX_RULES}`));
    const loaded = loadFloating('{"rules": [{"class": "x"}]}', '{"rules": 1}', [calc]);
    assert.deepEqual(loaded.rules, [calc]);
    assert.deepEqual(loaded.errors, ["floating.local.json: rules must be a list of rules"]);
});

test("the local file's rules replace the shared ones whole", () => {
    assert.deepEqual(loadFloating('{"rules": [{"class": "x"}]}', null), { rules: [{ class: "x" }], errors: [] });
    assert.deepEqual(loadFloating('{"rules": [{"class": "x"}]}', '{"rules": [{"class": "y"}]}').rules, [{ class: "y" }]);
    assert.deepEqual(loadFloating('{"rules": [{"class": "x"}]}', "{}").rules, [{ class: "x" }], "a local file setting no rules keeps the shared ones");
    assert.deepEqual(loadFloating(null, null), { rules: [], errors: [] });
});

test("a change copies the shared rules into the local file, keeping a hand edit there", () => {
    const r = editedFloating('{"rules": [{"class": "x"}]}', null, rules => withRule(rules, "org.gnome.Calculator", ""));
    assert.deepEqual(r.rules, [{ class: "x" }, calc]);
    assert.equal(r.text, '{\n  "rules": [\n    {\n      "class": "x"\n    },\n    {\n      "class": "org.gnome.Calculator"\n    }\n  ]\n}\n');
    assert.match(editedFloating(null, '{"rules": [', rules => ({ rules })).error, /^floating.local.json: line 1/, "a hand edit that doesn't parse isn't written over");
});

test("adding, moving and taking out a rule, by its place and what it is", () => {
    assert.deepEqual(withRule([calc], "firefox", "^Library$"), { rules: [calc, library] });
    assert.match(withRule([calc], "ORG.GNOME.CALCULATOR", "").error, /is listed already/);
    assert.match(withRule([calc], "", "").error, /needs a window class/);
    const full = Array.from({ length: MAX_RULES }, (_, i) => ({ class: `c${i}` }));
    assert.match(withRule(full, "more", "").error, /as many as there can be/);
    assert.deepEqual(movedRule([calc, library], 1, library, -1), { rules: [library, calc] });
    assert.deepEqual(movedRule([calc, library], undefined, calc, 5), { rules: [library, calc] });
    assert.match(movedRule([calc, library], 0, library, 1).error, /rule 1 isn't firefox titled \/\^Library\$\//, "a hand edit that moved it is refused");
    assert.deepEqual(withoutRule([calc, library], 0, calc), { rules: [library] });
    assert.match(withoutRule([calc], undefined, library).error, /isn't listed/);
});

test("the file conf reads gives each rule's class and title as Hyprland's whole-text patterns", () => {
    assert.deepEqual(hyprlandMatch({ class: "org.gnome.Calculator" }), { class: "(?i)org\\.gnome\\.Calculator", title: ".*" });
    assert.deepEqual(hyprlandMatch(library), { class: "(?i)firefox", title: "[^\\n]*(?:^Library$)[^\\n]*" });
    assert.equal(floatingLua([]), "-- Written by tide's shell from floating.json and floating.local.json\n-- (tide SPEC.md §6.4, §16); edit those, not this.\nreturn {\n    rules = {},\n}\n");
    assert.equal(floatingLua([calc, { class: 'we"ird', title: "a\\d" }]).split("\n").slice(2).join("\n"),
        'return {\n    rules = {\n        { class = "(?i)org\\\\.gnome\\\\.Calculator", title = ".*" },\n        { class = "(?i)we\\"ird", title = "[^\\\\n]*(?:a[\\\\p{Nd}])[^\\\\n]*" },\n    },\n}\n');
});

test("a rule covers a window by its class, ignoring case, and its title anywhere; conf's own come first", () => {
    assert.deepEqual(coveringRule([calc, library], "Org.Gnome.Calculator", "Calculator"), { builtIn: false, index: 0 });
    assert.deepEqual(coveringRule([calc, library], "firefox", "Library"), { builtIn: false, index: 1 });
    assert.equal(coveringRule([calc, library], "firefox", "Mozilla Firefox"), null);
    assert.deepEqual(coveringRule([{ class: "kitty", title: "htop" }], "kitty", "top: htop"), { builtIn: false, index: 0 }, "found anywhere in the title");
    assert.deepEqual(coveringRule([], "pavucontrol", "Volume Control"), { builtIn: true, index: -1 });
    assert.deepEqual(coveringRule([], "kitty", "Save As…"), { builtIn: true, index: -1 });
});

test("Floating now lists floating windows no rule covers, one per class, leaving out tiled and classless ones", () => {
    const windows = [
        { address: "0x1", class: "kitty", title: "htop", floating: true },
        { address: "0x2", class: "Kitty", title: "vim", floating: true },
        { address: "0x3", class: "firefox", title: "Mozilla Firefox", floating: false },
        { address: "0x4", class: "org.gnome.Calculator", title: "Calculator", floating: true },
        { address: "0x5", class: "pavucontrol", title: "Volume Control", floating: true },
        { address: "0x6", class: "", title: "", floating: true },
    ];
    assert.deepEqual(floatingNow(windows, [calc]), [{ class: "kitty", title: "htop", address: "0x1" }]);
});

test("a new rule floats the tiled windows it covers that the old rules didn't", () => {
    const windows = [
        { address: "0x1", class: "org.gnome.Calculator", title: "Calculator", floating: false },
        { address: "0x2", class: "firefox", title: "Library", floating: false },
        { address: "0x3", class: "firefox", title: "Library", floating: true },
        { address: "0x4", class: "kitty", title: "vim", floating: false },
    ];
    assert.deepEqual(newlyCovered(windows, [calc], [calc, library]), ["0x2"], "the Calculator, tiled by hand under its old rule, stays tiled");
    assert.deepEqual(newlyCovered(windows, [], [calc]), ["0x1"]);
    assert.deepEqual(newlyCovered(windows, null, [calc, library]), [], "the shell's first apply floats nothing: each window met the rules as it opened");
    assert.deepEqual(newlyCovered(windows, [calc], []), [], "taking a rule out tiles nothing");
});

test("Always float and Super+Alt+F fill the fields with the window's class and its exact title, adding nothing", () => {
    assert.deepEqual(prefilled([], { class: "kitty", title: "htop" }), { class: "kitty", title: "^htop$", note: "" });
    assert.match(prefilled([], null).error, /no window is focused/);
    assert.match(prefilled([], { class: "", title: "x" }).error, /no class/);
    assert.equal(prefilled([], { class: "pavucontrol", title: "Volume Control" }).note, "pavucontrol floats already, by conf's own rules");
    assert.equal(prefilled([calc], { class: "org.gnome.Calculator", title: "" }).note, "org.gnome.Calculator floats already, by rule 1, org.gnome.Calculator");
    assert.deepEqual(prefilled([calc], { class: "org.gnome.Calculator", title: "" }).title, "", "no title, no pattern");
});

test("a title filled in is a pattern matching exactly that title, which the files take", () => {
    for (const title of ["a.b (c) [d] {e} f|g ^h$ i*+? j/k \\ é", "Save As…", "Inbox (3) - user@example.com", "x\u0007y"]) {
        const pattern = literalTitle(title);
        assert.deepEqual(checkTitle(pattern), { title: pattern }, title);
        const rule = { class: "x", title: pattern };
        assert.equal(covers(rule, "x", title.replace(/\u0007/g, "")), true, `${title} matches`);
        assert.equal(covers(rule, "x", `${title}!`), false, `${title}! doesn't`);
        assert.equal(covers(rule, "x", `${title}`.slice(1)), false, `part of ${title} doesn't`);
    }
    assert.equal(literalTitle("a.b"), "^a\\.b$");
    assert.equal(literalTitle(""), "");
});

test("a window's title is the toplevel's live one, not its client-list snapshot's, for every rule check", () => {
    // Renamed since the last refresh: Quickshell updates title from
    // windowtitlev2, and the shell refreshes the snapshot on no title event.
    const renamed = { address: "55AA01", title: "Library", wayland: null, lastIpcObject: { class: "firefox", title: "Mozilla Firefox", floating: false } };
    assert.deepEqual(windowOf(renamed), { address: "55aa01", class: "firefox", title: "Library", floating: false, fullscreen: 0 });
    assert.deepEqual(newlyCovered([windowOf(renamed)], [], [library]), ["55aa01"], "a rule for its new title floats it");
    const stale = { address: "0x2", title: "Mozilla Firefox", lastIpcObject: { class: "firefox", title: "Library", floating: false } };
    assert.deepEqual(newlyCovered([windowOf(stale)], [], [library]), [], "nor does its old title float it");
    assert.deepEqual(floatingNow([windowOf({ address: "0x3", title: "now", lastIpcObject: { class: "kitty", title: "then", floating: true } })], []),
        [{ class: "kitty", title: "now", address: "3" }]);
    assert.match(prefilled([library], windowOf(renamed)).note, /by rule 1/, "Super+Alt+F sees the live title too");
    assert.equal(windowOf({ address: "0x4", title: "", lastIpcObject: { class: "a", title: "first", floating: true } }).title, "first", "before any title event, the snapshot's");
    assert.equal(windowOf({ address: "0x5", title: "t", wayland: { appId: "org.example.App" } }).class, "org.example.App", "no snapshot yet: the app ID");
    assert.equal(windowOf(null), null);
});

test("a window tiled by hand under conf's own rules isn't floated again by a broader rule of yours", () => {
    const saveAs = { address: "0x1", class: "firefox", title: "Save As", floating: false };
    const main = { address: "0x2", class: "firefox", title: "Mozilla Firefox", floating: false };
    assert.deepEqual(newlyCovered([saveAs, main], [], [{ class: "firefox" }]), ["0x2"]);
    const volume = { address: "0x3", class: "pavucontrol", title: "Volume Control", floating: false };
    assert.deepEqual(newlyCovered([volume], [], [{ class: "pavucontrol" }]), []);
});

test("a rule reaches every matching window, wherever it is, and nothing else changes one", () => {
    const at = (address, extra) => Object.assign({ address, class: "org.gnome.Calculator", title: "Calculator", floating: false, fullscreen: 0 }, extra);
    const windows = [
        at("0x1", { workspace: "in", monitor: 0 }),
        at("0x2", { workspace: "re", monitor: 1 }),
        at("0x3", { workspace: "special:minimized:in" }),
        at("0x4", { fullscreen: 1 }),
        at("0x5", { fullscreen: 2 }),
        at("0x6", { floating: true, pinned: true }),
    ];
    assert.deepEqual(newlyCovered(windows, [], [calc]), ["0x1", "0x2", "0x3"], "other workspaces and monitors, and minimized, float; maximized, fullscreen and pinned are left");
    assert.deepEqual(newlyCovered(windows, [calc, library], [library, calc]), [], "a list only reordered floats nothing");
    assert.deepEqual(newlyCovered(windows, [calc, library], [library]), [], "a rule taken out tiles nothing, and floats nothing");
    assert.deepEqual(newlyCovered(windows, [{ class: "org.gnome.Calculator", title: "^Sci" }], [calc]), ["0x1", "0x2", "0x3"], "a rule widened floats what the narrower one didn't cover");
    assert.deepEqual(newlyCovered(windows, [calc], [calc]), [], "applying the same rules again, at a shell's start, floats nothing: a hand-tiled window stays tiled");
});

test("the record of the rules last swept lets a restarted shell finish a change, and a new Hyprland starts without one", () => {
    assert.equal(sweptPath("/run/user/1000", "sig1"), "/run/user/1000/hypr/sig1/tide-floating-swept.json");
    assert.equal(sweptPath("", "sig1"), "");
    assert.equal(sweptPath("/run/user/1000", ""), "");
    assert.deepEqual(sweptRules(sweptText([calc]), [calc, library]), { rules: [calc], warning: "" }, "applied, not swept: the shell before died between");
    const windows = [{ address: "0x2", class: "firefox", title: "Library", floating: false }];
    assert.deepEqual(newlyCovered(windows, sweptRules(sweptText([calc]), [calc, library]).rules, [calc, library]), ["0x2"]);
    assert.deepEqual(sweptRules(null, [calc]), { rules: [calc], warning: "" }, "no record: Hyprland met the rules in effect as each window opened");
    const bad = sweptRules("{", [calc]);
    assert.deepEqual(bad.rules, [calc]);
    assert.match(bad.warning, /doesn't read/);
});

// A title pattern's JavaScript form, as the shell runs it.
const titled = (pattern, title) => new RegExp(titleMatch(pattern).js, "u").test(title);

test("\\w, \\d and \\s mean Unicode's letters, marks, numbers and _, decimal digits, and whitespace", () => {
    for (const [pattern, title, want] of [
        ["^\\w+$", "café", true], ["^\\w+$", "Жук", true], ["^\\w+$", "日本語", true], ["^\\w+$", "é", true],
        ["^\\w+$", "a_1²", true], ["^\\w+$", "a-b", false], ["^\\W$", "é", false], ["^\\W$", "-", true],
        ["^\\d+$", "٣٤", true], ["^\\d$", "²", false], ["^\\D$", "٣", false], ["^\\D$", "x", true],
        ["^a\\sb$", "a b", true], ["^a\\sb$", "a b", true], ["^a\\sb$", "a b", true], ["^a\\sb$", "a﻿b", true],
        ["^a\\sb$", "a\tb", true], ["^a\\sb$", "a​b", false], ["^\\S$", "　", false], ["^\\S$", "é", true],
        ["^[\\w-]+$", "ça-va", true], ["^[\\d.]+$", "١.٢", true],
        ["^.$", "\u{1F600}", true], ["^.$", " ", true], ["^a.b$", "a\rb", true],
    ]) {
        assert.equal(titled(pattern, title), want, `${pattern} on ${JSON.stringify(title)}`);
    }
});

test("\\b is an ASCII word boundary, as in RE2, while \\w is Unicode", () => {
    assert.equal(titled("\\bcaf\\b", "café"), true, "é isn't an ASCII word character, so caf ends a word");
    assert.equal(titled("café\\b", "café"), false, "nor does a word end after é");
    assert.equal(titled("\\bé", " é"), false);
    assert.equal(titled("\\bLibrary\\b", "Firefox Library"), true);
    assert.equal(titled("^caf\\w$", "café"), true, "where \\w takes é");
    assert.equal(translateTitle("\\bx\\B").re2, "\\bx\\B", "passed through unchanged");
});

test("Hyprland's pattern and the shell's are one translation, differing only in how each spells a class", () => {
    const asJs = (re2) => {
        let out = re2;
        for (const c of Object.values(CLASSES)) {
            out = out.split(c.re2).join(c.js);
        }
        return out;
    };
    for (const pattern of ["^Library$", "a.b", "(?:Open|Save) \\w+", "\\d{2,4}x", "[^\\s]+\\S", "\\bé\\b", "[\\w.-]+@", "ß+?$"]) {
        const t = translateTitle(pattern);
        assert.equal(asJs(t.re2), t.js, pattern);
        const m = titleMatch(pattern);
        assert.equal(asJs(m.re2), m.js.slice(4, -2), `${pattern}, wrapped`);
    }
    assert.equal(translateTitle("^Library$").re2, "^Library$", "with no class or dot, both are the pattern itself");
    assert.equal(translateTitle("a.b").re2, "a[^\\n]b");
    assert.equal(translateTitle("\\s").re2, "[\\x{9}-\\x{D}\\x{20}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}-\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]");
    assert.equal(translateTitle("\\w").re2, "[\\p{L}\\p{M}\\p{N}_]");
    assert.equal(translateTitle("\\D").re2, "[^\\p{Nd}]");
});

test("what the u flag or RE2 can't take the same way is refused, naming it", () => {
    assert.match(checkTitle("[\\W]").error, /\\W in a class/);
    assert.match(checkTitle("a\\!").error, /! needs no backslash/);
    assert.match(checkTitle("a]").error, /doesn't compile/, "a lone ] is literal in RE2, an error under the u flag");
    assert.match(checkTitle("[abc").error, /a class with no \]/);
    assert.deepEqual(checkTitle("[a\\-z]"), { title: "[a\\-z]" }, "\\- in a class");
});
