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

unit=systemd/user/tide.service
dropin=systemd/user/hypridle.service.d/tide.conf
entry=session/tide.desktop
wrapper=bin/tide-hyprland
portals=xdg-desktop-portal/tide-portals.conf
autostart=systemd/user/app-.service.d/tide-autostart.conf
lock=systemd/user/tide-lock.service

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# --- The session entry and its wrapper ----------------------------------------
# uwsm names the session after the compositor command, so the wrapper's name
# is the session's target; the unit must hang off that same target.
session_id=$(basename "$wrapper")
check "the entry starts the wrapper through uwsm with tide:Hyprland" \
    has_line "$entry" "Exec=uwsm start -e -D tide:Hyprland -N tide -- $session_id"
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
check "the wrapper is executable" test -x "$wrapper"
check "the wrapper parses as sh" sh -n "$wrapper"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes on the wrapper and this test" \
        shellcheck -s sh "$wrapper" session/session_test.sh
fi

# --- tide.service ---------------------------------------------------------
target="wayland-session@$session_id.target"
check "the unit is wanted by the tide session's target" \
    has_line "$unit" "WantedBy=$target"
# Plasma reaches graphical-session.target too; that's how swaync leaked in.
check "the unit is never WantedBy= graphical-session.target" \
    lacks_line_matching "$unit" '^WantedBy=.*graphical-session\.target'
check "the unit is WantedBy= nothing else" \
    test "$(grep -c '^WantedBy=' "$unit")" -eq 1
check "the unit is ordered after its session target" \
    grep -qE "^After=.*$target" "$unit"
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
check "hypridle is skipped under Plasma, even when a package enabled it" idle_skips_in "KDE"
check "hypridle's unit is skipped in a plain Hyprland login, which runs its own" idle_skips_in "Hyprland"
check "hypridle is skipped where no desktop is set" idle_skips_in ""

# --- The autostart allowlist -------------------------------------------------
# The drop-in's condition, as systemd would run it for a unit ($$ is a
# literal $, %n the unit's name), with this checkout's tide on PATH.
condition=$(sed -n 's/^ExecCondition=\/bin\/sh -c //p' "$autostart" | sed "s/^'//; s/'\$//; s/\\$\\$/\\$/g")
# condition_status DESKTOP UNIT: the condition's exit status; its stderr is
# kept in $tmp/condition.err for a failing check to show.
condition_status() {
    cmd=$(printf '%s\n' "$condition" | sed "s/%n/$(printf '%s' "$2" | sed 's/\\/\\\\/g')/g")
    env PATH="$PWD/bin:$PATH" XDG_CONFIG_HOME="$tmp/no-config" XDG_CURRENT_DESKTOP="$1" \
        sh -c "$cmd" 2>"$tmp/condition.err"
    echo $?
}
# A skip is exactly 1; 255 would be a failed unit, which isn't a skip.
runs_in() { s=$(condition_status "$@"); test "$s" -eq 0 || { cat "$tmp/condition.err" >&2; false; }; }
skips_in() { s=$(condition_status "$@"); test "$s" -eq 1 || { echo "status $s: $(cat "$tmp/condition.err")" >&2; false; }; }
agent='app-polkit\x2dmate\x2dauthentication\x2dagent\x2d1@autostart.service'
check "the autostart condition is a sh -c script" test -n "$condition"
check "another desktop's agent is skipped in the tide session" skips_in "tide:Hyprland" "$agent"
check "another desktop's daemon is skipped in the tide session" \
    skips_in "tide:Hyprland" 'app-xfce4\x2dnotifyd@autostart.service'
check "an allowlisted applet runs in the tide session" \
    runs_in "tide:Hyprland" 'app-nm\x2dapplet@autostart.service'
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
check "the lock runs lock.qml from the installed shell" \
    has_line "$lock" "ExecStart=qs -p %h/.config/quickshell/tide/lock.qml"
check "the lock's file watcher is off" \
    has_line "$lock" "Environment=QS_DISABLE_FILE_WATCHER=1"
check "only a crash restarts the lock" \
    has_line "$lock" "Restart=on-failure"
check "the lock's PAM service checks the password like a login" \
    has_line pam/tide-lock "auth include login"
check "the lock asks PAM for its own service" \
    grep -qF 'config: "tide-lock"' shell/lock.qml

# --- systemd-analyze verify ---------------------------------------------------
# Resolves the units as systemd would. tide-shell and hypridle aren't
# installed here, so the copies point ExecStart at a stub; everything else is
# as shipped.
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$tmp/run" "$tmp/units/hypridle.service.d"
    chmod 700 "$tmp/run"
    printf '#!/bin/sh\n' > "$tmp/stub"
    chmod +x "$tmp/stub"
    sed "s|^ExecStart=tide-shell\$|ExecStart=$tmp/stub|" "$unit" > "$tmp/units/tide.service"
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
    sed "s|^ExecStart=qs .*\$|ExecStart=$tmp/stub|" "$lock" > "$tmp/units/tide-lock.service"
    for u in tide.service tide-lock.service hypridle.service "$agent_unit"; do
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
# The fake HOME would send Go to an empty module cache, and so the network.
if make -s install HOME="$home" GOMODCACHE="$(go env GOMODCACHE)" GOCACHE="$(go env GOCACHE)" \
    >"$tmp/install.log" 2>&1; then
    for f in .config/hypr/tide/layout.lua \
             .config/hypr/tide/geometry.lua \
             .config/hypr/tide/focus.lua \
             .config/systemd/user/tide.service \
             .config/systemd/user/tide-lock.service \
             .config/quickshell/tide/lock.qml \
             .config/quickshell/tide/LockSurface.qml \
             .config/quickshell/tide/LockFace.qml \
             .config/quickshell/tide/lib/lock.mjs \
             .config/systemd/user/hypridle.service.d/tide.conf \
             .config/xdg-desktop-portal/tide-portals.conf \
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
else
    fail "make install: $(cat "$tmp/install.log")"
fi
if make -s install-session DESTDIR="$tmp/root" PREFIX=/usr >"$tmp/session.log" 2>&1; then
    check "make install-session installs the wrapper" \
        test -x "$tmp/root/usr/bin/tide-hyprland"
    check "make install-session installs the tide command" \
        test -x "$tmp/root/usr/bin/tide"
    check "make install-session installs tide-grant" \
        test -x "$tmp/root/usr/bin/tide-grant"
    check "make install-session installs the unit's shell" \
        test -x "$tmp/root/usr/bin/tide-shell"
    check "make install-session installs the session entry" \
        test -f "$tmp/root/usr/share/wayland-sessions/tide.desktop"
    check "make install-session installs the lock's PAM service in /etc/pam.d" \
        test -f "$tmp/root/etc/pam.d/tide-lock"
else
    fail "make install-session: $(cat "$tmp/session.log")"
fi

printf 'session_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
