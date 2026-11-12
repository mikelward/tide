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
`config/hypr` on 2026-10-05. The "Fork" column says what the fork,
[tidewm](https://github.com/mikelward/tidewm), and tide's tidewm session
have built, and what's left. It was checked on 2026-11-08 against tidewm
`v0.0.1474` (`c22f9ca`), this repository,
and conf's `config/tidewm`. "tidewm #N" is a tidewm pull request. "Built"
means built and tested headless, by tidewm's own tests and tide's stand-in
(`shell/tidewm_stand_in.py`): nothing has run in a real login yet. The
count is in [tidewm today](#tidewm-today).

## The biggest items

Four items decided the size of the port. All four are built:

1. **The focus guard** (§14) runs inside the compositor, on Hyprland's Lua
   hooks (`hypr/tide/focus.lua`). On tidewm it's C (tidewm #22 to #25),
   with grants over the IPC for `tide launch`, `tide-grant` and the shell.
2. **The layouts** (§6.1) are a Lua layout (`hypr/tide/layout.lua`). On
   tidewm they're C, dwm-style (tidewm #19 to #21, #55).
3. **The shell's view of windows, workspaces and monitors** (§7) comes from
   `Quickshell.Hyprland`. On tidewm it comes from sway's IPC (tidewm #7):
   Quickshell's I3 module for workspaces and monitors, and `GET_TREE` and
   window events for windows (`shell/Compositor.qml`,
   `shell/TidewmData.qml`).
4. **Capture** (§12, §13): window sharing and `grim -T` window
   screenshots. dwl 0.9 passed it for windows (decided 2026-11-02), and
   tidewm publishes each window's identifier.

The largest piece left is hiding the shell from capture, which the
maintainer deferred.

## Session (§5, §11)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §5.3: the session starts under uwsm, with `tide.service` ordered after the compositor | `tide-hyprland` runs `start-hyprland` under `uwsm start -D tide:Hyprland`; `wayland-session@tide-hyprland.target` | Built: `tide-tidewm` runs `tidewm -s '… uwsm finalize SWAYSOCK I3SOCK'` under `uwsm start -D tidewm:tide`; `wayland-session@tide-tidewm.target`, which tide's units are wanted by too. tidewm comes first so portals read `tidewm-portals.conf` (tidewm #47). Left: a first real login | `tide doctor` passes; the shell and hypridle start with the session |
| §5.4: autostart entries still run | `OnlyShowIn=Hyprland` entries match | Built: tide's units, hypridle and the autostart allowlist take any `XDG_CURRENT_DESKTOP` with `tide` in it, so `tidewm:tide` matches (SPEC.md §5.3) | Each autostart that ran on Hyprland still runs, or is listed as dropped |
| §5.4: doctor checks one bar per monitor and reports config errors | `hyprctl -j monitors`, `-j layers`, `configerrors` | Built: `GET_OUTPUTS`' `layers` and `window_area` (tidewm #48), `GET_CONFIG`'s `errors` (#12), and `GET_WORKSPACES`' `persistent` for home (#8), through `tide-msg` (`bin/tide-doctor`'s `bars_on_tidewm`, `tidewm_config_errors`) | `tide-doctor_test.sh`'s bar checks; a broken setting is reported by doctor and at load |
| §5.4: `tide` and doctor find the compositor's IPC | `HYPRLAND_INSTANCE_SIGNATURE` | Built: `SWAYSOCK` (tidewm #7), which the session's units get from `uwsm finalize`. `tide`, `tide-grant`, doctor and the shell's home reach it through `tide-msg` | `tide` and doctor find the IPC |
| §11, `conf`: US Dvorak with `compose:caps,altwin:menu_win` everywhere, and the lock's layout badge | `input` options; `hyprctl devices -j` (`keyboards[].main`, `active_keymap`); the `activelayout` event | Built: conf's tidewm config sets the keymap in an `input type:keyboard` block (tidewm #17); `GET_INPUTS` and the `input` event's `xkb_layout` (#36) drive the lock's badge (`shell/LockKeymap.qml`). The greeter still runs Hyprland (§11 greeter row) | Typing gives US Dvorak and Caps Lock composes; the lock's badge reads DVORAK and follows a switch |
| §16: the Mouse, Touchpad and Keyboard pages apply at once, and again at login | `tide-input.lua`, read by conf's hyprland.lua, and `hyprctl eval conf_input.reload()` | Built: `tide-input.conf`, `input type:pointer`, `type:touchpad` and `type:keyboard` lines, which conf's tidewm config includes, and `tide-msg reload` (`lib/input.mjs`'s `inputConf`). No acceleration curve, so a mouse's is adaptive or flat. A device's own settings are an `input` block naming it as Hyprland does, `GET_INPUTS`' `hyprland_name` (tidewm #57) | Turning off tap to click stops taps at once, and stays off after a login |
| `conf`: per-mouse settings (left-handed, scroll factor) | `apply-input.sh` runs `hyprctl eval 'hl.device(...)'` after `hyprctl devices -j` | Built: conf's tidewm config makes every mouse left-handed with a faster wheel in its `input type:pointer` block (tidewm #17, #35). tidewm calls a laptop's pointing stick and its touchpad's `-mouse` node pointers too, so tide's `apply-input.sh` writes `tide-devices.conf`, which that config includes before `tide-input.conf`: an `input` block for each, by its `hyprland_name` (#57), with the first touchpad's settings from `GET_INPUTS`, and `HYPR_MOUSE_SCROLL_FACTOR` as `type:pointer`'s. `watch-input.sh` runs it again on tidewm's `input` event, a device added or removed or a reload, through `tide-msg --subscribe input` | A mouse's buttons swap and it scrolls by its factor; touchpads stay as they are |
| §16: the Keyboard page lists every shortcut, and you can change one | `hyprctl binds -j`; conf's named bindings in `tide-keys.json`, and its `tide-keys` submap for recording | Built: the list is tidewm's `GET_BINDINGS` (tidewm #56), through `tide-msg --type get_bindings`; conf's `bindsym --name` bindings are listed by `GET_NAMED_BINDINGS`, and the page writes `rebind` lines to `tide-keys.conf`, which conf's config includes, and `tide-msg reload` applies them (tidewm #67, `lib/keys.mjs`'s `keysConf`); recording uses conf's `tide-keys` mode | Every binding shows with its keys; a changed one works at once and after a login |
| §11: the greeter, on the lock's face, with the lock's layout badge, and its displays off when idle | `tide-greeter` runs Hyprland with its own config | Not built: `bin/tide-greeter` still runs Hyprland, so a machine without Hyprland has no tide greeter (TODO.md, *A session on it*) | The greeter starts on tidewm, takes a password, and its displays go off when idle |

## Windows and layouts (§6)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §6.1: tile, three-column, two columns + stack and monocle, set per workspace; new windows join the end of the stack and the master stays put | `hl.layout.register("tide", …)` and its messages (`next`, `prev`, `monocle`, `mfact`, `addmaster`, `removemaster`, `mode`); the `tide-layout` event | Built: tidewm's layouts, per workspace part, the `layout` event, and the config's `default_layout`, `ultrawide_aspect`, `layout_defaults`, `single_window` and `new_window` lines (tidewm #19, #20, #21, #37, #55); the Layouts page writes `tide-layouts.conf` (`lib/layouts.mjs`'s `layoutsConf`); the bar's layout symbol, from the `layout` event and its own window count (`LayoutData.qml`, `lib/tidewm.mjs`), and `layout next` and `prev` (tidewm #65), which conf binds to `Super+.` and `Super+,` | `layout_test.lua`'s cases, ported; opening three windows in turn keeps the first as master; the layout symbol follows `Super+.` and a workspace switch |
| §6.2: dim the inactive window, nothing else; never dim a lone window, picture-in-picture, video or a screen-share preview | `dim_inactive` 0.12, no gaps or borders; `no_dim` rules | Built: tidewm's `dim_inactive`, with the exceptions built in (tidewm #33), and `default_border none` in `tidewm/tide.conf`; the Appearance page writes it to `tide-appearance.conf` (`lib/appearance.mjs`'s `appearanceConf`) and applies it with `tide-msg reload` | Only the focused window is undimmed, and the exceptions hold |
| §6.3: monocle, maximize and fullscreen as three states; maximize keeps the bar and ends when another window on the workspace takes focus; popups show over fullscreen but are held while it plays video | Hyprland's maximize and fullscreen, dispatched from the bar | Built: monocle; tidewm's own `maximize`, which ends when another window on the workspace takes focus (tidewm #26); fullscreen. The bar title's double-click and the switcher maximize through it (`Compositor.qml`'s `toggleMaximize`), and conf binds `Super+Up` | §6.3 as written; the bar title's double-click maximizes (§7.1) |
| §6.3, §14.3: a window that asks for fullscreen as it opens (a game, a video player with `--fullscreen`) opens fullscreen once the guard lets it take focus | Not yet: under `no_initial_focus` Hyprland 0.56 drops the request, and Lua can't see it, so it opens tiled (TODO.md, *Fullscreen on open*) | Built: the guard holds a window's fullscreen until it has focus (tidewm #27). An X11 window that sets `_NET_WM_STATE` before it maps can lose it, a wlroots race (tidewm's TODO.md, *Known bugs*) | A granted `mpv --fullscreen` opens fullscreen; a refused one stays unfocused, and goes fullscreen once you switch to it |
| §6.4: dialogs float, centered on the parent, capped at 80% of the monitor, kept above it and following it; closing one focuses the parent; picture-in-picture floats pinned at the bottom-right; a hand-floated window gets its last floating size back | Window rules in `conf`; Hyprland's parent handling | Built: dialogs centered on the parent and capped at 80% (tidewm #28), kept above it and following it (#29), picture-in-picture (#30), a hand-floated window at its app's last place (#31), and `for_window` rules with PCRE2 (#15, #58); the Floating page writes `tide-floating.conf` (`lib/floating.mjs`'s `floatingConf`) | §6.4 as written |
| §6.5: workspaces 1–9 are one shared pool, each shown on at most one monitor; one bar per monitor; with an external display, closing the lid disables the panel and moves its workspaces over | Hyprland workspaces and `hl.monitor`; lid switch binds in `conf` | Built: tidewm's workspaces, one pool spanning every monitor, in place of dwl's tags (tidewm #8), ext-workspace (#9), and `bindswitch` for the lid (#38), which conf's tidewm config binds. A workspace spans every monitor, so none is ever shown elsewhere | Workspace *n* is the same from every monitor, and the bar outlines one shown elsewhere; with an external display, closing the lid disables the panel and moves its workspaces over |
| §6.5: a new window on a workspace that asks for a name asks as it's first focused, unless it's a dialog, a status popup or one of home's apps; Super+Shift+Return asks for the focused window; Enter moves the window there and follows it; Esc closes a new one, unless it's pinned where it is | `openwindow`, `closewindow` and `activewindowv2` events, and `hyprctl clients -j` for the window first focused; `conf_workspaces.move` and `closewindow` dispatched | Built: window `new`, `close` and `focus` events, whose container is the window judged, so nothing is looked up, and `[con_id=N] move to workspace number NAME`, `focus` and `kill` (`shell/PromptData.qml`, `lib/tidewm.mjs`'s `promptEvent`) | A new terminal on a workspace that asks gets the prompt, and Enter moves it; a dialog doesn't ask; Esc closes the terminal |
| §6.5: a window pinned where it is stays open: Super+Backspace and the app's own close and quit keys leave it open, and say where it's pinned; every other window gets those keys | `hypr/tide/pinned.lua`, handed `tide-workspaces.lua`'s pinned list: a close bind and a bind for each app key that passes the key on for any other window | Built: tidewm's own `keep_open` (tidewm #62), set by the shell for each pinned window (`shell/PinnedData.qml`); `kill` leaves such a window open with a `close_refused` event, and conf binds the app's keys `--kept-open`, counted only in a window kept open | Super+Backspace and Ctrl+W leave a pinned window open with a notification, and Ctrl+W reaches every other window |
| §6.5: home is the first workspace after a login, stays while empty, and home's apps open there | `tide-workspaces.lua`, which conf's hyprland.lua reads: home's name, a persistent workspace and a rule for its apps | Built: `tide-tidewm` starts tidewm on home and keeps it with `persist workspace` (tidewm #8, #60); the shell keeps it from then on and sends home's apps there (`shell/WorkspacesData.qml`) | After a login home is current; it stays while empty; a home app opened elsewhere goes home |
| §6.7: Super+Z minimizes the focused window, which leaves the layout; the tray, the bar and the switcher show it, and a click or Enter, or anything else that focuses it, brings it back | A special workspace per workspace, `special:minimized:NAME`, which nothing shows; a silent move there, and a move back with `follow` (`Dispatch.minimizeWindow`) | Built: tidewm's own `minimize`, which hides the window on its workspace until anything focuses it (tidewm #51), the container's `minimized`, and the `minimize` window event; the shell reads a minimized window as on the minimize workspace (`lib/tidewm.mjs`'s `shellWindows`) | Super+Z hides a window and focuses the one before; its icon shows in the tray, and a click brings it back focused |
| §6.6: every binding works, including `locked` ones on the lock, release binds and submaps; `Super`+drag moves and resizes a floating window; dragging the master/stack edge, and a lone window's sides, with no key held | Binds in `conf`'s `hyprland.lua` | Built: the config file with `reload` (tidewm #12), submaps (#13), `--release` and `--locked` (#14) and `GET_BINDINGS` (#56). `floating_modifier` and button bindings, `focus` and `move` by direction, `resize`, `movestack`, and `workspace next` and `prev` (tidewm #65), which conf binds. Dragging the master/stack edge, with `resize_grab` and `single_width`, and `Super`+right-drag on a tile moving it (tidewm #68); tidewm sees a press on the bar's popovers itself, so the shell tells it nothing. The bar's nth workspace, `Super+Home`, `Super+Tab` and `Super+End` are the shell's, which keeps the bar's order and the workspaces used: conf binds them to `qs -c tide ipc call workspaces …` (`shell/WorkspaceKeys.qml`) | Every binding in §6.6 does its action, and keys work on the lock; a plain drag on the master/stack edge, and `Super`+right-drag on a tiled window, move the master split |
| §16: each output gets its configured mode, scale, position and single-window width, at login and when plugged in; the *advanced* Displays action edits it | `hl.monitor`, `monitor.added`; nwg-displays writes Hyprland's monitor config | Built: `output` lines with mode, scale, position and power, named by connector or description, `position auto` and the like, applied at plug-in and on reload (tidewm #16, #54, #61); the Displays page writes `tide-outputs.conf` (`lib/outputs.mjs`'s `outputsConf`) and lists `GET_OUTPUTS`. The *advanced* action runs nwg-displays as on sway (tidewm #71): it saves `~/.config/sway/outputs`, which tide's and conf's tidewm configs include (`lib/settings.mjs`'s `advancedFor`) | An output plugged in gets its settings; an advanced edit applies and survives a reload |
| §17: apps are sharp at fractional scale, X11 ones included | Hyprland's fractional-scale-v1 and viewporter; `xwayland:force_zero_scaling` | Part: `xwayland_scaling disable` puts X11 windows in their outputs' own pixels (tidewm #45, #46), and conf's tidewm config sets it. Left: an X11 app's own cursor is still scaled (tidewm's *Known bugs*) | At 1.25, a native Wayland app and an X11 app are both sharp and the right size |

## Bar (§7)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §7.1: the title names the focused window, on its monitor's bar only, including under a special workspace or when pinned; it goes blank when focus moves to an empty workspace, and is right just after a shell restart | `Hyprland.activeToplevel` with its monitor; the `activewindowv2` event; `hyprctl activewindow -j` at startup | Built: `GET_TREE` once and window `focus` events, the focused window's `output`, and the current workspace (`shell/TidewmData.qml`, `lib/tidewm.mjs`) | With two outputs, only the focused one's bar shows a title, and it follows focus; it's right after a shell restart and blank on an empty workspace |
| §7.1: tiling starts below the bar | wlr-layer-shell exclusive zone | Built: dwl's exclusive zones shrink the window area, and `GET_OUTPUTS` reports it as `window_area` (tidewm #48) | Windows never sit under the bar |
| §7.2: the workspace chips follow opens, closes, moves, fullscreen and urgency; clicking a chip or an icon goes there; scrolling over them moves through workspaces; right-clicking one changes its layout once that's built | `Hyprland.toplevels`, `Hyprland.workspaces`; `openwindow`, `closewindow`, `movewindowv2`, `fullscreen`, `changefloatingmode`, `urgent`, `activespecial` events; `Hyprland.dispatch` | Built: `GET_WORKSPACES` and workspace events through Quickshell's I3 module, and `workspace number NAME` (`shell/Compositor.qml`); `GET_TREE` and window events for the windows, and `[con_id=N] focus` and `move` for an icon's click; window `focus`, `close` and `urgent` events for the marks (`lib/tidewm.mjs`'s `markEvents`). A chip's right-click layout menu isn't built on either compositor | The bar on a fork matches the mocks, and clicks, scrolling and urgent marks work |
| §7.1, §8, §9: popups, the OSD and the notification center open on the focused monitor; a popup's countdown runs only there; the center key opens it rather than closing it | `Hyprland.focusedMonitor`, `monitorFor(screen)` | Built: `GET_OUTPUTS`' `focused`, asked again on tidewm's output focus event (tidewm #50), through Quickshell's I3 module (`shell/Compositor.qml`) | Popups and the OSD open on the focused monitor and expire there; the center key opens it |
| §7.1: after a shell restart, the layout symbol's fallback is right on a rotated monitor | `Hyprland.monitors` (`width`, `height`, `transform`) | Built: after a restart the bar reads `GET_WORKSPACES` and `GET_OUTPUTS`, transform included, and `Bar.qml` and `LayoutSymbol.qml` no longer ask `Hyprland.monitorFor` on tidewm | On a rotated ultrawide, the symbol is right after a restart |
| §7.4: the bar warns of config errors, and a notification says so once | Nothing: `hyprctl configerrors` and Hyprland's own error bar | Built: `GET_CONFIG`'s `errors` through `tide-msg`, asked as the shell connects, when a key bound to `reload` runs (the `binding` event) and after each reload of the shell's own (`shell/ConfigErrorsData.qml`, `lib/configerrors.mjs`). Left: tidewm has no event for a reload, so one from a terminal isn't seen until the next of those | `configerrors_test.mjs`; in a session, a bad line shows the triangle and one notification, and fixing it and reloading takes the triangle away |

## Launcher, notifications and lock (§8, §9, §10)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §8, R14: tapping Super opens the launcher; `Super+T`, `Super`+drag and `Super`+click don't | A release bind on `SUPER_L`, then Hyprland's global shortcut `tide:launcher` | Built: a `--release` binding is a tap only with no button or scroll meanwhile (tidewm #14, #34); conf binds `--release Super_L` to the launcher | §8's three checks |
| §8, §9: the launcher, share picker, region picker and lock keep the keyboard while a window opens beneath them or the pointer crosses one; clicking a notification's inline-reply field gives it the keyboard | wlr-layer-shell exclusive and on-demand keyboard focus | Built: dwl keeps an exclusive layer's keyboard; an on-demand layer, a notification's reply field, keeps it once clicked until you move focus (tidewm #40) | Typing in each, and in a notification's reply field, is never lost to a window |
| §8, §14.3: `Ctrl+Enter` runs an app on the workspace you name in the name prompt: its first window moves there as it opens and focus follows; nothing moves if the grant is canceled, and a quick action behaves as `Enter` | A grant option naming the workspace, which the guard reads (`tide launch`) | Built: `grant --workspace NAME` takes the first window there with focus (tidewm #22), and `tide launch` passes the name prompt's answer (`bin/tide`) | `Ctrl+Enter` opens the app on an empty workspace with focus there; a canceled grant moves nothing |
| §8: Screenshot window and Screenshot screen capture what the launcher opened over | `hyprctl clients -j` (`stableId`, `at`, `size`); the launcher remembers the monitor | Built: `GET_TREE` gives each window's `foreign_toplevel_identifier`, `rect` and `output` (tidewm #7). The launcher's Screenshot window reads `GET_TREE` on tidewm and shoots the recorded window's `rect` (`lib/launcher.mjs`), and scripts' `screenshot` asks tidewm through `tide-msg` where `SWAYSOCK` is set | Each captures the window or monitor the launcher opened over, even after focus moves |
| §9: a click outside the notification center closes it; moving the pointer across doesn't | `HyprlandFocusGrab` (`hyprland_focus_grab_v1`) | Built: tidewm takes hyprland-focus-grab-v1 (tidewm #44), so the center's `HyprlandFocusGrab` works unchanged | A click outside closes it; crossing it doesn't |
| §8.4: the picker pastes into the window it opened over, which keeps focus | Hyprland's `send_shortcut` dispatcher | Built: tidewm's own `send_shortcut` (tidewm #59), through `Compositor.qml`'s `sendShortcut` | A picked entry pastes into that window |
| §8.6: holding a letter offers its accents, through fcitx5 | text-input and input-method protocols | Built: dwl 0.9's text-input and input-method (tidewm's `ime.h`); `tide-tidewm` sets fcitx5's variables for every app | Holding a letter in a GTK and a Qt app offers its accents |
| §10: the lock, with restore after a crash | ext-session-lock; `allow_session_lock_restore`; `hl.clear_crashed_lockscreen()` from a TTY | Built: ext-session-lock; a new locker takes over a dead one's lock, and tidewm's own `unlock` drops it from a TTY (tidewm #39). §10's ways out name `unlock`. Left: M5's crash walk | §10's lock checks and crash walk: restarting `tide-lock` after a crash brings its password field back without showing or focusing any window in between |
| §10: idle locks at 5 minutes and turns the screens off at 5.5; keep awake holds; if M5 finds Chrome holding an inhibitor on ordinary pages, a per-window rule ignores it | ext-idle-notify and idle-inhibit; `hyprctl dispatch` dpms from hypridle; `idle_inhibit none` if needed | Built: ext-idle-notify and idle-inhibit, and `tide displays off` and `on` as tidewm's `output * power` (tidewm #61), so `wlopm` isn't needed. A per-window inhibitor rule isn't built, and waits on M5 | Screens lock, go off and come back on input; keep awake holds; if the rule is needed, an ordinary Chrome page doesn't keep the screens on while a fullscreen video does |

## Screen sharing and screenshots (§12, §13)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §12: share a window or a monitor in Meet, through tide's picker with live thumbnails | xdg-desktop-portal-hyprland with `tide-share-picker`; `tide-portals.conf` names `hyprland;gtk`; Quickshell's `ScreencopyView` | Built: xdg-desktop-portal-wlr with `tide-share-picker --dmenu` as its chooser (conf's `xdg-desktop-portal-wlr/tidewm`), `tidewm-portals.conf` naming `wlr;gtk` (tidewm #47, and tide installs its own). A window or a whole screen is all the picker needs (2026-11-06), so no thumbnails of windows. `setup` installs xdg-desktop-portal-wlr with tidewm, and doctor checks for it. Left: the restore flag waits on xdpw being patched, so every share prompts (decided 2026-11-02); not yet run in Chrome | §21.1 step 1; the picker shows live outputs; ticking "reuse the choice" restores a window share and a monitor share, and leaving it unticked restores neither; a file chooser and OpenURI still work through GTK |
| §12, §9: the Sharing pill shows during a share and not for a screenshot; popups are held for a screen or region share but not a window share | `ShareData.qml` watches PipeWire's `xdph-streaming-*` nodes and pairs each new one with the picker's recorded choice; the `screencast` event, not read yet, is kept as a prompt to re-check | Built: `lib/share.mjs` also matches xdg-desktop-portal-wlr's `xdpw-stream-*` nodes, which `ShareData.qml` pairs with the picker's choice as on Hyprland. tidewm's `capture` event (tidewm #41) isn't used, since a `grim -T` screenshot fires it too | The pill shows for a Meet share and not for a `grim` shot; a window share holds no popups, and a screen or region share does |
| §12: the notifications and the launcher show black to the far end of a share | `no_screen_share` on `tide-notifications`, `tide-launcher` and `tide-share-picker`, in `conf`'s `hyprland.lua` | Not built: deferred by the maintainer (2026-11-04, tidewm's TODO.md, *Decided*). It needs an output source rendered without those namespaces, or wlr-screencopy dropped | A popup, the center or the launcher during a share shows black to the far end |
| §13: window, screen and region screenshots; `Alt+Print` captures the focused window, falling back to its geometry if `grim -T` fails | ext-foreign-toplevel-list and ext-image-copy-capture; wlr-screencopy; `hyprctl activewindow -j` (`stableId`, `at`, `size`) | Built: the protocols, and each window's identifier and `rect` in `GET_TREE` (tidewm #7), which scripts' `screenshot` reads on tidewm; conf's tidewm config binds `Alt+Print` | Each screenshot captures; with `grim -T` made to fail, `Alt+Print` falls back to `grim -g` |
| §13, §16.2: a screenshot pastes into another app, and copying adds a clipboard-history entry | wl-data-device and a data-control protocol, for `wl-copy` and `wl-paste --watch cliphist store` | Built: dwl has wl-data-device and both wlr- and ext-data-control | A screenshot pastes as `image/png`; copying text adds a history entry, with the distro's packaged wl-clipboard |

## Focus and attention (§14)

| Requirement | Today | Fork | Check |
|---|---|---|---|
| §14.1, §9: a new window takes focus only with a grant (launcher, terminal, notification click, the app you're in); the rest open unfocused and marked urgent; a notification click that opens nothing focuses the app's most recent window | `no_initial_focus` on every window; `focus.lua` on `window.open`, `window.urgent`, `window.active`, `window.close`; grants over `hyprctl eval 'tide_focus.grant(…)'` and friends | Built: tidewm's guard, `focus_guard enable` in conf's config, and `grant`, `grant extend` and `grant --or-recent` (tidewm #22, #23); `tide`, `tide-grant` and the shell grant through `tide-msg` | `focus_test.lua`, `tide_test.sh` and `tide-grant`'s tests, ported; a launched app's first window takes focus, and a background app's doesn't |
| §14.1: a polkit prompt takes focus only when its requester descends from the focused window's process and your last input, key or click, went to that window within 2 s; otherwise a notification offers **Authenticate** | `focus.lua`'s `prompt_may_focus`, which sees only key presses and not the requester, so a click takes the notification path: agent windows (`prompt_classes`) ask it as they open, and the shell's agent (`TIDE_POLKIT=1`) through `tide prompt-focus` (`hyprctl repl`) | Part: `GET_SEATS`' `last_input` and `prompt_may_focus` (tidewm #25, #49), which `tide prompt-focus` and the shell's agent ask (`lib/agent.mjs`). Left: the requester check. As on Hyprland, nothing asks whether the requester descends from the focused window's process: `shell/PolkitData.qml` calls `tide prompt-focus` without the requester, and `PromptMayFocus` (`internal/swayipc`) reads only the seat's answer | A `pkexec` typed in a terminal, or an app's Unlock click, opens the prompt with focus; `sleep 30; pkexec …` left idle, or a request from a background process, gives the notification instead |
| §14.1: an app's own activation request, Wayland or X11, marks it rather than focusing it | `focus_on_activate = false`; xdg-activation; `_NET_ACTIVE_WINDOW` through Xwayland | Built: Wayland's and X11's activation are marked unless a grant names the app (tidewm #22) | An app's activation is marked, not obeyed |
| §14.2: an app launched on workspace 2 that maps after you move to 3 opens on 2, unfocused, and 2 turns urgent; the other focus rules there (`follow_mouse`, no warps, focus on close) | `initial_workspace_tracking` (Hyprland's default) and the `hl.config` focus options | Built: no warps and focus follows the pointer, as in dwl. A grant remembers the workspace it was made on, and its window opens there, unfocused and urgent, once you've moved on (tidewm #70). Closing the focused window focuses the one under the pointer, after the re-layout, as Hyprland does, or the most recent where there's none or it's one the guard holds (tidewm #72) | §14.2's cases |
| §14.3: a grant lapses once you type or click elsewhere; a stale one expires; a grant matches a window from a child process | `input.keyboard.key` (mouse buttons aren't exposed yet); `hl.timer`; `hl.get_windows()` with `pid`, and `/proc` ancestry | Built: a key, a click or a focus move cancels a grant, a grant lapses after `grant_seconds`, and `--pid` matches a child process (tidewm #22) | A slow window opens unfocused after you type, or after you click inside the window you're already in; a stale grant expires; `nautilus .` from a terminal takes focus |
| §14.3, §14.4: refused windows are marked on the bar, `Super+A` lists them on the switcher's Attention tab, and the marks survive a shell restart; with no shell running, a refused window is still announced | `tide-attention` events; `announce_waiting()` and `set_order()`; `hl.notification.create` | Built: a held window is `urgent`, with `urgent_order` (tidewm #22, #24), so a restarted shell reads the marks from the tree; conf binds `Super+A`. Left: with no shell, a held window shows nothing, since tide's tidewm config has no borders, as tidewm decided (*No notice without a shell*), against this row | `Super+A` lists the marks; marks match the guard after a restart; with the shell stopped, a refused window is announced |
| §6.4, §14.1: X11 apps run, their dialogs float over their parent, and their window types are honored | Xwayland | Part: built with Xwayland by `setup`, X11 windows sharp at a fractional scale (tidewm #45, #46), dialogs floating over their parent. Left: an X11 window sometimes never maps, a dialog right after its window four times in ten, which keeps that test out of tidewm's suite (tidewm's *Known bugs*) | An X11 app runs and its dialog floats over its parent |

## tidewm today

Checked 2026-11-09, against tidewm `v0.0.1474` and the repositories named
above. Nothing was run in a real login.

Of the 48 rows, 40 are built on both sides, 4 in part and 4 not at all.
On 2026-11-02, dwl 0.9 met 5 of the 39 rows there were then, 21 in part
and 13 not at all; that table, with dwl's line numbers, is in this file's
history. Of the 8 rows left, tidewm itself lacks something in 4; the
rest need only tide, conf or scripts.

| Row | tidewm | tide, conf, scripts | Left |
|---|---|---|---|
| §11 greeter | done | tide: no | The greeter on tidewm, with its displays off by `output * power` |
| §17 fractional scale | part | conf: done | X11 cursors at a fractional scale |
| §10 lock restore | done | tide: done | M5's crash walk |
| §12 share | done | scripts: done | A share in Chrome; the restore flag waits on xdpw |
| §12 hide from capture | no | — | Deferred by the maintainer: an output source without the shell's surfaces (L) |
| §14.1 polkit | done | tide: part | The requester check: whether it descends from the focused window's process, unbuilt on Hyprland too |
| §14.3 marks | part | — | A notice for a held window with no shell running, which tidewm decided against |
| §6.4 X11 | part | done | X11 windows that sometimes never map, a dialog after its window most of all, in wlroots and Xwayland |

**Getting tidewm onto a machine** (scripts' `setup-tide`):

- `setup` builds tidewm's latest `main` (unless `--no-tidewm`), which tidewm's CI gates.
  It asks GitHub which commit `main` is at and builds that one, so a rerun
  rebuilds only once `main` has moved. Offline, it keeps the build it has.
- It uses the distro's wlroots 0.20 on Debian testing and Arch. Where
  `pkg-config` finds no `wlroots-0.20` on Debian or Ubuntu (Ubuntu 26.04 has
  0.19, Debian 13 none), `install/wlroots` builds `deps.lock`'s wlroots group
  with meson into tidewm's own build directory, as §21.1 first proposed:
  wlroots 0.20.2, after whichever of wayland, wayland-protocols, libdrm,
  xkbcommon and pixman the distro has older than wlroots needs (all five on
  Debian 13, none on Ubuntu 26.04). tidewm builds against it through
  `PKG_CONFIG_PATH`, and it and each library carry a run path to that
  directory's `lib`, so only tidewm loads them. A new wlroots pin rebuilds
  tidewm. meson never downloads wlroots' own wraps, which follow each
  project's `HEAD`.
- Fedora isn't built on yet.
- It installs xdg-desktop-portal-wlr, which `setup`'s purge of obsolete
  packages keeps while tide is set up.
- `wlopm` isn't needed: tidewm turns outputs off itself (tidewm #61).

**tidewm's own plan**, after tide's rows: gestures (in progress),
keyboard-shortcuts-inhibit, xdg-foreign, security-context, then sway's
touchscreens, tablets, wlr-foreign-toplevel-management, adaptive sync and
a scratchpad. None is a row here. Its known bugs beyond the rows above: a
wlroots race that loses an X11 window's state set before it maps, and a
136-byte leak in dwl's output management.

**Before tidewm can be the default**, beyond a first real login: the
greeter and the keys conf's tidewm config still leaves out. Hiding the shell from capture is the one
row where tidewm would do less than Hyprland on purpose, until it's built.
