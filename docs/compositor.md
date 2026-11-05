# What tide needs from the compositor

SPEC.md §21.1, step 4: what tide's spec asks of a compositor, so the cost of a
dwl fork (or any other compositor) can be judged from a list rather than a
guess.

This is not a description of Hyprland. Every row is a requirement tide states
somewhere: a SPEC.md section, or the maintainer's `conf`. The row names that
source first. "Today" says only how Hyprland meets the requirement now, which
is where a port has to start. Hyprland behavior that no requirement asks for
is left out, even where tide happens to use it.

A check is the headline test, not the whole bar: a row passes only when
everything its source says still holds on the fork.

The "Today" column was read from this repository and `mikelward/conf`'s
`config/hypr` on 2026-10-05. The "Fork" column is a proposal, not built.
What dwl 0.9 on wlroots 0.20 already does for each row, checked against its
source, is in [dwl 0.9 against this list](#dwl-09-against-this-list).

## The biggest items

Most rows are small. These four are not, and decide the size of a port:

1. **The focus guard** (§14) runs inside the compositor, on Hyprland's Lua
   hooks (`hypr/tide/focus.lua`): every window opens unfocused, and a grant
   decides which may take focus. In a fork it becomes C in the compositor,
   with an IPC for `tide launch`, `tide-grant` and the shell.
2. **The layouts** (§6.1) are a Lua layout (`hypr/tide/layout.lua`) with its
   own messages and events. In a fork they are C, dwm-style.
3. **The shell's view of windows, workspaces and monitors** (§7) comes from
   `Quickshell.Hyprland`, which talks Hyprland's IPC. A fork needs a
   Quickshell module for its own IPC: no standard protocol says which
   workspace a window is on, so standard ones alone can't drive the bar.
4. **Capture** (§12, §13): window sharing and `grim -T` window
   screenshots. §21.1 called this the deciding question. dwl 0.9 passes it
   for windows, and a fork drops the 16:9 slice (decided 2026-11-02).

## Session (§5, §11)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §5.3: the session starts under uwsm, with `tide.service` ordered after the compositor | `tide-hyprland` runs `start-hyprland` under `uwsm start -D tide:Hyprland`; `wayland-session@tide-hyprland.target` | Built, as an option: `tide-tidewm` runs `tidewm -s 'uwsm finalize SWAYSOCK'` under `uwsm start -D tidewm:tide`; `wayland-session@tide-tidewm.target`, which tide's units are wanted by too. tidewm comes first so portals read `tidewm-portals.conf` | `tide doctor` passes; the shell and hypridle start with the session |
| §5.4: autostart entries still run | `OnlyShowIn=Hyprland` entries match | Each such entry gets a `tide` entry, or is dropped on purpose | Each autostart that ran on Hyprland still runs, or is listed as dropped |
| §5.4: doctor checks one bar per monitor and reports config errors | `hyprctl -j monitors`, `-j layers`, `configerrors` | Built: `GET_OUTPUTS`'s `layers` and `window_area`, and `GET_CONFIG`'s `errors`, through `tide-msg` | `tide-doctor_test.sh`'s bar checks; a broken setting is reported by doctor and at load |
| §5.4: `tide` and doctor find the compositor's IPC | `HYPRLAND_INSTANCE_SIGNATURE` | `SWAYSOCK`, which the session's units get from `uwsm finalize`. `tide` and `tide-grant` reach it through `tide-msg`; doctor doesn't yet | `tide` and doctor find the IPC |
| §11, `conf`: US Dvorak with `compose:caps,altwin:menu_win` everywhere, and the lock's layout badge | `input` options; `hyprctl devices -j` (`keyboards[].main`, `active_keymap`); the `activelayout` event | The same XKB settings for every keyboard; a device query and a layout-change event | Typing gives US Dvorak and Caps Lock composes; the lock's badge reads DVORAK and follows a switch |
| `conf`: per-mouse settings (left-handed, scroll factor) | `apply-input.sh` runs `hyprctl eval 'hl.device(...)'` after `hyprctl devices -j` | Per-device input settings in the fork's runtime config | A mouse's buttons swap and it scrolls by its factor; touchpads stay as they are |

## Windows and layouts (§6)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §6.1: tile, three-column, two columns + stack and monocle, set per workspace; new windows join the end of the stack and the master stays put | `hl.layout.register("tide", …)` and its messages (`next`, `prev`, `monocle`, `mfact`, `addmaster`, `removemaster`, `mode`); the `tide-layout` event | A dwm-style layout in C, with the same messages over IPC and a layout event | `layout_test.lua`'s cases, ported; opening three windows in turn keeps the first as master; the layout symbol follows `Super+.` and a workspace switch |
| §6.2: dim the inactive window, nothing else; never dim a lone window, picture-in-picture, video or a screen-share preview | `dim_inactive` 0.12, no gaps or borders; `no_dim` rules | Dimming as a scene-graph rectangle (§21.1), with the same exceptions | Only the focused window is undimmed, and the exceptions hold |
| §6.3: monocle, maximize and fullscreen as three states; maximize keeps the bar and ends when another window on the workspace takes focus; popups show over fullscreen but are held while it plays video | Hyprland's maximize and fullscreen, dispatched from the bar | Maximize and fullscreen kept as two states | §6.3 as written; the bar title's double-click maximizes (§7.1) |
| §6.3, §14.3: a window that asks for fullscreen as it opens (a game, a video player with `--fullscreen`) opens fullscreen once the guard lets it take focus | Not yet: under `no_initial_focus` Hyprland 0.56 drops the request, and Lua can't see it, so it opens tiled (TODO.md, *Fullscreen on open*) | The guard keeps the window's initial fullscreen request and applies it when it grants focus | A granted `mpv --fullscreen` opens fullscreen; a refused one stays unfocused, and goes fullscreen once you switch to it |
| §6.4: dialogs float, centered on the parent, capped at 80% of the monitor, kept above it and following it; closing one focuses the parent; picture-in-picture floats pinned at the bottom-right; a hand-floated window gets its last floating size back | Window rules in `conf`; Hyprland's parent handling | Floating for Wayland windows with a parent, modal or fixed size; rules in the runtime config | §6.4 as written |
| §6.5: workspaces 1–9 are one shared pool, each shown on at most one monitor; one bar per monitor; with an external display, closing the lid disables the panel and moves its workspaces over | Hyprland workspaces and `hl.monitor`; lid switch binds in `conf` | ext-workspace, a shared pool rather than dwl's per-monitor tags; lid switch handling | Workspace *n* is the same from every monitor, and the bar outlines one shown elsewhere; with an external display, closing the lid disables the panel and moves its workspaces over |
| §6.6: every binding works, including `locked` ones on the lock, release binds and submaps; `Super`+drag moves and resizes a floating window; §21.1 and TODO: dragging the master split, not built yet | Binds in `conf`'s `hyprland.lua` | Runtime config, reloadable without a restart (§21.1), plus `Super`+drag, including on a tiled window's master split | Every binding in §6.6 does its action, and keys work on the lock; `Super`+drag on a tiled window moves the master split once that's built |
| §16: each output gets its configured mode, scale, position and single-window width, at login and when plugged in; the *advanced* Displays action edits it | `hl.monitor`, `monitor.added`; nwg-displays writes Hyprland's monitor config | The fork's output config, plus an adapter or another editor (nwg-displays supports only Sway, Hyprland and Niri) | An output plugged in gets its settings; an advanced edit applies and survives a reload |
| §17: apps are sharp at fractional scale, X11 ones included | Hyprland's fractional-scale-v1 and viewporter; `xwayland:force_zero_scaling` | Both protocols exposed; X11 windows unscaled at fractional scale | At 1.25, a native Wayland app and an X11 app are both sharp and the right size |

## Bar (§7)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §7.1: the title names the focused window, on its monitor's bar only, including under a special workspace or when pinned; it goes blank when focus moves to an empty workspace, and is right just after a shell restart | `Hyprland.activeToplevel` with its monitor; the `activewindowv2` event; `hyprctl activewindow -j` at startup | wlr-foreign-toplevel-management's `activated` state and `output_enter`, or the same from the fork's event stream, and a focused-window query | With two outputs, only the focused one's bar shows a title, and it follows focus; it's right after a shell restart and blank on an empty workspace |
| §7.1: tiling starts below the bar | wlr-layer-shell exclusive zone | Expected in dwl | Windows never sit under the bar |
| §7.2: the workspace chips follow opens, closes, moves, fullscreen and urgency; clicking a chip or an icon goes there; scrolling over them moves through workspaces; right-clicking one changes its layout once that's built | `Hyprland.toplevels`, `Hyprland.workspaces`; `openwindow`, `closewindow`, `movewindowv2`, `fullscreen`, `changefloatingmode`, `urgent`, `activespecial` events; `Hyprland.dispatch` | The fork's event stream, giving each window's workspace, output, focus, fullscreen, floating and urgent state, and an IPC command to go to a window or workspace. ext-foreign-toplevel-list gives only the identifier, title and app ID, and neither it nor ext-workspace says which windows are on a workspace | The bar on a fork matches the mocks, and clicks, scrolling and urgent marks work |
| §7.1, §8, §9: popups, the OSD and the notification center open on the focused monitor; a popup's countdown runs only there; the center key opens it rather than closing it | `Hyprland.focusedMonitor`, `monitorFor(screen)` | Built: `GET_OUTPUTS`'s `focused`, asked again on tidewm's output focus event, through Quickshell's I3 module (`shell/Compositor.qml`) | Popups and the OSD open on the focused monitor and expire there; the center key opens it |
| §7.1: after a shell restart, the layout symbol's fallback is right on a rotated monitor | `Hyprland.monitors` (`width`, `height`, `transform`) | The same fields from the output query | On a rotated ultrawide, the symbol is right after a restart |

## Launcher, notifications and lock (§8, §9, §10)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §8, R14: tapping Super opens the launcher; `Super+T`, `Super`+drag and `Super`+click don't | A release bind on `SUPER_L`, then Hyprland's global shortcut `tide:launcher` | Tap Super in the fork, sent over IPC | §8's three checks |
| §8, §9: the launcher, share picker, region picker and lock keep the keyboard while a window opens beneath them or the pointer crosses one; clicking a notification's inline-reply field gives it the keyboard | wlr-layer-shell exclusive and on-demand keyboard focus | Expected in dwl | Typing in each, and in a notification's reply field, is never lost to a window |
| §8, §14.3: `Ctrl+Enter` runs an app on the monitor's first empty workspace: its first window moves there as it opens and focus follows; nothing moves if the grant is canceled, and a quick action behaves as `Enter` | A grant option the guard reads, moving the window with Hyprland's `emptym` selector | The same grant option in the guard's IPC, and a first-empty-workspace move in C | `Ctrl+Enter` opens the app on an empty workspace with focus there; a canceled grant moves nothing |
| §8: Screenshot window and Screenshot screen capture what the launcher opened over | `hyprctl clients -j` (`stableId`, `at`, `size`); the launcher remembers the monitor | A window query giving the ext-foreign-toplevel identifier and geometry, and the output name | Each captures the window or monitor the launcher opened over, even after focus moves |
| §9: a click outside the notification center closes it; moving the pointer across doesn't | `HyprlandFocusGrab` (`hyprland_focus_grab_v1`) | The protocol in the fork, or another outside-click event; not focus loss, since the center keeps the keyboard | A click outside closes it; crossing it doesn't |
| §10: the lock, with restore after a crash | ext-session-lock; `allow_session_lock_restore`; `hl.clear_crashed_lockscreen()` from a TTY | ext-session-lock in dwl, plus letting a restarted lock client take over a crashed one's lock (as `allow_session_lock_restore` does), and an IPC command that drops a dead lock | §10's lock checks and crash walk: restarting `tide-lock` after a crash brings its password field back without showing or focusing any window in between |
| §10: idle locks at 5 minutes and turns the screens off at 5.5; keep awake holds; if M5 finds Chrome holding an inhibitor on ordinary pages, a per-window rule ignores it | ext-idle-notify and idle-inhibit; `hyprctl dispatch` dpms from hypridle; `idle_inhibit none` if needed | Both protocols, plus wlr-output-power-management (`wlopm`) for screen-off and a per-window inhibitor rule if needed. `wlopm` costs nothing, but if it's missing the screens stay on behind the lock, so `setup` installs it and doctor checks it | Screens lock, go off and come back on input; keep awake holds; if the rule is needed, an ordinary Chrome page doesn't keep the screens on while a fullscreen video does |

## Screen sharing and screenshots (§12, §13)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §12: share a window or a monitor in Meet, through tide's picker with live thumbnails; on Hyprland, a 16:9 region too | xdg-desktop-portal-hyprland with `tide-share-picker`; `tide-portals.conf` names `hyprland;gtk`; Quickshell's `ScreencopyView` | xdg-desktop-portal-wlr plus an adapter (its `dmenu` chooser), and no region: a fork drops the 16:9 slice; `wlr;gtk` in the portals config. xdpw 0.8.5 takes persistence only from the process-wide `XDPW_PERSIST_MODE` and restores only monitors, so the picker's "reuse the choice" checkbox needs xdpw patched or replaced. The portal costs nothing, but if it's missing Meet's share fails with no picker, so `setup` installs it and doctor checks it | §21.1 step 1; the picker shows live outputs; ticking "reuse the choice" restores a window share and a monitor share, and leaving it unticked restores neither; a file chooser and OpenURI still work through GTK |
| §12, §9: the Sharing pill shows during a share and not for a screenshot; popups are held for a screen or region share but not a window share | `ShareData.qml` watches PipeWire's `xdph-streaming-*` nodes and pairs each new one with the picker's recorded choice; the `screencast` event, not read yet, is kept as a prompt to re-check | The detector taught xdg-desktop-portal-wlr's `xdpw-stream-*` names (0.8.4's `pipewire_screencast.c`), paired with the picker's choice the same way, and a capture-started event if the fork has one | The pill shows for a Meet share and not for a `grim` shot; a window share holds no popups, and a screen or region share does |
| §12: the notifications and the launcher show black to the far end of a share | `no_screen_share` on `tide-notifications`, `tide-launcher` and `tide-share-picker`, in `conf`'s `hyprland.lua` | Both namespaces excluded from capture | A popup, the center or the launcher during a share shows black to the far end |
| §13: window, screen and region screenshots; `Alt+Print` captures the focused window, falling back to its geometry if `grim -T` fails | ext-foreign-toplevel-list and ext-image-copy-capture; wlr-screencopy; `hyprctl activewindow -j` (`stableId`, `at`, `size`) | wlroots has the protocols, and dwl must expose them (§21.1 step 2); a focused-window query giving the identifier and geometry | Each screenshot captures; with `grim -T` made to fail, `Alt+Print` falls back to `grim -g` |
| §13, §16.2: a screenshot pastes into another app, and copying adds a clipboard-history entry | wl-data-device and a data-control protocol, for `wl-copy` and `wl-paste --watch cliphist store` | wlroots has them; dwl must expose wlr-data-control, not only ext-data-control, since Debian 13 and Ubuntu 26.04 package wl-clipboard 2.2.1 and ext-data-control support arrived in 2.3.0 | A screenshot pastes as `image/png`; copying text adds a history entry, with the distro's packaged wl-clipboard |

## Focus and attention (§14)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §14.1, §9: a new window takes focus only with a grant (launcher, terminal, notification click, the app you're in); the rest open unfocused and marked urgent; a notification click that opens nothing focuses the app's most recent window | `no_initial_focus` on every window; `focus.lua` on `window.open`, `window.urgent`, `window.active`, `window.close`; grants over `hyprctl eval 'tide_focus.grant(…)'` and friends | The guard in C, with its IPC answering `ok` | `focus_test.lua`, `tide_test.sh` and `tide-grant`'s tests, ported; a launched app's first window takes focus, and a background app's doesn't |
| §14.1: a polkit prompt takes focus only when its requester descends from the focused window's process and your last input, key or click, went to that window within 2 s; otherwise a notification offers **Authenticate** | `focus.lua`'s `prompt_may_focus`, which sees only key presses and not the requester, so a click takes the notification path: agent windows (`prompt_classes`) ask it as they open, and the shell's agent (`TIDE_POLKIT=1`) through `tide prompt-focus` (`hyprctl repl`) | A guard query the shell's agent asks before opening the prompt: the focused window's pid and the time and target of the last key or click | A `pkexec` typed in a terminal, or an app's Unlock click, opens the prompt with focus; `sleep 30; pkexec …` left idle, or a request from a background process, gives the notification instead |
| §14.1: an app's own activation request, Wayland or X11, marks it rather than focusing it | `focus_on_activate = false`; xdg-activation; `_NET_ACTIVE_WINDOW` through Xwayland | xdg-activation and `_NET_ACTIVE_WINDOW` onto the guard's urgent path | An app's activation is marked, not obeyed |
| §14.2: an app launched on workspace 2 that maps after you move to 3 opens on 2, unfocused, and 2 turns urgent; the other focus rules there (`follow_mouse`, no warps, focus on close) | `initial_workspace_tracking` (Hyprland's default) and the `hl.config` focus options | Opening a window on the workspace it was launched from; the same focus rules | §14.2's cases |
| §14.3: a grant lapses once you type or click elsewhere; a stale one expires; a grant matches a window from a child process | `input.keyboard.key` (mouse buttons aren't exposed yet); `hl.timer`; `hl.get_windows()` with `pid`, and `/proc` ancestry | Key and pointer-button hooks, a timer, and a window list with pids, in C | A slow window opens unfocused after you type, or after you click inside the window you're already in; a stale grant expires; `nautilus .` from a terminal takes focus |
| §14.3, §14.4: refused windows are marked on the bar, `Super+Tab` cycles them, and the marks survive a shell restart; with no shell running, a refused window is still announced | `tide-cycle` and `tide-attention` events; `announce_waiting()` and `set_order()`; `hl.notification.create` | Guard events and the same calls over IPC; a compositor-side notification for when no shell runs | `Super+Tab` cycles marks; marks match the guard after a restart; with the shell stopped, a refused window is announced |
| §6.4, §14.1: X11 apps run, their dialogs float over their parent, and their window types are honored | Xwayland | Built with Xwayland, mapping `WM_TRANSIENT_FOR` and window types onto the same float and parent rules | An X11 app runs and its dialog floats over its parent |

## dwl 0.9 against this list

Checked 2026-11-02 by reading dwl 0.9 (`98bea2c`) on wlroots 0.20.2
(`d783533`), with sway 1.12 (`8886939`) as the model for missing pieces.
Nothing was built or run. Line numbers are `dwl.c`'s unless a file is named.
Size is the fork's own C: **S** under 50 lines, **M** 50 to 300, **L** over
300.

Of the 39 rows, 5 already work, 21 work in part and 13 not at all. Five
rows need nothing from the compositor, 19 are S, 9 are M and 6 are L.

| Row | dwl 0.9 | What dwl does | The fork builds |
|---|---|---|---|
| §5.3 uwsm | part | Sets `WAYLAND_DISPLAY` and `DISPLAY` only; `-s` runs a startup command (2410–2427) | A wrapper and session entry, `uwsm finalize` through `-s` (—) |
| §5.4 autostart | yes | uwsm reads `XDG_CURRENT_DESKTOP`, not the compositor | `tide` entries (—) |
| §5.4 doctor queries | no | No layer or config-error query | Both queries (S) |
| §5.4 IPC variable | no | No socket at all | A socket and its variable (S, with the IPC) |
| §11 XKB and the badge | part | One compiled `xkb_rule_names` for every keyboard (`config.def.h` 52–58); no layout-change report | Runtime XKB, a keymap query and a layout event (S) |
| conf per-mouse settings | no | libinput settings are global constants (`config.def.h` 63–104); no scroll factor | Per-device rules and a scroll factor (M) |
| §6.1 layouts | part | Tile and monocle, per monitor; a new window goes to the list head, so it becomes master (1910) | Attach at the tail (S); three-column, two columns + stack, per-workspace layout, messages and an event (M) |
| §6.2 dimming | no | Border colors only | A scene rectangle per window, with the exceptions (S) |
| §6.3 three states | part | Monocle and fullscreen; maximize requests ignored by design (1946–1962) | A maximize state that ends on a focus change (M) |
| §6.3 fullscreen on open | part | Wayland works: a request before map is applied at map (2508, 2574). X11's `_NET_WM_STATE` isn't read at map (inferred) | Hold the request until the grant; read X11's state at map (S) |
| §6.4 dialogs | part | A window with a parent or a fixed size floats on the parent's monitor (1929–1931, `client.h` 256), but at its own origin, not centered; no cap, follow, modal or remembered size | Center, cap, follow, modal, a PiP rule, size memory (M) |
| §6.5 workspace pool and lid | no | Tags are per monitor (`VISIBLEON`, 83); no ext-workspace; switch devices are a TODO (1707) | A shared pool replacing tags (L); ext-workspace (S); the lid (S) |
| §6.6 bindings | part | Compiled `keys[]` and `buttons[]`, on press only; all off while locked (1761); no submaps | Runtime config with reload (L); locked and release binds, submaps (S); master-split drag (S) |
| §16 outputs | part | Monitor rules set scale, transform and position at plug-in; always the preferred mode; wlr-output-management applies but nothing persists | Runtime output rules with mode and width, reapplied on hotplug, and an editor adapter (M) |
| §17 fractional scale | part | fractional-scale-v1 and viewporter (2682–2684); X11 apps blur, as on sway | Unscaled Xwayland with scaled X11 buffers (L, no sway model) |
| §7.1 focused title | part | The status lines name each monitor's top title and the selected monitor; no wlr-foreign-toplevel-management | A focused-window query or that protocol (S) |
| §7.1 tiling below the bar | yes | Exclusive zones shrink the window area (611–631) | — |
| §7.2 workspace chips | no | Per-monitor tag bitmasks only (2287) | Event stream, window list, go-to commands (L, the IPC) |
| §7 focused output | part | The status names the selected monitor; `wl_output` has the rest | Output query (S) |
| §7.1 rotated monitor | part | Transform is in `wl_output` | Part of the output query (S) |
| §8 tap Super | no | Bindings fire on press only | Tap tracking and an IPC event (S) |
| §8, §9 keep the keyboard | part | An exclusive top or overlay layer keeps it when a window maps or the pointer crosses (1547–1556, 636–651). An on-demand layer, a notification's reply field, loses it to a mapping window or a crossing (2577, 2230) | Hold on-demand focus and block those enters (S) |
| §8 `Ctrl+Enter` | no | No grants, no empty-workspace move | On top of the guard and the pool (S) |
| §8 screenshot target | part | Every window has an ext-foreign-toplevel handle (1913), but nothing publishes its identifier | Window query: identifier, geometry, output (S) |
| §9 outside click | no | No `hyprland_focus_grab_v1` | The protocol (M) or a click event (S) |
| §10 lock restore | part | A crashed lock client leaves the session locked, and a new client may take the lock (1386–1400, 1840–1848), as in sway. Nothing drops a dead lock; while it's gone, pointer events may reach hidden windows (inferred) | A command that drops a dead lock; no pointer delivery while locked (S) |
| §10 idle | yes | ext-idle-notify; idle-inhibit counts visible inhibitors only (772–788); output power for `wlopm` | A per-window inhibitor rule, if M5 needs it (S) |
| §12 share | yes | Window and monitor sources (2676–2678, 2736–2738) | — |
| §12 Sharing pill | part | wlroots' capture manager has a `new_session` signal, unused | Capture start and stop events (S) |
| §12 hide from capture | no | Output capture copies the composited output | An output source rendered from a scene without those namespaces, and screencopy dropped or matched (L, no sway model) |
| §13 screenshots | part | The protocols are there | Focused-window query (S) |
| §13 clipboard | yes | wl-data-device, wlr- and ext-data-control (2674, 2679, 2680) | — |
| §14.1 guard | no | Every new window is focused (1911, 2577) | The guard (L) |
| §14.1 polkit | no | No record of the last input; pids are known | Last key and click, and a pid query (S) |
| §14.1 activation | part | xdg-activation marks urgent and never focuses (3153–3166); X11 `_NET_ACTIVE_WINDOW` bypasses that | X11 onto the urgent path (S) |
| §14.2 rules | part | A window's tags come from the focused monitor at map, not launch; focus follows real motion and never warps; close focuses the most recent window | Launch-workspace tracking (M); focus under the pointer on close (S) |
| §14.3 grant lapses | no | Key, button and timer hooks exist | Part of the guard (M) |
| §14.3 marks and cycle | part | A per-window urgent flag and bitmask | Attention list, cycle, events, a fallback notification (M) |
| §6.4 X11 | part | Only built with `-DXWAYLAND`; `WM_TRANSIENT_FOR` sets the parent and dialog-like types float (`client.h` 199–253) | Turn it on; dialog placement as for Wayland (S) |

**Where dwl's design fights tide's:**

- **Per-monitor tags against a shared pool with per-workspace layouts
  (hard).** Tags run through `VISIBLEON`, `setmon`, `focustop`, `arrange`,
  `view`, `tag`, `tagmon`, `closemon` and `printstatus`. A fork replaces the
  model rather than patching it, which also makes upstream dwl patches harder
  to carry.
- **Compiled-in config against reload without a restart (medium).** Every
  tunable is a `static const` in `config.h`; moving them to a runtime file is
  mechanical, but every upstream change to `config.def.h` conflicts.
- **Focus on map against the guard (medium).** About 15 call sites focus
  `focustop(selmon)`, so a refused window has to be kept out of the focus
  order, not just left unfocused once.

**The biggest new work**, in order: the IPC and its Quickshell module; the
focus guard; the shared workspace pool; runtime config with reload. Hiding
the shell from capture and sharp X11 at fractional scale are L too, but each
stands alone.
