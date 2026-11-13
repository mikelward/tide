// Tests for keymaps.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PRESETS, PRESET_NAMES } from "./keymaps.mjs";
import { keysId, recordedKeys } from "./keys.mjs";

// conf's binding names (config/hypr/hyprland.lua's bind() calls), which
// a preset may name.
const NAMES = new Set([
    "terminal", "terminal_on_workstation", "browser", "browser_third", "browser_second", "headphones",
    "audio_profile", "chat", "calendar", "home_folder", "irc", "meet", "notepad", "remote_desktop", "music",
    "files", "launcher", "next_keyboard_layout", "notifications", "clipboard", "fill", "characters", "close",
    "minimize", "lock", "keep_awake", "presenter", "quit", "next_layout", "previous_layout", "monocle",
    "grow_master", "shrink_master", "add_master", "remove_master", "swap_master", "focus_down", "focus_up",
    "move_down", "move_up", "maximize", "fullscreen", "restore", "float", "floating_rule", "resize_mode",
    "previous_workspace", "next_workspace", "move_to_previous_workspace", "move_to_next_workspace",
    "focus_left", "focus_right", "move_left", "move_right", "home_or_back", "home", "last_other_workspace", "last_layout",
    "go_to_workspace", "move_to_workspace", "attention", "screenshot", "screenshot_window", "screenshot_region",
    "mute_microphone", "reload",
]);

test("every preset is listed once, tide's first", () => {
    assert.deepEqual(PRESET_NAMES.slice().sort(), Object.keys(PRESETS).sort());
    assert.equal(PRESET_NAMES[0], "tide");
    assert.deepEqual(PRESETS.tide.keys, {});
});

for (const name of PRESET_NAMES) {
    test(`${name}'s keys name only conf's bindings, each keys a recording could make, none twice`, () => {
        const seen = new Map();
        for (const [binding, keys] of Object.entries(PRESETS[name].keys)) {
            assert.ok(NAMES.has(binding), `${binding} is one of conf's`);
            assert.ok(keys.length > 0, `${binding} has keys`);
            for (const k of keys) {
                const id = keysId(k);
                assert.ok(!seen.has(id), `${id} is both ${seen.get(id)} and ${binding}`);
                seen.set(id, binding);
                // Super+0…9 stay the workspaces.
                assert.ok(!/^Super(\+Shift)?\+\d$/.test(id), `${id} is a workspace's`);
                assert.match(k, /^(SUPER|CTRL|ALT|SHIFT)( \+ (CTRL|ALT|SHIFT))* \+ [A-Za-z0-9_]+$/, k);
            }
        }
    });
}

test("a preset's keys are written as a recording writes them", () => {
    // Super+Shift+Return, as a press records it.
    assert.equal(recordedKeys(0x01000004, 0x10000000 | 0x02000000).keys, PRESETS.dwm.keys.terminal[0]);
});

test("each preset reloads on the key its window manager reloads or restarts on", () => {
    assert.deepEqual(PRESETS.i3.keys.reload, ["SUPER + SHIFT + C"]);
    assert.deepEqual(PRESETS.sway.keys.reload, ["SUPER + SHIFT + C"]);
    assert.deepEqual(PRESETS.xmonad.keys.reload, ["SUPER + Q"]);
    assert.deepEqual(PRESETS.bspwm.keys.reload, ["SUPER + ALT + R"]);
    assert.equal(PRESETS.dwm.keys.reload, undefined, "dwm has none, so tide's key stays");
});
