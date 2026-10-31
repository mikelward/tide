// Tests for clipboard.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULTS, historySummary, loadClipboardSettings, steppedMax, storeConf, withSetting } from "./clipboard.mjs";

test("history on, keeping the picker's 200, by default", () => {
    assert.deepEqual(loadClipboardSettings(null, null), { settings: { history: true, maxItems: 200 }, errors: [] });
    assert.equal(storeConf(DEFAULTS), "# Written by tide's settings panel (SPEC.md §16); edit clipboard.local.json instead.\nhistory=on\nmax_items=200\n");
});

test("the local file overrides key by key, and a bad one names the setting and keeps the last good", () => {
    assert.deepEqual(loadClipboardSettings('{"maxItems": 500}', '{"history": false}').settings, { history: false, maxItems: 500 });
    const good = { history: false, maxItems: 50 };
    for (const [text, why] of [
        ['{"maxItems": 0}', /maxItems must be a whole number from 1 to 10000/],
        ['{"maxItems": 2.5}', /maxItems must be a whole number/],
        ['{"history": "off"}', /history must be true or false/],
        ['{"keep": 3}', /"keep" isn't a setting/],
        ["[]", /expected an object/],
        ["{", /^clipboard\.local\.json: line 1/],
    ]) {
        const r = loadClipboardSettings(null, text, good);
        assert.equal(r.settings, good, text);
        assert.match(r.errors[0], why, text);
    }
});

test("a change writes the local file, keeping its other settings, and refuses a bad value", () => {
    assert.deepEqual(JSON.parse(withSetting('{"history": false}', "maxItems", 100).text), { history: false, maxItems: 100 });
    assert.match(withSetting(null, "maxItems", 20000).error, /from 1 to 10000/);
    assert.match(withSetting("{", "history", true).error, /^clipboard\.local\.json: /);
});

test("the cap steps through its marks, landing on one from between them", () => {
    assert.equal(steppedMax(200, 1), 500);
    assert.equal(steppedMax(200, -1), 100);
    assert.equal(steppedMax(300, 1), 500, "a hand-set 300 goes to the next mark up");
    assert.equal(steppedMax(300, -1), 200);
    assert.equal(steppedMax(1000, 1), 1000, "the last mark stays");
    assert.equal(steppedMax(25, -1), 25);
    assert.equal(steppedMax(5000, 1), 5000, "past the end, + stays");
    assert.equal(steppedMax(5000, -1), 1000);
    assert.equal(steppedMax(10, -1), 10);
});

test("storeConf writes off and the cap as tide clipboard store reads them", () => {
    assert.match(storeConf({ history: false, maxItems: 50 }), /\nhistory=off\nmax_items=50\n$/);
    assert.equal(historySummary({ history: false, maxItems: 50 }), "Off: new copies aren't kept");
    assert.equal(historySummary(DEFAULTS), "Keeps the newest 200 copies");
});
