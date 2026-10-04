#!/bin/sh
#
# Tests for bin/tide-doctor, against recorded answers from fake
# systemctl, busctl, pgrep and hyprctl, and portal
# directories under a temporary XDG tree.

cd "$(dirname "$0")/.." || exit 1
doctor=$PWD/bin/tide-doctor

passes=0
failures=0
pass() { passes=$((passes + 1)); }
fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1" >&2
}
check() {
    _name=$1
    shift
    if "$@"; then pass; else fail "$_name"; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/bin
mkdir "$fake"

# systemctl --user is-active UNIT answers active, or $FAKE_INACTIVE's state
# for the unit it names (UNIT=STATE). $FAKE_AUTOSTART_UNITS holds autostart
# units as NAME=STARTED words, STARTED being the unit's
# ExecMainStartTimestampMonotonic (0: its command never started); list-units
# and show answer from it, or fail with $FAKE_LIST_FAILS or $FAKE_SHOW_FAILS.
cat > "$fake/systemctl" <<'FAKE'
#!/bin/sh
if test "$2" = list-units; then
    printf '%s\n' "$*" > "$FAKE_TMP/systemctl-args"
    if test -n "$FAKE_LIST_FAILS"; then
        echo "$FAKE_LIST_FAILS" >&2
        exit 1
    fi
    # One unit per "NAME=STARTED" word; list-units prints its name.
    for u in $FAKE_AUTOSTART_UNITS; do
        printf '%s loaded inactive dead x\n' "${u%%=*}"
    done
    exit 0
fi
if test "$2" = show && test "$4" = MainPID; then
    if test -n "$FAKE_MAINPID_FAILS"; then
        echo "$FAKE_MAINPID_FAILS" >&2
        exit 1
    fi
    echo "${FAKE_MAIN_PID:-100}"
    exit 0
fi
if test "$2" = show && test "$4" = ActiveEnterTimestampMonotonic; then
    echo "${FAKE_SESSION_START:-100}"
    exit 0
fi
if test "$2" = show; then
    if test -n "$FAKE_SHOW_FAILS"; then
        echo "$FAKE_SHOW_FAILS" >&2
        exit 1
    fi
    shift 7 # --user show -p Id -p ExecMainStartTimestampMonotonic --
    for name in "$@"; do
        for u in $FAKE_AUTOSTART_UNITS; do
            if test "${u%%=*}" = "$name"; then
                printf 'Id=%s\nExecMainStartTimestampMonotonic=%s\n\n' "$name" "${u#*=}"
            fi
        done
    done
    exit 0
fi
case " $FAKE_INACTIVE " in
    *" $3="*) state=${FAKE_INACTIVE#*"$3"=}; echo "${state%% *}"; exit 3 ;;
esac
echo active
FAKE
# busctl --user status NAME: the owner is a file of that name in
# $FAKE_OWNED holding "COMM UNIT".
cat > "$fake/busctl" <<'FAKE'
#!/bin/sh
test -e "$FAKE_OWNED/$3" || { echo "Failed to get credentials: No such device or address" >&2; exit 1; }
read -r comm unit < "$FAKE_OWNED/$3"
printf 'PID=42\nComm=%s\nUserUnit=%s\n' "$comm" "$unit"
FAKE
# pgrep -u UID -x NAME: one pid per $FAKE_PROCS word (where _ stands for a
# space) that the regex NAME matches whole, or
# failing with $FAKE_PGREP_FAILS.
cat > "$fake/pgrep" <<'FAKE'
#!/bin/sh
if test -n "$FAKE_PGREP_FAILS"; then
    echo "$FAKE_PGREP_FAILS" >&2
    exit 3
fi
found=1
for p in $FAKE_PROCS; do
    # NAME is an extended regex, as in procps.
    if printf '%s\n' "$p" | tr _ ' ' | grep -Eqx -- "$4"; then
        # The pid is 100, or $FAKE_PID_NAME (- as _) if that's set.
        eval "pid=\${FAKE_PID_$(printf '%s' "$p" | tr -c 'A-Za-z0-9_' _):-100}"
        echo "$pid"
        found=0
    fi
done
exit $found
FAKE
# hyprctl configerrors prints $FAKE_CONFIGERRORS; -j monitors and -j layers
# print $FAKE_MONITORS and $FAKE_LAYERS (none of either by default). Any of
# them fails with $FAKE_HYPRCTL_FAILS.
cat > "$fake/hyprctl" <<'FAKE'
#!/bin/sh
if test -n "$FAKE_HYPRCTL_FAILS"; then
    echo "$FAKE_HYPRCTL_FAILS"
    exit 1
fi
case "$*" in
    "-j monitors") printf '%s' "${FAKE_MONITORS:-[]}" ;;
    "-j layers") printf '%s' "${FAKE_LAYERS:-{\}}" ;;
    *) printf '%s' "$FAKE_CONFIGERRORS" ;;
esac
FAKE
chmod +x "$fake"/*

# A healthy session: every owner in place, one of each daemon, the portal
# config installed, and no autostart unit running.
healthy() {
    rm -rf "${tmp:?}/owned" "${tmp:?}/proc" "${tmp:?}/config" "${tmp:?}/etc" "${tmp:?}/share"
    mkdir -p "$tmp/owned" "$tmp/config/xdg-desktop-portal" "$tmp/etc" "$tmp/share"
    echo "swaync tide.service" > "$tmp/owned/org.freedesktop.Notifications"
    echo "waybar tide.service" > "$tmp/owned/org.kde.StatusNotifierWatcher"
    echo "hypridle hypridle.service" > "$tmp/owned/org.freedesktop.ScreenSaver"
    # Every other fake pgrep match is pid 100, in tide.service.
    mkdir -p "$tmp/proc/100"
    echo "0::/user.slice/user-1000.slice/user@1000.service/session.slice/tide.service" > "$tmp/proc/100/cgroup"
    # hypridle is pid 101, in its own unit.
    mkdir -p "$tmp/proc/101"
    echo "0::/user.slice/user-1000.slice/user@1000.service/session.slice/hypridle.service" > "$tmp/proc/101/cgroup"
    printf 'HOME=/home/user\0' > "$tmp/proc/100/environ"
    cp xdg-desktop-portal/tide-portals.conf "$tmp/config/xdg-desktop-portal/"
}

# run ENV...: runs the doctor in a tide session unless ENV says
# otherwise, with the given fakes' answers.
run() {
    env PATH="$fake:$PATH" FAKE_OWNED="$tmp/owned" FAKE_TMP="$tmp" \
        XDG_CURRENT_DESKTOP=tide:Hyprland XDG_CONFIG_HOME="$tmp/config" TIDE_PROC="$tmp/proc" \
        XDG_CONFIG_DIRS="$tmp/etc" XDG_DATA_HOME="$tmp/no-data-home" XDG_DATA_DIRS="$tmp/share" \
        FAKE_PROCS="hypridle swaync waybar hyprpolkitagent" FAKE_PID_hypridle=101 \
        "$@" sh "$doctor" > "$tmp/out" 2> "$tmp/err"
    status=$?
    out=$(cat "$tmp/out")
}

healthy
run
check "a healthy session exits 0" test "$status" -eq 0
check "a healthy session says so" test "$out" = "No problems found."

run XDG_CURRENT_DESKTOP=KDE
check "outside tide it exits 2" test "$status" -eq 2
check "outside tide it says why" contains "$(cat "$tmp/err")" "not in a tide session"

run FAKE_INACTIVE="hypridle.service=failed"
check "a failed unit is a problem" test "$status" -eq 1
check "a failed unit is named, with where to look" \
    contains "$out" "hypridle.service is failed: see \`systemctl --user status hypridle.service\`"

healthy
rm "$tmp/owned/org.freedesktop.ScreenSaver"
run
check "a missing owner is reported with busctl's error" \
    contains "$out" "org.freedesktop.ScreenSaver has no owner (Failed to get credentials: No such device or address): hypridle.service should own it"

healthy
echo "dunst app-dunst@autostart.service" > "$tmp/owned/org.freedesktop.Notifications"
run
check "a name owned by the wrong unit names the owner" \
    contains "$out" "org.freedesktop.Notifications is owned by dunst in app-dunst@autostart.service, not tide.service"

healthy
run FAKE_PROCS="hypridle hypridle swaync waybar hyprpolkitagent"
check "a daemon running twice is a problem" contains "$out" "2 hypridle processes are running"
run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent swww-daemon swww-daemon"
check "two wallpaper daemons are a problem" contains "$out" "2 swww-daemon processes are running"

healthy
mkdir -p "$tmp/proc/200"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-swww.scope" > "$tmp/proc/200/cgroup"
run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent swww-daemon" FAKE_PID_swww_daemon=200
check "a daemon outside its unit is a problem, named by its scope" contains "$out" "swww-daemon (pid 200) runs in app-swww.scope, not tide.service"

run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent polkit-gnome-au"
check "two polkit agents are a problem" contains "$out" "2 polkit agents are running"

run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent mako"
check "a rival daemon is a problem" contains "$out" "mako is running, but tide owns its job"
run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent swayidle"
check "swayidle is a rival to hypridle" contains "$out" "swayidle is running, but tide owns its job"
run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent swaybg"
check "the shell's own swaybg isn't a problem" test -z "$(grep swaybg "$tmp/out")"
run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent swww-daemon swaybg"
check "swww-daemon and swaybg together are a problem, even in the unit" \
    contains "$out" "swww-daemon and swaybg are both running"
run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent swaybg" FAKE_PID_swaybg=200
check "a swaybg outside the shell is a problem" \
    contains "$out" "swaybg (pid 200) runs in app-swww.scope, not tide.service"

run FAKE_PROCS="hypridle swaync waybar"
check "no polkit agent is a problem" contains "$out" "no polkit agent is running"

healthy
printf '%s\n' '0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-polkit\x2dgnome@autostart.service' > "$tmp/proc/100/cgroup"
run FAKE_PROCS="hypridle swaync waybar polkit-gnome-au"
check "a polkit agent outside tide.service is a problem" \
    contains "$out" "the polkit agent (pid 100) runs in app-polkit\\x2dgnome@autostart.service, not tide.service"
rm "$tmp/proc/100/cgroup"
run
check "a polkit agent with no cgroup (gone) is reported with no unit" contains "$out" "runs in no user unit"
healthy

healthy
printf 'HOME=/home/user\0TIDE_POLKIT_AGENT=/opt/agents/my-polkit-agent-with-a-long-name\0' > "$tmp/proc/100/environ"
run FAKE_PROCS="hypridle swaync waybar my-polkit-agent"
check "an agent set with TIDE_POLKIT_AGENT counts, by its first 15 characters" test -z "$(grep 'polkit agent' "$tmp/out")"
printf 'TIDE_POLKIT_AGENTS=/opt/a/agent-one /opt/b/agent-two\0' > "$tmp/proc/100/environ"
run FAKE_PROCS="hypridle swaync waybar agent-two"
check "an agent from TIDE_POLKIT_AGENTS counts" test -z "$(grep 'polkit agent' "$tmp/out")"
printf 'TIDE_POLKIT_AGENT=/opt/My Agent/bin/my agent\0' > "$tmp/proc/100/environ"
run FAKE_PROCS="hypridle swaync waybar my_agent"
check "a TIDE_POLKIT_AGENT path with spaces is one agent" test -z "$(grep 'polkit agent' "$tmp/out")"
printf 'TIDE_POLKIT_AGENT=/opt/bin/agent+foo\0' > "$tmp/proc/100/environ"
run FAKE_PROCS="hypridle swaync waybar agent+foo"
check "a configured agent name is matched literally, not as a regex" test -z "$(grep 'polkit agent' "$tmp/out")"
run FAKE_PROCS="hypridle swaync waybar agenttfoo"
check "a configured agent name's metacharacters match only themselves" contains "$out" "no polkit agent is running"
healthy

healthy
run FAKE_MAINPID_FAILS="Failed to connect to bus"
check "failing to read the shell's MainPID is a problem" \
    contains "$out" "couldn't read tide.service's MainPID (Failed to connect to bus), so an agent set with TIDE_POLKIT_AGENT may be missed"
rm "$tmp/proc/100/environ"
run FAKE_PROCS="hypridle swaync waybar"
check "an unreadable shell environment is a problem" \
    contains "$out" "couldn't read tide.service's environment (pid 100:"
check "an unreadable shell environment doesn't claim there's no polkit agent" test -z "$(grep 'no polkit agent' "$tmp/out")"
run FAKE_PROCS="hypridle swaync waybar" FAKE_MAIN_PID=0 FAKE_INACTIVE=tide.service=inactive
check "a stopped shell has no environment to read" test -z "$(grep "tide.service's environment" "$tmp/out")"
healthy

run FAKE_PGREP_FAILS="cannot read /proc"
check "pgrep failing is a problem, not a clean bill" test "$status" -eq 1
check "pgrep failing doesn't claim there's no polkit agent" test -z "$(grep 'no polkit agent' "$tmp/out")"
check "pgrep failing is reported once, with its error" \
    test "$(grep -c 'pgrep failed (3: cannot read /proc), so the process checks are incomplete' "$tmp/out")" -eq 1

run XDG_CURRENT_DESKTOP=Hyprland:tide
check "tide not first in XDG_CURRENT_DESKTOP is a problem" \
    contains "$out" "XDG_CURRENT_DESKTOP is 'Hyprland:tide': tide must come first"

healthy
rm "$tmp/config/xdg-desktop-portal/tide-portals.conf"
run
check "a missing portal config is a problem" contains "$out" "tide-portals.conf isn't installed"
mkdir -p "$tmp/data/xdg-desktop-portal"
cp xdg-desktop-portal/tide-portals.conf "$tmp/data/xdg-desktop-portal/"
run XDG_DATA_HOME="$tmp/data"
check "a portal config under XDG_DATA_HOME counts" test "$status" -eq 0
rm -r "$tmp/data"
mkdir -p "$tmp/share/xdg-desktop-portal"
cp xdg-desktop-portal/tide-portals.conf "$tmp/share/xdg-desktop-portal/"
run
check "a portal config under XDG_DATA_DIRS counts" test "$status" -eq 0

healthy
printf '[preferred]\ndefault=kde\n' > "$tmp/config/xdg-desktop-portal/tide-portals.conf"
# A good one later in the search path doesn't help: only the first is read.
mkdir -p "$tmp/share/xdg-desktop-portal"
cp xdg-desktop-portal/tide-portals.conf "$tmp/share/xdg-desktop-portal/"
run
check "the first portal config found must be the shipped one" \
    contains "$out" "$tmp/config/xdg-desktop-portal/tide-portals.conf isn't the one tide ships"
: > "$tmp/config/xdg-desktop-portal/tide-portals.conf"
run
check "an empty portal config is a problem" contains "$out" "isn't the one tide ships"
{ echo "not a key file line"; cat xdg-desktop-portal/tide-portals.conf; } > "$tmp/config/xdg-desktop-portal/tide-portals.conf"
run
check "an edited portal config is a problem even with the right default" contains "$out" "isn't the one tide ships"
chmod 000 "$tmp/config/xdg-desktop-portal/tide-portals.conf"
if ! cat "$tmp/config/xdg-desktop-portal/tide-portals.conf" >/dev/null 2>&1; then
    run
    check "an unreadable portal config is reported" contains "$out" "couldn't read $tmp/config/xdg-desktop-portal/tide-portals.conf"
fi # root reads it anyway
chmod 644 "$tmp/config/xdg-desktop-portal/tide-portals.conf"

# The doctor's copy of the shipped config must match the repo's.
check "the doctor's copy of tide-portals.conf is the shipped one" \
    test "$(sed -n "/^    cat <<'EOF'$/,/^EOF$/p" "$doctor" | sed '1d;$d')" = "$(cat xdg-desktop-portal/tide-portals.conf)"

healthy
run FAKE_CONFIGERRORS="$(printf 'line 3: bad keyword\nline 9: bad value\n')"
check "each config error is a problem" test "$(grep -c '^Hyprland config error' "$tmp/out")" -eq 2
check "config errors fail the check" test "$status" -eq 1
run FAKE_HYPRCTL_FAILS="HYPRLAND_INSTANCE_SIGNATURE not set"
check "hyprctl failing is reported" \
    contains "$out" "hyprctl configerrors failed (HYPRLAND_INSTANCE_SIGNATURE not set)"
check "hyprctl failing leaves the bar check incomplete" \
    contains "$out" "hyprctl monitors failed: HYPRLAND_INSTANCE_SIGNATURE not set, so the one-bar-per-monitor check is incomplete"

# Bars: a 3440x1440 monitor at scale 1.25 is 2752x1152 logical, and a
# rotated 1920x1080 one beside it is 1080 wide.
if command -v jq >/dev/null 2>&1; then
    monitors='[{"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1.25,"transform":0},
               {"name":"DP-2","x":2752,"y":0,"width":1920,"height":1080,"scale":1,"transform":1}]'
    bar() { printf '{"x":%s,"y":%s,"w":%s,"h":%s,"namespace":"%s"}' "$@"; }
    healthy
    run FAKE_MONITORS="$monitors" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"0\":[$(bar 0 0 2752 1152 wallpaper)],\"2\":[$(bar 0 0 2752 32 waybar)],\"3\":[$(bar 2400 40 340 100 notifications)]}},\"DP-2\":{\"levels\":{\"2\":[$(bar 2752 0 1080 32 waybar)]}}}"
    check "one bar per monitor, a wallpaper and a popup are fine" test -z "$(grep 'bars on' "$tmp/out")"
    run FAKE_MONITORS="$monitors" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 0 2752 32 waybar),$(bar 0 0 2752 30 tide-bar)]}},\"DP-2\":{\"levels\":{\"2\":[$(bar 2752 0 1080 32 waybar)],\"3\":[$(bar 2752 0 1080 28 other)]}}}"
    check "two bars on a monitor are a problem, named" \
        contains "$out" "2 bars on DP-1 (waybar, tide-bar): only tide's should be there"
    check "a bar on the overlay layer counts, on a rotated monitor" \
        contains "$out" "2 bars on DP-2 (waybar, other)"
    run FAKE_MONITORS="$monitors" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 1120 2752 32 bottom-bar),$(bar 0 0 2752 32 waybar),$(bar 1076 300 600 400 launcher)]}}}"
    check "a bottom bar or the launcher isn't counted" test -z "$(grep 'bars on' "$tmp/out")"
    run FAKE_MONITORS="$monitors" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 0 2752 32 waybar),$(bar 8 40 1800 30 floating-bar)]}}}"
    check "a bar with margins and a set width still counts" contains "$out" "2 bars on DP-1 (waybar, floating-bar)"
    run FAKE_MONITORS="$monitors" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"1\":[$(bar 0 0 2752 32 bottom-layer-bar)],\"2\":[$(bar 0 0 2752 32 waybar)]}}}"
    check "a bar on the bottom layer counts" contains "$out" "2 bars on DP-1 (bottom-layer-bar, waybar)"
    # Reserved space: tide's 34 px bar on DP-1 reserves 34 at the top.
    reserved() {
        printf '[{"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1.25,"transform":0,"reserved":[%s]}]' "$1"
    }
    ours="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 0 2752 34 tide-bar)]}}}"
    run FAKE_MONITORS="$(reserved 0,34,0,0)" FAKE_LAYERS="$ours"
    check "tide's bar reserving its own height is fine" test -z "$(grep 'reserves\|bars on' "$tmp/out")"
    run FAKE_MONITORS="$(reserved 0,62,0,48)" FAKE_LAYERS="$ours"
    check "space reserved beyond tide's bar is a problem, by edge" \
        contains "$out" "DP-1 reserves 28 px at the top, 48 px at the bottom beyond tide's bar"
    run FAKE_MONITORS="$(reserved 0,74,0,0)" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 40 2752 34 tide-bar)]}}}"
    check "a monitor rule's reservation above tide's bar is found though it moves the bar down" \
        contains "$out" "DP-1 reserves 40 px at the top beyond tide's bar"
    run FAKE_MONITORS="$(reserved 40,34,0,0)" FAKE_LAYERS="$ours"
    check "a side dock is caught by the space it reserves" contains "$out" "DP-1 reserves 40 px on the left beyond tide's bar"
    run FAKE_MONITORS="$(reserved 0,34,0,48)" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 0 2752 34 waybar)]}}}"
    check "without tide's bar (under waybar) reserved space isn't judged" test -z "$(grep 'reserves' "$tmp/out")"
    run FAKE_MONITORS="$(reserved 0,64,0,0)" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 0 2752 34 tide-bar),$(bar 0 34 2752 30 waybar)]}}}"
    check "a second full-width bar is named once, as a bar" contains "$out" "2 bars on DP-1 (tide-bar, waybar)"
    check "a second full-width bar isn't also reported as reserved space" test -z "$(grep 'reserves' "$tmp/out")"
    run FAKE_MONITORS="$(reserved 0,34,0,0)" FAKE_LAYERS="{\"DP-1\":{\"levels\":{\"2\":[$(bar 0 0 2752 34 tide-bar)],\"3\":[$(bar 2000 0 700 34 popup)]}}}"
    check "a layer that reserves nothing isn't counted" test -z "$(grep 'reserves\|bars on' "$tmp/out")"
    run FAKE_MONITORS="$monitors" FAKE_LAYERS="not json"
    check "unreadable layers leave the bar check incomplete" \
        contains "$out" "so the one-bar-per-monitor check is incomplete"
fi
mkdir "$tmp/no-jq"
for cmd in sh cat sed awk grep tr tail head mktemp rm id dirname; do
    real=$(command -v "$cmd") && ln -s "$real" "$tmp/no-jq/$cmd"
done
healthy
out=$(env PATH="$fake:$tmp/no-jq" FAKE_OWNED="$tmp/owned" FAKE_TMP="$tmp" XDG_CURRENT_DESKTOP=tide:Hyprland \
    XDG_CONFIG_HOME="$tmp/config" TIDE_PROC="$tmp/proc" XDG_CONFIG_DIRS="$tmp/etc" XDG_DATA_DIRS="$tmp/share" \
    FAKE_PROCS="hypridle swaync waybar hyprpolkitagent" FAKE_PID_hypridle=101 \
    "$tmp/no-jq/sh" "$doctor" 2>&1)
check "no jq is reported" contains "$out" "jq isn't installed, so the one-bar-per-monitor check is skipped"

healthy
run FAKE_AUTOSTART_UNITS="app-nm\\x2dapplet@autostart.service=123 app-hplip\\x2dsystray@autostart.service=789 app-oneshot@autostart.service=456 app-skipped@autostart.service=0 app-earlier@autostart.service=50"
check "each autostart unit off the allowlist whose command started is a problem" \
    test "$(grep -c '^autostart unit' "$tmp/out")" -eq 2
check "an autostart unit that ran and exited counts" contains "$out" "autostart unit app-oneshot@autostart.service ran in tide"
check "an autostart unit is named, with the fix" \
    contains "$out" "autostart unit app-hplip\\x2dsystray@autostart.service ran in tide but isn't on the autostart allowlist: run tide's make install, whose app-.service.d drop-in skips it, then systemctl --user daemon-reload, then systemctl --user stop 'app-hplip\\x2dsystray@autostart.service'"
check "an allowlisted autostart unit isn't a problem" test -z "$(grep 'nm\\x2dapplet' "$tmp/out")"
check "a unit whose condition stopped its command isn't a problem" test -z "$(grep 'app-skipped' "$tmp/out")"
check "a unit that ran before this session began isn't a problem" test -z "$(grep 'app-earlier' "$tmp/out")"
check "systemctl is asked for every loaded autostart unit, dead ones too" \
    contains "$(cat "$tmp/systemctl-args")" "list-units --all --plain --no-legend app-*@autostart.service"
run FAKE_AUTOSTART_UNITS="app-hplip\\x2dsystray@autostart.service=789" TIDE_CMD="$tmp/no-such-tide"
check "a failed allowlist check is reported as one, not as a unit off the list" \
    contains "$out" "couldn't check autostart unit app-hplip\\x2dsystray@autostart.service against the allowlist ("
check "a failed allowlist check doesn't suggest allowing the unit" test -z "$(grep "isn't on the autostart allowlist" "$tmp/out")"
run FAKE_LIST_FAILS="Failed to connect to bus"
check "systemctl failing to list the units is a problem" \
    contains "$out" "systemctl couldn't read the autostart units (Failed to connect to bus)"
run FAKE_AUTOSTART_UNITS="app-x@autostart.service=1" FAKE_SHOW_FAILS="Access denied"
check "systemctl failing to show the units is a problem" \
    contains "$out" "systemctl couldn't read the autostart units (Access denied)"

doctor_out=$(env PATH="$fake:$PATH" XDG_CURRENT_DESKTOP=KDE sh bin/tide doctor 2>&1)
check "tide doctor runs it" contains "$doctor_out" "tide-doctor: not in a tide session"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes" shellcheck -s sh "$doctor" bin/tide-doctor_test.sh
fi

printf 'tide-doctor_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
