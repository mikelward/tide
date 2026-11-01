// Which windows float (SPEC.md §6.4, §16): the rules in floating.json and
// floating.local.json, each a window class and, optionally, a pattern its
// title must match, as pure functions the QML binds to. conf's
// hyprland.lua reads them, as Hyprland's own patterns, from
// tide-floating.lua (floatingLua), and floats a window that opens matching
// one; the shell floats the windows already open that a new rule covers
// (newlyCovered).

import { jsonError } from "./clocks.mjs";
import { DIGIT, WORD } from "./unicode.mjs";
import { luaString } from "./workspacenames.mjs";
import { normalizeAddress } from "./workspaces.mjs";

export const FILES = Object.freeze(["floating.json", "floating.local.json"]);

// The most rules there can be: conf keeps as many window rules, to turn
// off the ones a shorter list no longer needs (Hyprland 0.56 can't drop
// one).
export const MAX_RULES = 64;

// conf's own dialog rules (its hyprland.lua, WINDOW RULES), which float a
// window whatever the files say: a window one of these covers needs no
// rule of its own, so the page doesn't offer one. Kept in step with conf
// by hand; one missed here only offers a rule that changes nothing.
export const BUILT_IN = Object.freeze([
    Object.freeze({ class: /^(org\.pulseaudio\.)?pavucontrol$/ }),
    Object.freeze({ class: /^nm-connection-editor$/ }),
    Object.freeze({ class: /^blueman-manager$/ }),
    Object.freeze({ class: /^xdg-desktop-portal-(gtk|gnome|kde)$/ }),
    Object.freeze({ title: /^(Open File|Open Files|Save File|Save As)(…|\.\.\.)?$/ }),
    Object.freeze({ title: /^Picture[- ]in[- ][Pp]icture$/ }),
]);

// What a class can't hold: control characters. Anything else is the class
// as the app sets it, and is matched as text, not as a pattern.
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]/;

// The most a quantifier may count to: RE2's limit (its kMaxRepeat).
const MAX_REPEAT = 1000;

// Whitespace, as JavaScript's \s has it, which RE2's \s (ASCII) and its
// Z category (no tab, no BOM) each miss part of: spelled out for both.
const SPACE_CPS = [[0x09, 0x0d], [0x20, 0x20], [0xa0, 0xa0], [0x1680, 0x1680], [0x2000, 0x200a],
    [0x2028, 0x2029], [0x202f, 0x202f], [0x205f, 0x205f], [0x3000, 0x3000], [0xfeff, 0xfeff]];

function spelledRanges(list, one) {
    return list.map(([a, b]) => a === b ? one(a) : `${one(a)}-${one(b)}`).join("");
}

// What a shorthand means in a title pattern (SPEC.md §16, Floating), as
// the contents of a class, in each engine's spelling: \w and \d by
// Unicode's categories, as RE2 names them and as shell/lib/unicode.mjs
// lists them for the shell's JavaScript, which has no tables for property
// escapes, and \s as JavaScript's whitespace, listed for both.
export const CLASSES = Object.freeze({
    w: { re2: "\\p{L}\\p{M}\\p{N}_", js: WORD },
    d: { re2: "\\p{Nd}", js: DIGIT },
    s: {
        re2: spelledRanges(SPACE_CPS, cp => `\\x{${cp.toString(16).toUpperCase()}}`),
        js: spelledRanges(SPACE_CPS, cp => `\\u{${cp.toString(16).toUpperCase()}}`),
    },
});

// What JavaScript's u flag lets be escaped as itself; in a class, - too.
const SYNTAX = "^$\\.*+?()[]{}|/";

// `pattern` as each engine reads it, the same way: {re2, js}, the js
// meant for the u flag, or {error} naming what it uses that they'd read
// differently, or that one lacks. Taken as they are: literals, `^`, `$`,
// `|`, groups and `(?:…)`, `*`, `+`, `?` and their lazy forms, counts up
// to MAX_REPEAT, classes, `\b \B` (an ASCII word boundary in both, the u
// flag's included, without i), the syntax characters' escapes, `\n \t \r
// \f \v` and `\xHH`. Translated: `.` to [^\n], since JavaScript's also
// stops at \r and the line separators; `\w \d \s` and their capitals to
// CLASSES. JavaScript's own \w and \d are ASCII, RE2's \s is, and RE2's
// `.` isn't JavaScript's, so neither is ever left to an engine.
export function translateTitle(pattern) {
    let re2 = "";
    let js = "";
    const both = (t) => {
        re2 += t;
        js += t;
    };
    // An escape at `i`: {next, re2, js} or {error}.
    const escape = (i, inClass) => {
        const c = pattern[i + 1];
        if (c === undefined) {
            return { error: "a lone backslash at the end" };
        }
        const plain = (n) => ({ next: i + n, re2: pattern.slice(i, i + n), js: pattern.slice(i, i + n) });
        if (SYNTAX.includes(c) || (inClass && c === "-")) {
            return plain(2);
        }
        if ("ntrfv".includes(c) || (!inClass && "bB".includes(c))) {
            return plain(2);
        }
        if (c === "x" && /^[0-9A-Fa-f]{2}$/.test(pattern.slice(i + 2, i + 4))) {
            return plain(4);
        }
        const lower = c.toLowerCase();
        if (CLASSES[lower] !== undefined) {
            const cls = CLASSES[lower];
            if (c === lower) {
                return inClass ? { next: i + 2, re2: cls.re2, js: cls.js } : { next: i + 2, re2: `[${cls.re2}]`, js: `[${cls.js}]` };
            }
            if (inClass) {
                return { error: `\\${c} in a class, which can't be put there the same way in both; use [^…] around \\${lower}` };
            }
            return { next: i + 2, re2: `[^${cls.re2}]`, js: `[^${cls.js}]` };
        }
        if (/[1-9]/.test(c) || c === "k") {
            return { error: "a backreference, which Hyprland's patterns don't have" };
        }
        if (c === "u") {
            return { error: "a \\u escape, which Hyprland's patterns spell \\x{…}" };
        }
        if (/[!-/:-@[-`{-~]/.test(c)) {
            return { error: `\\${c}; ${c} needs no backslash` };
        }
        return { error: `\\${c}, which Hyprland's patterns read differently or not at all` };
    };
    let i = 0;
    while (i < pattern.length) {
        const c = pattern[i];
        if (c === "\\") {
            const e = escape(i, false);
            if (e.error) {
                return { error: e.error };
            }
            re2 += e.re2;
            js += e.js;
            i = e.next;
        } else if (c === "(" && pattern[i + 1] === "?") {
            if (pattern[i + 2] !== ":") {
                if (/^\(\?<?[=!]/.test(pattern.slice(i))) {
                    return { error: "a lookahead or lookbehind, which Hyprland's patterns don't have" };
                }
                if (pattern[i + 2] === "<") {
                    return { error: "a named group, which Hyprland's patterns spell differently" };
                }
                return { error: "a (?…) group other than (?:…)" };
            }
            both("(?:");
            i += 3;
        } else if (c === ".") {
            both("[^\\n]");
            i++;
        } else if (c === "[") {
            let j = i + 1;
            let open = "[";
            if (pattern[j] === "^") {
                open += "^";
                j++;
            }
            if (pattern[j] === "]") {
                return { error: "an empty class, [] or [^], which Hyprland's patterns don't have" };
            }
            both(open);
            while (j < pattern.length && pattern[j] !== "]") {
                if (pattern[j] === "\\") {
                    const e = escape(j, true);
                    if (e.error) {
                        return { error: e.error };
                    }
                    re2 += e.re2;
                    js += e.js;
                    j = e.next;
                } else if (pattern[j] === "[" && pattern[j + 1] === ":") {
                    return { error: "a [:…:] class name, which JavaScript doesn't have" };
                } else {
                    const cp = pattern.codePointAt(j);
                    const ch = String.fromCodePoint(cp);
                    both(ch);
                    j += ch.length;
                }
            }
            if (j >= pattern.length) {
                return { error: "a class with no ]" };
            }
            both("]");
            i = j + 1;
        } else if (c === "{") {
            const m = /^\{(\d+)(,(\d*))?\}/.exec(pattern.slice(i));
            if (m === null) {
                return { error: "a { that isn't a count, such as {2,5}; write \\{ for a brace" };
            }
            const counts = [m[1], m[3]].filter(n => n !== undefined && n !== "").map(Number);
            if (counts.some(n => n > MAX_REPEAT)) {
                return { error: `a count over ${MAX_REPEAT}, more than Hyprland's patterns take` };
            }
            both(m[0]);
            i += m[0].length;
        } else {
            const ch = String.fromCodePoint(pattern.codePointAt(i));
            both(ch);
            i += ch.length;
        }
    }
    return { re2, js };
}

// The title pattern as each engine runs it, a whole-title match found
// anywhere in it, as Hyprland's FullMatch takes it: {re2, js}, the js for
// the u flag. With no pattern, any title.
export function titleMatch(title) {
    if (!title) {
        return { re2: ".*", js: "^[^\\n]*$" };
    }
    const t = translateTitle(title);
    if (t.error) {
        throw new Error(`title ${JSON.stringify(title)}: ${t.error}`);
    }
    return { re2: `[^\\n]*(?:${t.re2})[^\\n]*`, js: `^(?:[^\\n]*(?:${t.js})[^\\n]*)$` };
}

// A class as typed, made one: {class} trimmed, or {error}.
export function checkClass(raw) {
    if (typeof raw !== "string" || raw.trim() === "") {
        return { error: "a rule needs a window class, such as org.gnome.Calculator" };
    }
    const cls = raw.trim();
    if (CONTROL.test(cls)) {
        return { error: `class ${JSON.stringify(cls)} has a control character` };
    }
    return { class: cls };
}

// A title pattern as typed: {title} trimmed ("" for none, which matches
// any title), or {error} saying why it can't be one.
export function checkTitle(raw) {
    if (raw === undefined || raw === null) {
        return { title: "" };
    }
    if (typeof raw !== "string") {
        return { error: "a title pattern is text" };
    }
    const title = raw.trim();
    if (title === "") {
        return { title: "" };
    }
    if (CONTROL.test(title)) {
        return { error: `title ${JSON.stringify(title)} has a control character` };
    }
    const t = translateTitle(title);
    if (t.error) {
        return { error: `title ${JSON.stringify(title)} uses ${t.error}` };
    }
    try {
        new RegExp(t.js, "u");
    } catch (e) {
        return { error: `title ${JSON.stringify(title)} doesn't compile: ${e.message}` };
    }
    return { title };
}

// Whether two rules float the same windows: the class ignoring case, as
// it's matched, and the same title pattern.
export function sameRule(a, b) {
    return a.class.toLowerCase() === b.class.toLowerCase() && (a.title ?? "") === (b.title ?? "");
}

// A rule as the files and the page keep it: {class} or {class, title}.
function ruleOf(cls, title) {
    return title === "" ? { class: cls } : { class: cls, title };
}

// A rule as typed or as written in a file: {rule} or {error}, naming the
// rule's place when `at` (from 1) is given.
export function checkRule(raw, at) {
    const where = at === undefined ? "" : `rules entry ${at}: `;
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
        return { error: `${where}a rule is an object, such as {"class": "org.gnome.Calculator"}` };
    }
    for (const key of Object.keys(raw)) {
        if (key !== "class" && key !== "title") {
            return { error: `${where}${key} isn't part of a rule (class, title)` };
        }
    }
    const cls = checkClass(raw.class);
    if (cls.error) {
        return { error: where + cls.error };
    }
    const title = checkTitle(raw.title);
    if (title.error) {
        return { error: where + title.error };
    }
    return { rule: ruleOf(cls.class, title.title) };
}

// Why a list of rules can't be one, or null.
function rulesError(list) {
    if (!Array.isArray(list)) {
        return "rules must be a list of rules";
    }
    if (list.length > MAX_RULES) {
        return `rules lists ${list.length} rules, more than ${MAX_RULES}`;
    }
    const seen = [];
    for (let i = 0; i < list.length; i++) {
        const checked = checkRule(list[i], i + 1);
        if (checked.error) {
            return checked.error;
        }
        if (checked.rule.class !== list[i].class || (list[i].title !== undefined && checked.rule.title !== list[i].title)) {
            return `rules entry ${i + 1}: ${JSON.stringify(list[i].class)} has space around it`;
        }
        if (seen.some(r => sameRule(r, checked.rule))) {
            return `rules entry ${i + 1}: ${describe(checked.rule)} is listed already`;
        }
        seen.push(checked.rule);
    }
    return null;
}

// One file: {rules} (undefined when it sets none) or {error}.
export function parseFloatingFile(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: "expected an object of settings, such as {\"rules\": [{\"class\": \"org.gnome.Calculator\"}]}" };
    }
    for (const key of Object.keys(value)) {
        if (key !== "rules") {
            return { error: `${key} isn't a setting (rules)` };
        }
    }
    if (value.rules === undefined) {
        return { rules: undefined };
    }
    const err = rulesError(value.rules);
    if (err) {
        return { error: err };
    }
    return { rules: value.rules.map(r => checkRule(r).rule) };
}

// The rules in effect: floating.local.json's when it sets them, since a
// list replaces the shared one whole (§16.1), else floating.json's, else
// none. Each text is null for no file. A file that's wrong keeps
// `lastGood`, and `errors` names it: {rules, errors}.
export function loadFloating(sharedText, localText, lastGood = []) {
    let rules = [];
    const errors = [];
    for (const [name, text] of [[FILES[0], sharedText], [FILES[1], localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseFloatingFile(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        if (parsed.rules !== undefined) {
            rules = parsed.rules;
        }
    }
    return errors.length > 0 ? { rules: lastGood, errors } : { rules, errors };
}

// floating.local.json's text with the rules `change` makes of the ones in
// effect: {text, rules} or {error}. The first change copies the shared
// list into the local file. Either file not loading, or a list the files
// wouldn't take, is an {error}, so a hand edit gone wrong isn't
// overwritten.
export function editedFloating(sharedText, localText, change) {
    const loaded = loadFloating(sharedText, localText);
    if (loaded.errors.length > 0) {
        return { error: loaded.errors[0] };
    }
    const result = change(loaded.rules.slice());
    if (result.error) {
        return { error: result.error };
    }
    const err = rulesError(result.rules);
    if (err) {
        return { error: err };
    }
    const local = localText === null || localText === undefined || localText.trim() === "" ? {} : JSON.parse(localText);
    const text = JSON.stringify(Object.assign({}, local, { rules: result.rules }), null, 2) + "\n";
    return { text, rules: result.rules };
}

// A rule as the page and its messages name it.
export function describe(rule) {
    return rule.title ? `${rule.class} titled /${rule.title}/` : rule.class;
}

// The rules with one for `cls` and `title` added at the end: {rules} or
// {error}.
export function withRule(rules, cls, title) {
    const checked = checkRule({ class: cls, title });
    if (checked.error) {
        return { error: checked.error };
    }
    if (rules.some(r => sameRule(r, checked.rule))) {
        return { error: `${describe(checked.rule)} is listed already` };
    }
    if (rules.length >= MAX_RULES) {
        return { error: `there are ${MAX_RULES} rules already, as many as there can be` };
    }
    return { rules: rules.concat([checked.rule]) };
}

// The rule a change is for: `index` (from 0) if it's still the one named,
// so a hand edit that has moved them since is refused; with no index, the
// first that is. -1 when none is.
function ruleIndex(rules, index, rule) {
    if (index === undefined || index === null) {
        return rules.findIndex(r => sameRule(r, rule));
    }
    return index >= 0 && index < rules.length && sameRule(rules[index], rule) ? index : -1;
}

function missing(index, rule) {
    return index === undefined || index === null
        ? { error: `${describe(rule)} isn't listed` }
        : { error: `rule ${index + 1} isn't ${describe(rule)}` };
}

export function movedRule(rules, index, rule, step) {
    const from = ruleIndex(rules, index, rule);
    if (from < 0) {
        return missing(index, rule);
    }
    const to = Math.max(0, Math.min(rules.length - 1, from + step));
    const next = rules.slice();
    next.splice(to, 0, next.splice(from, 1)[0]);
    return { rules: next };
}

export function withoutRule(rules, index, rule) {
    const at = ruleIndex(rules, index, rule);
    if (at < 0) {
        return missing(index, rule);
    }
    return { rules: rules.filter((r, i) => i !== at) };
}

// `s` as a pattern, RE2's or JavaScript's, that matches only it.
function quoted(s) {
    return s.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}

// A rule as Hyprland matches it. Hyprland 0.56 matches a whole class or
// title (RE2's FullMatch), so the class is the text, ignoring case, and
// the title is the pattern found anywhere in it (titleMatch), as the page
// tries it (covers). Both are always given: a rule Hyprland already has keeps a
// match it isn't given again.
export function hyprlandMatch(rule) {
    return {
        class: `(?i)${quoted(rule.class)}`,
        title: titleMatch(rule.title).re2,
    };
}

// ~/.config/hypr/tide-floating.lua, which conf's hyprland.lua reads as
// data: each rule's class and title, as Hyprland's patterns.
export function floatingLua(rules) {
    const items = rules.map(r => {
        const m = hyprlandMatch(r);
        return `        { class = ${luaString(m.class)}, title = ${luaString(m.title)} },\n`;
    });
    return "-- Written by tide's shell from floating.json and floating.local.json\n"
        + "-- (tide SPEC.md §6.4, §16); edit those, not this.\n"
        + "return {\n"
        + (items.length === 0 ? "    rules = {},\n" : `    rules = {\n${items.join("")}    },\n`)
        + "}\n";
}

// A Quickshell toplevel as these functions take a window: {address,
// class, title, floating, fullscreen}. The title is the toplevel's own,
// which Quickshell keeps live from windowtitlev2, not its client-list
// snapshot (lastIpcObject), which only a refresh renews and the shell
// refreshes on no title change; the snapshot's is the fallback before the
// first title event. The class, the floating flag and the fullscreen state
// are the snapshot's, refreshed on openwindow, changefloatingmode and
// fullscreen. The one lookup for every caller, so none can read a stale
// title.
export function windowOf(toplevel) {
    if (!toplevel) {
        return null;
    }
    const ipc = toplevel.lastIpcObject ?? {};
    return {
        address: normalizeAddress(toplevel.address),
        class: ipc.class || toplevel.wayland?.appId || "",
        title: toplevel.title || ipc.title || "",
        floating: ipc.floating === true,
        fullscreen: Number(ipc.fullscreen ?? 0),
    };
}

// Whether `rule` covers a window with class `cls` and title `title`.
export function covers(rule, cls, title) {
    if (rule.class instanceof RegExp || rule.title instanceof RegExp) {
        return (!rule.class || rule.class.test(cls)) && (!rule.title || rule.title.test(title));
    }
    if (String(cls).toLowerCase() !== rule.class.toLowerCase()) {
        return false;
    }
    return !rule.title || titleRegExp(rule.title).test(String(title));
}

// Each title pattern's RegExp, made once: covers runs for every window
// and rule on each change of either.
const compiled = new Map();

function titleRegExp(title) {
    let re = compiled.get(title);
    if (re === undefined) {
        re = new RegExp(titleMatch(title).js, "u");
        compiled.set(title, re);
    }
    return re;
}

// The first of `rules` that covers the window, conf's built-in ones
// first: {builtIn, index} (index from 0, among `rules`), or null.
export function coveringRule(rules, cls, title) {
    if (BUILT_IN.some(r => covers(r, cls, title))) {
        return { builtIn: true, index: -1 };
    }
    const index = rules.findIndex(r => covers(r, cls, title));
    return index < 0 ? null : { builtIn: false, index };
}

// The windows the page lists under Floating now: those floating that no
// rule covers, one per class, in the order given, each {class, title,
// address}. `windows` are {address, class, title, floating}. A window
// with no class can't be named by a rule, so it isn't listed.
export function floatingNow(windows, rules) {
    const out = [];
    for (const w of windows) {
        const cls = String(w.class ?? "");
        if (!w.floating || cls === "" || coveringRule(rules, cls, w.title ?? "") !== null) {
            continue;
        }
        if (out.some(o => o.class.toLowerCase() === cls.toLowerCase())) {
            continue;
        }
        out.push({ class: cls, title: String(w.title ?? ""), address: w.address });
    }
    return out;
}

// The tiled windows to float now that `after` is applied (SPEC.md §16):
// every window `after` covers that nothing covered before, on any
// workspace or monitor, a minimized one included. Covered before means by
// `before` or by conf's own rules, which never change, so a window tiled
// by hand under any rule stays tiled, and a list only reordered, or a rule
// taken out, floats nothing. A fullscreen or maximized window is left as
// it is, as Hyprland would leave one that opened so. With no `before`,
// none: nothing says what Hyprland had.
export function newlyCovered(windows, before, after) {
    if (before === null || before === undefined) {
        return [];
    }
    return windows
        .filter(w => w && !w.floating && !(w.fullscreen > 0) && String(w.class ?? "") !== "")
        .filter(w => after.some(r => covers(r, w.class, w.title ?? "")) && coveringRule(before, w.class, w.title ?? "") === null)
        .map(w => w.address);
}

// The record of the rules the shell last floated open windows for, kept
// beside Hyprland's own runtime files, so a shell that restarts floats
// what a change it applied but didn't get to sweep still needs, and a new
// Hyprland, at the next login, starts with none.
export function sweptPath(runtimeDir, instance) {
    return runtimeDir && instance ? `${runtimeDir}/hypr/${instance}/tide-floating-swept.json` : "";
}

export function sweptText(rules) {
    return JSON.stringify({ rules }) + "\n";
}

// The rules to sweep from, by the record's text (null for none): {rules,
// warning}. With no record, `current`: Hyprland read them as it started,
// so every window met them as it opened. A record that can't be read the
// same way, with a warning saying why.
export function sweptRules(text, current) {
    if (text === null || text === undefined) {
        return { rules: current, warning: "" };
    }
    const parsed = parseFloatingFile(text);
    if (parsed.error || parsed.rules === undefined) {
        return { rules: current, warning: `the record of the floating rules last swept doesn't read (${parsed.error ?? "no rules"}); taking the rules in effect` };
    }
    return { rules: parsed.rules, warning: "" };
}

// A title pattern that matches exactly `title`, as Always float and
// Super+Alt+F fill the page's field with it: the syntax characters
// escaped, the rest as it is, anchored at both ends. Control characters,
// which a pattern can't hold, are left out.
export function literalTitle(title) {
    const text = String(title ?? "").replace(/[\u0000-\u001f\u007f]/g, "");
    return text === "" ? "" : `^${text.replace(/[\\^$.*+?()[\]{}|/]/g, "\\$&")}$`;
}

// What Always float and Super+Alt+F put in the page's fields for `window`
// ({class, title} or null), for you to trim and add with Enter: {class,
// title, note}, the note saying which rule covers it already, or "", or
// {error} for a window no rule could name.
export function prefilled(rules, window) {
    if (!window) {
        return { error: "no window is focused" };
    }
    const cls = String(window.class ?? "").trim();
    if (cls === "") {
        return { error: "the window has no class for a rule to name" };
    }
    const covering = coveringRule(rules, cls, window.title ?? "");
    const note = covering === null ? ""
        : covering.builtIn ? `${cls} floats already, by conf's own rules`
            : `${cls} floats already, by rule ${covering.index + 1}, ${describe(rules[covering.index])}`;
    return { class: cls, title: literalTitle(window.title), note };
}
