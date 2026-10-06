// Tests for input.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LADDERS, SECTIONS, formatValue, inputLua, loadInput, parseInput, settingError, shown, stepped, withSetting } from "./input.mjs";

test("mice and touchpads have their own settings, in Hyprland's option names", () => {
    assert.deepEqual(SECTIONS.mouse.map(s => [s.key, s.option]), [
        ["speed", "sensitivity"], ["scrollSpeed", "scroll_factor"], ["naturalScroll", "natural_scroll"], ["leftHanded", "left_handed"],
    ]);
    assert.deepEqual(SECTIONS.touchpad.map(s => s.key), [
        "speed", "scrollSpeed", "naturalScroll", "leftHanded", "tapToClick", "disableWhileTyping",
    ]);
});

test("what's shown until set is conf's config: a left-handed mouse, a right-handed touchpad", () => {
    assert.equal(shown({}, "mouse", "leftHanded"), true);
    assert.equal(shown({}, "touchpad", "leftHanded"), false);
    assert.equal(shown({}, "mouse", "scrollSpeed"), 3);
    assert.equal(shown({}, "touchpad", "scrollSpeed"), 1);
    assert.equal(shown({ mouse: { leftHanded: false } }, "mouse", "leftHanded"), false);
});

test("a file sets any settings of either section", () => {
    assert.deepEqual(parseInput('{"mouse": {"speed": -0.5}, "touchpad": {"tapToClick": false}}'), {
        settings: { mouse: { speed: -0.5 }, touchpad: { tapToClick: false } },
    });
    assert.deepEqual(parseInput("{}"), { settings: {} });
});

test("a bad setting is an error naming it", () => {
    assert.match(parseInput('{"mouse": {"speed": 2}}').error, /^mouse\.speed must be from -1 to 1/);
    assert.match(parseInput('{"mouse": {"scrollSpeed": 0}}').error, /^mouse\.scrollSpeed must be above 0/);
    assert.match(parseInput('{"mouse": {"leftHanded": "yes"}}').error, /^mouse\.leftHanded must be true or false/);
    assert.match(parseInput('{"mouse": {"tapToClick": true}}').error, /^unknown setting "mouse\.tapToClick"/);
    assert.match(parseInput('{"trackball": {}}').error, /^unknown section "trackball"/);
    assert.match(parseInput('{"mouse": 1}').error, /^mouse must be an object/);
    assert.match(parseInput("[]").error, /^expected an object/);
    assert.match(parseInput('{"mouse": ').error, /^line 1:/);
    assert.equal(settingError("mouse", "speed", 0.5), "");
});

test("the local file merges key by key over the shared one", () => {
    const result = loadInput('{"mouse": {"speed": 0.5, "leftHanded": true}}', '{"mouse": {"speed": -0.25}, "touchpad": {"leftHanded": false}}');
    assert.deepEqual(result, {
        input: { mouse: { speed: -0.25, leftHanded: true }, touchpad: { leftHanded: false } },
        errors: [],
    });
    assert.deepEqual(loadInput(null, null), { input: {}, errors: [] });
});

test("a file that fails keeps the last good settings, and every bad file is named", () => {
    const lastGood = { mouse: { speed: 0 } };
    const result = loadInput('{"mouse": {"speed": 9}}', '{"oops": {}}', lastGood);
    assert.equal(result.input, lastGood);
    assert.equal(result.errors.length, 2);
    assert.match(result.errors[0], /^input\.json: mouse\.speed/);
    assert.match(result.errors[1], /^input\.local\.json: unknown section "oops"/);
});

test("only what's set reaches hyprland.lua, in Hyprland's option names", () => {
    assert.equal(inputLua({}), [
        "-- Written by tide from input.json and input.local.json (tide SPEC.md §16).",
        "-- Change those, or the Mouse and Touchpad pages of tide's settings, not",
        "-- this file. Only what's set is here; conf's hyprland.lua has the rest.",
        "return {",
        "    mouse = {},",
        "    touchpad = {},",
        "}",
        "",
    ].join("\n"));
    const text = inputLua({ mouse: { leftHanded: true, speed: -0.5 }, touchpad: { scrollSpeed: 0.75, tapToClick: false } });
    assert.ok(text.includes("    mouse = { sensitivity = -0.5, left_handed = true },\n"), text);
    assert.ok(text.includes("    touchpad = { scroll_factor = 0.75, tap_to_click = false },\n"), text);
});

test("setting one keeps the rest of the local file, in the page's order", () => {
    assert.deepEqual(withSetting('{"touchpad": {"tapToClick": false}}', "mouse", "leftHanded", false), {
        text: '{\n  "mouse": {\n    "leftHanded": false\n  },\n  "touchpad": {\n    "tapToClick": false\n  }\n}\n',
    });
    assert.deepEqual(withSetting('{"mouse": {"leftHanded": true}}', "mouse", "speed", 0.25), {
        text: '{\n  "mouse": {\n    "speed": 0.25,\n    "leftHanded": true\n  }\n}\n',
    });
    assert.deepEqual(withSetting(null, "touchpad", "speed", 0), { text: '{\n  "touchpad": {\n    "speed": 0\n  }\n}\n' });
});

test("a bad setting, or a local file that doesn't parse, writes nothing", () => {
    assert.match(withSetting(null, "mouse", "speed", 5).error, /^mouse\.speed must be from -1 to 1/);
    assert.match(withSetting(null, "mouse", "tapToClick", true).error, /^unknown setting/);
    assert.match(withSetting('{"mouse": ', "mouse", "speed", 0).error, /^input\.local\.json: line 1:/);
});

test("− and + step along each ladder, and stop at its ends", () => {
    assert.equal(stepped("speed", 0, 1), 0.25);
    assert.equal(stepped("speed", 1, 1), 1);
    assert.equal(stepped("speed", -1, -1), -1);
    assert.equal(stepped("speed", 0.3, -1), 0.25);
    assert.equal(stepped("scroll", 3, 1), 4);
    assert.equal(stepped("scroll", 0.25, -1), 0.25);
    assert.equal(stepped("scroll", 2.5, 1), 3);
    assert.equal(stepped("toggle", true, 1), true, "a switch doesn't step");
});

test("every default is on its ladder", () => {
    for (const section of Object.keys(SECTIONS)) {
        for (const s of SECTIONS[section]) {
            if (s.kind !== "toggle") {
                assert.ok(LADDERS[s.kind].includes(s.shown), `${section}.${s.key}`);
            }
        }
    }
});

test("values read as the page shows them", () => {
    assert.equal(formatValue("speed", 0.5), "+0.50");
    assert.equal(formatValue("speed", -0.25), "−0.25");
    assert.equal(formatValue("speed", 0), "0.00");
    assert.equal(formatValue("scroll", 1.5), "1.5×");
    assert.equal(formatValue("toggle", true), "On");
});

test("a section named after something every object has is unknown, not a crash", () => {
    assert.match(parseInput('{"constructor": {"speed": 1}}').error, /^unknown section "constructor"/);
    assert.match(parseInput('{"constructor": {}}').error, /^unknown section "constructor"/);
    assert.match(parseInput('{"__proto__": {"speed": 1}}').error, /^unknown section "__proto__"/);
    assert.match(settingError("toString", "speed", 1), /^unknown section "toString"/);
    assert.match(withSetting(null, "constructor", "speed", 1).error, /^unknown section "constructor"/);
});
