// Tests for picker.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { match } from "./fuzzy.mjs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
    TABS, TAB_NAMES, PLACEHOLDERS, CHARACTER_LIMIT, toggled, movedTab, parseHistory, historyRows,
    words, parseChars, characterRows, codePoint, characterSub, emptyText, listedHistory, FUZZY_CHARS,
} from "./picker.mjs";

const shipped = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "chars", "chars.tsv"), "utf8");

test("two tabs, Clipboard first, each named", () => {
    assert.deepEqual([...TABS], ["clipboard", "characters"]);
    for (const t of TABS) {
        assert.ok(TAB_NAMES[t] && PLACEHOLDERS[t], t);
    }
});

test("Super+C opens it, again closes it, and the other tab's key moves there", () => {
    assert.deepEqual(toggled(false, "characters", "clipboard"), { visible: true, tab: "clipboard" });
    assert.deepEqual(toggled(true, "clipboard", "clipboard"), { visible: false, tab: "clipboard" });
    assert.deepEqual(toggled(true, "clipboard", "characters"), { visible: true, tab: "characters" });
    assert.throws(() => toggled(false, "clipboard", "apps"), /not a picker tab/);
});

test("Tab and Shift+Tab move between the two tabs, and wrap", () => {
    assert.equal(movedTab("clipboard", 1), "characters");
    assert.equal(movedTab("characters", 1), "clipboard");
    assert.equal(movedTab("clipboard", -1), "characters");
});

test("the history is read from cliphist's list: text, links and images", () => {
    const { entries, errors } = parseHistory([
        "42\tgit commit --amend",
        "41\thttps://example.com/docs/setup#keys",
        "40\t[[ binary data 240 KiB png 1280x720 ]]",
        "39\tsee https://example.com for more",
        "",
    ].join("\n"));
    assert.deepEqual(errors, []);
    assert.deepEqual(entries.map((e) => [e.id, e.kind, e.name, e.sub]), [
        ["42", "text", "git commit --amend", "Text"],
        ["41", "link", "https://example.com/docs/setup#keys", "Link"],
        ["40", "image", "Image", "PNG · 1280×720 · 240 KiB"],
        ["39", "text", "see https://example.com for more", "Text"],
    ]);
});

test("a history line that isn't ID<tab>preview is left out, and said so", () => {
    const { entries, errors } = parseHistory("7\tok\nnot a line\nx\tbad id\n8\t\n");
    assert.deepEqual(entries.map((e) => e.id), ["7", "8"]);
    assert.equal(errors.length, 2);
    assert.match(errors[0], /line 2/);
});

test("the Clipboard tab lists newest first, and a query ranks by the fuzzy score", () => {
    const { entries } = parseHistory("3\tmake test\n2\tgit commit --amend\n1\tmake mocks\n");
    assert.deepEqual(historyRows(entries, "").map((r) => r.item.id), ["3", "2", "1"]);
    assert.deepEqual(historyRows(entries, "mock").map((r) => r.item.id), ["1"]);
    const both = historyRows(entries, "make");
    assert.deepEqual(both.map((r) => r.item.id), ["3", "1"], "equal scores stay newest first");
    assert.deepEqual(both[0].positions, [0, 1, 2, 3]);
});

test("a query finds text past the first 100 characters of a preview", () => {
    const { entries } = parseHistory(`9\t${"x".repeat(150)} needle\n8\tshort\n`);
    assert.deepEqual(historyRows(entries, "needle").map((r) => r.item.id), ["9"]);
});

test("the fuzzy scorer reads at most FUZZY_CHARS of each preview, however long", () => {
    // Codex's case: 200 previews of 1,000 repetitive characters and a
    // repetitive query, which the quadratic scorer took seconds over. The
    // work is counted, not timed: how many characters the scorer is handed.
    const long = "ab".repeat(500);
    const { entries } = parseHistory(Array.from({ length: 200 }, (_, i) => `${i + 1}\t${long}`).join("\n"));
    const seen = [];
    const spy = (q, text) => {
        seen.push([...text].length);
        return match(q, text);
    };
    historyRows(entries, "ab".repeat(30) + "c", { match: spy });
    assert.equal(seen.length, 200, "once per entry");
    assert.ok(Math.max(...seen) <= FUZZY_CHARS, `longest text scored: ${Math.max(...seen)}`);
});

test("a plain-text match past the fuzzy part still finds the entry, after the fuzzy matches", () => {
    const { entries } = parseHistory(`3\t${"x".repeat(150)} Needle here\n2\tneedle at the start\n1\tnothing\n`);
    const rows = historyRows(entries, "needle");
    assert.deepEqual(rows.map((r) => r.item.id), ["2", "3"]);
    assert.deepEqual(rows[1].positions, [151, 152, 153, 154, 155, 156], "the match is highlighted");
});

test("an image is found by its description, without highlighting", () => {
    const { entries } = parseHistory("5\t[[ binary data 1 MiB jpeg 10x20 ]]\n");
    const rows = historyRows(entries, "jpeg");
    assert.equal(rows.length, 1);
    assert.deepEqual(rows[0].positions, []);
});

test("a name's words are lowercase, split at anything but letters and digits", () => {
    assert.deepEqual(words("flag: cote d'ivoire"), ["flag", "cote", "d", "ivoire"]);
    assert.deepEqual(words('japanese "here" button'), ["japanese", "here", "button"]);
    assert.deepEqual(words("  "), []);
});

const list = parseChars([
    "# a comment",
    "á\tlatin small letter a with acute\tLatin-1",
    "é\tlatin small letter e with acute\tLatin-1",
    "É\tlatin capital letter e with acute\tLatin-1",
    "→\trightwards arrow\tArrows",
    "⇒\trightwards double arrow\tArrows",
    "↑\tupwards arrow\tArrows",
    "🤷\tperson shrugging\tPeople & Body",
    "⬆️\tup arrow\tSymbols",
].join("\n")).chars;

test("each typed word must start a word of the name, in any order", () => {
    assert.deepEqual(characterRows(list, "e acute").map((r) => r.item.char), ["é", "É"], "not á");
    assert.deepEqual(characterRows(list, "acute e").map((r) => r.item.char), ["é", "É"]);
    assert.deepEqual(characterRows(list, "shrug").map((r) => r.item.char), ["🤷"]);
    assert.deepEqual(characterRows(list, "rugging").map((r) => r.item.char), [], "a word's middle doesn't count");
});

test("whole words rank before prefixes, then the list's order", () => {
    assert.deepEqual(characterRows(list, "arrow").map((r) => r.item.char), ["→", "⇒", "↑", "⬆️"]);
    assert.deepEqual(characterRows(list, "arr").map((r) => r.item.char), ["→", "⇒", "↑", "⬆️"]);
    assert.deepEqual(characterRows(list, "up").map((r) => r.item.char), ["⬆️", "↑"], "up is whole in up arrow");
});

test("the matched letters are highlighted", () => {
    const [row] = characterRows(list, "acute e");
    const name = row.item.name;
    assert.equal(row.positions.map((p) => name[p]).join(""), "eacute");
});

test("no query lists from the top, and every list is capped", () => {
    assert.equal(characterRows(list, "").length, list.length);
    const many = parseChars(Array.from({ length: 300 }, (_, i) => `x\tthing ${i}\tG`).join("\n")).chars;
    assert.equal(characterRows(many, "").length, CHARACTER_LIMIT);
    assert.equal(characterRows(many, "thing").length, CHARACTER_LIMIT);
    assert.equal(characterRows(many, "thing", 5).length, 5);
});

test("a row whose character starts with # isn't a comment", () => {
    const { chars, errors } = parseChars("# a comment\n#\u{fe0f}\u{20e3}\tkeycap: #\tSymbols\n");
    assert.deepEqual(errors, []);
    assert.deepEqual(chars.map((c) => c.name), ["keycap: #"]);
});

test("a malformed character line is left out, and said so", () => {
    const { chars, errors } = parseChars("x\tname\tgroup\nbroken line\n\tno char\tG\n");
    assert.equal(chars.length, 1);
    assert.equal(errors.length, 2);
});

test("a single code point is shown as U+XXXX, ignoring the emoji selector", () => {
    assert.equal(codePoint("é"), "U+00E9");
    assert.equal(codePoint("→"), "U+2192");
    assert.equal(codePoint("🤷"), "U+1F937");
    assert.equal(codePoint("⬆️"), "U+2B06");
    assert.equal(codePoint("🇯🇵"), "");
    assert.equal(characterSub({ char: "é", group: "Latin-1" }), "Latin-1 · U+00E9");
    assert.equal(characterSub({ char: "🇯🇵", group: "Flags" }), "Flags");
});

test("an empty tab says why", () => {
    assert.equal(emptyText("clipboard", "", {}), "Nothing copied yet");
    assert.equal(emptyText("clipboard", "", { loading: true }), "");
    assert.equal(emptyText("clipboard", "x", {}), "Nothing matches");
    assert.equal(emptyText("clipboard", "", { error: "cliphist isn't installed" }), "cliphist isn't installed");
    assert.equal(emptyText("characters", "zzz", {}), "Nothing matches");
});

test("the shipped list parses whole, and finds the spec's examples", () => {
    const { chars, errors } = parseChars(shipped);
    assert.deepEqual(errors, []);
    assert.ok(chars.length > 3000, `${chars.length} characters`);
    assert.equal(new Set(chars.map((c) => c.char)).size, chars.length, "each character once");
    for (const c of chars) {
        assert.match(c.name, /^[\x20-\x7e]+$/, c.char);
        assert.equal(c.name, c.name.toLowerCase(), c.char);
    }
    assert.deepEqual(characterRows(chars, "e acute").map((r) => r.item.char), ["é", "É"]);
    assert.equal(characterRows(chars, "shrug")[0].item.char, "🤷");
    assert.ok(characterRows(chars, "arrow").some((r) => r.item.char === "→"));
    assert.ok(characterRows(chars, "cote").some((r) => r.item.char === "🇨🇮"));
    assert.ok(characterRows(chars, "em dash").some((r) => r.item.char === "—"));
    assert.ok(characterRows(chars, "keycap").some((r) => r.item.char === "#\u{fe0f}\u{20e3}"), "the keycap # is a row");
});

test("a failed listing shows why in the tab; a good one lists", () => {
    assert.deepEqual(listedHistory(true, "", "tide clipboard: cliphist isn't installed, so there's no clipboard history; install the cliphist package\n"),
        { entries: [], error: "cliphist isn't installed, so there's no clipboard history; install the cliphist package", warnings: [] });
    assert.equal(listedHistory(true, "", "").error, "Couldn't read the clipboard history");
    const ok = listedHistory(false, "2\ttwo\nbad\n", "");
    assert.deepEqual(ok.entries.map((e) => e.id), ["2"]);
    assert.equal(ok.error, "");
    assert.equal(ok.warnings.length, 1);
});
