# tide layout for Hyprland

One Lua layout, `lua:tide`, for Hyprland 0.55 and later (the Lua
config). It keeps a mode per workspace:

| Mode | Symbol | Shape |
|---|---|---|
| `tile` | `[]=` | master left (55%), stack right |
| `threecol` | `\|M\|` | master centered (50%), stacks either side |
| `twocol` | `\|\|=` | two full-height masters side by side, stack right |
| `monocle` | `[M]` | every window fills the area |

A workspace starts in `threecol` when its work area is ultrawide (aspect
≥ 2.1) and in `tile` otherwise. In every mode a lone window follows the
single-window rule: 80% wide and centered from aspect 2.1, 60% from 3.2,
and full width below that. See SPEC.md §6 for the design.

- `geometry.lua` is the pure window geometry, with no Hyprland API.
- `direction.lua` is the pure rule for left and right between windows and
  monitors, also with no Hyprland API.
- `span.lua` is the pure model of a workspace spanning every monitor
  (SPEC.md §6.5): each monitor's part's name, what a switch shows, and
  where windows go when a monitor goes and comes back.
- `layout.lua` registers the layout and provides helpers for keybinds.
- `layout_test.lua` tests `geometry.lua` and `layout.lua`, the latter
  against a stub of `hl`; `direction_test.lua` tests `direction.lua`,
  and `span_test.lua` tests `span.lua`.

## Using it

`make install` copies the modules to `~/.config/hypr/tide/`. Then,
in `hyprland.lua`:

```lua
local qs = dofile(os.getenv("HOME") .. "/.config/hypr/tide/layout.lua")
qs.setup({})  -- override any key of qs.defaults, e.g. { single = {...} }

hl.config({ general = { layout = "lua:tide" } })

hl.bind("SUPER + period", qs.cycle_next)
hl.bind("SUPER + comma", qs.cycle_prev)
hl.bind("SUPER + grave", qs.toggle_monocle)
hl.bind("SUPER + O", qs.toggle_monocle)
hl.bind("SUPER + backslash", qs.grow, { repeating = true })
hl.bind("SUPER + slash", qs.shrink, { repeating = true })
hl.bind("SUPER + equal", qs.add_master)
hl.bind("SUPER + minus", qs.remove_master)
hl.bind("ALT + Tab", qs.swap_with_master)
hl.bind("SUPER + J", function() qs.focus(1) end)
hl.bind("SUPER + K", function() qs.focus(-1) end)
hl.bind("SUPER + SHIFT + J", function() qs.move(1) end)
hl.bind("SUPER + SHIFT + K", function() qs.move(-1) end)
-- Left and right, going on to the next monitor at the edge (SPEC.md §6.6).
hl.bind("SUPER + Left", function() qs.focus_side(-1) end)
hl.bind("SUPER + Right", function() qs.focus_side(1) end)
hl.bind("SUPER + SHIFT + Left", function() qs.move_side(-1) end)
hl.bind("SUPER + SHIFT + Right", function() qs.move_side(1) end)
-- Drag the master/stack edge with no key held (SPEC.md §6.6).
hl.bind("mouse:272", qs.drag_press)
hl.bind("mouse:272", qs.drag_release, { release = true, non_consuming = true, ignore_mods = true, locked = true })
```

`focus_side` focuses the window to the left or right of the focused one,
and at a monitor's edge the nearest window on the next monitor that way,
or that monitor itself if it shows none. `move_side` moves the focused
tiled window the same way: a swap on its monitor, or onto the next one at
the edge, where it lands at the edge it came in by. Past the last monitor,
both do nothing. Hyprland's own `movefocus` wraps around the monitor there,
and its `movewindow` under a Lua layout swaps in Hyprland's window order and
never leaves the monitor, so these don't use them.

`drag_press` takes a press within `resize_grab` pixels (4 by default) of a
split edge and passes any other on to the window, returning
`{ pass_event = true }`. The release bind ignores modifiers and the lock, so
the drag ends however the button comes up; with no drag on, it does
nothing.

`setup()` checks the merged options against a schema: every key, type and
range, with no unknown keys and no holes in lists. It raises an error
naming the path (`tide.setup: modes.tile.mfat is not an option`), so
a typo shows up once, as a config error at load, not later on a keypress.

The mode-changing helpers announce the new mode on Hyprland's event socket
as `custom>>tide-layout>>WORKSPACE,MODE`, which the bar follows, and
`setup()` adds a `workspace.active` handler that announces each workspace's
mode as it becomes active, so a bar that started later catches up. The
same commands also work as plain `layoutmsg`s (`mode <name>`, `next`, `prev`,
`monocle`, `mfact <+d|-d|value>`, `addmaster`, `removemaster`, `reset`), but
those don't announce.

## Status

The tests cover the geometry and the layout's behavior against a stub of
the `hl` API, written from Hyprland's source at 0.56. The layout has not yet
run inside a real Hyprland session; that happens in M2 on a real machine.
The `hl.bind` options and window selectors above were checked against the
same source.
