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
or swaybg (for waybar's bar; the Quickshell shell draws its own wallpaper),
notify-send (libnotify), which the shell reports a bad settings
file with, jq, which `tide doctor` reads Hyprland's JSON with, python3,
which it reads the session bus's config with, and NetworkManager's nmcli,
which the network menu lists VPNs with. `setup-tide` installs them all.
jq and python3 are free distro packages that run locally, with no network
calls; without one, the doctor reports the check it skipped.

Then pick **tide** at the display manager. It runs Hyprland through
uwsm as `tide-hyprland`, which gives the session its own systemd
target, so tide's units never start in a plain Hyprland or Plasma
login (SPEC.md §5.3). If the display manager doesn't list the session,
install it with `sudo make install-session PREFIX=/usr`.

`make install-session` also installs tide's greeter, for greetd (SPEC.md
§11): `tide-greeter`, which runs Hyprland with its own config and the
greeter on the lock's face, plus a copy of the shell for it and a greetd
config template in `$(PREFIX)/share/tide/greeter/greetd.toml`. Nothing
switches your display manager to it: `setup --tide` will, and until then
it's by hand, as root. Install greetd, copy the template to
`/etc/greetd/config.toml` with `user` set to the greeter account your
greetd package created, and enable greetd in place of the current display
manager. The greeter user has to be able to run `Hyprland` and `qs`, so a
build under someone's home directory won't do (see `TODO.md`).

Key bindings and the launcher start apps with `tide launch [--app ID]...
COMMAND...`: it waits (at most 15 s) for the shell, gives the app a one-shot
focus grant, and runs it with `uwsm app` so it outlives a shell restart.
Repeat `--app` when the app's window class could be any of several IDs.
Terminal commands get their grants from `tide-grant`, which each shell
runs before a command (SPEC.md §14.3).

Until the Quickshell shell is complete, `tide.service` runs
`tide-shell`, a transitional shell. It runs the Quickshell bar
(`qs -c tide`) when Quickshell and the shell are installed, and waybar
otherwise; conf's theme daemon, which runs swaync (and waybar, when that's
the bar); a polkit agent; and, with waybar, swww (or swaybg where swww
isn't packaged) for the wallpaper, which the Quickshell shell draws itself.
It also runs conf's input setup once. It reports ready once
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
to try them, stop swaync, run
`systemctl --user set-environment TIDE_NOTIFICATIONS=1` (or put it in
uwsm's `env`), and restart the shell. The lock reads the same setting to
show the notification count, so set it for the session, not just one
process.

The shell can be the polkit agent too, which asks for your password when
an app needs privileges: set `TIDE_POLKIT=1` the same way and restart
the shell, and `tide-shell` starts no other agent. Its prompt takes the
keyboard only right after you press a key (a `pkexec` in a terminal);
otherwise a notification offers **Authenticate**.

`tide doctor` checks the running session and prints one line per
problem, with its fix: units that aren't running, D-Bus names owned by the
wrong process or that D-Bus could start a rival for, daemons running twice
or rivals to an owner, the portal
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
