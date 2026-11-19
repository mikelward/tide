// Tests for tipsize.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { tipShown } from "./tipsize.mjs";

test("a popup waits for its size to be worked out for its text", () => {
    const title = "Claude Code - Google Chrome";
    assert.equal(tipShown(title, ""), false, "the text has just come in");
    assert.equal(tipShown(title, title), true, "a turn later, sized for it");
});

test("a popup whose text changes as it shows goes until it's sized again", () => {
    assert.equal(tipShown("Volume 41%", "Volume 40%"), false);
    assert.equal(tipShown("Volume 41%", "Volume 41%"), true);
});

test("with no text there's no popup", () => {
    assert.equal(tipShown("", ""), false);
    assert.equal(tipShown(undefined, undefined), false);
});
