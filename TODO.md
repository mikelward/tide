# TODO

Deferred work, with enough notes to pick it up later.

## Decisions needing review

Calls made on autopilot, each chosen for being cheap to undo. Delete an entry
once you have agreed with it or reversed it.

- [ ] **A launcher entry with no `StartupWMClass` grants named classes,
  not any app's window.** It grants its desktop ID and program (unless a
  wrapper), where it used to grant `*`. An app whose window class is
  neither now comes up unfocused and marked instead of focused; in
  exchange, an unrelated window that opens first no longer takes the
  focus. Reverting is one line in `grantIds`: return `["*"]` when the entry
  names no class.
- [ ] **A terminal command waits for its desktop-entry lookup.**
  `tide-grant` reads desktop entries before the command runs, about 4 ms
  over 300 entries, so a command costs about 7 ms where it cost 3. Done
  in the background, an already-running app could activate its window
  before its class was granted. The alternative is a cache of program to
  classes, invalidated when the applications directories change; it's
  `extendFromEntries` in `cmd/tide-grant/main.go`.
- [ ] **Entries running one program with different arguments grant
  nothing.** Each `libreoffice --writer`, `--calc` and plain `libreoffice`
  entry is its own app, so a key binding or terminal command running
  `libreoffice` grants only that name, and a Writer window whose class is
  `libreoffice-writer` may come up unfocused. Telling them apart by the
  command's arguments was tried, first in order and then by prefix, and
  review kept finding commands it misread (option values, field codes
  inside an argument, an argument only the shell could expand). The
  alternative is to bring that matching back; the launcher's own entries
  are unaffected, since it grants the entry it launches. It's the
  `slices.Equal` check in `desktopClasses`, `cmd/tide-grant/desktop.go`.
- [ ] **The autostart allowlist starts as `nm-applet` and `blueman`.** The
      spec says it starts empty, but the bar's network and Bluetooth icons
      come from those applets' autostart entries until the shell draws them
      (M3). Emptying it is a one-line change to `autostart_default` in
      `bin/tide`.
- [ ] **A marked window's icon stays in view past five windows.** SPEC.md
      §7.2 shows five icons then `+n`; when a ringed (urgent) window would
      be past the fifth, it takes a place ahead of unmarked windows, so the
      ring is never hidden in `+n`. The alternative is plain window order,
      leaving the workspace's amber fill as the only cue. It's one function,
      `icons` in `shell/lib/workspaces.mjs`.
- [ ] **A notification's marks stay when its popup times out.** SPEC.md
      §14.4 clears them when it's dismissed; an action invoked from it, a
      reply, or its app closing it counts as that too, but running out of time on
      screen doesn't, since nobody has looked yet. The alternative clears
      them on every close. It's `clearsMarks` in
      `shell/lib/notifications.mjs`.
- [ ] **Focusing one window an app-wide mark covered clears the whole
      mark.** SPEC.md §14.4 says the state clears when a marked window is
      focused; with Nautilus marked on two hidden workspaces, visiting one
      clears both. The alternative clears only the focused window, leaving
      the other workspace amber until visited too. It's the `focused` case
      of `updateMarks` in `shell/lib/workspaces.mjs`.
- [ ] **A history file that isn't valid JSON is replaced.** The shell warns
      and starts an empty history, which its next write saves over the
      damaged file; one it can't read at all (permissions) is left alone,
      and that shell's history isn't saved. The alternative keeps the
      damaged file aside as `notifications.json.bad` first. It's the
      `FileView` in `shell/HistoryData.qml`.
- [ ] **A system critical shows during a share.** SPEC.md §9 shows a
      critical on a monitor that isn't shared, else holds it with the bell
      flashing; for now a system sender's critical gets through a share as
      it does manual Do not disturb, wherever popups go, relying on the
      `no_screen_share` layer rule to black it out of the stream. The
      alternative holds every popup during a share. It's `quiet` in
      `shell/NotificationData.qml`.
- [ ] **Do not disturb lasts until the shell restarts.** It survives a
      config reload (`PersistentProperties` in `shell/NotificationData.qml`),
      but a new shell starts with it off, so it can't be left on by
      accident. The alternative saves it with the history in
      `notifications.json`.
- [ ] **A notification Do not disturb holds is expired at once.** It goes
      to the history and keeps its marks, but its app is told it expired,
      as when a popup times out. The alternative keeps it open until
      Do not disturb ends and shows it then. It's `holdForDnd` in
      `shell/NotificationData.qml`.
- [ ] **The bar follows the desktop's light/dark color scheme for now.**
      SPEC.md §15 has the shell own the schedule (`appearance.json`); until
      it does, `shell/Theme.qml` watches `org.gnome.desktop.interface
      color-scheme`, which conf's theme daemon already flips. The
      alternative was building the shell's schedule first. The watch is two
      `gsettings` processes in `Theme.qml`, easy to swap for the shell's
      own schedule later.
- [ ] **The bar can miss a light/dark flip at its own startup.** `gsettings
      monitor` has no "ready" signal, so a flip in the instant before it
      subscribes leaves the startup read's old value up until the next flip
      (at most twice a day). Accepted for now; the alternatives were polling
      `gsettings get` every minute, or building the shell's own schedule
      (SPEC.md §15), which removes the watch altogether. It's `Theme.qml`.
- [ ] **The bar's status icons are the icon theme's symbolic icons, not
      Material Symbols.** SPEC.md §15 picked Material Symbols Rounded for
      the shell's glyphs, and now names symbolic icons instead: no distro
      setup installs that font yet, and a missing font shows the ligature
      names as text. Adwaita's symbolic
      icons are on every GTK desktop; `SymbolicIcon.qml` tints them with
      `QtQuick.Effects`, which Debian and Ubuntu package as
      `qml6-module-qtquick-effects`. Switching means installing the font and
      changing `SymbolicIcon.qml` and the names in `shell/lib/status.mjs`.
- [ ] **The clocks popover names each zone by the city in its zone ID.**
      The mock says "San Francisco" and "Local"; tzdata only knows
      `America/Los_Angeles`, so the popover says "Los Angeles", and local
      shows its own city (or "Local" when it has no zone ID). The
      alternative is an optional `city` field in `clocks.json`. It's
      `cityOf` in `shell/lib/popover.mjs`.
- [ ] **The popover always shows the next DST change, however far off.**
      Within two weeks it leads with "Clocks change soon.", as in the mock;
      otherwise with "Next clock change:". The calendar underlines the days
      the clocks change. The alternative is hiding the line until a change
      is near. It's `dstLead` and `SOON` in `shell/lib/popover.mjs`.
- [ ] **The battery popover always offers the power profiles.** They need
      power-profiles-daemon (or Fedora's tuned-ppd, which serves the same
      D-Bus API). Quickshell 0.3's `PowerProfiles` has no "available" flag,
      so without the daemon the rows still show and choosing one only logs
      a warning. The alternatives are hiding the rows when the D-Bus name
      has no owner, or having `setup --tide` install the daemon. It's
      `shell/BatteryPopover.qml`.
- [ ] **The DST sentence names clocks by their bar labels.** SPEC.md §7.3's
      example says "London moves to GMT"; `dst.mjs` says "LON moves to GMT",
      since `clocks.json` has labels, not city names. A clock labeled `abbr`
      is named by its abbreviation before the change, and one with no label
      by the city in its zone ID (`Europe/London` gives London). The
      alternative is that city name for every clock. It's `clockName` in
      `shell/lib/dst.mjs`.
- [ ] **The DST sentence groups changes and describes one gap.** Review
      kept finding edge cases in the grouping (zones that move together,
      one instant on two calendar days, transitions a day apart), each now
      fixed and tested. The simpler alternative is a plain list of each
      clock's next change, with no gap sentence; it drops SPEC.md §7.3's
      "a week before" line, which is the point of the feature. It's
      `nextDstChange` and `dstMessage` in `shell/lib/dst.mjs`.
- [ ] **Monocle with nothing hidden shows `[M]`, not `[0]`.** SPEC.md §6.1
      says monocle shows the hidden count; with one window there's nothing
      hidden to count. It's `layoutSymbol` in `shell/lib/layouts.mjs`.

## Transitional shell (M2)

`tide.service` runs `bin/tide-shell`, not `qs -c tide`,
because the Quickshell shell can't be built or tested in the sandbox and the
MVP comes first. The bar and tray watcher are the Quickshell shell's
(`qs -c tide`) when it's installed, else waybar's; swaync (notifications)
is run by `conf`'s theme daemon, as waybar is when that's the bar; plus the
first polkit agent found and swww for the wallpaper (swaybg where swww isn't
packaged). It also runs
`conf`'s `apply-input.sh` once, since Hyprland's config starts nothing but
`uwsm finalize` in this session.

- Replace it piece by piece as M3 (bar, launcher) and M4 (notifications)
  land: each Quickshell owner joins the shell's ready check, and its old
  owner leaves `tide-shell`.
- Until then the polkit agent isn't part of the ready check, and the tray
  and notifications look like today's, not the mocks.
- The polkit agent is restarted on its own, with backoff, rather than
  failing the unit (SPEC.md §5.2's M2 note). The Quickshell agent has to
  keep that: another desktop's agent can hold the session first, and the
  bar mustn't restart over it.
- Ready is checked once, at start. After that the shell watches only the
  theme daemon, which restarts waybar and swaync at each light/dark
  boundary. For that moment the notification and tray names are unowned,
  and an app launched then doesn't wait for them. Failing the unit on
  their loss would restart the whole shell at every theme change instead.
  It goes away with the Quickshell owners, which change theme without a
  restart (SPEC.md §5.4).
- A polkit prompt takes focus only after a key press (the keyboard half of
  SPEC.md §14.1); after a click it waits for `Super+Tab`, and there's no
  **Authenticate** notification yet. Both come with the Quickshell agent.
- The Quickshell bar marks the windows the focus guard leaves waiting
  (`tide-attention`, in `shell/MarkData.qml`), and it's now the bar
  wherever Quickshell is installed. The guard shows a Hyprland notification
  for each only until the bar first calls `set_order`, so under
  `TIDE_BAR=waybar`, which can't mark them, it still does. Drop
  `notify` once waybar goes.
- The theme daemon restarts swaync at each light/dark boundary (and waybar,
  when it's the bar); the Quickshell bar changes theme in place.

## Bar (M3)

The Quickshell bar replaces waybar piece by piece (SPEC.md §7), each piece
tested where it can be without a live session.

- Keep awake (SPEC.md §10) is the bar toggle, and it also holds while the
  mic is live: an app's capture stream with an active PipeWire link from a
  microphone (`shell/MicData.qml`, `shell/lib/mic.mjs`), the same signal
  the orange mic indicator (§7.4) will use. Meters don't count: a stream
  marked `media.category` Monitor or Manager, or `stream.monitor`
  (pavucontrol's, through pipewire-pulse). On a live session, check that a Meet call holds it, and
  that pavucontrol's level meters don't.
- The orange mic pill (§7.4) is `shell/MicPill.qml`, left of the tray
  beside the Sharing pill, shown while `MicData.live`; a click lists each
  app recording, and a click on one mutes or unmutes its recording
  (`shell/MicPopover.qml`, `captureRows` in `shell/lib/mic.mjs`). Only
  parsed with `qmlformat`: on a live session, check that a Meet call shows
  it and its mute works.
  On a live session, check that hypridle honors the bar's inhibitor,
  including while a fullscreen window covers the bar.
- The launcher (SPEC.md §8) is `shell/LauncherWindow.qml`: fuzzy search
  over desktop entries and their actions (`shell/lib/fuzzy.mjs`,
  `shell/lib/launcher.mjs`), run through `tide launch`. It answers
  Hyprland's `tide:launcher` global shortcut and
  `qs -c tide ipc call launcher toggle`. Only parsed with `qmlformat`.
  Still to do:
  - Point `conf`'s `Super+Space` at `global, tide:launcher` instead of
    fuzzel, once it's been tried live.
  - Quick actions: screenshots, the session actions, Do not disturb (while
    the shell serves notifications), keep awake and reload are in, with
    their keys shown. A blocked power action
    keeps the launcher open and asks, naming what blocks it, as the
    session menu does. Still to come: Settings and the theme (dark /
    light / automatic), which wait on the shell owning the schedule (§15).
  - Frecency is in: the empty query lists the apps you run most and most
    recently first, and a query puts them first among equal matches; kept in
    `$XDG_STATE_HOME/tide/launcher.json`.
  - Sections are in, with `Tab` and `Shift+Tab` stepping through them.
  - `Ctrl+Enter` is in: the focus guard takes the app's first window to
    the first empty workspace as it opens (`tide launch --new-workspace`).
    On a live session, check that the window doesn't flash on the
    workspace you were on before it moves, and that the launcher's unmap
    doesn't refocus the window you were in after the move.
  - "Screenshot window" records Hyprland's focused window's address as the
    launcher opens, then reads its geometry with `hyprctl clients -j` as
    the screenshot runs and passes it to `screenshot --geometry`, the same
    capture `--window` makes. §13's `grim -T <stableId>`, which captures a
    window's own contents even under a popup, waits on the script (in
    `mikelward/scripts`) taking a window to capture; the launcher would then
    record the `stableId` instead. On a live session, check it takes the
    window you were in.
  - "Screenshot screen" takes every monitor, as `Print` does today: the
    script's screen mode is a bare `grim`. §13's `grim -o <focused output>`
    waits on the script taking an output; the launcher would then record
    its monitor as it opens and pass it, so a focus change while it closes
    can't move the capture to another display.
  - On a live session, check that typing reaches it with the pointer over
    a window (§14.2), and that an app it starts takes focus.
- The system monitor (SPEC.md §7.4) is built but unchecked on a live
  session: the CPU % against `top`, the sensor picked on an Intel and an
  AMD machine, and the throttling line under load.
- The system monitor reads every CPU package's throttle counter and
  sensor; on a live multi-socket machine, check both packages are found
  and that the bar follows the hotter one.
- The clocks collapse to local alone when the title would get under 200 px
  (SPEC.md §7.3). On a live session, check the switch at the edge: resize
  or plug in a monitor across it, and watch for the clocks flickering
  between the two, which `collapseClocks` is built to prevent.

- Clock logic is in `shell/lib/clocks.mjs`: the `.local` list rule, hiding
  the local zone, day offsets and labels, tested with `node --test`.
- Workspace logic is in `shell/lib/workspaces.mjs`: the four states, icons
  up to five then `+n`, urgency from Hyprland and from notification marks
  (§14.4), the maximized/fullscreen glyph and scroll steps. Marks are kept
  as events arrive (`updateMarks`), since what a notification marked
  depends on what was on screen when it came; the QML feeds it Hyprland's
  and the notification daemon's events.
- Reconsider, once the bar is in daily use, whether a replaced
  notification should mark its workspace again after a focus cleared it.
  Today it does: Chat in Chrome replaces one conversation's notification
  with each new message, and a reply to a conversation already looked at
  is news. If that turns out noisy, keep a focused notification cleared
  until it's dismissed. Agreed with the maintainer; it's the `notified`
  and `focused` cases of `updateMarks` in `shell/lib/workspaces.mjs`.
- The tzdata reader is `cmd/tide-tz`, and `shell/lib/tzdata.mjs` turns
  its output into the clocks' lookups and the time of the next re-run.
- The bar itself is `shell/*.qml` (`qs -c tide`): one panel per
  monitor with the workspaces and clocks. It has only been parsed with
  `qmlformat`, not run, since Quickshell can't run in the sandbox. Next:
  - Try it on a real session, beside waybar.
  - `Super+Tab` and `Super+Home` both run the focus guard's
    `focus_attention()`, on trial: keep whichever sticks in daily use and
    free the other. It steps through the guard's waiting windows and the
    shell's notification marks while Super is held (§14.3). On a live
    session, check that conf's release binding on Super fires after
    Super+Tab, and that a window focused by stepping doesn't lose its mark
    on the bar.
  - `updateMarks` is fed the focus guard's events (`shell/MarkData.qml`,
    via `markEvent`), Hyprland's urgent flag and `urgent` events, and
    notifications' events while the shell is the notification server
    (`TIDE_NOTIFICATIONS=1`). On a live session, check:
    - that the Lua side's addresses match Quickshell's
      (`normalizeAddress` takes either form);
    - which window classes the apps in use give, against the desktop
      entry or app name their notifications send (`sameApp`). Chrome's
      `--app` windows are the known gap (§14.4).
  - The layout symbol is `shell/LayoutSymbol.qml`, from
    `shell/lib/layouts.mjs`. On a live session, check that a Hyprland
    config reload resets `layout.lua`'s modes, as `LayoutData.qml` assumes
    when it forgets them on `configreloaded`.
  - Right-click a workspace for the layout menu (§7.2): not wanted yet, so
    decide whether to keep it before building it. If it stays, choose
    between switching to the workspace before the menu opens and adding a
    workspace argument to `layout.lua`'s `layoutmsg`. A plain `layoutmsg`
    also doesn't announce the new mode today.
  - A bad clocks file is a notification naming the file and line
    (§16.1), and a zone in it that doesn't load one naming the file and
    entry, at most once per distinct error while the shell runs
    (`shell/lib/report.mjs`, through `notify-send`; one undelivered at
    login is retried). On a live session,
    check that one arrives, and that a reload with the same error is quiet.
  - `Theme.qml` reads its light and dark colors from `theme/palette.json`,
    which `make palette` turns into `shell/lib/palette.mjs` (`make test`
    fails when that's stale, or when the palette and the mocks'
    `common.css` disagree), and follows the desktop's `color-scheme`.
    Next for §15: generate GTK's, Qt's and Hyprland's colors from the
    same file (M7), and move the light/dark schedule from conf's theme
    daemon into the shell (`appearance.json`).
  - Status icons (§7.4): `shell/StatusIcons.qml` has volume (scroll by 5%)
    and battery (red below 15%), from `shell/lib/status.mjs`, and the
    session menu (`shell/SessionMenu.qml`, from `shell/lib/session.mjs`).
    On a live session, check that a blocked suspend lists its inhibitors.
    The battery popover (`shell/BatteryPopover.qml`) has the time left and
    the power profile. The volume popover (`shell/VolumePopover.qml`, from
    `shell/lib/audio.mjs`) picks the output and input and sets each app's
    level. Bluetooth (`shell/BluetoothPopover.qml`, from
    `shell/lib/bluetooth.mjs`) shows off, on or connected, and connects
    paired devices; pairing opens blueman-manager.
    The network icon and popover (`shell/NetworkPopover.qml`, from
    `shell/lib/network.mjs`) use Quickshell 0.3's `Quickshell.Networking`
    (NetworkManager): wired, Wi-Fi strength, no route or offline; Wi-Fi on
    and off, connecting with a password asked for in place, and
    nm-connection-editor for the rest. Wi-Fi scanning is shared across
    monitors' popovers, in `shell/NetworkData.qml`. VPNs (§7.4), which
    `Quickshell.Networking` 0.3 doesn't list, come from `nmcli`
    (`shell/lib/vpn.mjs`): a lock on the network icon while one is up,
    faint while it connects, and a row each in the popover that brings it
    up or down. They're read again on each `nmcli monitor` line, when a
    popover opens, and every minute. On a live session, check that the
    lock follows a VPN brought up from elsewhere without the minute's
    wait, and that one needing a password asks through the polkit or
    nm-applet secret agent.
  - The tray (`shell/Tray.qml`, from `shell/lib/tray.mjs`) shows apps'
    StatusNotifierItems, hiding passive ones as waybar did: a left or
    right click opens the menu (§7.4), and a middle click activates.
    With it the Quickshell bar replaced waybar in `tide-shell`.
    Try it live: an app's menu, and an app that registers before the bar.
  - The clocks popover (§7.3) is `shell/ClocksPopover.qml`, from
    `shell/lib/popover.mjs` and `shell/lib/dst.mjs`. Scrolling over the
    clocks scrubs them (`scrubbed` in `shell/lib/clocks.mjs`).

## Notifications (M4)

SPEC.md §9. So far the shell has the server and the popups. They're
opt-in, with `TIDE_NOTIFICATIONS=1`, until swaync retires: Quickshell
claims `org.freedesktop.Notifications` whenever the name is free, and it's
free for a moment each time the theme daemon restarts swaync, so an
always-on server would take it over by accident. `shell/NotificationData.qml`
holds the queue, and
`shell/NotificationPopups.qml` draws it on the focused monitor, from
`shell/lib/notifications.mjs`. A click grants focus to the sender's app
(`tide grant`) before invoking the action. Only parsed with
`qmlformat`; nothing has run in a live session. Still to do:

- Try it on a real session: stop swaync, run the shell with
  `TIDE_NOTIFICATIONS=1`, and check Chrome's notifications, a reply,
  and that a click brings up the right window.
- When a click's app sends no activation and opens no window within 10 s,
  and you haven't moved on, the focus guard brings up its most recently
  focused window, switching workspace (`grant_or_recent` in
  `hypr/tide/focus.lua`, through `tide grant`). On a live session, check it
  with an app that doesn't activate on a click, and that Chrome's own
  activation still wins.
- Bring up the browser window a notification came from, not just the
  browser's most recent one, when the browser's own activation doesn't
  arrive. Today the fallback picks the app's most recently focused window
  (§9 *Clicking*), which for Chrome with several windows may be the wrong
  one. Open questions before choosing how:
  - Can Quickshell hand the action an xdg-activation token? It doesn't
    emit `ActivationToken` today, so the browser can't be told which
    surface the click came from.
  - Does Hyprland 0.56 show the Lua guard which token, or which surface,
    an activation request carries? If so the grant could follow the
    token instead of the app.
  - Which browsers send a `sender-pid` hint, which would narrow the
    fallback to the sending process's windows?
- History: the center (`shell/NotificationCenter.qml`), the bell, and
  `notifications.json` (`shell/HistoryData.qml`, `shell/lib/history.mjs`)
  are in, behind the same opt-in; only parsed with `qmlformat`.
  `Super+Shift+N` in `conf` opens it (swaync's panel while the call
  fails). Persistence is in: a popup that times out leaves its notification
  resting, live on the server, until the center lets its entry go
  (`rest`, `unkept` in `shell/lib/notifications.mjs`). On a live session,
  check a timed-out Chrome notification's entry still opens its page, and
  that clearing the center releases it.
- A click on a center entry does what its popup's click does while its
  notification is live (shown or held), and otherwise brings up its app's
  most recent window (`tide focus`, `focus_recent` in
  `hypr/tide/focus.lua`). On a live
  session, check both, and that the center closes after.
- Do not disturb: manual DND is in (the center's tile, the bell's
  middle-click, and `qs -c tide ipc call notifications dnd`), with
  only system senders' criticals getting through (`passesDnd` in
  `shell/lib/notifications.mjs`); only parsed with `qmlformat`. Popups
  are also held while a share is live (`shell/ShareData.qml`,
  `shell/lib/share.mjs`: an `xdph-streaming-*` node with an active link
  out of it), with the center's "held while you were sharing" banner.
  Do not disturb is a launcher quick action too. Still to do: telling a
  window share from a screen
  share, once the picker records its choice (§12), so a window share
  holds nothing; showing a critical on a monitor that isn't shared; and
  the Sharing pill's click (§7.4: what is being shared), which waits on
  the same. The pill itself is `shell/SharingPill.qml`. On a live
  session, check that Chrome's consumer link reads as active.
- Retire swaync: the shell owns the name, joins the ready check, and
  `tide-shell` stops starting it; drop the opt-in.

## OSD (M4)

SPEC.md §9's OSD is `shell/Osd.qml`, from `shell/OsdData.qml` and
`shell/lib/osd.mjs`: a change to the default output's volume or mute, or the
default input's mute, from any source, and the backlight when the keys in
`conf` change it through `tide brightness STEP` and the shell's `osd`
`IpcHandler`. Only parsed with `qmlformat`. Still to do:

- Try it on a real session: the volume and brightness keys, the bar's
  scroll and the volume popover should each show it, and switching
  outputs or hypridle dimming shouldn't.

## The rest of `tide doctor`

M2's `tide doctor` (`bin/tide-doctor`) checks units, D-Bus
owners, duplicate and rival daemons, the portal config, Hyprland's config
errors, autostart entries, and a second bar on any monitor. SPEC.md §5.4
also wants:

- **Bars by a better signal than geometry.** Where tide's bar (layer
  `tide-bar`) is on a monitor, the check now also reports space reserved
  beyond its height, which catches a narrow bar or a dock that reserves
  space. A bar that reserves none, narrower than half the monitor, still
  goes unseen; `hyprctl layers` has no anchors to say more. On a live
  session, check that the bar's reservation matches its height at each
  scale, so a lone tide bar reports nothing.
- **Activatable services that could steal a name.** In M2 swaync's own
  activation file names `org.freedesktop.Notifications`, so flagging every
  activatable one would flag the owner. Check it once the shell owns the
  name, naming the service file and the package that ships it.

## Grants for terminal commands

Every shell in `conf` runs `tide-grant` (SPEC.md §14.3) before a
command except mesh, which waits until `conf` tests it (tracked in `conf`'s
TODO.md). Nothing has run it in a live session yet.

## Grants through desktop entries

The focus guard matches a grant against the window class alone (SPEC.md
§14.3), so a grant lists every class the app's window may have. The
launcher grants each entry its `StartupWMClass`, desktop ID and
program at once (`grantIds` in `shell/lib/launcher.mjs`, repeated `--app`).
Key bindings (`tide launch COMMAND`) and terminal commands (`tide-grant`)
grant the program the command runs, past wrappers, and the desktop ID and
`StartupWMClass` of each entry whose `Exec` runs it
(`cmd/tide-grant/desktop.go`). On a live session, check which apps in use
come up unfocused because their window class is none of those.

- `xdg-open` and `gio open`, from a key binding or the terminal, grant
  the default app for the target's type (`openerClasses` in
  `cmd/tide-grant/opener.go`). On a live session, check a URL and a file
  each bring up their app focused, with the browser already running.

## Fullscreen on open, under the focus guard

Deferred: it needs a Hyprland patch, and the MVP comes first.

- The guard's catch-all `no_initial_focus` rule makes Hyprland 0.56 skip a
  fullscreen request made as a window opens (`Window.cpp`: the initial
  fullscreen is applied only when `!m_noInitialFocus`).
- The guard can't re-apply it: Lua's window object has no field for
  `m_wantsInitialFullscreen`, and `fullscreen_client` stays 0 because the
  request was never applied.
- Until then, a window that opens fullscreen (a game, a video player
  started with `--fullscreen`) comes up tiled; `Super+Shift+Up` makes it
  fullscreen.
- Plan: expose the request as a window field (a few lines in
  `LuaWindow.cpp`), next to the pointer-button event (§14.3); the guard
  then re-applies it when it focuses the window.

## Drag to resize a tiled window

Deferred: it needs a Hyprland patch, and the MVP comes first.

- Floating windows already resize with `Super`+right-drag or by dragging an
  edge. Under the master fallback, dragging a tiled window changes `mfact`.
- Under `lua:tide` a drag does nothing. Hyprland 0.56 drops it before it
  reaches a Lua layout: `CLuaTiledAlgorithm::resizeTarget`
  (`src/config/lua/layout/LuaLayoutProvider.cpp`) ignores the delta and only
  recalculates.
- Plan: a small upstream patch that passes the delta and corner to an optional
  Lua `resize` callback. `layout.lua` then maps a drag across the
  master/stack boundary to `mfact`, per workspace and mode like
  `Super+\` / `Super+/`. Pick it up on the Hyprland upgrade PR that brings the
  patch in.
- Rejected: polling the cursor with `hl.timer` while the button is held. It
  works today, but it's a polling loop on a hot path and fights Hyprland's
  own drag.
- Until then, the keys resize the master.

## Double-click the bar to maximize

- Double-clicking the window title in the middle of the bar (SPEC.md §7.1)
  focuses the window it names and toggles maximize on it, like a title
  bar: `Title.barWindow` and `Dispatch.toggleMaximize`, wired in
  `shell/WindowTitle.qml`. Only parsed with `qmlformat`; on a real
  session, check it on the focused monitor and on another one.
- `Super`+middle-click does the same from the keyboard and mouse (SPEC.md
  §6.6, in `conf`'s `hyprland.lua`).
- Rejected: title bars from the `hyprbars` plugin. A plugin is rebuilt against
  every Hyprland upgrade (SPEC.md §3.1).

## Compositor: explore a dwl fork (SPEC.md §21.1)

Hyprland stays the baseline, but building it on Debian and Ubuntu is heavy,
so §21.1 records a tide fork of dwl on a pinned wlroots as the
alternative. The fork's code goes in
[mikelward/dwl](https://github.com/mikelward/dwl), which holds upstream's
history; tide's changes go on top of v0.9 there. Before rewriting §3.1 around it, work through §21.1's next steps:

- Screen sharing through `tide-share-picker` on xdg-desktop-portal-wlr,
  with an adapter, including a way to share the 16:9 slice.
- `grim -T` on a dwl build that exposes the toplevel-capture protocols.
- Re-check Debian 13's toolchain.
- Inventory everything the spec needs from the compositor, with the fork's
  replacement and a check for each.

If the fork is adopted, machines build a pinned release tag, never a branch:

- **Tags.** `tide-<upstream base>-<n>`, cut from the fork's `main`
  once it is in a state to run (`tide-0.9-1` is dwl 0.9 plus our
  changes, release 1). Upstream's own `v*` tags stay as they are, so a tag
  says at a glance whether it carries our code and which base it sits on.
  Moving to a new upstream release rebases our changes onto it and starts
  the count again (`tide-0.10-1`).
- **`setup-tide` pins one.** A line in the same shape as the Hyprland
  pins, `dwl https://github.com/mikelward/dwl.git tide-0.9-1 make`,
  so every machine builds the same reviewed code, and moving them all is a
  one-line scripts pull request that CI checks first. Not `main`, which
  moves under a later run; not `v0.9`, which is upstream's code without
  ours.
- **Protection.** `main` gets the fleet ruleset from `repo setup`, like
  every other repository. A tag ruleset makes `tide-*` and `v*`
  immutable, since a moved tag would silently change what machines build.
  The repository is public, so nothing secret ever goes in it, on any
  branch: per-machine settings stay in an untracked local file.
