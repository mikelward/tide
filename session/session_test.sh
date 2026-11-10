#!/bin/sh
#
# Tests for the tide session: the wayland-sessions entry, its
# compositor wrapper, the systemd user units and the portal config
# (SPEC.md §5.2-§5.4). No compositor runs here, so these check the files'
# contracts, verify the units with systemd-analyze where it can run, and
# check what `make install` puts where.

cd "$(dirname "$0")/.." || exit 1

passes=0
failures=0

pass() { passes=$((passes + 1)); }
fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1" >&2
}
# check NAME COMMAND...: passes when COMMAND succeeds.
check() {
    _name=$1
    shift
    if "$@"; then pass; else fail "$_name"; fi
}
has_line() { grep -qxF -- "$2" "$1"; }
lacks_line_matching() { ! grep -qE -- "$2" "$1"; }
# not COMMAND...: succeeds when COMMAND fails.
not() { ! "$@"; }

unit=systemd/user/tide.service
dropin=systemd/user/hypridle.service.d/tide.conf
entry=session/tide.desktop
wrapper=bin/tide-hyprland
tidewm_entry=session/tide-tidewm.desktop
tidewm_wrapper=bin/tide-tidewm
portals=xdg-desktop-portal/tide-portals.conf
tidewm_portals=xdg-desktop-portal/tidewm-portals.conf
autostart=systemd/user/app-.service.d/tide-autostart.conf
lock=systemd/user/tide-lock.service
lockfallback=systemd/user/tide-lock-fallback.service
shellfallback=systemd/user/tide-shell-fallback.service
clipboard=systemd/user/tide-clipboard.service
fcitx5=systemd/user/tide-fcitx5.service
lidinhibit=systemd/user/tide-lid-inhibit.service
kdelauncher=systemd/user/tide-kde.service

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# --- The session entry and its wrapper ----------------------------------------
# uwsm names the session after the compositor command, so the wrapper's name
# is the session's target; the unit must hang off that same target.
session_id=$(basename "$wrapper")
check "the entry starts the Hyprland session through tide-session" \
    has_line "$entry" "Exec=tide-session hyprland"
check "the entry lists tide first in DesktopNames" \
    has_line "$entry" "DesktopNames=tide;Hyprland"
# The wrapper runs start-hyprland when there is one, and Hyprland otherwise,
# passing its arguments through either way. PATH holds only the stubs, so a
# host with a real start-hyprland never runs it here.
mkdir -p "$tmp/wrapper-bin" "$tmp/wrapper-bin-old"
for cmd in start-hyprland Hyprland; do
    printf '#!/bin/sh\necho "%s $*"\n' "$cmd" > "$tmp/wrapper-bin/$cmd"
    chmod +x "$tmp/wrapper-bin/$cmd"
done
cp "$tmp/wrapper-bin/Hyprland" "$tmp/wrapper-bin-old/"
check "the wrapper starts Hyprland through its watchdog" \
    test "$(PATH="$tmp/wrapper-bin" /bin/sh "$wrapper" --config x)" = "start-hyprland -- --config x"
check "the wrapper falls back to Hyprland without start-hyprland" \
    test "$(PATH="$tmp/wrapper-bin-old" /bin/sh "$wrapper" --config x)" = "Hyprland --config x"
# Without a config of your own, Hyprland gets tide's; with one, or a
# --config given, it's left to Hyprland.
mkdir -p "$tmp/hyprhome/.config/hypr/tide"
: > "$tmp/hyprhome/.config/hypr/tide/hyprland.lua"
check "the wrapper runs tide's config when you have none" \
    test "$(HOME="$tmp/hyprhome" XDG_CONFIG_HOME='' PATH="$tmp/wrapper-bin" /bin/sh "$wrapper")" = "start-hyprland -- --config $tmp/hyprhome/.config/hypr/tide/hyprland.lua"
check "a --config given wins over tide's" \
    test "$(HOME="$tmp/hyprhome" XDG_CONFIG_HOME='' PATH="$tmp/wrapper-bin" /bin/sh "$wrapper" --config x)" = "start-hyprland -- --config x"
check "TIDE_HYPRLAND_CONFIG names another" \
    test "$(HOME="$tmp/hyprhome" XDG_CONFIG_HOME='' TIDE_HYPRLAND_CONFIG=/y PATH="$tmp/wrapper-bin" /bin/sh "$wrapper")" = "start-hyprland -- --config /y"
: > "$tmp/hyprhome/.config/hypr/hyprland.lua"
check "your own hyprland.lua is Hyprland's to read" \
    test "$(HOME="$tmp/hyprhome" XDG_CONFIG_HOME='' PATH="$tmp/wrapper-bin" /bin/sh "$wrapper")" = "start-hyprland --"
# The input method's variables (SPEC.md §8.6) are the compositor's, so every
# app it starts has them: set where fcitx5 is installed, unless TIDE_IME=0,
# and left as they were otherwise.
mkdir -p "$tmp/ime-bin" "$tmp/ime-bin-none"
for cmd in start-hyprland tidewm; do
    # shellcheck disable=SC2016 # the stub expands them when it runs
    printf '#!/bin/sh\necho "$QT_IM_MODULE|$XMODIFIERS"\n' > "$tmp/ime-bin/$cmd"
done
printf '#!/bin/sh\n' > "$tmp/ime-bin/fcitx5"
chmod +x "$tmp/ime-bin"/*
cp "$tmp/ime-bin/start-hyprland" "$tmp/ime-bin/tidewm" "$tmp/ime-bin-none/"
# Only the stubs and grep, so a host with a real fcitx5 can't count.
for d in ime-bin ime-bin-none; do ln -s "$(command -v grep)" "$tmp/$d/grep"; done
for w in "$wrapper" "$tidewm_wrapper"; do
    name=$(basename "$w")
    check "$name points Qt and X11 apps at fcitx5" \
        test "$(env -u QT_IM_MODULE -u XMODIFIERS PATH="$tmp/ime-bin" XDG_CONFIG_HOME="$tmp/none" /bin/sh "$w" | tail -n 1)" = "fcitx|@im=fcitx"
    check "$name leaves them alone with TIDE_IME=0" \
        test "$(env -u QT_IM_MODULE -u XMODIFIERS TIDE_IME=0 PATH="$tmp/ime-bin" XDG_CONFIG_HOME="$tmp/none" /bin/sh "$w" | tail -n 1)" = "|"
    check "$name leaves them alone without fcitx5" \
        test "$(env -u QT_IM_MODULE -u XMODIFIERS PATH="$tmp/ime-bin-none" XDG_CONFIG_HOME="$tmp/none" /bin/sh "$w" | tail -n 1)" = "|"
done
# A Hyprland too old for tide's config isn't started: it would come up
# with no tide keys and no bar. One new enough, or of no version the
# wrapper can read, is.
mkdir -p "$tmp/wrapper-bin-ver"
cp "$tmp/wrapper-bin/start-hyprland" "$tmp/wrapper-bin-ver/"
hyprland_version() {
    # shellcheck disable=SC2016  # the stub's own $1 and $*
    printf '#!/bin/sh\ncase "$1" in --version) echo "Hyprland %s built from branch main" ;; *) echo "Hyprland $*" ;; esac\n' "$1" > "$tmp/wrapper-bin-ver/Hyprland"
    chmod +x "$tmp/wrapper-bin-ver/Hyprland"
}
hyprland_version 0.56.1
check "the wrapper refuses a Hyprland older than 0.56.2" \
    not env PATH="$tmp/wrapper-bin-ver:/usr/bin:/bin" /bin/sh "$wrapper" --config x
check "the wrapper says why it refuses" \
    test -n "$(PATH="$tmp/wrapper-bin-ver:/usr/bin:/bin" /bin/sh "$wrapper" --config x 2>&1 >/dev/null | grep -F 'needs Hyprland 0.56.2 or later, and this is 0.56.1')"
check "the wrapper starts nothing for a Hyprland too old" \
    test -z "$(PATH="$tmp/wrapper-bin-ver:/usr/bin:/bin" /bin/sh "$wrapper" --config x 2>/dev/null)"
hyprland_version 0.56.2
check "the wrapper starts a Hyprland 0.56.2 or later" \
    test "$(PATH="$tmp/wrapper-bin-ver:/usr/bin:/bin" /bin/sh "$wrapper" --config x)" = "start-hyprland -- --config x"
hyprland_version 0.60.0
check "the wrapper starts a Hyprland past 0.56.2" \
    test "$(PATH="$tmp/wrapper-bin-ver:/usr/bin:/bin" /bin/sh "$wrapper" --config x)" = "start-hyprland -- --config x"
# Each step lands in the journal, as tidewm's wrapper's do.
cat > "$tmp/wrapper-bin-ver/logger" <<STUB
#!/bin/sh
echo "\$*" >> "$tmp/hypr-logged"
STUB
chmod +x "$tmp/wrapper-bin-ver/logger"
PATH="$tmp/wrapper-bin-ver:/usr/bin:/bin" /bin/sh "$wrapper" --config x >/dev/null 2>&1
check "the wrapper logs that the session is starting" \
    grep -qxF -- "-t tide-hyprland -- starting the tide session" "$tmp/hypr-logged"
check "the wrapper logs which Hyprland it starts, and how" \
    grep -qxF -- "-t tide-hyprland -- starting Hyprland 0.60.0 through start-hyprland: --config x" "$tmp/hypr-logged"
check "the wrapper is executable" test -x "$wrapper"
check "the wrapper parses as sh" sh -n "$wrapper"

# The tidewm session, an option beside Hyprland's (SPEC.md §5.3): its own
# wrapper, so its own target, and tidewm first in XDG_CURRENT_DESKTOP, so
# portals read tidewm-portals.conf.
tidewm_id=$(basename "$tidewm_wrapper")
check "the tidewm entry starts the tidewm session through tide-session" \
    has_line "$tidewm_entry" "Exec=tide-session tidewm"
# tide-session, which each entry runs, starts uwsm with the session's
# desktops, name and wrapper, and logs what it ran, uwsm's output and how
# it ended. Stubs: uwsm prints its arguments one per line and exits
# $FAKE_UWSM; systemd-cat runs what it's given, marking its output; logger
# appends to a file.
mkdir -p "$tmp/session-bin"
# shellcheck disable=SC2016 # the stubs' own $@, $1 and the rest
printf '#!/bin/sh\nprintf "[%%s]\\n" "$@"\nexit "${FAKE_UWSM:-0}"\n' > "$tmp/session-bin/uwsm"
# shellcheck disable=SC2016 # and here
printf '#!/bin/sh\ntest "$1" = -t && test "$2" = tide-session && test "$3" = -- || exit 99\nshift 3\necho "systemd-cat:"\nexec "$@"\n' > "$tmp/session-bin/systemd-cat"
printf '#!/bin/sh\nshift 3\necho "$*" >> "%s"\n' "$tmp/session-log" > "$tmp/session-bin/logger"
chmod +x "$tmp/session-bin/uwsm" "$tmp/session-bin/systemd-cat" "$tmp/session-bin/logger"
run_session() { PATH="$tmp/session-bin:/usr/bin:/bin" sh bin/tide-session "$@" 2>"$tmp/session-err"; }
: > "$tmp/session-log"
out=$(run_session tidewm)
check "tide-session tidewm runs uwsm, through systemd-cat, with tidewm's desktops, name and wrapper" \
    test "$out" = "$(printf '%s\n' "systemd-cat:" "[start]" "[-e]" "[-D]" "[tidewm:tide]" "[-N]" "[tide (tidewm)]" "[--]" "[tide-tidewm]")"
check "and logs what it ran" \
    grep -qxF "starting the tide (tidewm) session: uwsm start -e -D tidewm:tide -N 'tide (tidewm)' -- tide-tidewm" "$tmp/session-log"
check "and that it ended" grep -qxF "the tide (tidewm) session ended" "$tmp/session-log"
out=$(run_session hyprland)
check "tide-session hyprland runs uwsm with Hyprland's desktops, name and wrapper" \
    test "$out" = "$(printf '%s\n' "systemd-cat:" "[start]" "[-e]" "[-D]" "[tide:Hyprland]" "[-N]" "[tide]" "[--]" "[tide-hyprland]")"
: > "$tmp/session-log"
FAKE_UWSM=3 run_session tidewm >/dev/null
check "a uwsm that fails is tide-session's status" test "$?" -eq 3
check "and is logged with its status" \
    grep -qxF "the tide (tidewm) session ended with uwsm exiting 3: the lines above say why" "$tmp/session-log"
run_session sway >/dev/null
check "an unknown session is an error" test "$?" -eq 2
check "and says which are known" grep -qF "usage: tide-session hyprland|tidewm, not 'sway'" "$tmp/session-err"
check "make install-session installs tide-session" grep -qF "bin/tide-session" Makefile
# A login screen hands Exec on in ways that break a quote: GDM wraps it in
# double quotes of its own, unescaped (gdm-session.c's gdm-wayland-session
# "%s"), so a quoted word ends them early, and SDDM's wayland-session
# splits it on spaces with no quoting at all. A session that logged in
# then straight out had -N "tide (tidewm)". Each entry's Exec is plain
# words, nothing a shell or GDM would read as quoting or syntax.
for e in "$entry" "$tidewm_entry"; do
    check "$(basename "$e")'s Exec has no quotes, escapes or shell syntax" \
        lacks_line_matching "$e" "^Exec=.*[\"'\\\\\`\$()<>|;&*?]"
done
check "the tidewm entry lists tidewm, then tide, in DesktopNames" \
    has_line "$tidewm_entry" "DesktopNames=tidewm;tide"
check "the tidewm entry is offered only where tidewm is installed" \
    has_line "$tidewm_entry" "TryExec=tidewm"
check "the tidewm entry says which compositor it runs" \
    has_line "$tidewm_entry" "Name=tide (tidewm)"
# A stub tidewm runs its -s command as tidewm does, under /bin/sh -c, with
# a stub uwsm that prints what it was asked.
mkdir -p "$tmp/tidewm-bin"
cat > "$tmp/tidewm-bin/tidewm" <<'STUB'
#!/bin/sh
echo "tidewm $*"
test "$1" = -s && /bin/sh -c "$2"
STUB
# The stub uwsm fails with $FAKE_UWSM_FAILS.
# shellcheck disable=SC2016 # the stub expands them when it runs
printf '#!/bin/sh\necho "uwsm $*"\ntest -z "$FAKE_UWSM_FAILS"\n' > "$tmp/tidewm-bin/uwsm"
# A stub tide-msg prints what it was asked, fails with $FAKE_TIDEMSG_FAILS,
# and with $FAKE_TIDEMSG_HANGS never answers: it waits to read a FIFO that
# nothing ever writes.
cat > "$tmp/tidewm-bin/tide-msg" <<'STUB'
#!/bin/sh
echo "tide-msg $*"
test -n "$FAKE_TIDEMSG_HANGS" && exec cat "$FAKE_TIDEMSG_HANGS"
test -z "$FAKE_TIDEMSG_FAILS"
STUB
# A stub logger keeps what it's asked in $tmp/logged, not the journal.
cat > "$tmp/tidewm-bin/logger" <<STUB
#!/bin/sh
echo "\$*" >> "$tmp/logged"
STUB
chmod +x "$tmp/tidewm-bin/tidewm" "$tmp/tidewm-bin/uwsm" "$tmp/tidewm-bin/tide-msg" "$tmp/tidewm-bin/logger"
# How the startup command ends: telling uwsm, or logging that it couldn't.
fin="uwsm finalize SWAYSOCK || logger -t tide-tidewm -- 'uwsm finalize failed, so uwsm will end the session' 2>/dev/null"
# What the startup command logs before anything else.
up="logger -t tide-tidewm -- 'tidewm is up; going home and telling uwsm the session is ready' 2>/dev/null; "
mkdir -p "$tmp/tidewm-config/hypr"
# tidewm_start [VAR=VALUE...]: what the wrapper's tidewm and its startup
# command print, with the shell's config under $tmp/tidewm-config.
tidewm_start() {
    env PATH="$tmp/tidewm-bin:/usr/bin:/bin" XDG_CONFIG_HOME="$tmp/tidewm-config" "$@" /bin/sh "$tidewm_wrapper" -c x 2>/dev/null
}
: > "$tmp/logged"
tidewm_ran=$(tidewm_start)
check "the tidewm wrapper starts tidewm, passing its arguments through" \
    test "$(printf '%s\n' "$tidewm_ran" | head -n 1)" = "tidewm -s ${up}timeout 5 tide-msg 'workspace number in; persist workspace in'; $fin -c x"
check "before the shell has named home, tidewm goes to in and keeps it" \
    test "$(printf '%s\n' "$tidewm_ran" | sed -n 2p)" = "tide-msg workspace number in; persist workspace in"
check "tidewm's startup command finalizes the session with tidewm's IPC socket" \
    test "$(printf '%s\n' "$tidewm_ran" | sed -n 3p)" = "uwsm finalize SWAYSOCK"
# Each step lands in the journal, so a login that shows no desktop says how
# far it got.
check "the tidewm wrapper logs that the session is starting" \
    grep -qxF -- "-t tide-tidewm -- starting the tide (tidewm) session" "$tmp/logged"
check "the tidewm wrapper logs tidewm's start, with home and arguments" \
    grep -qxF -- "-t tide-tidewm -- starting tidewm, home in: -c x" "$tmp/logged"
check "tidewm's startup command logs that tidewm is up" \
    grep -qxF -- "-t tide-tidewm -- tidewm is up; going home and telling uwsm the session is ready" "$tmp/logged"
check "the tidewm wrapper says the same on stderr" \
    test -n "$(env PATH="$tmp/tidewm-bin:/usr/bin:/bin" XDG_CONFIG_HOME="$tmp/tidewm-config" /bin/sh "$tidewm_wrapper" -c x 2>&1 >/dev/null | grep -F 'tide-tidewm: starting the tide (tidewm) session')"
# shellcheck disable=SC2016 # the name has a $ that mustn't expand
printf '%s\n' 'return {' '    home = "my $HOME & mail",' '    in_apps = {},' '}' > "$tmp/tidewm-config/hypr/tide-workspaces.lua"
tidewm_ran=$(tidewm_start)
# shellcheck disable=SC2016 # nor here
check "tidewm goes to the home the shell names, as written" \
    test "$(printf '%s\n' "$tidewm_ran" | sed -n 2p)" = 'tide-msg workspace number my $HOME & mail; persist workspace my $HOME & mail'
tidewm_ran=$(tidewm_start FAKE_TIDEMSG_FAILS=1)
check "the session finalizes even if tidewm refuses home" \
    test "$(printf '%s\n' "$tidewm_ran" | sed -n 3p)" = "uwsm finalize SWAYSOCK"
printf '%s\n' 'return {' '    home = "a;b",' '}' > "$tmp/tidewm-config/hypr/tide-workspaces.lua"
tidewm_ran=$(tidewm_start)
check "a home with a ; goes to tidewm in quotes, as it reads a quoted name" \
    test "$(printf '%s\n' "$tidewm_ran" | sed -n 2p)" = 'tide-msg workspace number "a;b"; persist workspace "a;b"'
printf '%s\n' 'return {' "    home = \"it's\"," '}' > "$tmp/tidewm-config/hypr/tide-workspaces.lua"
tidewm_ran=$(tidewm_start)
check "a home tidewm's start can't name is left to the shell" \
    test "$tidewm_ran" = "tidewm -s ${up}$fin -c x
uwsm finalize SWAYSOCK"
# Without a config of your own, tidewm gets tide's; with one, or a -c,
# it's tidewm's to read.
rm -f "$tmp/tidewm-config/hypr/tide-workspaces.lua"
mkdir -p "$tmp/tidewm-config/tidewm"
: > "$tmp/tidewm-config/tidewm/tide.conf"
tidewm_bare() {
    env PATH="$tmp/tidewm-bin:/usr/bin:/bin" HOME="$tmp/tidewm-home" XDG_CONFIG_HOME="$tmp/tidewm-config" /bin/sh "$tidewm_wrapper" 2>/dev/null
}
check "with no config of yours, tidewm runs tide's" \
    test "$(tidewm_bare | head -n 1)" = "tidewm -s ${up}timeout 5 tide-msg 'workspace number in; persist workspace in'; $fin -c $tmp/tidewm-config/tidewm/tide.conf"
check "a -c given wins over tide's" \
    test "$(tidewm_start | head -n 1)" = "tidewm -s ${up}timeout 5 tide-msg 'workspace number in; persist workspace in'; $fin -c x"
: > "$tmp/tidewm-config/tidewm/config"
check "your own config is tidewm's to read" \
    test "$(tidewm_bare | head -n 1)" = "tidewm -s ${up}timeout 5 tide-msg 'workspace number in; persist workspace in'; $fin"
# make install puts tide.conf where the wrapper looks: XDG_CONFIG_HOME's
# tidewm, else ~/.config's.
# shellcheck disable=SC2016 # sh -c's own $1
check "make install puts tide.conf in XDG_CONFIG_HOME's tidewm" \
    sh -c 'make -n install XDG_CONFIG_HOME="$1" 2>/dev/null | grep -qF "tidewm/tide.conf \"$1/tidewm/\""' sh "$tmp/xdg"
# shellcheck disable=SC2016 # and here
check "and without it, in ~/.config's" \
    sh -c 'env -u XDG_CONFIG_HOME HOME="$1" make -n install 2>/dev/null | grep -qF "tidewm/tide.conf \"$1/.config/tidewm/\""' sh "$tmp/home"
# A tide-msg that never answers would hold up the finalize after it, and
# uwsm ends a session that never says it's ready.
# The wrapper's 5 seconds, not the stub, end the wait: without them the whole
# start is cut off at 20 and never reaches the finalize.
mkfifo "$tmp/never"
tidewm_ran=$(timeout 20 env PATH="$tmp/tidewm-bin:/usr/bin:/bin" XDG_CONFIG_HOME="$tmp/tidewm-config" \
    FAKE_TIDEMSG_HANGS="$tmp/never" /bin/sh "$tidewm_wrapper" -c x 2>/dev/null)
check "the session finalizes within seconds even if going home hangs" \
    test "$(printf '%s\n' "$tidewm_ran" | tail -n 1)" = "uwsm finalize SWAYSOCK"
: > "$tmp/logged"
tidewm_start FAKE_UWSM_FAILS=1 >/dev/null
check "a failed finalize is logged" \
    grep -qxF -- "-t tide-tidewm -- uwsm finalize failed, so uwsm will end the session" "$tmp/logged"
check "the tidewm wrapper is executable" test -x "$tidewm_wrapper"
check "the tidewm wrapper parses as sh" sh -n "$tidewm_wrapper"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes on the wrappers and this test" \
        shellcheck -s sh "$wrapper" "$tidewm_wrapper" bin/tide-session session/session_test.sh
fi

# --- tide.service ---------------------------------------------------------
target="wayland-session@$session_id.target"
tidewm_target="wayland-session@$tidewm_id.target"
check "the unit is wanted by each tide session's target, Hyprland's and tidewm's" \
    has_line "$unit" "WantedBy=$target $tidewm_target"
# Plasma reaches graphical-session.target too; that's how swaync leaked in.
check "the unit is never WantedBy= graphical-session.target" \
    lacks_line_matching "$unit" '^WantedBy=.*graphical-session\.target'
check "the unit is WantedBy= nothing else" \
    test "$(grep -c '^WantedBy=' "$unit")" -eq 1
check "the unit is ordered after its session target" \
    grep -qE "^After=.*$target" "$unit"
check "the unit is ordered after the tidewm session's target" \
    grep -qE "^After=.*$tidewm_target" "$unit"
check "the unit stops with the graphical session" \
    has_line "$unit" "PartOf=graphical-session.target"
check "ready means the shell said so" has_line "$unit" "Type=notify"
check "the shell's helpers may report ready" has_line "$unit" "NotifyAccess=all"
check "a shell that never gets ready fails in 15 s" \
    has_line "$unit" "TimeoutStartSec=15"
check "a bad setting isn't restarted" has_line "$unit" "RestartPreventExitStatus=78"
check "hypridle is wanted, not required" has_line "$unit" "Wants=hypridle.service"
check "hypridle is not required" lacks_line_matching "$unit" '^Requires=.*hypridle'
check "the shell starts after hypridle" has_line "$unit" "After=hypridle.service"
check "once the shell is up, it says if the session won't lock" \
    has_line "$unit" "ExecStartPost=-tide lock-check"
check "the shell is up before autostarted apps" \
    has_line "$unit" "Before=xdg-desktop-autostart.target"

# --- The hypridle drop-in -------------------------------------------------------
check "hypridle is started once it owns org.freedesktop.ScreenSaver" \
    has_line "$dropin" "Type=dbus"
check "the drop-in names the ScreenSaver bus name" \
    has_line "$dropin" "BusName=org.freedesktop.ScreenSaver"
check "a hypridle that never claims the name fails in 10 s" \
    has_line "$dropin" "TimeoutStartSec=10"
check "the drop-in adds no [Install], so hypridle isn't enabled globally" \
    lacks_line_matching "$dropin" '^\[Install\]'
# The drop-in's condition, as systemd would run it ($$ is a literal $).
idle_condition=$(sed -n 's/^ExecCondition=\/bin\/sh -c //p' "$dropin" | sed "s/^'//; s/'\$//; s/\\$\\$/\\$/g")
idle_runs_in() { XDG_CURRENT_DESKTOP=$1 sh -c "$idle_condition"; }
idle_skips_in() { ! idle_runs_in "$1"; }
check "hypridle's condition is a sh -c script" test -n "$idle_condition"
check "hypridle runs in the tide session" idle_runs_in "tide:Hyprland"
check "hypridle runs in the tidewm session" idle_runs_in "tidewm:tide"
check "hypridle is skipped under Plasma, even when a package enabled it" idle_skips_in "KDE"
check "hypridle's unit is skipped in a plain Hyprland login, which runs its own" idle_skips_in "Hyprland"
check "hypridle is skipped where no desktop is set" idle_skips_in ""
# The drop-in's command, as systemd would run it, against a hypridle that
# says which config it was given, in a home with none of your own, one
# with a link to a config that's gone, and one with your own.
idle_start=$(sed -n 's/^ExecStart=\/bin\/sh -c //p' "$dropin" | sed "s/^'//; s/'\$//; s/\\$\\$/\\$/g")
mkdir -p "$tmp/idle-bin" "$tmp/idle-none/.config/hypr" "$tmp/idle-gone/.config/hypr" \
    "$tmp/idle-own/.config/hypr"
printf '#!/bin/sh\necho "$*"\n' > "$tmp/idle-bin/hypridle"
chmod +x "$tmp/idle-bin/hypridle"
ln -s "$tmp/idle-gone/gone.conf" "$tmp/idle-gone/.config/hypr/hypridle.conf"
: > "$tmp/idle-own/.config/hypr/hypridle.conf"
idle_config() { HOME="$tmp/$1" XDG_CONFIG_HOME='' PATH="$tmp/idle-bin:/usr/bin:/bin" sh -c "$idle_start"; }
check "the drop-in replaces the packaged command" has_line "$dropin" "ExecStart="
check "without a hypridle config of your own, hypridle gets tide's" \
    test "$(idle_config idle-none)" = "--config $tmp/idle-none/.config/hypr/tide-hypridle.conf"
check "a link to a config that's gone gets tide's too" \
    test "$(idle_config idle-gone)" = "--config $tmp/idle-gone/.config/hypr/tide-hypridle.conf"
check "your own hypridle config wins" \
    test "$(idle_config idle-own)" = "--config $tmp/idle-own/.config/hypr/hypridle.conf"
# shellcheck disable=SC2016 # sh -c's own $1
check "make install puts tide's hypridle config beside the tide-idle.conf it sources" \
    sh -c 'env -u XDG_CONFIG_HOME HOME="$1" make -n install 2>/dev/null | grep -qF "hypr/hypridle.conf \"$1/.config/hypr/tide-hypridle.conf\""' sh "$tmp/home"
check "tide's hypridle config sources the Idle page's file beside itself" \
    grep -qx "source = tide-idle.conf" hypr/hypridle.conf

# --- The autostart allowlist -------------------------------------------------
# The drop-in's condition, as systemd would run it for a unit ($$ is a
# literal $, %n the unit's name), with this checkout's tide on PATH.
condition=$(sed -n 's/^ExecCondition=\/bin\/sh -c //p' "$autostart" | sed "s/^'//; s/'\$//; s/\\$\\$/\\$/g")
# condition_status DESKTOP UNIT: the condition's exit status; its stderr is
# kept in $tmp/condition.err for a failing check to show.
condition_status() {
    cmd=$(printf '%s\n' "$condition" | sed "s/%n/$(printf '%s' "$2" | sed 's/\\/\\\\/g')/g")
    env PATH="$PWD/bin:$PATH" XDG_CONFIG_HOME="${config_home:-$tmp/no-config}" XDG_CURRENT_DESKTOP="$1" \
        sh -c "$cmd" 2>"$tmp/condition.err"
    echo $?
}
# A skip is exactly 1; 255 would be a failed unit, which isn't a skip.
runs_in() { s=$(condition_status "$@"); test "$s" -eq 0 || { cat "$tmp/condition.err" >&2; false; }; }
skips_in() { s=$(condition_status "$@"); test "$s" -eq 1 || { echo "status $s: $(cat "$tmp/condition.err")" >&2; false; }; }
agent='app-polkit\x2dmate\x2dauthentication\x2dagent\x2d1@autostart.service'
check "the autostart condition is a sh -c script" test -n "$condition"
check "another desktop's agent is skipped in the tide session" skips_in "tide:Hyprland" "$agent"
check "another desktop's agent is skipped in the tidewm session" skips_in "tidewm:tide" "$agent"
check "another desktop's daemon is skipped in the tide session" \
    skips_in "tide:Hyprland" 'app-xfce4\x2dnotifyd@autostart.service'
# With no Quickshell shell answering (waybar's bar), nm-applet is the
# secret agent; with the shell's tide-agent, it's skipped (SPEC.md §5.6).
# A fake qs answers `ipc call agent status` with $FAKE_AGENT, or fails as
# qs does with no shell running.
mkdir -p "$tmp/shell-bin"
cat > "$tmp/shell-bin/qs" <<'FAKE'
#!/bin/sh
test -n "$FAKE_AGENT" || { echo "No running instances" >&2; exit 255; }
echo "$FAKE_AGENT"
FAKE
chmod +x "$tmp/shell-bin/qs"
path_saved=$PATH
PATH="$tmp/shell-bin:$PATH"
FAKE_AGENT=
export FAKE_AGENT
check "the network applet runs in the tide session when no shell's agent does" \
    runs_in "tide:Hyprland" 'app-nm\x2dapplet@autostart.service'
FAKE_AGENT=registered
check "the network applet is skipped in the tide session whose shell's tide-agent asks for passwords" \
    skips_in "tide:Hyprland" 'app-nm\x2dapplet@autostart.service'
unset FAKE_AGENT
PATH=$path_saved
check "the Bluetooth applet is skipped in the tide session, whose bar draws its icon" \
    skips_in "tide:Hyprland" 'app-blueman@autostart.service'
mkdir -p "$tmp/allow/tide"
echo blueman > "$tmp/allow/tide/autostart"
config_home=$tmp/allow
check "an applet on the user's allowlist runs in the tide session" \
    runs_in "tide:Hyprland" 'app-blueman@autostart.service'
config_home=
check "an app that isn't autostarted runs in the tide session" \
    runs_in "tide:Hyprland" 'app-org.kde.dolphin@1234.service'
check "another desktop's agent still runs under Plasma" runs_in "KDE" "$agent"
check "another desktop's agent still runs under MATE" runs_in "MATE" "$agent"
check "another desktop's agent still runs in a plain Hyprland login" runs_in "Hyprland" "$agent"
check "another desktop's agent still runs where no desktop is set" runs_in "" "$agent"

# Suppressing the legacy agents must not leave the session with none: the
# shell falls back to KDE's, always installed beside Plasma (SPEC.md §5.5).
agents=$(sed -n '/^default_agents="/,/^"/p' bin/tide-shell)
searches_for() { printf '%s\n' "$agents" | grep -q "/$1\$"; }
check "the shell falls back to KDE's polkit agent" \
    searches_for polkit-kde-authentication-agent-1
# Doctor finds the running agent by its process name, the first 15
# characters of the file name, so it must know every one the shell can start.
doctor_names=$(sed -n '/^agent_names="/,/"$/p' bin/tide-doctor | tr -d '"' | sed 's/^agent_names=//')
doctor_knows() { printf '%s\n' "$doctor_names" | grep -qxF -- "$(printf '%.15s' "$1")"; }
for path in $(printf '%s\n' "$agents" | grep '^ */'); do
    check "doctor recognizes the shell's agent $path" doctor_knows "${path##*/}"
done

# --- tide-lock.service ----------------------------------------------------------
# The lock (SPEC.md §10) runs the shell's lock.qml with the file watcher off,
# and only a crash restarts it: an unlock is a clean exit.
check "the lock runs tide-lock, which runs lock.qml from the installed shell" \
    has_line "$lock" "ExecStart=tide-lock"
check "the lock's file watcher is off" \
    has_line "$lock" "Environment=QS_DISABLE_FILE_WATCHER=1"
check "only a crash restarts the lock" \
    has_line "$lock" "Restart=on-failure"
# A lock that fails still locks the session, with hyprlock: at once for a
# lock that can't start, and once a crash loop's restarts run out.
check "a failed lock starts the fallback" \
    has_line "$lock" "OnFailure=tide-lock-fallback.service"
# contains TEXT PART: TEXT holds PART.
contains() {
    case $1 in *"$2"*) return 0 ;; esac
    return 1
}
# A shell that fails for good leaves a terminal saying why, not a session
# with nothing on it; three failed starts in two minutes is for good, so
# 15-second hangs can't restart forever under systemd's default limit.
check "a failed shell falls back to a terminal" \
    has_line "$unit" "OnFailure=tide-shell-fallback.service"
check "the shell gives up after three failed starts" \
    has_line "$unit" "StartLimitBurst=3"
check "in two minutes" has_line "$unit" "StartLimitIntervalSec=120"
check "and falls back only then, not for a failure a restart recovers from" \
    has_line "$unit" "RestartMode=direct"
check "the shell's fallback runs only in a tide session" \
    grep -q "^ExecCondition=.*:tide:" "$shellfallback"
check "the shell's fallback stops with the session" \
    has_line "$shellfallback" "PartOf=graphical-session.target"
check "make install installs the shell's fallback" \
    grep -qF "bin/tide-shell-fallback " Makefile
# The fallback opens the first terminal there is, running itself to show
# why; with none, it says what to do.
mkdir -p "$tmp/sf-foot" "$tmp/sf-none" "$tmp/sf-show"
printf '#!/bin/sh\necho "foot $*"\n' > "$tmp/sf-foot/foot"
printf '#!/bin/sh\necho "xterm $*"\n' > "$tmp/sf-foot/xterm"
chmod +x "$tmp/sf-foot/foot" "$tmp/sf-foot/xterm"
check "the shell's fallback opens the first terminal there is, showing why" \
    test "$(PATH="$tmp/sf-foot" /bin/sh bin/tide-shell-fallback 2>/dev/null)" = "foot bin/tide-shell-fallback --show"
sf_err=$(PATH="$tmp/sf-none" /bin/sh bin/tide-shell-fallback 2>&1)
sf_status=$?
check "with no terminal, the shell's fallback fails" test "$sf_status" -eq 1
check "and says what to do" \
    test -n "$(printf '%s\n' "$sf_err" | grep -F 'no terminal to open: install foot, or log out with Super+Shift+E')"
for cmd in systemctl journalctl; do
    printf '#!/bin/sh\necho "%s $*"\n' "$cmd" > "$tmp/sf-show/$cmd"
done
printf '#!/bin/sh\necho "shell $*"\n' > "$tmp/sf-show/stubshell"
chmod +x "$tmp/sf-show"/*
sf_shown=$(PATH="$tmp/sf-show" SHELL="$tmp/sf-show/stubshell" /bin/sh bin/tide-shell-fallback --show 2>&1)
check "the fallback's terminal says the shell didn't start" \
    contains "$sf_shown" "tide's shell didn't start"
check "and how to log out" contains "$sf_shown" "Super+Shift+E logs out"
check "it shows the shell's status" \
    contains "$sf_shown" "systemctl --user status tide.service"
check "and its log" contains "$sf_shown" "journalctl --user -u tide.service -b"
check "then leaves a shell to fix it from" \
    test "$(printf '%s\n' "$sf_shown" | tail -n 1)" = "shell -i"
# A bar meanwhile: waybar in a unit of its own, where it's installed. The
# stub systemd-run records its arguments and exits $FAKE_RUN_STATUS.
mkdir -p "$tmp/sf-bar"
ln -s "$tmp/sf-foot/foot" "$tmp/sf-bar/foot"
printf '#!/bin/sh\n' > "$tmp/sf-bar/waybar"
# shellcheck disable=SC2016 # the stub's own $* and ${...}
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s"\necho "run failed" >&2\nexit "${FAKE_RUN_STATUS:-0}"\n' "$tmp/sf-run" > "$tmp/sf-bar/systemd-run"
chmod +x "$tmp/sf-bar/waybar" "$tmp/sf-bar/systemd-run"
sf_err=$(PATH="$tmp/sf-bar" /bin/sh bin/tide-shell-fallback 2>&1 >/dev/null)
check "the fallback starts waybar in a unit of its own, which the shell's return stops" \
    test "$(cat "$tmp/sf-run")" = "--user --quiet --collect --unit=tide-bar-fallback --property=PartOf=graphical-session.target --property=Conflicts=tide.service --slice=session-graphical.slice waybar"
check "and says waybar is the bar" contains "$sf_err" "waybar is the bar until the shell runs again"
check "and still opens the terminal" \
    test "$(PATH="$tmp/sf-bar" /bin/sh bin/tide-shell-fallback 2>/dev/null)" = "foot bin/tide-shell-fallback --show"
sf_err=$(FAKE_RUN_STATUS=1 PATH="$tmp/sf-bar" /bin/sh bin/tide-shell-fallback 2>&1 >/dev/null)
check "a waybar that can't start is reported" contains "$sf_err" "couldn't start waybar as the bar: run failed"
check "and the terminal still opens" \
    test "$(FAKE_RUN_STATUS=1 PATH="$tmp/sf-bar" /bin/sh bin/tide-shell-fallback 2>/dev/null)" = "foot bin/tide-shell-fallback --show"
sf_err=$(PATH="$tmp/sf-foot" /bin/sh bin/tide-shell-fallback 2>&1 >/dev/null)
check "without waybar, the fallback says there's no bar" contains "$sf_err" "no waybar, so there's no bar"
check "the shell's fallback parses as sh" sh -n bin/tide-shell-fallback
check "the shell's fallback is executable" test -x bin/tide-shell-fallback
check "a lock that can't start isn't restarted" \
    has_line "$lock" "RestartPreventExitStatus=78"
check "tide-lock exits with the status the unit doesn't restart" \
    has_line bin/tide-lock "EX_CONFIG=78"
check "a crash loop's restarts run out within 10 s" \
    has_line "$lock" "StartLimitIntervalSec=10"
check "and at the fifth start" has_line "$lock" "StartLimitBurst=5"
# A crash that's restarted mustn't also start hyprlock, which would race
# the restarted lock for the session.
check "a restarted lock skips the fallback" has_line "$lock" "RestartMode=direct"
# The fallback's command, as systemd would run it, against a hyprlock that
# says which config it was given: tide's without one of yours, or with a
# link to one that's gone, and yours when it's there.
lock_start=$(sed -n 's/^ExecStart=\/bin\/sh -c //p' "$lockfallback" | sed "s/^'//; s/'\$//; s/\\$\\$/\\$/g")
mkdir -p "$tmp/lock-bin" "$tmp/lock-none/.config/hypr" "$tmp/lock-gone/.config/hypr" \
    "$tmp/lock-own/.config/hypr"
printf '#!/bin/sh\necho "hyprlock $*"\n' > "$tmp/lock-bin/hyprlock"
chmod +x "$tmp/lock-bin/hyprlock"
ln -s "$tmp/lock-gone/gone.conf" "$tmp/lock-gone/.config/hypr/hyprlock.conf"
: > "$tmp/lock-own/.config/hypr/hyprlock.conf"
lock_config() { HOME="$tmp/$1" XDG_CONFIG_HOME='' PATH="$tmp/lock-bin:/usr/bin:/bin" sh -c "$lock_start"; }
check "the fallback is hyprlock, with your config" \
    test "$(lock_config lock-own)" = "hyprlock --config $tmp/lock-own/.config/hypr/hyprlock.conf"
check "without a hyprlock config of your own, the fallback gets tide's" \
    test "$(lock_config lock-none)" = "hyprlock --config $tmp/lock-none/.config/hypr/tide-hyprlock.conf"
check "a link to a hyprlock config that's gone gets tide's too" \
    test "$(lock_config lock-gone)" = "hyprlock --config $tmp/lock-gone/.config/hypr/tide-hyprlock.conf"
# shellcheck disable=SC2016 # sh -c's own $1
check "make install puts tide's hyprlock config beside yours" \
    sh -c 'env -u XDG_CONFIG_HOME HOME="$1" make -n install 2>/dev/null | grep -qF "hypr/hyprlock.conf \"$1/.config/hypr/tide-hyprlock.conf\""' sh "$tmp/home"
check "tide's hyprlock config has a password field" grep -q "^input-field {" hypr/hyprlock.conf
check "and names the host" grep -qF "uname -n" hypr/hyprlock.conf
check "the fallback stops with the session" \
    has_line "$lockfallback" "PartOf=graphical-session.target"
check "a crashed fallback takes the lock back" has_line "$lockfallback" "Restart=on-failure"
check "nothing but the lock's failure starts the fallback" \
    lacks_line_matching "$lockfallback" "^(\[Install\]|WantedBy=)"
check "the fallback has no fallback of its own" \
    lacks_line_matching "$lockfallback" "^OnFailure="
# The fallback's notice, as systemd would run it, with a fake notify-send
# that records its arguments, one per line, and exits $FAKE_NOTIFY_STATUS.
fallback_notice=$(sed -n "s/^ExecStartPost=\/bin\/sh -c '\(.*\)'\$/\1/p" "$lockfallback")
mkdir -p "$tmp/notice-bin"
cat > "$tmp/notice-bin/notify-send" <<FAKE
#!/bin/sh
printf '%s\n' "\$@" > "$tmp/notice"
exit "\${FAKE_NOTIFY_STATUS:-0}"
FAKE
chmod +x "$tmp/notice-bin/notify-send"
notice_err=$(PATH="$tmp/notice-bin:$PATH" sh -c "$fallback_notice" 2>&1)
check "the fallback's notice runs: $notice_err" test "$?" -eq 0
check "the fallback says the lock fell back, and where to look" \
    test "$(cat "$tmp/notice")" = "$(printf '%s\n' --urgency=critical --app-name=tide "The tide lock failed" "hyprlock locked the session instead. Run tide doctor to see why.")"
notice_err=$(FAKE_NOTIFY_STATUS=1 PATH="$tmp/notice-bin:$PATH" sh -c "$fallback_notice" 2>&1)
check "a notice that fails never stops the fallback" test "$?" -eq 0
check "and is logged" test "$notice_err" = "tide-lock-fallback: notify-send failed, so only the journal says the lock fell back"
check "make install installs the fallback's unit" \
    grep -q 'systemd/user/tide-lock-fallback.service' Makefile
check "the lock's PAM service checks the password like a login" \
    has_line pam/tide-lock "auth include login"
check "the lock asks PAM for its own service" \
    grep -qF 'config: "tide-lock"' shell/lock.qml

# --- tide-clipboard.service -----------------------------------------------------
# The picker's history (SPEC.md §8.4): every copy through tide clipboard
# store, which skips a password manager's, capped at 200; the database
# private to you; stopped with the session, and only in tide's.
check "the history watches the clipboard through tide clipboard store" \
    has_line "$clipboard" "ExecStart=wl-paste --watch tide clipboard store --max-items 100"
check "the history's database is private" has_line "$clipboard" "UMask=0077"
check "the history stops with the session" has_line "$clipboard" "PartOf=graphical-session.target"
check "the history runs only in the tide sessions" \
    has_line "$clipboard" "WantedBy=wayland-session@tide-hyprland.target wayland-session@tide-tidewm.target"
check "and is ordered after either one's target" \
    grep -qE "^After=wayland-session@tide-hyprland\.target wayland-session@tide-tidewm\.target " "$clipboard"
check "make install installs the history's unit" \
    grep -q 'systemd/user/tide-clipboard.service' Makefile

# --- tide-fcitx5.service --------------------------------------------------------
# Accents on a held letter (SPEC.md §8.6): fcitx5 in either tide session,
# never Plasma's, skipped where it isn't installed or TIDE_IME=0, and its
# variables in the manager's environment only while it runs.
check "the input method is fcitx5, replacing any already running" \
    has_line "$fcitx5" "ExecStart=fcitx5 --replace"
check "it's ready once it owns its bus name" has_line "$fcitx5" "BusName=org.fcitx.Fcitx5"
check "and is skipped where fcitx5 isn't installed" \
    has_line "$fcitx5" "ExecCondition=/bin/sh -c 'command -v fcitx5 >/dev/null'"
check "TIDE_IME=0 turns it off" has_line "$fcitx5" "ConditionEnvironment=!TIDE_IME=0"
check "apps started after it get the input method's variables" \
    has_line "$fcitx5" "ExecStartPost=systemctl --user set-environment QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx"
check "which go once it stops" \
    has_line "$fcitx5" "ExecStopPost=systemctl --user unset-environment QT_IM_MODULE XMODIFIERS"
check "it starts before autostarted apps" has_line "$fcitx5" "Before=xdg-desktop-autostart.target"
check "and each autostarted app's service waits for it, not only their target" \
    has_line "$autostart" "After=tide-fcitx5.service"
check "it stops with the session" has_line "$fcitx5" "PartOf=graphical-session.target"
check "it runs only in the tide sessions, not Plasma's" \
    has_line "$fcitx5" "WantedBy=wayland-session@tide-hyprland.target wayland-session@tide-tidewm.target"
check "make install installs the input method's unit" \
    grep -q 'systemd/user/tide-fcitx5.service' Makefile

# --- tide-lid-inhibit.service -------------------------------------------------
# The Power page's Lock and Do nothing (SPEC.md §16): logind's lid switch
# held while it runs, stopped with the session, and started only by the
# shell, never at login on its own.
check "the lid action holds logind's lid switch" \
    grep -q '^ExecStart=systemd-inhibit --what=handle-lid-switch .*--mode=block systemd-notify --ready --exec \\; sleep infinity$' "$lidinhibit"
check "the lid action counts as started only once the inhibitor is held" has_line "$lidinhibit" "Type=notify"
check "and takes the readiness systemd-inhibit's child sends" has_line "$lidinhibit" "NotifyAccess=all"
check "the lid action stops with the session" has_line "$lidinhibit" "PartOf=graphical-session.target"
check "nothing starts the lid action but the shell" lacks_line_matching "$lidinhibit" "^(\[Install\]|WantedBy=)"
check "make install installs the lid action's unit" \
    grep -q 'systemd/user/tide-lid-inhibit.service' Makefile

# --- tide-kde.service ----------------------------------------------------------
# tide's launcher on KDE Plasma (SPEC.md §8.5): kde.qml, resident, only in
# Plasma's session and never in tide's.
check "the launcher on Plasma runs kde.qml alone" \
    has_line "$kdelauncher" "ExecStart=qs -p %h/.config/quickshell/tide/kde.qml"
check "it starts with Plasma" has_line "$kdelauncher" "WantedBy=plasma-workspace.target"
check "and stops with it" has_line "$kdelauncher" "PartOf=plasma-workspace.target"
check "it is WantedBy= nothing else" test "$(grep -c '^WantedBy=' "$kdelauncher")" -eq 1
check "it runs only where Plasma's session says KDE" \
    has_line "$kdelauncher" "ConditionEnvironment=XDG_CURRENT_DESKTOP=KDE"
check "it never starts in tide's session" \
    lacks_line_matching "$kdelauncher" '(graphical-session|wayland-session@tide)'
check "make install installs it" grep -q 'systemd/user/tide-kde.service' Makefile

# --- systemd-analyze verify ---------------------------------------------------
# Resolves the units as systemd would. tide-shell and hypridle aren't
# installed here, so the copies point ExecStart at a stub; everything else is
# as shipped.
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$tmp/run" "$tmp/units/hypridle.service.d"
    chmod 700 "$tmp/run"
    printf '#!/bin/sh\n' > "$tmp/stub"
    chmod +x "$tmp/stub"
    sed -e "s|^ExecStart=tide-shell\$|ExecStart=$tmp/stub|" \
        -e "s|^ExecStartPost=-tide lock-check\$|ExecStartPost=-$tmp/stub|" "$unit" > "$tmp/units/tide.service"
    # A stand-in for the packaged hypridle.service, with the drop-in on top.
    printf '[Unit]\nDescription=hypridle\n[Service]\nExecStart=%s\n' "$tmp/stub" \
        > "$tmp/units/hypridle.service"
    cp "$dropin" "$tmp/units/hypridle.service.d/"
    # A stand-in for a generated autostart unit, under the prefix drop-in.
    agent_unit='app-polkit\x2dmate\x2dauthentication\x2dagent\x2d1@autostart.service'
    mkdir -p "$tmp/units/app-.service.d"
    printf '[Unit]\nDescription=agent\n[Service]\nExecStart=%s\n' "$tmp/stub" \
        > "$tmp/units/$agent_unit"
    cp "$autostart" "$tmp/units/app-.service.d/"
    sed "s|^ExecStart=tide-lock\$|ExecStart=$tmp/stub|" "$lock" > "$tmp/units/tide-lock.service"
    sed "s|^ExecStart=/bin/sh -c .*hyprlock.*\$|ExecStart=$tmp/stub|" "$lockfallback" > "$tmp/units/tide-lock-fallback.service"
    sed "s|^ExecStart=tide-shell-fallback\$|ExecStart=$tmp/stub|" "$shellfallback" > "$tmp/units/tide-shell-fallback.service"
    sed "s|^ExecStart=wl-paste .*\$|ExecStart=$tmp/stub|" "$clipboard" > "$tmp/units/tide-clipboard.service"
    sed "s|^ExecStart=qs .*\$|ExecStart=$tmp/stub|" "$kdelauncher" > "$tmp/units/tide-kde.service"
    sed "s|^ExecStart=fcitx5 .*\$|ExecStart=$tmp/stub|" "$fcitx5" > "$tmp/units/tide-fcitx5.service"
    for u in tide.service tide-lock.service tide-lock-fallback.service tide-shell-fallback.service tide-clipboard.service tide-kde.service tide-fcitx5.service hypridle.service "$agent_unit"; do
        out=$(cd "$tmp/units" && XDG_RUNTIME_DIR="$tmp/run" \
            systemd-analyze verify --user --man=no "$u" 2>&1)
        status=$?
        check "systemd-analyze verify $u exits 0: $out" test "$status" -eq 0
        # The system bus doesn't exist in a container; nothing else may print.
        out=$(printf '%s\n' "$out" | grep -v '^Failed to connect to system bus')
        check "systemd-analyze verify $u prints nothing: $out" test -z "$out"
    done
else
    echo "SKIP: systemd-analyze verify (not installed)"
fi

# --- Portals --------------------------------------------------------------------
check "the portal config names hyprland then gtk" \
    has_line "$portals" "default=hyprland;gtk"
check "the portal config never picks kde, gnome or wlr" \
    lacks_line_matching "$portals" '^[^#]*(kde|gnome|wlr)'
check "tidewm's portal config names wlr then gtk" \
    has_line "$tidewm_portals" "default=wlr;gtk"
check "tidewm's portal config never picks hyprland, kde or gnome" \
    lacks_line_matching "$tidewm_portals" '^[^#]*(hyprland|kde|gnome)'

# --- make install / install-session ----------------------------------------------
home="$tmp/home"
# An upgrade removes the per-agent drop-ins earlier versions installed, but
# nothing else beside them.
old_dropin="$home/.config/systemd/user/app-polkit\x2dmate\x2dauthentication\x2dagent\x2d1@autostart.service.d"
old_kept="$home/.config/systemd/user/app-xfce\x2dpolkit@autostart.service.d"
old_custom="$home/.config/systemd/user/app-custom\x2dagent@autostart.service.d"
not_ours="$home/.config/systemd/user/app-other@autostart.service.d"
mkdir -p "$old_dropin" "$old_kept" "$old_custom" "$not_ours"
git show "$(git rev-list -1 HEAD -- systemd/user/not-in-quickspace.conf)^:systemd/user/not-in-quickspace.conf" \
    > "$tmp/old-dropin.conf" 2>/dev/null \
    || printf "# A drop-in for another desktop's autostarted polkit agent: it skips the agent\n[Service]\n" > "$tmp/old-dropin.conf"
for d in "$old_dropin" "$old_kept" "$old_custom"; do cp "$tmp/old-dropin.conf" "$d/quickspace.conf"; done
touch "$old_kept/mine.conf"
printf '[Service]\nEnvironment=MINE=1\n' > "$not_ours/quickspace.conf"
# An install from before the rename from quickspace (2026-10-03) left its
# files behind, as they shipped (651d5ec's drop-in, e36846f's unit, enabled).
# The hypridle drop-in skipped hypridle in tide, so nothing locked.
units="$home/.config/systemd/user"
mkdir -p "$units/hypridle.service.d" "$units/app-.service.d" \
    "$units/wayland-session@quickspace-hyprland.target.wants" "$home/.config/xdg-desktop-portal"
cat > "$units/hypridle.service.d/quickspace.conf" <<'EOF'
# hypridle counts as started only once it owns org.freedesktop.ScreenSaver:
# Chrome uses the D-Bus inhibitor only if that name is already owned, so an
# app started earlier would silently lose its inhibits (SPEC.md §5.4).
[Service]
ExecCondition=/bin/sh -c 'case ":$${XDG_CURRENT_DESKTOP}:" in *:quickspace:*) ;; *) exit 1 ;; esac'
Type=dbus
BusName=org.freedesktop.ScreenSaver
TimeoutStartSec=10
EOF
cat > "$units/app-.service.d/quickspace-autostart.conf" <<'EOF'
# XDG autostart is an allowlist in quickspace (SPEC.md §5.4). systemd's
[Service]
ExecCondition=/bin/sh -c 'case ":$${XDG_CURRENT_DESKTOP}:%n" in *:quickspace:*@autostart.service) quickspace autostart-allowed "%n"; s=$$?; test "$$s" -le 1 && exit "$$s"; echo "quickspace autostart-allowed failed ($$s) for %n" >&2; exit 255 ;; esac'
EOF
printf '# The quickspace shell: bar, launcher, notifications, tray watcher and polkit\n[Service]\nExecStart=quickspace-shell\n' \
    > "$units/quickspace.service"
ln -s ../quickspace.service "$units/wayland-session@quickspace-hyprland.target.wants/quickspace.service"
printf '# Portal backends for XDG_CURRENT_DESKTOP=quickspace:Hyprland. xdg-desktop-portal\n[preferred]\ndefault=hyprland;gtk\n' \
    > "$home/.config/xdg-desktop-portal/quickspace-portals.conf"
# A drop-in of yours that happens to share the name stays.
mine_dir="$tmp/mine-units"
mkdir -p "$mine_dir/hypridle.service.d"
printf '[Service]\nEnvironment=MINE=1\n' > "$mine_dir/hypridle.service.d/quickspace.conf"
# The fake HOME would send Go to an empty module cache, and so the network.
if make -s install HOME="$home" GOMODCACHE="$(go env GOMODCACHE)" GOCACHE="$(go env GOCACHE)" \
    >"$tmp/install.log" 2>&1; then
    for f in .config/hypr/tide/layout.lua \
             .config/hypr/tide/geometry.lua \
             .config/hypr/tide/direction.lua \
             .config/hypr/tide/span.lua \
             .config/hypr/tide/focus.lua \
             .config/hypr/tide/pinned.lua \
             .config/systemd/user/tide.service \
             .config/systemd/user/tide-lock.service \
             .config/systemd/user/tide-lock-fallback.service \
             .config/systemd/user/tide-shell-fallback.service \
             .config/quickshell/tide/lock.qml \
             .config/quickshell/tide/LockSurface.qml \
             .config/quickshell/tide/LockFace.qml \
             .config/quickshell/tide/greeter.qml \
             .config/quickshell/tide/lib/greeter.mjs \
             .config/quickshell/tide/lib/lock.mjs \
             .config/systemd/user/hypridle.service.d/tide.conf \
             .config/xdg-desktop-portal/tide-portals.conf \
             .config/xdg-desktop-portal/tidewm-portals.conf \
             .config/systemd/user/app-.service.d/tide-autostart.conf \
             .config/quickshell/tide/icons/cpu-symbolic.svg \
             .config/quickshell/tide/icons/memory-symbolic.svg; do
        check "make install puts $f in place" test -f "$home/$f"
    done
    check "make install removes an old per-agent drop-in and its directory" test ! -e "$old_dropin"
    check "make install removes our old drop-in beside a file of yours" test ! -e "$old_kept/quickspace.conf"
    check "make install keeps your own drop-in" test -f "$old_kept/mine.conf"
    check "make install removes an old drop-in installed under a custom POLKIT_AUTOSTART" test ! -e "$old_custom"
    check "make install keeps a quickspace.conf it didn't write" test -f "$not_ours/quickspace.conf"
    check "make install removes quickspace's hypridle drop-in, which skipped hypridle in tide" \
        test ! -e "$units/hypridle.service.d/quickspace.conf"
    check "make install removes quickspace's autostart drop-in" \
        test ! -e "$units/app-.service.d/quickspace-autostart.conf"
    check "make install removes quickspace's shell unit" test ! -e "$units/quickspace.service"
    check "and its enablement" test ! -e "$units/wayland-session@quickspace-hyprland.target.wants"
    check "make install removes quickspace's portal config" \
        test ! -e "$home/.config/xdg-desktop-portal/quickspace-portals.conf"
    check "make install says what it removed" \
        grep -qF "make install: removed $units/hypridle.service.d/quickspace.conf, left from quickspace" "$tmp/install.log"
    # What the lock rests on: hypridle answers logind's Lock. systemd runs
    # every ExecCondition in its drop-ins, so each must pass in tide, and
    # fail elsewhere (Plasma keeps the ScreenSaver name).
    conds=$(sed -n 's/^ExecCondition=//p' "$units"/hypridle.service.d/*.conf | sed 's/\$\$/$/g')
    check "hypridle has an ExecCondition" test -n "$conds"
    # Each ExecCondition is `/bin/sh -c '...'`; strip the quotes for sh -c.
    conds=$(printf '%s\n' "$conds" | sed "s/^\/bin\/sh -c '\(.*\)'\$/\1/")
    hypridle_runs() {
        printf '%s\n' "$conds" | while IFS= read -r c; do
            XDG_CURRENT_DESKTOP=$1 sh -c "$c" || exit 1
        done
    }
    check "after make install over a quickspace install, hypridle runs in tide" hypridle_runs tide:Hyprland
    check "and not under Plasma" not hypridle_runs KDE
    # Run as an upgrade would, over a drop-in of yours by the same name.
    if make -s install HOME="$home" SYSTEMD_USER_DIR="$mine_dir" GOMODCACHE="$(go env GOMODCACHE)" GOCACHE="$(go env GOCACHE)" \
        >"$tmp/install-mine.log" 2>&1; then
        check "make install keeps a hypridle quickspace.conf it didn't write" \
            test -f "$mine_dir/hypridle.service.d/quickspace.conf"
    else
        fail "make install over your own drop-in: $(cat "$tmp/install-mine.log")"
    fi
else
    fail "make install: $(cat "$tmp/install.log")"
fi
if make -s install-session DESTDIR="$tmp/root" PREFIX=/usr >"$tmp/session.log" 2>&1; then
    check "make install-session installs the wrapper" \
        test -x "$tmp/root/usr/bin/tide-hyprland"
    check "make install-session installs the tidewm session's wrapper" \
        test -x "$tmp/root/usr/bin/tide-tidewm"
    check "make install-session installs the tide command" \
        test -x "$tmp/root/usr/bin/tide"
    check "make install-session installs tide-grant" \
        test -x "$tmp/root/usr/bin/tide-grant"
    check "make install-session installs tide-msg, tidewm's IPC client" \
        test -x "$tmp/root/usr/bin/tide-msg"
    check "make install-session installs tide-tabs, the browser tabs' host" \
        test -x "$tmp/root/usr/bin/tide-tabs"
    check "make install-session installs tide-pick, the wallpaper's file chooser" \
        test -x "$tmp/root/usr/bin/tide-pick"
    check "make install-session installs the unit's shell" \
        test -x "$tmp/root/usr/bin/tide-shell"
    check "make install-session installs what the lock's unit runs" \
        test -x "$tmp/root/usr/bin/tide-lock"
    check "make install-session installs the session entry" \
        test -f "$tmp/root/usr/share/wayland-sessions/tide.desktop"
    check "make install-session installs the tidewm session's entry" \
        test -f "$tmp/root/usr/share/wayland-sessions/tide-tidewm.desktop"
    check "make install-session installs the lock's PAM service in /etc/pam.d" \
        test -f "$tmp/root/etc/pam.d/tide-lock"
    check "make install-session installs the greeter's command" \
        test -x "$tmp/root/usr/bin/tide-greeter"
    for f in share/tide/greeter/hyprland.lua \
             share/tide/greeter/greetd.toml \
             share/tide/shell/greeter.qml \
             share/tide/shell/LockFace.qml \
             share/tide/shell/lib/greeter.mjs \
             share/tide/shell/lib/lock.mjs; do
        check "make install-session puts the greeter's $f in place" test -f "$tmp/root/usr/$f"
    done
    # The installed command finds the config and the QML beside it.
    mkdir -p "$tmp/greeter-stubs"
    printf '#!/bin/sh\nexit 1\n' > "$tmp/greeter-stubs/busctl"
    cat > "$tmp/greeter-stubs/Hyprland" <<EOF
#!/bin/sh
printf '%s\n' "\$2" "\$TIDE_GREETER_QML" > "$tmp/greeter-ran"
EOF
    # The greeter won't start Hyprland without a qs to run in it.
    printf '#!/bin/sh\n' > "$tmp/greeter-stubs/qs"
    chmod +x "$tmp/greeter-stubs/busctl" "$tmp/greeter-stubs/Hyprland" "$tmp/greeter-stubs/qs"
    # busctl failing makes it warn, so what it says is kept for a failure.
    if PATH="$tmp/greeter-stubs:$PATH" "$tmp/root/usr/bin/tide-greeter" 2>"$tmp/greeter.err"; then
        pass
    else
        fail "the installed tide-greeter exited $?: $(cat "$tmp/greeter.err")"
    fi
    check "the installed tide-greeter runs Hyprland with the installed config and QML" \
        test "$(cat "$tmp/greeter-ran" 2>/dev/null)" = "$tmp/root/usr/bin/../share/tide/greeter/hyprland.lua
$tmp/root/usr/bin/../share/tide/shell/greeter.qml"
else
    fail "make install-session: $(cat "$tmp/session.log")"
fi

printf 'session_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
