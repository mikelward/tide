// Tests for fuzzy.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { match } from "./fuzzy.mjs";

test("a query matches its letters in order, ignoring case", () => {
    assert.deepEqual(match("scr", "Screenshot").positions, [0, 1, 2]);
    assert.notEqual(match("SCR", "screenshot"), null);
    assert.equal(match("rcs", "Screenshot"), null);
    assert.equal(match("x", "Screenshot"), null);
    assert.equal(match("toolong", "tool"), null);
});

test("an empty or blank query matches anything with no letters", () => {
    assert.deepEqual(match("", "kitty"), { score: 0, positions: [] });
    assert.deepEqual(match("  ", "kitty"), { score: 0, positions: [] });
});

test("spaces in the query are ignored", () => {
    assert.deepEqual(match("s s", "Secure Shell").positions, [0, 7]);
});

test("a prefix beats letters scattered through the middle", () => {
    assert.ok(match("scr", "Screenshot window").score > match("scr", "Secure Shell").score);
});

test("word starts beat letters inside a word", () => {
    // Both words' first letters, not the "s" and "c" of "Secure".
    assert.deepEqual(match("ss", "Secure Shell").positions, [0, 7]);
    assert.ok(match("nm", "Network Manager").score > match("nm", "Penumbra").score);
});

test("a camelCase hump counts as a word start", () => {
    assert.deepEqual(match("nm", "NetworkManager").positions, [0, 7]);
});

test("a consecutive run beats the same letters spread out", () => {
    assert.ok(match("fire", "Firefox").score > match("fire", "Files Reader").score);
});

test("punctuation and symbols end a word, and letters without case start one", () => {
    // A "b" after a dash or a trademark sign starts a word; after a letter
    // with an accent it doesn't.
    assert.ok(match("b", "a—b").score > match("b", "aéb").score);
    assert.ok(match("b", "a™b").score > match("b", "aéb").score);
    // 日 after a space starts a word; 本 after 日 doesn't.
    assert.ok(match("日", "ab 日本").score > match("本", "ab 日本").score);
});

test("positions are code points, so they index a name with emoji", () => {
    assert.deepEqual(match("b", "😀 Bob").positions, [2]);
});

test("case and accents fold the same way on both sides", () => {
    // "İ" lowercases to two code points; it still matches a plain "i".
    assert.deepEqual(match("i", "İnternet").positions, [0]);
    assert.deepEqual(match("İ", "internet").positions, [0]);
    assert.deepEqual(match("cafe", "Café").positions, [0, 1, 2, 3]);
    assert.deepEqual(match("é", "Cafe").positions, [3]);
});

test("of equally scored alignments, an unbroken run, then the earliest start", () => {
    // "ba" scores the same at [0, 7] and at the run [6, 7].
    assert.equal(match("ba", "bxxx-BbA_B").score, 54);
    assert.deepEqual(match("ba", "bxxx-BbA_B").positions, [6, 7]);
    // Neither of "abb"'s best alignments is a run: the earlier start, not
    // the one with fewer gaps.
    assert.deepEqual(match("abb", "axxxxxab--xB").positions, [0, 7, 11]);
});
