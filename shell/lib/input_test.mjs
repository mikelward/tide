// Tests for input.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LADDERS, SECTIONS, formatValue, inputLua, isText, loadInput, pairError, parseInput, parseValue, settingError, shown, stepped, withSetting } from "./input.mjs";

test("mice and touchpads have their own settings, in Hyprland's option names", () => {
    assert.deepEqual(SECTIONS.mouse.map(s => [s.key, s.option]), [
        ["speed", "sensitivity"], ["scrollSpeed", "scroll_factor"], ["naturalScroll", "natural_scroll"], ["leftHanded", "left_handed"],
    ]);
    assert.deepEqual(SECTIONS.touchpad.map(s => s.key), [
        "speed", "scrollSpeed", "naturalScroll", "leftHanded", "tapToClick", "disableWhileTyping",
    ]);
    assert.deepEqual(SECTIONS.keyboard.map(s => [s.key, s.option]), [
        ["layout", "kb_layout"], ["variant", "kb_variant"], ["repeatDelay", "repeat_delay"], ["repeatRate", "repeat_rate"],
    ]);
});

test("what's shown until set is conf's config: a left-handed mouse, a right-handed touchpad", () => {
    assert.equal(shown({}, "mouse", "leftHanded"), true);
    assert.equal(shown({}, "touchpad", "leftHanded"), false);
    assert.equal(shown({}, "mouse", "scrollSpeed"), 3);
    assert.equal(shown({}, "touchpad", "scrollSpeed"), 1);
    assert.equal(shown({ mouse: { leftHanded: false } }, "mouse", "leftHanded"), false);
    assert.equal(shown({}, "keyboard", "layout"), "us");
    assert.equal(shown({}, "keyboard", "variant"), "dvorak");
    assert.equal(shown({}, "keyboard", "repeatDelay"), 600);
    assert.equal(shown({ keyboard: { variant: "" } }, "keyboard", "variant"), "", "no variant is a setting");
});

test("a keyboard's layouts are XKB names, up to four, each with a variant or none", () => {
    assert.equal(settingError("keyboard", "layout", "us"), "");
    assert.equal(settingError("keyboard", "layout", "us,de,fr,gb"), "");
    assert.match(settingError("keyboard", "layout", "us,de,fr,gb,it"), /^keyboard\.layout must be up to four XKB layouts/);
    assert.match(settingError("keyboard", "layout", ""), /^keyboard\.layout must be/);
    assert.match(settingError("keyboard", "layout", "us,"), /^keyboard\.layout must be/);
    assert.match(settingError("keyboard", "layout", 'us" .. os.exit() .. "'), /^keyboard\.layout must be/, "nothing that isn't a name reaches Lua");
    assert.match(settingError("keyboard", "layout", 1), /^keyboard\.layout must be/);
    assert.equal(settingError("keyboard", "variant", "dvorak"), "");
    assert.equal(settingError("keyboard", "variant", ""), "");
    assert.equal(settingError("keyboard", "variant", "dvorak,"), "");
    assert.equal(settingError("keyboard", "variant", "dvorak-intl,nodeadkeys"), "");
    assert.match(settingError("keyboard", "variant", "dvorak\n"), /^keyboard\.variant must be/);
});

test("a keyboard takes one variant, or one for each layout", () => {
    assert.equal(pairError({}), "", "conf's us and dvorak pair");
    assert.equal(pairError({ keyboard: { layout: "us,de,fr" } }), "", "one variant");
    assert.equal(pairError({ keyboard: { layout: "us,de", variant: "" } }), "", "one, none");
    assert.equal(pairError({ keyboard: { layout: "us,de", variant: "dvorak," } }), "", "one each");
    assert.equal(pairError({ keyboard: { layout: "us,de,fr", variant: "dvorak,nodeadkeys" } }),
        "keyboard.variant has 2 variants for 3 layouts; it takes one, or one for each layout");
    assert.match(pairError({ keyboard: { variant: "dvorak,nodeadkeys" } }), /2 variants for 1 layout;/, "against conf's layout");
});

test("layouts and variants that don't pair up, across both files, are an error at load naming the last to set them", () => {
    const lastGood = { mouse: { speed: 0 } };
    const result = loadInput('{"keyboard": {"layout": "us,de,fr"}}', '{"keyboard": {"variant": "dvorak,nodeadkeys"}}', lastGood);
    assert.equal(result.input, lastGood);
    assert.deepEqual(result.errors, ["input.local.json: keyboard.variant has 2 variants for 3 layouts; it takes one, or one for each layout"]);
    assert.match(loadInput('{"keyboard": {"variant": "a,b"}}', '{"mouse": {"speed": 0}}').errors[0], /^input\.json: keyboard\.variant/);
    assert.deepEqual(loadInput('{"keyboard": {"layout": "us,de"}}', '{"keyboard": {"variant": "dvorak,"}}').errors, []);
});

test("a keyboard change that wouldn't pair up with the other files' is refused", () => {
    assert.match(withSetting('{"keyboard": {"layout": "us,de"}}', "keyboard", "variant", "a,b,c").error, /^keyboard\.variant has 3 variants for 2 layouts/);
    assert.match(withSetting(null, "keyboard", "layout", "us,de,fr", '{"keyboard": {"variant": "a,b"}}').error, /^keyboard\.variant has 2 variants for 3 layouts/);
    assert.ok(withSetting(null, "keyboard", "variant", "dvorak,nodeadkeys", '{"keyboard": {"layout": "us,de"}}').text, "the shared file's layouts count");
    assert.ok(withSetting(null, "mouse", "speed", 0, '{"keyboard": {"variant": "a,b"}}').text, "only a keyboard change is checked");
    assert.ok(withSetting(null, "keyboard", "layout", "us,de", '{"keyboard": ').text, "a shared file that doesn't parse is load's to report");
});

test("a key repeats after a whole number of milliseconds, a whole number of times a second", () => {
    assert.equal(settingError("keyboard", "repeatDelay", 250), "");
    assert.match(settingError("keyboard", "repeatDelay", 250.5), /^keyboard\.repeatDelay must be a whole number of milliseconds/);
    assert.match(settingError("keyboard", "repeatDelay", 50), /^keyboard\.repeatDelay must be/);
    assert.equal(settingError("keyboard", "repeatRate", 40), "");
    assert.match(settingError("keyboard", "repeatRate", 0), /^keyboard\.repeatRate must be a whole number a second/);
    assert.match(settingError("keyboard", "repeatRate", "fast"), /^keyboard\.repeatRate must be a number/);
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
        "-- Change those, or the Mouse, Touchpad and Keyboard pages of tide's",
        "-- settings, not this file. Only what's set is here; conf's hyprland.lua",
        "-- has the rest.",
        "return {",
        "    mouse = {},",
        "    touchpad = {},",
        "    keyboard = {},",
        "}",
        "",
    ].join("\n"));
    const text = inputLua({ mouse: { leftHanded: true, speed: -0.5 }, touchpad: { scrollSpeed: 0.75, tapToClick: false } });
    assert.ok(text.includes("    mouse = { sensitivity = -0.5, left_handed = true },\n"), text);
    assert.ok(text.includes("    touchpad = { scroll_factor = 0.75, tap_to_click = false },\n"), text);
    const keys = inputLua({ keyboard: { repeatRate: 40, layout: "us,de", variant: "" } });
    assert.ok(keys.includes('    keyboard = { kb_layout = "us,de", kb_variant = "", repeat_rate = 40 },\n'), keys);
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
    assert.equal(stepped("delay", 600, -1), 500);
    assert.equal(stepped("rate", 25, 1), 30);
    assert.equal(stepped("layout", "us", 1), "us", "nor does a name");
});

test("every default is on its ladder", () => {
    for (const section of Object.keys(SECTIONS)) {
        for (const s of SECTIONS[section]) {
            if (s.kind !== "toggle" && !isText(s.kind)) {
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
    assert.equal(formatValue("delay", 600), "600 ms");
    assert.equal(formatValue("rate", 25), "25/s");
    assert.equal(formatValue("layout", "us,de"), "us,de");
    assert.equal(formatValue("variant", ""), "none");
});

test("a value from qs ipc is typed by its setting", () => {
    assert.equal(parseValue("keyboard", "layout", "us,de"), "us,de");
    assert.equal(parseValue("keyboard", "variant", ""), "", "an empty variant is none, not a missing number");
    assert.equal(parseValue("keyboard", "variant", "true"), "true", "a name is never a switch");
    assert.equal(parseValue("keyboard", "repeatDelay", "300"), 300);
    assert.equal(parseValue("mouse", "leftHanded", "false"), false);
    assert.equal(parseValue("mouse", "speed", "-0.5"), -0.5);
    assert.ok(Number.isNaN(parseValue("mouse", "speed", "")));
    assert.ok(Number.isNaN(parseValue("mouse", "speed", "fast")));
    assert.ok(Number.isNaN(parseValue("trackball", "speed", " ")), "an unknown setting isn't a name either");
});

test("a keyboard setting keeps the rest of the local file", () => {
    assert.deepEqual(withSetting('{"mouse": {"speed": 0.5}}', "keyboard", "layout", "us,de"), {
        text: '{\n  "mouse": {\n    "speed": 0.5\n  },\n  "keyboard": {\n    "layout": "us,de"\n  }\n}\n',
    });
    assert.match(withSetting(null, "keyboard", "layout", "us;de").error, /^keyboard\.layout must be/);
});

test("a section named after something every object has is unknown, not a crash", () => {
    assert.match(parseInput('{"constructor": {"speed": 1}}').error, /^unknown section "constructor"/);
    assert.match(parseInput('{"constructor": {}}').error, /^unknown section "constructor"/);
    assert.match(parseInput('{"__proto__": {"speed": 1}}').error, /^unknown section "__proto__"/);
    assert.match(settingError("toString", "speed", 1), /^unknown section "toString"/);
    assert.match(withSetting(null, "constructor", "speed", 1).error, /^unknown section "constructor"/);
});
