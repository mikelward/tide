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
- `layout.lua` registers the layout and provides helpers for keybinds.
- `layout_test.lua` tests both, `layout.lua` against a stub of `hl`.

## Using it

`make install` copies the two modules to `~/.config/hypr/tide/`. Then,
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
hl.bind("SUPER + Return", qs.swap_with_master)
hl.bind("SUPER + J", function() qs.focus(1) end)
hl.bind("SUPER + K", function() qs.focus(-1) end)
hl.bind("SUPER + SHIFT + J", function() qs.move(1) end)
hl.bind("SUPER + SHIFT + K", function() qs.move(-1) end)
```

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
