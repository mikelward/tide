// Tests for layouts.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { SYMBOLS, defaultMode, parseAnnouncement, layoutSymbol } from "./layouts.mjs";

test("a workspace starts in threecol on an ultrawide work area, else tile", () => {
    assert.equal(defaultMode({ width: 3440, height: 1440 }, 36), "threecol");
    assert.equal(defaultMode({ width: 2560, height: 1440 }, 36), "tile");
    assert.equal(defaultMode({ width: 1920, height: 1080, scale: 1.25 }, 36), "tile");
    assert.equal(defaultMode({ width: 5120, height: 1440, scale: 1.5 }, 36), "threecol");
});

test("the bar's height counts against the work area, as the layout sees it", () => {
    // 2.09 as a whole monitor, 2.15 below a 36 px bar.
    assert.equal(defaultMode({ width: 2508, height: 1200 }, 0), "tile");
    assert.equal(defaultMode({ width: 2508, height: 1200 }, 36), "threecol");
});

test("a rotated monitor is measured as it's shown", () => {
    assert.equal(defaultMode({ width: 3440, height: 1440, transform: 1 }, 36), "tile");
    assert.equal(defaultMode({ width: 1440, height: 3440, transform: 3 }, 36), "threecol");
    assert.equal(defaultMode({ width: 3440, height: 1440, transform: 2 }, 36), "threecol");
});

test("a monitor with no size yet starts in tile", () => {
    assert.equal(defaultMode({ width: 0, height: 0 }, 36), "tile");
});

test("announcements name a workspace and a known mode", () => {
    assert.deepEqual(parseAnnouncement("tide-layout>>3,monocle"), { workspace: 3, mode: "monocle" });
    assert.deepEqual(parseAnnouncement("tide-layout>>-98,tile"), { workspace: -98, mode: "tile" });
    assert.equal(parseAnnouncement("tide-layout>>3,spiral"), null);
    assert.equal(parseAnnouncement("tide-layout>>three,tile"), null);
    assert.equal(parseAnnouncement("tide-layout>>3"), null);
    assert.equal(parseAnnouncement("something-else>>3,tile"), null);
    assert.equal(parseAnnouncement(undefined), null);
});

test("each mode shows its symbol, and monocle its hidden count", () => {
    for (const [mode, symbol] of Object.entries(SYMBOLS)) {
        assert.equal(layoutSymbol(mode, 1), symbol);
    }
    assert.equal(layoutSymbol("tile", 4), "[]=");
    assert.equal(layoutSymbol("monocle", 0), "[M]");
    assert.equal(layoutSymbol("monocle", 4), "[3]");
    assert.equal(layoutSymbol("spiral", 2), "");
});
