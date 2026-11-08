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
- `pinned.lua` keeps a workspace's pinned apps open (SPEC.md §6.5): its
  `close` is `Super+Backspace`'s, and its `shortcut`, bound to an app's
  own close and quit keys, passes each key on to every window but a
  pinned one.
- `config.lua` is tide's Hyprland config, which loads the others, and
  `hyprland.lua` is that config as it comes (below).
- `layout_test.lua` tests `geometry.lua` and `layout.lua`, the latter
  against a stub of `hl`; `direction_test.lua` tests `direction.lua`,
  `span_test.lua` tests `span.lua`, and `pinned_test.lua` tests
  `pinned.lua`, against a stub of `hl` too.

## tide's Hyprland config

`config.lua` is the rest of what the tide session needs from Hyprland 0.57,
as a module: the session's `uwsm finalize`, these modules, the files tide's
shell writes in `~/.config/hypr` (`tide-outputs.lua`, `tide-input.lua`,
`tide-appearance.lua`, `tide-keys.lua`, `tide-power.lua`,
`tide-floating.lua`, `tide-workspaces.lua`), the calls the shell makes
through `hyprctl eval` (`tide_input`, `tide_outputs`, `tide_appearance`,
`tide_workspaces`, `tide_floating`, `tide_keys`, `tide_attention`), the
keys of SPEC.md §6.6 with their names for the Keyboard shortcuts page, the
lid, and the window rules. `hyprland.lua` is that config with none of your
changes. `make install` puts both in `~/.config/hypr/tide/`.

With no `~/.config/hypr/hyprland.lua`, the session runs tide's
(`bin/tide-hyprland` passes Hyprland `--config`). A plain Hyprland login
would write an example config there instead. To use tide's there too, the
file is one line:

```lua
dofile(os.getenv("HOME") .. "/.config/hypr/tide/hyprland.lua")
```

To change some of it, load `config.lua`, change what you prefer, then
call `setup()`:

```lua
local tide = dofile(os.getenv("HOME") .. "/.config/hypr/tide/config.lua")
local key, exec, app, does = tide.key, tide.exec, tide.app, tide.does

-- Defaults that tide's Keyboard and Mouse settings still change.
tide.input.kb_layout = "de"
tide.mouse.left_handed = true

-- Your apps, named for the Keyboard shortcuts page, listed after tide's.
tide.bind("browser", key("G"), app("firefox", "firefox"), does("Browser"))
-- One of tide's names replaces tide's binding, in its place.
tide.bind("terminal", key("T"), app("foot", "foot"), does("Terminal"))
-- Keys that keep theirs, as the media keys do.
tide.fixed("XF86Tools", app("gnome-control-center"), does("Settings"))

tide.setup()

-- What wins over tide's settings: monitors, input, devices, the dim, keys.
tide.override(function()
    hl.monitor({ output = "DP-1", mode = "2560x1440@144", position = "0x0", scale = 1 })
    hl.unbind("SUPER + E")
    hl.bind("SUPER + E", exec("nautilus"))
end)
-- Or a file's, if it's there, as conf loads hyprland.local.lua.
tide.override(os.getenv("HOME") .. "/.config/hypr/hyprland.local.lua")
```

- **Before `setup()`.** `tide.input` holds the input options: the
  keyboard's layout, variant and XKB options, the pointer's speed, and the
  touchpad's. `tide.mouse` holds what every mouse gets over them.
  `tide.input_setup` is the command that gives each device its settings,
  conf's `apply-input.sh` by default. `tide.bind(name, keys, target,
  opts)` and `tide.fixed(keys, target, opts)` add bindings. Each binding
  runs through `tide launch` in the tide session (`tide.app(command,
  window class)`) or as a plain command (`tide.exec`), and says what it
  does (`tide.does`), which is all the Keyboard shortcuts page can show.
  Adding one after `setup()` is an error.
- **`setup()`** applies tide's config with those changes, once.
- **`tide.override()`** runs a function, or a Lua file at a path if there
  is one. What it does to monitors, input, devices, the dim and keys is
  recorded as yours, and tide's settings leave it alone: a change on the
  Displays, Mouse, Keyboard or Appearance page, or to a shortcut's keys,
  never takes it back. A function's error is an error in your config. A
  file's is a notification, after the calls before it have applied.
- **Rebinding a key.** In Hyprland 0.57 a second `hl.bind` on the same
  keys adds a binding, and a press runs both
  (`CKeybindManager::processEvent` runs every match). `hl.unbind(keys)`
  removes every binding on those keys, in any submap
  (`CKeybindManager::removeBinds`). So unbind
  first, as the example does. The named binding then gives the keys up,
  and the Keyboard shortcuts page shows it without them. A key bound
  without the unbind is reported.
- **The old names.** conf's `hyprland.lua` named the shell's calls
  `conf_input` and so on, and the shell still calls those. `setup()` makes
  each `conf_` name the `tide_` one too, until the shell moves (TODO.md).

`config_test.lua` tests both files against a stub of `hl`, written from
Hyprland's source.

## Using the layout alone

`make install` copies the modules to `~/.config/hypr/tide/`. Without
tide's config, in `hyprland.lua`:

```lua
local qs = dofile(os.getenv("HOME") .. "/.config/hypr/tide/layout.lua")
qs.setup({})  -- override any key of qs.defaults, e.g. { single = {...} }

hl.config({ general = { layout = "lua:tide" } })

hl.bind("SUPER + period", qs.cycle_next)
hl.bind("SUPER + comma", qs.cycle_prev)
-- qs.last_mode: the mode used before this one (conf gives it no key)
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

-- A workspace's pinned apps stay open (SPEC.md §6.5), from the shell's
-- tide-workspaces.lua, which tide's config reads and checks first.
local pinned = dofile(os.getenv("HOME") .. "/.config/hypr/tide/pinned.lua")
pinned.set(dofile(os.getenv("HOME") .. "/.config/hypr/tide-workspaces.lua").pinned)
hl.bind("SUPER + BackSpace", pinned.close)
for _, keys in ipairs(pinned.shortcuts) do
    hl.bind(keys, pinned.shortcut)
end
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
same commands also work as plain `layoutmsg`s (`mode <name>`, `next`, `prev`, `last`,
`monocle`, `mfact <+d|-d|value>`, `addmaster`, `removemaster`, `reset`,
`single <value|reset>`), but
those don't announce.

## Status

The tests cover the geometry and the layout's behavior against a stub of
the `hl` API, written from Hyprland's source at 0.56. The layout has not yet
run inside a real Hyprland session; that happens in M2 on a real machine.
The `hl.bind` options and window selectors above were checked against the
same source.
