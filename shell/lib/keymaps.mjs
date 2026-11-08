// Other tiling window managers' default keys, for the Keyboard page's
// Start from (SPEC.md §16): each maps conf's binding names to the keys that
// window manager gives the same action, with Super as its modifier. A
// binding a preset doesn't name keeps tide's keys, unless the preset gives
// them to another, when it's off. What only the other window manager
// does (i3's split direction, dwm's tag views) is left out, and Super+0…9
// stay the workspaces, as they are in all of them.
//
// From each one's shipped config: dwm's config.def.h, i3's and sway's
// default config, xmonad's XMonad.Config, and bspwm's example sxhkdrc.

const S = k => `SUPER + ${k}`;
const SS = k => `SUPER + SHIFT + ${k}`;

export const PRESETS = Object.freeze({
    tide: Object.freeze({ label: "tide", keys: Object.freeze({}) }),
    dwm: Object.freeze({
        label: "dwm",
        keys: Object.freeze({
            launcher: [S("P")],
            terminal: [SS("Return")],
            focus_down: [S("J")],
            focus_up: [S("K")],
            add_master: [S("I")],
            remove_master: [S("D")],
            shrink_master: [S("H")],
            grow_master: [S("L")],
            swap_master: [S("Return")],
            home_or_back: [S("Tab")],
            close: [SS("C")],
            monocle: [S("M")],
            last_layout: [S("Space")],
            float: [SS("Space")],
            focus_left: [S("comma")],
            focus_right: [S("period")],
            move_left: [SS("comma")],
            move_right: [SS("period")],
            quit: [SS("Q")],
        }),
    }),
    i3: Object.freeze({
        label: "i3",
        keys: Object.freeze({
            terminal: [S("Return")],
            launcher: [S("D")],
            close: [SS("Q")],
            focus_left: [S("J"), S("Left")],
            focus_down: [S("K"), S("Down")],
            focus_up: [S("L"), S("Up")],
            focus_right: [S("semicolon"), S("Right")],
            move_left: [SS("J"), SS("Left")],
            move_down: [SS("K"), SS("Down")],
            move_up: [SS("L"), SS("Up")],
            move_right: [SS("semicolon"), SS("Right")],
            fullscreen: [S("F")],
            float: [SS("Space")],
            monocle: [S("W")],
            next_layout: [S("E")],
            resize_mode: [S("R")],
            quit: [SS("E")],
        }),
    }),
    sway: Object.freeze({
        label: "sway",
        keys: Object.freeze({
            terminal: [S("Return")],
            launcher: [S("D")],
            close: [SS("Q")],
            focus_left: [S("H"), S("Left")],
            focus_down: [S("J"), S("Down")],
            focus_up: [S("K"), S("Up")],
            focus_right: [S("L"), S("Right")],
            move_left: [SS("H"), SS("Left")],
            move_down: [SS("J"), SS("Down")],
            move_up: [SS("K"), SS("Up")],
            move_right: [SS("L"), SS("Right")],
            fullscreen: [S("F")],
            float: [SS("Space")],
            monocle: [S("W")],
            next_layout: [S("E")],
            resize_mode: [S("R")],
            quit: [SS("E")],
        }),
    }),
    xmonad: Object.freeze({
        label: "xmonad",
        keys: Object.freeze({
            terminal: [SS("Return")],
            launcher: [S("P")],
            close: [SS("C")],
            next_layout: [S("Space")],
            focus_down: [S("J")],
            focus_up: [S("K")],
            swap_master: [S("Return")],
            move_down: [SS("J")],
            move_up: [SS("K")],
            shrink_master: [S("H")],
            grow_master: [S("L")],
            float: [S("T")],
            add_master: [S("comma")],
            remove_master: [S("period")],
            quit: [SS("Q")],
        }),
    }),
    bspwm: Object.freeze({
        label: "bspwm",
        keys: Object.freeze({
            terminal: [S("Return")],
            launcher: [S("Space")],
            close: [S("W")],
            quit: [`SUPER + ALT + Q`],
            monocle: [S("M")],
            float: [S("S")],
            fullscreen: [S("F")],
            focus_left: [S("H")],
            focus_down: [S("J")],
            focus_up: [S("K")],
            focus_right: [S("L")],
            move_left: [SS("H")],
            move_down: [SS("J")],
            move_up: [SS("K")],
            move_right: [SS("L")],
            swap_master: [S("G")],
            previous_workspace: [S("bracketleft")],
            next_workspace: [S("bracketright")],
        }),
    }),
});

// The presets in the page's order.
export const PRESET_NAMES = Object.freeze(["tide", "dwm", "i3", "sway", "xmonad", "bspwm"]);
