// Tests for frecency.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_ENTRIES, initial, parse, record, score, serialize } from "./frecency.mjs";

const DAY = 24 * 60 * 60 * 1000;
const now = 1000 * DAY;

test("running a row counts it and stamps the time", () => {
    let s = record(initial(), "app:kitty", now - DAY);
    s = record(s, "app:kitty", now);
    assert.deepEqual(s["app:kitty"], { count: 2, last: now });
    assert.equal(Object.isFrozen(s), true);
});

test("recent use outweighs the same use long ago", () => {
    const recent = { count: 3, last: now - DAY };
    const old = { count: 3, last: now - 60 * DAY };
    const ancient = { count: 3, last: now - 400 * DAY };
    assert.ok(score(recent, now) > score(old, now));
    assert.ok(score(old, now) > score(ancient, now));
    assert.ok(score(ancient, now) > 0);
    assert.equal(score(undefined, now), 0);
});

test("more use outweighs less, at the same age", () => {
    assert.ok(score({ count: 5, last: now }, now) > score({ count: 1, last: now }, now));
});

test("a clock that went back counts as now, not as the future", () => {
    assert.equal(score({ count: 1, last: now + DAY }, now), score({ count: 1, last: now }, now));
});

test("past the limit, the least used entries go", () => {
    let s = initial();
    for (let i = 0; i < MAX_ENTRIES; i++) {
        s = record(s, `app:${i}`, now - 100 * DAY);
    }
    s = record(s, "app:0", now);
    s = record(s, "app:new", now);
    assert.equal(Object.keys(s).length, MAX_ENTRIES);
    assert.ok("app:new" in s);
    assert.ok("app:0" in s);
});

test("what's saved reads back the same", () => {
    const s = record(record(initial(), "app:kitty", now), "quick:lock", now - DAY);
    const back = parse(serialize(s));
    assert.deepEqual(back.errors, []);
    assert.deepEqual(back.state, s);
});

test("a damaged file loses what's damaged and keeps the rest", () => {
    const text = JSON.stringify({
        version: 1,
        entries: {
            "app:kitty": { count: 2, last: now },
            "app:bad": { count: "two", last: now },
            "app:zero": { count: 0, last: now },
            "app:nolast": { count: 1 },
        },
    });
    const { state, errors } = parse(text);
    assert.deepEqual(Object.keys(state), ["app:kitty"]);
    assert.equal(errors.length, 3);
    assert.match(errors[0], /app:bad/);
});

test("a file that isn't the shape starts over, saying so", () => {
    for (const text of ["{", "[]", "null", '{"entries": []}', '{"entries": 3}']) {
        const { state, errors } = parse(text);
        assert.deepEqual(state, {});
        assert.equal(errors.length, 1, text);
    }
});
