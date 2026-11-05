// Tests for compositor.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { isTidewm, screenNamed } from "./compositor.mjs";

test("tidewm's session is the one naming tidewm", () => {
    assert.equal(isTidewm("tidewm:tide"), true);
    assert.equal(isTidewm("tide:tidewm"), true, "wherever it's named");
    assert.equal(isTidewm("tidewm"), true);
});

test("anything else is Hyprland's, the default", () => {
    assert.equal(isTidewm("tide:Hyprland"), false);
    assert.equal(isTidewm(""), false);
    assert.equal(isTidewm(undefined), false, "unset");
    assert.equal(isTidewm("tidewmx:tide"), false, "a name that only starts with it");
    assert.equal(isTidewm("TIDEWM:tide"), false, "names are matched as written, as bin/tide does");
});

const screens = [{ name: "DP-1" }, { name: "HDMI-A-1" }];

test("the focused screen is the one named as the focused monitor", () => {
    assert.equal(screenNamed(screens, "HDMI-A-1"), screens[1]);
});

test("no focused monitor, or one no screen shows, is no screen", () => {
    assert.equal(screenNamed(screens, ""), null);
    assert.equal(screenNamed(screens, null), null);
    assert.equal(screenNamed(screens, "DP-2"), null);
    assert.equal(screenNamed([], "DP-1"), null);
    assert.equal(screenNamed(undefined, "DP-1"), null, "before the screens are known");
});
