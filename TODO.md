# TODO

Deferred work, with enough notes to pick it up later.

## Decisions needing review

Calls made on autopilot, each chosen for being cheap to undo. Delete an entry
once you have agreed with it or reversed it.

- [ ] **The settings files are read and written synchronously.** The Idle,
  Mouse and Touchpad settings' `FileView`s use `blockAllReads` and
  `blockWrites`, so each change re-reads the file and writes it before
  returning, with no read or write in flight for a change to race. It costs
  a blocking read or write of a file under 1 KB on the shell's UI thread, on
  a settings click or a change to the file; a slow home directory (NFS, say)
  would stall the bar that long. The alternative was keeping the settings in
  memory and sequencing changes around `FileView`'s background reads and
  writes, which review kept finding races in (PR 151). It's the
  `SettingsFile` component in `shell/IdleData.qml` and
  `shell/InputData.qml`.

- [ ] **A setting that can't be applied is retried every 30 s, for as long
  as it fails.** A failed write of `tide-idle.conf` or hypridle restart is
  one notification, then tried again on a timer with no limit. Outside a
  session that has hypridle's unit, `try-restart` does nothing and succeeds,
  so this costs nothing there. The mouse and touchpad settings do the same,
  but outside a Hyprland running `conf`'s config their `hyprctl eval` fails,
  so the shell notifies once and runs it every 30 s for as long as it runs.
  The alternative is a few tries with a backoff, then giving up until the
  next change; it's the `retry` timer in `shell/IdleData.qml` and
  `shell/InputData.qml`.

- [ ] **The settings pages run Idle, Sound, Network, Bluetooth, then the
  input devices.** That's the order you asked for; PR 155 had put Mouse and
  Touchpad after Idle. It's `PAGES` in `shell/lib/settings.mjs`, and §16's
  table, which the sidebar follows.

- [ ] **A wrong password doesn't shake the lock's field.** The mock had it
  shake once; tide-lock only clears it and shows the error under it. You
  insisted keystrokes never wait on an animation, and weren't sure about
  one after Enter. A shake after a failed check could be added back
  without touching keystroke feedback.

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
- [ ] **The launcher isn't hidden from a screen share.** SPEC.md §12 puts
      `no_screen_share` on popups, the notification center and the
      launcher, but `conf`'s `hyprland.lua` sets it only on the
      `tide-notifications` namespace. Add a `tide-launcher` layer rule and
      its test in `hyprland_test.lua`.
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
- [ ] **The shell puts back a color scheme set elsewhere.**
      `shell/AppearanceData.qml` owns the schedule (SPEC.md §15) and
      watches `color-scheme`: when something else sets it, the shell sets
      its own again at once. conf's theme daemon stops setting it in a tide
      session (mikelward/conf#386), and follows the shell through
      `appearance-hook` instead. The alternative was leaving another
      program's write in place until the shell's next change, which can be
      hours.
- [ ] **GTK 3 gets Adwaita and Adwaita-dark, not adw-gtk3.** SPEC.md §15
      names adw-gtk3, which no setup installs yet, so the shell sets what
      conf's theme script sets today. It's `schemeCommands` in
      `shell/lib/appearance.mjs`; switch it when M7's setup installs
      adw-gtk3.
- [ ] **A light/dark flip lasts until logout at the latest.** It's kept
      across a shell reload (`PersistentProperties`), not in a file, so
      logging back in starts on the schedule. The alternative is saving
      it in `$XDG_STATE_HOME/tide`.
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
- Until then the polkit agent isn't part of the ready check, the shell's
  agent included, and the tray and notifications look like today's, not
  the mocks.
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
- The shell's polkit agent (`shell/PolkitData.qml`, `shell/PolkitPrompt.qml`,
  `shell/lib/polkit.mjs`) is in, opt-in with `TIDE_POLKIT=1`, and
  `tide-shell` then starts no other. Only parsed with `qmlformat`, and made
  in CI's load test with no polkitd to register with. Still to do:
  - Try it on a real session: `pkexec true` typed in a terminal gets the
    prompt with the keyboard; `sleep 5; pkexec true`, with your hands off
    the keyboard, gets the **Authenticate** notification, which opens it;
    closing the notification says no; a wrong password, then the right
    one; Cancel and Escape; GNOME Software or another app's Unlock click,
    which takes the notification path (Lua sees no clicks).
  - Check that `hyprctl repl` answers `true` or `false` for
    `tide_focus.prompt_may_focus()` (Hyprland 0.56's source says it does;
    `tide prompt-focus` relies on it).
  - Check the backoff live: with hyprpolkitagent started by hand first,
    the shell logs a refusal and takes over once it's stopped.
  - The requester half of SPEC.md §14.1: Quickshell 0.3.1 keeps polkit's
    details from the agent ("nothing seems to use them",
    `src/services/polkit/listener.hpp`), and polkitd puts the requesting
    process's pid there. It's an upstream change to expose them; then the
    guard can check the requester descends from the focused window.
  - Join the ready check, then make it the default and drop the opt-in and
    `tide-shell`'s agent search.
  - A mock for the prompt (`docs/mocks/`), which it's drawn without; it
    follows the launcher's card.
- A polkit prompt from an agent window (the M2 agents) takes focus only
  after a key press (the keyboard half of SPEC.md §14.1); after a click it
  waits for `Super+Tab`.
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

- The load test (`shell/shell_test.sh`) stops the shell once it has taken
  in the stand-in Hyprland's answers and events and the output of its own
  commands (`tide-tz`, stand-ins for `tide-sysmon`, `hyprctl`, `gsettings`
  and `nmcli`). So an error the shell reports later, from a timer, a file
  read or a monitor's line (`gsettings monitor`, `nmcli monitor`, whose
  stand-ins report nothing), isn't caught. Keeping it
  running a few seconds more would catch some, at that cost on every run,
  and as a timed wait. Kept as it is for now.
- The load test's `tide-sysmon` probe names no sensors, so the system
  monitor's sensor and throttle reads aren't covered. Covering them needs
  a fake `/sys` the shell reads through (the probe names real paths today),
  and a way to wait for the shell's background reads of it.
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
  `qs -c tide ipc call launcher toggle`. CI opens it in Quickshell,
  types a query and runs the app it names (`shell/shell_test.sh`).
  Still to do:
  - Point `conf`'s `Super+Space` at `global, tide:launcher` instead of
    fuzzel, once it's been tried live.
  - Quick actions: screenshots, the session actions, Do not disturb (while
    the shell serves notifications), keep awake and reload are in, with
    their keys shown. A blocked power action
    keeps the launcher open and asks, naming what blocks it, as the
    session menu does. Dark style is in too: it flips light and dark
    until the schedule's next change (§15). Settings opens the settings
    panel (below).
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
    launcher opens, then looks it up with `hyprctl clients -j` as the
    screenshot runs and passes its `stableId` to `screenshot --window-id`,
    which captures it with `grim -T`, its own contents even under a popup.
    A Hyprland reporting no `stableId` gets `--geometry` instead. On a live
    session, check it takes the window you were in, and that `grim -T`
    accepts the `stableId` Hyprland reports.
  - "Screenshot screen" records the focused monitor's name as the launcher
    opens and passes it to `screenshot --output`, so a focus change while
    it closes can't move the capture to another display. On a live session
    with two monitors, check it takes the one the launcher was on.
  - On a live session, check that typing reaches it with the pointer over
    a window (§14.2), and that an app it starts takes focus.
  - Accentless matching and word starts in every script. Qt's JavaScript
    has no Unicode property escapes, so `fuzzy.mjs` spells out its classes
    by hand. They fold Latin, Greek and Cyrillic accents, but miss some
    punctuation, such as the Arabic comma and Armenian and Hebrew marks,
    so a letter after one gets no word-start bonus. The fix is to generate
    exact tables from Node's Unicode data, the way `palette.mjs` is
    generated, and have `make test` check they're current.
    A name in decomposed form (`e` then U+0301) also ranks below the same
    name precomposed (`é`), in Node as in Qt: the combining mark counts as
    a word break, and as a skipped letter between matches. Scoring should
    pass over marks while keeping their positions for highlighting.
    Deferred: other things come first.
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
    `common.css` disagree). The light/dark schedule is the shell's
    (`shell/AppearanceData.qml`, from `appearance.json`): it sets
    `color-scheme` and `gtk-theme` for apps. On a live session, check a
    flip from the launcher, the switch at a boundary, and one after a
    suspend across it. Next for §15: generate GTK's, Qt's and Hyprland's
    colors from the same file (M7), and have conf's theme daemon leave the
    color scheme to tide in a tide session.
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
    right click opens the menu (§7.4), which `shell/TrayMenu.qml` draws,
    and a middle click activates.
    With it the Quickshell bar replaced waybar in `tide-shell`.
    Try it live: an app's menu, with its submenus and checkboxes, and an
    app that registers before the bar.
  - The clocks popover (§7.3) is `shell/ClocksPopover.qml`, from
    `shell/lib/popover.mjs` and `shell/lib/dst.mjs`. Scrolling over the
    clocks scrubs them (`scrubbed` in `shell/lib/clocks.mjs`).

## Settings panel (SPEC.md §16)

`shell/SettingsWindow.qml`, from the launcher's Settings action or
`qs -c tide ipc call settings toggle`, with its pages in
`shell/lib/settings.mjs`. CI opens it and opens the Network page's app
from the keyboard (`shell/shell_test.sh`).

- In: Idle (below), Sound (the devices, as the volume popover lists them,
  and `pavucontrol`), Network (`nm-connection-editor`) and Bluetooth
  (`blueman-manager`).
- Idle steps each of SPEC.md §10's times along a ladder of durations
  (`shell/lib/idle.mjs`), writing `idle.local.json`; `shell/IdleData.qml`
  writes `~/.config/hypr/tide-idle.conf` and restarts hypridle. CI checks
  the shell writes the default timings and restarts hypridle at startup.
  Still to do:
  - A failed hypridle restart is retried only while the shell runs. A
    shell restarted before the retry works takes the file on disk as
    applied, so hypridle keeps its old times until it next restarts.
    Recording what hypridle was last given, in `$XDG_RUNTIME_DIR`, would
    let the new shell tell (`readTarget` in `shell/lib/writes.mjs`).
  - Suspend on AC, §16's other Idle setting: `tide idle-suspend` would
    read it.
  - On a live session, check a change restarts hypridle with the new
    times, and that Fedora's hypridle is 0.1.7 or later for `source`
    (Ubuntu 26.04 has 0.1.7).
- Mouse and Touchpad (`shell/lib/input.mjs`, `shell/InputData.qml`)
  write `~/.config/hypr/tide-input.lua` and run `hyprctl eval
  'conf_input.reload()'`, which `conf`'s `hyprland.lua` defines (its PR
  "Apply tide's Mouse, Touchpad and Keyboard settings"). CI checks the
  shell writes no settings at startup, then one set over IPC, applying
  each. Still to do:
  - Keyboard: layouts, repeat delay and rate (the maintainer's first
    milestone), through the same file's `keyboard` table, which `conf`
    already reads.
  - Settings for one device by name, not just every mouse or every
    touchpad: what the maintainer said matters most, after the first
    milestone.
  - On a live session, check a change reaches a mouse and a touchpad at
    once, and survives `hyprctl reload`.
- Then the rest of §16's table: Appearance, Displays, Layouts, Clocks and
  Keys.

## Notifications (M4)

SPEC.md §9. So far the shell has the server and the popups. They're
opt-in, with `TIDE_NOTIFICATIONS=1`, until swaync retires: Quickshell
claims `org.freedesktop.Notifications` whenever the name is free, and it's
free for a moment each time the theme daemon restarts swaync, so an
always-on server would take it over by accident. `shell/NotificationData.qml`
holds the queue, and
`shell/NotificationPopups.qml` draws it on the focused monitor, from
`shell/lib/notifications.mjs`. A click grants focus to the sender's app
(`tide grant`) before invoking the action. CI's load test runs the
server headless: it takes a notification and a critical one, keeps both in
the history, and draws their popups with every icon loaded (SPEC.md §20).
Nothing has run in a live session. Still to do:

- Try it on a real session: stop swaync, set `TIDE_NOTIFICATIONS=1` in
  the user manager's environment (README), restart the shell, and check Chrome's notifications, a reply,
  and that a click brings up the right window.
- When a click's app sends no activation and opens no window within 10 s,
  and you haven't moved on, the focus guard brings up its most recently
  focused window, switching workspace (`grant_or_recent` in
  `hypr/tide/focus.lua`, through `tide grant`). On a live session, check it
  with an app that doesn't activate on a click, and that Chrome's own
  activation still wins.
- A Chrome notification goes to its site's `--app` window when one is
  open: the server advertises `x-kde-origin-name`, and `targetApp` in
  `shell/lib/notifications.mjs` matches the site to the window's class for
  marks, clicks and the center (§14.4). Checked against Chromium's source,
  not a live Chrome. On a live session, check a Chat and a Meet
  notification each mark and bring up their own `--app` window, that the
  popup and the center show the site, and that a tab's notification still
  marks the ordinary Chrome windows.
- Bring up the right one of several ordinary Chrome windows (a tab's
  notification). Chrome already handles it given an xdg-activation token:
  it listens for the server's `ActivationToken` signal and activates with
  it (`OnActivationToken` in Chromium's
  `notification_platform_bridge_linux.cc`). Quickshell 0.3.1 declares that
  signal but never sends it, and has no xdg-activation client to get a
  token from the compositor. So it's an upstream Quickshell change: get a
  token for the click's serial and emit `ActivationToken` before
  `ActionInvoked`. Then check the focus guard focuses Chrome's activation
  under the click's grant rather than just marking it.
- A Chrome extension whose context message looks like a host
  (`chat.google.com`) is taken for that site, and routes to its `--app`
  window. Chrome puts the site and an extension's context message in the
  same hint, with nothing to tell them apart. Rare enough to leave for now;
  the fix needs a way to know which one Chrome sent.
- A packaged Chrome (Flatpak) prefixes its `--app` window classes with
  its desktop ID (`com.google.Chrome.chrome-chat.google.com__-Default`,
  `CHROME_WEB_APP_DESKTOP_ID_PREFIX`), which the site match doesn't
  allow for, so its notifications go to Chrome as before. Rare; allow the
  prefix if a packaged Chrome is ever used.
- A site with an internationalized domain (`öbb.at`) comes in the hint as
  Unicode, while its `--app` class has the Punycode host
  (`chrome-xn--bb-eka.at__-Default`), so it doesn't match and goes to
  Chrome as before. Rare; convert the host to ASCII if one is ever used.
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

## Lock (M5)

SPEC.md §10's lock is `tide-lock`: `shell/lock.qml` and
`shell/LockSurface.qml`, with the face it shares with the greeter
(`shell/LockFace.qml`), from `shell/lib/lock.mjs`, run by
`tide-lock.service` (`qs -p .../tide/lock.qml`) with PAM service
`tide-lock`. It has the password face (the short hostname, the time and
date, the user, the field and PAM's messages) and the screensaver face, which
an idle lock opens on (`tide idle-lock`). CI runs it in Quickshell under
headless sway: it loads, turns down a wrong password through PAM, and
unlocks on the right one (`shell/shell_test.sh`). Nothing has run it on
Hyprland yet. Still to do:

- Try it on a real session: `make install`, `sudo make install-session`
  (for `/etc/pam.d/tide-lock`), then `systemctl --user start
  tide-lock.service`. A right password unlocks; a wrong one clears the
  field and says so; every key shows at once.
- `conf` locks the tide session with tide-lock (mikelward/conf#384,
  #385): hypridle's `lock_cmd` starts `tide-lock.service`, its 5-minute
  listener runs `tide idle-lock`, `Super+L` runs `loginctl lock-session`,
  and `misc:allow_session_lock_restore` is on. hyprlock stays only for a
  plain Hyprland login. On a real session, check all three paths reach
  tide-lock, and before sleep too.
- On a real session, check the screensaver: an idle lock opens on it, the
  first pointer report doesn't wake it but a move does, and the first key
  lands in the field.
- On a real session, check the notification count: a notification that
  arrives while locked bumps it, and opening the center after unlocking
  clears it. It follows the history file the bar rewrites atomically, so
  this also checks that the file watch survives the rename.
- On a real session, check Suspend, Restart and Shut down from the lock,
  and that an inhibitor's name shows instead of the action going through.
- On a real session, check the layout badge: it names the main keyboard's
  layout, follows a switch, and what it shows after a YubiKey's code (which
  may make the YubiKey Hyprland's main keyboard) and after unplugging an
  external keyboard while locked.
- Skip the lock inside a Chrome Remote Desktop session. Kept for when
  tide runs in one; not built yet because the signal is unsafe as it
  stands. `lock-screensaver` checks `CHROME_REMOTE_DESKTOP_SESSION=1` in
  its own environment, but `tide-lock.service` reads the systemd user
  manager's, which a remote session and the local one share. A remote
  session that exports it there would stop the local screen locking, so
  the check has to be per session (logind's session type, or the
  variable in the session that raised `Lock`), and it must fail toward
  locking.
- Crash it on purpose and walk the three ways out (§10).
- `tide idle-suspend` is hypridle's 30-minute step in `conf`: it suspends
  on battery only. It doesn't leave the flag for unplugging while idle
  yet, and the shell doesn't watch for the switch to battery, so
  unplugging after the 30 minutes doesn't suspend (§10).

## Login (M5)

SPEC.md §11's greeter is `tide-greeter`: Hyprland with
`greeter/hyprland.lua`, running `shell/greeter.qml` on the lock's face
(`shell/LockFace.qml`), logging in through greetd. `make install-session`
installs it under `$(PREFIX)`, with a greetd config template. CI loads it in
Quickshell under headless sway and logs in on a stand-in greetd
(`shell/shell_test.sh`); nothing has run it under greetd or Hyprland yet.
Still to do:

- `setup --tide` (scripts repo): make greetd the display manager. That
  means:
  - install greetd;
  - put the template in `/etc/greetd/config.toml`, with the greeter user the
    distro's package created;
  - enable greetd in place of GDM or SDDM;
  - give the greeter user a writable home, where the greeter remembers the
    last login.

  It's a switch with a lockout risk, so it wants a way back, and Plasma
  stays a session at the new greeter.
- The greeter user can't run the Hyprland and Quickshell that
  `setup-tide` builds from source. It builds them under `~/.local/opt` and
  links them from `/usr/local/bin`, and a home directory isn't readable by
  other users (750 on Ubuntu). They need to go somewhere system-wide, such
  as `/usr/local/opt`, before greetd can use them.
- The keyring (SPEC.md §11): `pam_gnome_keyring` in greetd's PAM stack,
  `auth optional` and `session optional ... auto_start`. That's
  `/etc/pam.d/greetd`, the distro's file, so `setup --tide` owns the edit.
- Try it on a real machine:
  - every monitor gets the face, and the keyboard goes to one of them;
  - the badge reads the system layout;
  - a wrong password, then the right one, logs in to tide;
  - Plasma and Shell from the session chip;
  - Restart and Shut down;
  - the last user and session preselected at the next boot;
  - Ctrl+Alt+F2 to a text console.
- A user `getent` doesn't list (LDAP without enumeration) can't log in:
  "Other user" lists only `getent passwd`'s accounts. Typing a user name
  into the field isn't built.
- The mock's "last signed in yesterday" line under the user isn't built.
- Quickshell 0.3.1's `Greetd` takes the answer to a cancel it didn't wait
  for as the next login's own (SPEC.md §11). It's filed upstream as
  quickshell-mirror/quickshell#1266; master has the same code as 0.3.1.
  The greeter shipped working around it: no held Enter, and no user
  switch during a login. A login started within greetd's round trip after
  a failure can still hit it, and greetd then refuses the start, so the
  password has to be typed again.
- Write tide's own greetd client and use it in place of Quickshell's
  `Greetd` (maintainer, 2026-10-05). It waits for the reply to every
  request it sends, a cancel's included, so no reply is taken for
  another's, whatever #1266's fate. A small Go helper in `cmd/` that the
  greeter talks to is the likely shape; greetd's IPC is a length-prefixed
  JSON message each way.
- The greeter has no idle: no dim, no screensaver and no DPMS, so a
  machine left at the greeter keeps its screens lit.
- SPEC.md §15 has the greeter follow the default light/dark schedule. Its
  face is the lock's, which is dark only, like the lock.

## The rest of `tide doctor`

M2's `tide doctor` (`bin/tide-doctor`) checks units, D-Bus
owners and the activation files that could start a rival for them,
duplicate and rival daemons, the portal config, Hyprland's config errors,
autostart entries, and a second bar on any monitor. Still to do:

- **Activatable services on a live session.** Check that doctor says
  nothing about them after `setup --tide`, and that unmasking
  `swaync.service` gets it named, with the package and the mask to restore.

- **Bars by a better signal than geometry.** Where tide's bar (layer
  `tide-bar`) is on a monitor, the check now also reports space reserved
  beyond its height, which catches a narrow bar or a dock that reserves
  space. A bar that reserves none, narrower than half the monitor, still
  goes unseen; `hyprctl layers` has no anchors to say more. On a live
  session, check that the bar's reservation matches its height at each
  scale, so a lone tide bar reports nothing.

## Grants for terminal commands

Every shell in `conf` runs `tide-grant` (SPEC.md §14.3) before a
command, mesh included since mikelward/conf#398. Nothing has run it in a
live session yet.

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

## Screenshot region on a frozen screen

Deferred until after the MVP, which needs only "Screenshot window" and
"Screenshot screen" (both done). SPEC.md §13's region mode takes one `grim`
capture of the output as the overlay opens, shows it frozen while you drag,
and crops that same capture to the region. Until then, `Shift+Print` and
"Screenshot region" pick a live region with `slurp`.

- Open question: what the `screenshot` script crops the capture with. §13
  puts the crop, and the mapping through the output's scale and transform,
  in the script, where its tests can reach them, but nothing tide installs
  today can crop an image. Pick the tool, and assess its cost, packaging
  and failure mode, when this is built.
- The shell's part is the overlay: the frozen image, the drag and handles,
  `Enter` or a double-click to confirm, `Space` for window picking, `Esc`
  to cancel, and the 0/3/5 s timer.

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
  toggles maximize on the window it names, like a title bar:
  `Title.barWindow` and `Dispatch.toggleMaximize`, wired in
  `shell/WindowTitle.qml`. Only the focused monitor shows a title, so
  that's always the focused window. Only parsed with `qmlformat`; on a
  real session, check it, and that other monitors' bars stay blank.
- `Super`+middle-click does the same from the keyboard and mouse (SPEC.md
  §6.6, in `conf`'s `hyprland.lua`).
- Rejected: title bars from the `hyprbars` plugin. A plugin is rebuilt against
  every Hyprland upgrade (SPEC.md §3.1).

## Later: our own window manager on river (SPEC.md §21.2)

Not started, and not to start until river exposes xdg-activation to window
managers ([river#1281](https://codeberg.org/river/river/issues/1281)),
including X11 apps' `_NET_ACTIVE_WINDOW`, which river 0.4.8 doesn't listen
for either, and the modal and X11 window-type information §6.4 floats
dialogs by, which 0.4.8 doesn't expose, and a way to see every key and
button press, wherever it lands (bar, wallpaper or window), in river's order
and without eating it, which the focus guard needs, and a way to keep the
launcher and notifications out of a screen share (§12). Re-check that issue now and
then. When all of these have landed, not just the issue, §21.2's steps: a Go
prototype window manager, the capture flows, and each compositor need with
river's replacement checked. If river stalls, the fallback is our own
compositor started from tinywl (check its CC0 license before copying).

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
  replacement and a check for each: first draft in `docs/compositor.md`.
  Its fork column is a proposal; check it against dwl 0.9 and wlroots 0.20.

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
