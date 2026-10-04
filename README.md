# tide

Formerly quickspace. A small Wayland desktop built for dwm/Krohnkite-style tiling:

- **Hyprland** tiles the windows.
- **Quickshell** draws the bar, launcher, notifications, lock and login
  screens, OSDs and screen-share picker.
- **greetd** logs you in.
- **uwsm** runs the session, with one owner per job, so nothing starts twice.

**Status: milestone 2, session skeleton.** Start with the [spec](SPEC.md).
The mocks are in [`docs/mocks/`](docs/mocks/).

![desktop mock](docs/mocks/desktop.png)

## Installing

`setup --tide` in the scripts repo will do all of this; until it lands,
this is the way to install by hand:

    make install                       # builds tide-grant and tide-tz (needs Go 1.22+); layout, user units, portal config under ~/.config
    sudo make install-session          # session entry, compositor wrapper, `tide`, tide-grant, tide-tz and tide-sysmon under /usr/local
    systemctl --user daemon-reload
    systemctl --user enable tide.service

By hand, also install what the session runs: Hyprland 0.56 or later,
Quickshell 0.3 (`qs`, which draws the bar; without it `tide-shell`
falls back to waybar), hypridle, uwsm, waybar, swaync, a polkit agent, swww
or swaybg, notify-send (libnotify), which the shell reports a bad settings
file with, and jq, which `tide doctor` reads Hyprland's JSON with.
`setup-tide` installs them all. jq is a free distro package that runs locally, with no
network calls; without it, the doctor reports its bar check as skipped.

Then pick **tide** at the display manager. It runs Hyprland through
uwsm as `tide-hyprland`, which gives the session its own systemd
target, so tide's units never start in a plain Hyprland or Plasma
login (SPEC.md §5.3). If the display manager doesn't list the session,
install it with `sudo make install-session PREFIX=/usr`.

Key bindings and the launcher start apps with `tide launch [--app ID]
COMMAND...`: it waits (at most 15 s) for the shell, gives the app a one-shot
focus grant, and runs it with `uwsm app` so it outlives a shell restart.
Terminal commands get their grants from `tide-grant`, which each shell
runs before a command (SPEC.md §14.3).

Until the Quickshell shell is complete, `tide.service` runs
`tide-shell`, a transitional shell. It runs the Quickshell bar
(`qs -c tide`) when Quickshell and the shell are installed, and waybar
otherwise; conf's theme daemon, which runs swaync (and waybar, when that's
the bar); a polkit agent; and swww (or swaybg where swww isn't packaged) for
the wallpaper. It also runs conf's input setup once. It reports ready once
swaync owns the notification name and the bar's tray owns the watcher (see
`TODO.md`). `TIDE_BAR=waybar` in `~/.config/uwsm/env` keeps waybar.

The Quickshell bar has the workspaces, the layout symbol, the tray, the
clocks and their popover, a keep-awake toggle, network, Bluetooth, volume
and battery with their percentages, the system monitor (CPU %, with top
processes, memory and temperature) and the session menu, plus the volume and mic-mute OSD. To use it, install
Quickshell (above), run `make install` and `sudo make install-session`,
then log in to tide again (or `systemctl --user restart tide`).
The clocks need `tide-tz` on `PATH`, and the system monitor's temperature
and process lists need `tide-sysmon`. Its notification popups are off
while swaync runs;
to try them, stop swaync and restart the shell with
`TIDE_NOTIFICATIONS=1` in its environment.

`tide doctor` checks the running session and prints one line per
problem, with its fix: units that aren't running, D-Bus names owned by the
wrong process, daemons running twice or rivals to an owner, the portal
config, Hyprland's config errors, and autostart entries that run in
tide without being on its allowlist. It exits 1 if it found a problem.

XDG autostart is an allowlist in tide. `make install` adds one systemd
drop-in, `app-.service.d/tide-autostart.conf`, that reaches every
autostart unit; in the tide session it skips each entry that
`tide autostart-allowed` doesn't name, so other desktops' daemons and
tray icons stay out, while Plasma runs them all as before. The list is
`nm-applet` and `blueman` for now; add desktop IDs, one per line, to
`~/.config/tide/autostart` to allow more.

## Mocks

The mocks are plain HTML/CSS. To re-render the PNGs after editing one:

    make mocks

This needs Node and Playwright with Chromium.

## License

Apache-2.0; see `LICENSE`. The dwl fork explored in SPEC.md §21.1 lives in
its own repository, [mikelward/dwl](https://github.com/mikelward/dwl), under
dwl's GPL-3.0-or-later license.
