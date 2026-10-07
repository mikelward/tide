// Tests for input.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    LADDERS, SECTIONS, connectedDevices, deviceKind, deviceSection, listedDevices, deviceSettingError, deviceShown, formatValue, hasOwn, inputLua, isText, loadInput,
    pairError, parseInput, parseValue, settingError, shown, stepped, targetLabel, targets, withDeviceSetting, withSetting, withoutDevice,
} from "./input.mjs";

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

test("a pointer is a touchpad when its name says so, else a mouse, as conf's apply-input.sh decides", () => {
    assert.equal(deviceKind("synps/2-synaptics-touchpad"), "touchpad");
    assert.equal(deviceKind("apple-magic-trackpad"), "touchpad");
    assert.equal(deviceKind("elan0670:00-04f3:3150-touchpad"), "touchpad");
    assert.equal(deviceKind("logitech-usb-receiver"), "mouse");
    assert.equal(deviceKind("tpps/2-elan-trackpoint"), "mouse");
});

test("a device takes its kind's settings, named for it", () => {
    assert.deepEqual(parseInput('{"devices": {"logitech-usb-receiver": {"speed": 0.5}, "synps/2-synaptics-touchpad": {"tapToClick": false}}}'), {
        settings: { devices: { "logitech-usb-receiver": { speed: 0.5 }, "synps/2-synaptics-touchpad": { tapToClick: false } } },
    });
    assert.match(parseInput('{"devices": {"logitech-usb-receiver": {"tapToClick": false}}}').error,
        /^devices\.logitech-usb-receiver: unknown setting "mouse\.tapToClick"/, "a mouse has no tap to click");
    assert.match(parseInput('{"devices": {"trackball": {"speed": 3}}}').error, /^devices\.trackball\.speed must be from -1 to 1/);
    assert.match(parseInput('{"devices": {"bad\\"name": {}}}').error, /^devices: "bad"name" isn't a name/, "nothing that needs escaping reaches Lua");
    assert.match(parseInput('{"devices": {"__proto__": {"speed": 0}}}').error, /^devices: "__proto__" isn't a name/);
    assert.match(parseInput('{"devices": []}').error, /^devices must be an object/);
    assert.match(parseInput('{"devices": {"trackball": 1}}').error, /^devices\.trackball must be an object/);
    assert.equal(deviceSettingError("trackball", "leftHanded", false), "");
});

test("each file's devices merge key by key, and a device shows its own setting, else its kind's", () => {
    const { input, errors } = loadInput(
        '{"mouse": {"speed": -0.5}, "devices": {"trackball": {"speed": 0.25, "leftHanded": false}}}',
        '{"devices": {"trackball": {"speed": 0.75}, "constructor": {"speed": 0}}}');
    assert.deepEqual(errors, []);
    assert.deepEqual(input.devices.trackball, { speed: 0.75, leftHanded: false });
    assert.equal(deviceShown(input, "trackball", "speed"), 0.75);
    assert.equal(deviceShown(input, "trackball", "scrollSpeed"), 3, "conf's, through every mouse");
    assert.equal(deviceShown(input, "other-mouse", "speed"), -0.5, "every mouse's");
    assert.equal(deviceShown(input, "toString", "speed"), -0.5, "a name every object has is just a device without settings");
    assert.equal(hasOwn(input, "trackball"), true);
    assert.equal(hasOwn(input, "other-mouse"), false);
});

test("a device's own settings reach hyprland.lua under its name, and none means no devices table", () => {
    const text = inputLua({ devices: { "synps/2-synaptics-touchpad": { tapToClick: false, speed: -0.25 }, trackball: { leftHanded: false }, empty: {} } });
    assert.ok(text.endsWith([
        "    keyboard = {},",
        "    devices = {",
        '        ["synps/2-synaptics-touchpad"] = { sensitivity = -0.25, tap_to_click = false },',
        '        ["trackball"] = { left_handed = false },',
        "    },",
        "}",
        "",
    ].join("\n")), text);
    assert.ok(!inputLua({ devices: {} }).includes("devices"));
});

test("a device's own setting is set and cleared in the local file, keeping the rest", () => {
    let r = withDeviceSetting('{"mouse": {"speed": 0}}', "trackball", "leftHanded", false);
    assert.equal(r.text, '{\n  "mouse": {\n    "speed": 0\n  },\n  "devices": {\n    "trackball": {\n      "leftHanded": false\n    }\n  }\n}\n');
    r = withDeviceSetting(r.text, "trackball", "speed", 0.5);
    assert.deepEqual(JSON.parse(r.text).devices.trackball, { speed: 0.5, leftHanded: false }, "in the page's order");
    r = withDeviceSetting(r.text, "trackball", "speed", undefined);
    assert.deepEqual(JSON.parse(r.text).devices.trackball, { leftHanded: false });
    r = withDeviceSetting(r.text, "trackball", "leftHanded", undefined);
    assert.deepEqual(JSON.parse(r.text), { mouse: { speed: 0 } }, "a device with nothing of its own is gone");
    assert.match(withDeviceSetting(null, "trackball", "tapToClick", true).error, /unknown setting "mouse\.tapToClick"/);
    assert.match(withDeviceSetting(null, "bad\\name", "speed", undefined).error, /^devices: "bad\\name" isn't/);
    assert.match(withDeviceSetting('{"mouse": ', "trackball", "speed", 0).error, /^input\.local\.json: line 1:/);
});

test("a device's own settings are cleared all at once", () => {
    const r = withoutDevice('{"devices": {"trackball": {"speed": 0.5}, "other": {"speed": 0}}}', "trackball");
    assert.deepEqual(JSON.parse(r.text), { devices: { other: { speed: 0 } } });
    assert.deepEqual(JSON.parse(withoutDevice(null, "trackball").text), {});
});

test("a keyboard by name takes a keyboard's settings, beside a mouse's under the same name", () => {
    assert.equal(deviceSection("logitech-usb-receiver", "layout"), "keyboard");
    assert.equal(deviceSection("logitech-usb-receiver", "speed"), "mouse");
    assert.equal(deviceSection("synps/2-synaptics-touchpad", "tapToClick"), "touchpad");
    assert.deepEqual(parseInput('{"devices": {"logitech-usb-receiver": {"speed": 0.5, "layout": "gb", "repeatRate": 40}}}'), {
        settings: { devices: { "logitech-usb-receiver": { speed: 0.5, layout: "gb", repeatRate: 40 } } },
    });
    assert.match(parseInput('{"devices": {"at-keyboard": {"layout": "us de"}}}').error, /^devices\.at-keyboard\.layout must be up to four XKB layouts/);
    assert.match(parseInput('{"devices": {"at-keyboard": {"repeatDelay": 5}}}').error, /^devices\.at-keyboard\.repeatDelay must be a whole number/);

    const { input, errors } = loadInput('{"keyboard": {"layout": "us,de", "variant": "dvorak,"}}',
        '{"devices": {"logitech-usb-receiver": {"speed": 0.5, "layout": "gb", "variant": ""}}}');
    assert.deepEqual(errors, []);
    assert.equal(deviceShown(input, "logitech-usb-receiver", "layout"), "gb");
    assert.equal(deviceShown(input, "logitech-usb-receiver", "repeatRate"), 25, "conf's, through every keyboard");
    assert.equal(deviceShown(input, "at-keyboard", "variant"), "dvorak,", "every keyboard's");
    assert.equal(hasOwn(input, "logitech-usb-receiver", "keyboard"), true);
    assert.equal(hasOwn(input, "logitech-usb-receiver", "mouse"), true);
    assert.equal(hasOwn(input, "logitech-usb-receiver", "touchpad"), false);
    assert.equal(hasOwn(input, "logitech-usb-receiver"), true);

    const text = inputLua(input);
    assert.ok(text.includes('        ["logitech-usb-receiver"] = { sensitivity = 0.5, kb_layout = "gb", kb_variant = "" },\n'), text);
});

test("a keyboard's own layouts and variants pair up, with every keyboard's where it has none of its own", () => {
    assert.equal(pairError({ keyboard: { layout: "us,de" }, devices: { kb: { variant: "dvorak," } } }), "");
    assert.equal(pairError({ keyboard: { layout: "us,de" }, devices: { mouse: { speed: 0 } } }), "", "a device with no layout of its own");
    assert.match(pairError({ keyboard: { layout: "us,de", variant: "dvorak," }, devices: { kb: { layout: "gb" } } }),
        /^devices\.kb\.variant has 2 variants for 1 layout;/, "every keyboard's two variants for its own one layout");
    let r = loadInput('{"keyboard": {"layout": "us,de", "variant": "dvorak,"}}', '{"devices": {"kb": {"layout": "us,de,fr"}}}');
    assert.deepEqual(r.errors, ["input.local.json: devices.kb.variant has 2 variants for 3 layouts; it takes one, or one for each layout"]);
    r = loadInput('{"devices": {"aaa": {"layout": "us,de", "variant": "a,b,c"}}}', '{"devices": {"zzz": {"layout": "gb"}}}');
    assert.deepEqual(r.errors, ["input.json: devices.aaa.variant has 3 variants for 2 layouts; it takes one, or one for each layout"],
        "the file that set that keyboard's, not the last to set any keyboard's");
    r = loadInput('{"devices": {"kb": {"variant": "a,b"}}}', '{"keyboard": {"layout": "us,de,fr"}}');
    assert.deepEqual(r.errors, ["input.local.json: devices.kb.variant has 2 variants for 3 layouts; it takes one, or one for each layout"],
        "every keyboard's layout, which it pairs its own variant with");
    r = loadInput('{"keyboard": {"layout": "us,de", "variant": "a,b,c"}, "devices": {"kb": {"layout": "gb", "variant": "x,y"}}}', null);
    assert.equal(r.errors.length, 2, "each keyboard that doesn't pair up");
    assert.match(withDeviceSetting(null, "kb", "layout", "gb", '{"keyboard": {"layout": "us,de", "variant": "dvorak,"}}').error,
        /^devices\.kb\.variant has 2 variants for 1 layout;/, "refused as it's set");
    assert.equal(withDeviceSetting(null, "kb", "layout", "gb,fr", '{"keyboard": {"layout": "us,de", "variant": "dvorak,"}}').error, undefined);
    r = withSetting('{"devices": {"kb": {"variant": "dvorak,"}}}', "keyboard", "layout", "us");
    assert.match(r.error, /^devices\.kb\.variant has 2 variants for 1 layout;/, "every keyboard's layout, which a keyboard's own variant pairs with");
});

test("a receiver's keyboard settings are cleared apart from its mouse's", () => {
    const text = '{"devices": {"logitech-usb-receiver": {"speed": 0.5, "layout": "gb"}}}';
    assert.deepEqual(JSON.parse(withoutDevice(text, "logitech-usb-receiver", "keyboard").text),
        { devices: { "logitech-usb-receiver": { speed: 0.5 } } });
    assert.deepEqual(JSON.parse(withoutDevice(text, "logitech-usb-receiver", "mouse").text),
        { devices: { "logitech-usb-receiver": { layout: "gb" } } });
    assert.deepEqual(JSON.parse(withoutDevice('{"devices": {"kb": {"layout": "gb"}}}', "kb", "keyboard").text), {}, "nothing left, no device");
    assert.deepEqual(JSON.parse(withoutDevice(text, "logitech-usb-receiver").text), {}, "all of it, as IPC's clearDevice");
});

test("a page sets every device of its kind, or one by name, connected or with settings of its own", () => {
    const connected = [{ name: "logitech-usb-receiver", kind: "mouse" }, { name: "synps/2-synaptics-touchpad", kind: "touchpad" }];
    const input = { devices: { trackball: { speed: 0 }, "apple-magic-trackpad": { speed: 0 } } };
    assert.deepEqual(targets(input, connected, "mouse"), ["", "logitech-usb-receiver", "trackball"]);
    assert.deepEqual(targets(input, connected, "touchpad"), ["", "apple-magic-trackpad", "synps/2-synaptics-touchpad"]);
    assert.deepEqual(targets({}, [], "mouse"), [""]);
    assert.deepEqual(targets(input, connected.concat([{ name: "trackball", kind: "mouse" }]), "mouse"), ["", "logitech-usb-receiver", "trackball"], "once each");
    assert.equal(targetLabel("mouse", ""), "Every mouse");
    assert.equal(targetLabel("touchpad", ""), "Every touchpad");
    assert.equal(targetLabel("mouse", "trackball"), "trackball");
    assert.equal(targetLabel("keyboard", ""), "Every keyboard");
    const keyboards = [{ name: "at-keyboard", kind: "keyboard" }, { name: "logitech-usb-receiver", kind: "mouse" }];
    const own = { devices: { "logitech-usb-receiver": { layout: "gb" }, trackball: { speed: 0 } } };
    assert.deepEqual(targets(own, keyboards, "keyboard"), ["", "at-keyboard", "logitech-usb-receiver"], "a receiver with a keyboard's settings");
    assert.deepEqual(targets(own, keyboards, "mouse"), ["", "logitech-usb-receiver", "trackball"]);
    assert.deepEqual(targets({ devices: { "logitech-usb-receiver": { layout: "gb" } } }, [], "mouse"), [""], "a keyboard's settings don't make it a mouse to set");
});

test("hyprctl's devices are read for their mice, touchpads and keyboards", () => {
    const json = JSON.stringify({
        mice: [
            { address: "0x1", name: "logitech-usb-receiver", defaultSpeed: 0, scrollFactor: -1 },
            { address: "0x2", name: "synps/2-synaptics-touchpad", defaultSpeed: 0, scrollFactor: -1 },
            { address: "0x3", name: 'bad"name' },
            { address: "0x4" },
        ],
        keyboards: [{ name: "at-translated-set-2-keyboard" }, { name: "logitech-usb-receiver" }, { name: 'bad"name' }],
    });
    assert.deepEqual(connectedDevices(json), {
        devices: [
            { name: "logitech-usb-receiver", kind: "mouse" }, { name: "synps/2-synaptics-touchpad", kind: "touchpad" },
            { name: "at-translated-set-2-keyboard", kind: "keyboard" }, { name: "logitech-usb-receiver", kind: "keyboard" },
        ],
    });
    assert.match(connectedDevices("{").error, /^hyprctl devices -j: line 1:/);
    assert.match(connectedDevices("{}").error, /no list of mice/);
    assert.match(connectedDevices('{"mice": []}').error, /no list of keyboards/);
});

test("a listing that fails, or doesn't read, names no devices, not the last list's", () => {
    const json = JSON.stringify({ mice: [{ name: "trackball" }], keyboards: [] });
    assert.deepEqual(listedDevices(false, json), { devices: [{ name: "trackball", kind: "mouse" }], error: "" });
    assert.deepEqual(listedDevices(true, json), { devices: [], error: "" }, "a failed run's output isn't read");
    const bad = listedDevices(false, "{");
    assert.deepEqual(bad.devices, []);
    assert.match(bad.error, /^hyprctl devices -j: line 1:/);
});
