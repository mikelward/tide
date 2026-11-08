// Tests for settingssearch.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { matches, searchWords, searchedRows, words } from "./settingssearch.mjs";

test("words are a text's runs of letters and digits, in lowercase", () => {
    assert.deepEqual(words("Wi-Fi, 24 hour"), ["wi", "fi", "24", "hour"]);
    assert.deepEqual(words("Zürich"), ["zürich"]);
    assert.deepEqual(words("  "), []);
    assert.deepEqual(words(undefined), []);
});

test("a term of several words is also found whole, without its marks", () => {
    assert.deepEqual(searchWords(["Wi-Fi", "Mouse"]), ["wi", "fi", "wifi", "mouse"]);
});

test("every word of the query must start a word of the terms, in any order", () => {
    const terms = ["Touchpad", "tap to click", "trackpad"];
    assert.ok(matches("touch", terms));
    assert.ok(matches("TAP", terms));
    assert.ok(matches("click tap", terms));
    assert.ok(matches("taptoc", terms));
    assert.ok(!matches("ouch", terms), "a word is found from its start");
    assert.ok(!matches("tap mouse", terms), "every word must be found");
});

test("a query with no words finds everything", () => {
    assert.ok(matches("", ["Mouse"]));
    assert.ok(matches(" - ", []));
});

test("the rows kept are the pages found, under their headings, and no empty heading", () => {
    const rows = [
        { heading: "Hardware" }, { page: "Mouse", keys: ["pointer"] }, { page: "Sound", keys: ["volume"] },
        { heading: "General" }, { page: "Clocks", keys: ["time zone"] },
    ];
    const kept = q => searchedRows(rows, q, r => r.heading !== undefined, r => [r.page, ...r.keys])
        .map(r => r.heading ?? r.page);
    assert.deepEqual(kept("vol"), ["Hardware", "Sound"]);
    assert.deepEqual(kept("zone"), ["General", "Clocks"]);
    assert.deepEqual(kept(""), ["Hardware", "Mouse", "Sound", "General", "Clocks"]);
    assert.deepEqual(kept("nothing"), []);
});
