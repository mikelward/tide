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
# show -p LoadState --value UNIT: loaded, or $FAKE_LOADSTATE's state for the
# unit it names (UNIT=STATE); it fails with $FAKE_LOADSTATE_FAILS.
if test "$2" = show && test "$4" = LoadState; then
    if test -n "$FAKE_LOADSTATE_FAILS"; then
        echo "$FAKE_LOADSTATE_FAILS" >&2
        exit 1
    fi
    case " $FAKE_LOADSTATE " in
        *" $6="*) state=${FAKE_LOADSTATE#*"$6"=}; echo "${state%% *}"; exit 0 ;;
    esac
    echo loaded
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
# busctl --user call ... ListActivatableNames: the names in
# $FAKE_ACTIVATABLE, or fails with $FAKE_ACTIVATABLE_FAILS.
if test "$2" = call; then
    if test -n "$FAKE_ACTIVATABLE_FAILS"; then
        echo "$FAKE_ACTIVATABLE_FAILS" >&2
        exit 1
    fi
    set -- $FAKE_ACTIVATABLE
    printf 'as %s' "$#"
    for n in "$@"; do printf ' "%s"' "$n"; done
    printf '\n'
    exit 0
fi
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
# dpkg-query -S PATH names the package $FAKE_PACKAGES gives for PATH's
# file name (NAME=PACKAGE words), and fails as dpkg-query does for a file no
# package owns, or with $FAKE_DPKG_FAILS as it does when it can't look.
cat > "$fake/dpkg-query" <<'FAKE'
#!/bin/sh
if test -n "$FAKE_DPKG_FAILS"; then
    echo "$FAKE_DPKG_FAILS" >&2
    exit 2
fi
for p in $FAKE_PACKAGES; do
    if test "${p%%=*}" = "${2##*/}"; then
        printf '%s: %s\n' "${p#*=}" "$2"
        exit 0
    fi
done
echo "dpkg-query: no path found matching pattern $2" >&2
exit 1
FAKE
# rpm -qf PATH answers the same way from $FAKE_RPM_PACKAGES, or fails with
# $FAKE_RPM_FAILS. pacman owns nothing. With all three on PATH, a host's
# own rpm or pacman database never enters a test.
cat > "$fake/rpm" <<'FAKE'
#!/bin/sh
if test -n "$FAKE_RPM_FAILS"; then
    echo "$FAKE_RPM_FAILS" >&2
    exit 1
fi
for p in $FAKE_RPM_PACKAGES; do
    if test "${p%%=*}" = "${4##*/}"; then
        printf '%s\n' "${p#*=}"
        exit 0
    fi
done
echo "file $4 is not owned by any package"
exit 1
FAKE
cat > "$fake/pacman" <<'FAKE'
#!/bin/sh
echo "error: No package owns $2" >&2
exit 1
FAKE
# qs --version answers as Quickshell 0.3.1, or prints $FAKE_QS_VERSION and
# exits $FAKE_QS_VERSION_STATUS. It comes before any real qs on PATH, and in
# a directory of its own, so a run can leave it off.
mkdir "$tmp/qs-bin"
# qs -c tide ipc call polkit status answers $FAKE_QS_POLKIT (registered by
# default), or fails with $FAKE_QS_IPC_FAILS.
cat > "$tmp/qs-bin/qs" <<'FAKE'
#!/bin/sh
if test "$*" = "-c tide ipc call polkit status"; then
    if test -n "$FAKE_QS_IPC_FAILS"; then
        echo "$FAKE_QS_IPC_FAILS" >&2
        exit 1
    fi
    printf '%s\n' "${FAKE_QS_POLKIT:-registered}"
    exit 0
fi
printf '%s\n' "${FAKE_QS_VERSION:-Quickshell 0.3.1 (revision 1a4716c, distributed by test)}"
exit "${FAKE_QS_VERSION_STATUS:-0}"
FAKE
chmod +x "$fake"/* "$tmp/qs-bin/qs"

# A healthy session: every owner in place, one of each daemon, the portal
# config installed, and no autostart unit running.
healthy() {
    rm -rf "${tmp:?}/owned" "${tmp:?}/proc" "${tmp:?}/config" "${tmp:?}/etc" "${tmp:?}/share" \
        "${tmp:?}/runtime" "${tmp:?}/datadir" "${tmp:?}/sysconf" "${tmp:?}/no-data-home"
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
    # The session bus's config, laid out as dbus ships it: the standard
    # directories, then the local files under (here) $tmp/sysconf.
    mkdir -p "$tmp/datadir/dbus-1"
    bus_conf
}
# bus_conf [LINE...]: writes the session bus's config, the one doctor
# starts from, with LINEs inside <busconfig> after the shipped ones.
bus_conf() {
    {
        printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"' \
            ' "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
            '<busconfig>' '  <standard_session_servicedirs />' \
            "  <include ignore_missing=\"yes\">$tmp/sysconf/dbus-1/session.conf</include>" \
            '  <includedir>session.d</includedir>' \
            "  <includedir>$tmp/sysconf/dbus-1/session.d</includedir>" \
            "  <include ignore_missing=\"yes\">$tmp/sysconf/dbus-1/session-local.conf</include>" \
            '  <include if_selinux_enabled="yes" selinux_root_relative="yes">contexts/dbus_contexts</include>'
        printf '%s\n' "$@"
        printf '%s\n' '</busconfig>'
    } > "$tmp/datadir/dbus-1/session.conf"
}

# run ENV...: runs the doctor in a tide session unless ENV says
# otherwise, with the given fakes' answers.
run() {
    env PATH="$fake:$tmp/qs-bin:$PATH" FAKE_OWNED="$tmp/owned" FAKE_TMP="$tmp" \
        XDG_CURRENT_DESKTOP=tide:Hyprland XDG_CONFIG_HOME="$tmp/config" TIDE_PROC="$tmp/proc" \
        XDG_CONFIG_DIRS="$tmp/etc" XDG_DATA_HOME="$tmp/no-data-home" XDG_DATA_DIRS="$tmp/share" \
        XDG_RUNTIME_DIR="$tmp/runtime" TIDE_DATADIR="$tmp/datadir" TIDE_SYSCONFDIR="$tmp/sysconf" \
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

# A Quickshell older than 0.3 can't load tide's shell (Debian's 0.2.1),
# so tide-shell runs waybar, and says so only in its log.
run FAKE_QS_VERSION="quickshell 0.2.1, revision 0000000, distributed by: Debian"
check "an old Quickshell is a problem" test "$status" -eq 1
check "an old Quickshell is named, with the fix" \
    contains "$out" "qs ($tmp/qs-bin/qs) is Quickshell 0.2.1, and tide's shell needs 0.3 or newer, so the bar is waybar: install a newer Quickshell (on Debian and Ubuntu, \`setup --tide\` builds one), then \`systemctl --user restart tide.service\`"
run FAKE_QS_VERSION="Quickshell 0.3.0 (revision 0000000, distributed by Ubuntu)"
check "Quickshell 0.3.0 is no problem" test "$out" = "No problems found."
run FAKE_QS_VERSION="Quickshell nightly"
check "an unreadable Quickshell version is a problem" \
    contains "$out" "couldn't tell which Quickshell $tmp/qs-bin/qs is (qs --version printed 'Quickshell nightly'), so the version check is skipped"
run FAKE_QS_VERSION="qs: cannot open display" FAKE_QS_VERSION_STATUS=1
check "a failing qs --version is a problem" \
    contains "$out" "couldn't tell which Quickshell $tmp/qs-bin/qs is (qs --version: qs: cannot open display), so the version check is skipped"

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

# Activation files: service DIR NAME [LINE...] writes DIR/dbus-1/services/
# NAME, declaring the name LINEs name.
service() {
    mkdir -p "$1/dbus-1/services"
    _file=$1/dbus-1/services/$2
    shift 2
    printf '[D-BUS Service]\n' > "$_file"
    printf '%s\n' "$@" >> "$_file"
}
dunst() {
    service "$1" org.knopwob.dunst.service Name=org.freedesktop.Notifications \
        Exec=/usr/bin/dunst SystemdService=dunst.service
}
healthy
dunst "$tmp/datadir"
service "$tmp/datadir" org.knopwob.other.service Name=org.knopwob.dunst Exec=/usr/bin/other
run FAKE_PACKAGES="org.knopwob.dunst.service=dunst"
check "an activatable rival is a problem" test "$status" -eq 1
check "an activatable rival is named by its unit, file and package, with the fix" \
    contains "$out" "$tmp/datadir/dbus-1/services/org.knopwob.dunst.service (from the dunst package) lets D-Bus start dunst.service whenever org.freedesktop.Notifications has no owner, and it would then keep the name from tide: \`systemctl --user mask dunst.service\`"
check "an activation file for another name isn't a problem" test -z "$(grep 'other' "$tmp/out")"
run
check "an activation file no package owns is named alone" \
    contains "$out" "$tmp/datadir/dbus-1/services/org.knopwob.dunst.service lets D-Bus start dunst.service"
run FAKE_LOADSTATE="dunst.service=masked"
check "an activation file whose unit is masked starts nothing" test "$out" = "No problems found."
run FAKE_LOADSTATE="dunst.service=not-found"
check "an activation file whose unit isn't installed starts nothing" test "$out" = "No problems found."
run FAKE_LOADSTATE_FAILS="Failed to connect to bus"
check "failing to read a unit's state is reported, not taken as masked" \
    contains "$out" "couldn't check whether dunst.service is masked (Failed to connect to bus), so $tmp/datadir/dbus-1/services/org.knopwob.dunst.service may let D-Bus start it whenever org.freedesktop.Notifications has no owner"

healthy
service "$tmp/share" org.xfce.xfce4-notifyd.Notifications.service \
    "Name = org.freedesktop.Notifications" "Exec = /usr/lib/xfce4/notifyd/xfce4-notifyd --replace"
run FAKE_PACKAGES="org.xfce.xfce4-notifyd.Notifications.service=xfce4-notifyd"
check "one with no unit is named by its command, with the package to remove" \
    contains "$out" "$tmp/share/dbus-1/services/org.xfce.xfce4-notifyd.Notifications.service (from the xfce4-notifyd package) lets D-Bus start /usr/lib/xfce4/notifyd/xfce4-notifyd whenever org.freedesktop.Notifications has no owner, and it would then keep the name from tide; it has no unit to mask: remove the xfce4-notifyd package"
run
check "one with no unit and no package is the file to remove" \
    contains "$out" "$tmp/share/dbus-1/services/org.xfce.xfce4-notifyd.Notifications.service lets D-Bus start /usr/lib/xfce4/notifyd/xfce4-notifyd whenever org.freedesktop.Notifications has no owner, and it would then keep the name from tide; it has no unit to mask: remove that file"
run FAKE_DPKG_FAILS="dpkg-query: error: parsing file '/var/lib/dpkg/status' near line 9"
check "a package lookup that fails is reported, not taken for no package" \
    contains "$out" "(which package ships it couldn't be told: dpkg-query: error: parsing file '/var/lib/dpkg/status' near line 9)"
check "a package lookup that fails doesn't say to remove the file alone" \
    contains "$out" "it has no unit to mask: remove the package that ships it, or the file if none does"
run FAKE_RPM_PACKAGES="org.xfce.xfce4-notifyd.Notifications.service=xfce4-notifyd"
check "a file dpkg doesn't know is looked up in rpm too" \
    contains "$out" "(from the xfce4-notifyd package) lets D-Bus start /usr/lib/xfce4/notifyd/xfce4-notifyd"
run FAKE_RPM_FAILS="error: cannot open Packages database in /var/lib/rpm"
check "one manager failing, with none owning the file, is a failed lookup" \
    contains "$out" "(which package ships it couldn't be told: error: cannot open Packages database in /var/lib/rpm)"


healthy
service "$tmp/datadir" org.kde.plasma.Notifications.service Name=org.freedesktop.Notifications \
    "Exec=/usr/bin/plasma_waitforname org.freedesktop.Notifications"
run
check "KDE's plasma_waitforname entry starts nothing" test "$out" = "No problems found."
service "$tmp/datadir" org.example.Wrapped.service Name=org.freedesktop.Notifications \
    "Exec=/usr/bin/env HELPER=plasma_waitforname /usr/bin/dunst"
service "$tmp/datadir" org.example.False.service Name=org.freedesktop.Notifications \
    "Exec=/home/user/bin/false"
run
check "plasma_waitforname as another command's argument isn't KDE's" \
    contains "$out" "$tmp/datadir/dbus-1/services/org.example.Wrapped.service lets D-Bus start /usr/bin/env"
check "a script named false isn't an override" \
    contains "$out" "$tmp/datadir/dbus-1/services/org.example.False.service lets D-Bus start /home/user/bin/false"

# Which file the bus uses can't be told from outside (an arbitrary pick in
# one directory, a cached XDG_RUNTIME_DIR), so every one is judged and none
# shadows another.
healthy
dunst "$tmp/datadir"
service "$tmp/no-data-home" quiet.service Name=org.freedesktop.Notifications Exec=/bin/false
run
check "an Exec=false override is no problem itself" test -z "$(grep 'quiet.service' "$tmp/out")"
check "an override doesn't excuse the rival it would shadow" \
    contains "$out" "$tmp/datadir/dbus-1/services/org.knopwob.dunst.service lets D-Bus start dunst.service"
service "$tmp/no-data-home" quiet.service Name=org.freedesktop.Notifications Exec=/bin/false SystemdService=quiet.service
run
check "Exec=false doesn't stop a unit from being activated" \
    contains "$out" "$tmp/no-data-home/dbus-1/services/quiet.service lets D-Bus start quiet.service"
rm -r "$tmp/no-data-home"
service "$tmp/runtime" org.freedesktop.Notifications.service Name=org.freedesktop.Notifications Exec=/usr/bin/swaync SystemdService=swaync.service
service "$tmp/runtime" misnamed.service Name=org.freedesktop.Notifications Exec=/usr/bin/mako
run FAKE_LOADSTATE="dunst.service=masked"
check "a file in XDG_RUNTIME_DIR named after its name is judged" \
    contains "$out" "$tmp/runtime/dbus-1/services/org.freedesktop.Notifications.service lets D-Bus start swaync.service"
check "so is a misnamed one, which dbus-broker loads though dbus-daemon doesn't" \
    contains "$out" "$tmp/runtime/dbus-1/services/misnamed.service lets D-Bus start /usr/bin/mako"
rm -r "$tmp/runtime"
dunst "$tmp/share"
chmod 000 "$tmp/share/dbus-1/services/org.knopwob.dunst.service"
if ! cat "$tmp/share/dbus-1/services/org.knopwob.dunst.service" >/dev/null 2>&1; then
    run FAKE_LOADSTATE="dunst.service=masked"
    check "an unreadable activation file is reported, not passed over" \
        contains "$out" "couldn't read $tmp/share/dbus-1/services/org.knopwob.dunst.service, so the activatable-services check is incomplete"
fi # root reads it anyway
rm -f "$tmp/share/dbus-1/services/org.knopwob.dunst.service"
dunst "$tmp/share"
chmod 000 "$tmp/share/dbus-1/services"
if ! ls "$tmp/share/dbus-1/services" >/dev/null 2>&1; then
    run FAKE_LOADSTATE="dunst.service=masked"
    check "a service directory that can't be listed is reported, not taken for empty" \
        contains "$out" "couldn't list $tmp/share/dbus-1/services, so the activatable-services check is incomplete"
fi # root lists it anyway
chmod 755 "$tmp/share/dbus-1/services"
rm -f "$tmp/share/dbus-1/services/org.knopwob.dunst.service"
service "$tmp/share" swaync.service Name=org.freedesktop.Notifications Exec=/usr/bin/swaync SystemdService=swaync.service
run
check "files in every directory are judged" \
    test "$(grep -c 'lets D-Bus start' "$tmp/out")" -eq 2
run FAKE_LOADSTATE="swaync.service=masked dunst.service=masked"
check "every file masked is no problem" test "$out" = "No problems found."
service "$tmp/datadir" org.erikreider.swaync.service Name=org.freedesktop.Notifications Exec=/usr/bin/swaync SystemdService=swaync-other.service
run FAKE_LOADSTATE="swaync.service=masked dunst.service=masked"
check "a second file in one directory is judged too, whichever the bus picks" \
    contains "$out" "$tmp/datadir/dbus-1/services/org.erikreider.swaync.service lets D-Bus start swaync-other.service"

# The bus config can add service directories, through its includes,
# absolute or relative: to the file naming them for dbus-daemon, and to
# the home directory for dbus-broker. It's read as XML, as the buses read
# it: a commented-out one isn't one, and neither is one spread over lines,
# since neither bus trims an element's text.
healthy
mkdir -p "$tmp/sysconf/dbus-1/session.d" "$tmp/datadir/dbus-1/session.d/more" "$tmp/extra" \
    "$tmp/nested" "$tmp/commented" "$tmp/spread" "$tmp/home/more"
printf '<busconfig>\n  <servicedir>%s</servicedir>\n  <!-- <servicedir>%s</servicedir> -->\n  <servicedir>\n    %s\n  </servicedir>\n</busconfig>\n' \
    "$tmp/extra" "$tmp/commented" "$tmp/spread" > "$tmp/sysconf/dbus-1/session-local.conf"
printf '<busconfig><servicedir>more</servicedir></busconfig>\n' > "$tmp/datadir/dbus-1/session.d/more.conf"
printf '<busconfig><include>%s</include></busconfig>\n' "$tmp/nested/inner.xml" \
    > "$tmp/sysconf/dbus-1/session.d/outer.conf"
printf '<busconfig><servicedir>%s</servicedir><include>%s</include></busconfig>\n' \
    "$tmp/nested" "$tmp/sysconf/dbus-1/session.d/outer.conf" > "$tmp/nested/inner.xml"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/mako\n' > "$tmp/extra/mako.service"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/fnott\n' \
    > "$tmp/datadir/dbus-1/session.d/more/fnott.service"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/dunst\n' > "$tmp/home/more/dunst.service"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/nested\n' > "$tmp/nested/nested.service"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/commented\n' > "$tmp/commented/commented.service"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/spread\n' > "$tmp/spread/spread.service"
run HOME="$tmp/home"
check "a service directory the bus config's included file adds is searched" \
    contains "$out" "$tmp/extra/mako.service lets D-Bus start /usr/bin/mako"
check "a relative one is searched relative to the file naming it" \
    contains "$out" "$tmp/datadir/dbus-1/session.d/more/fnott.service lets D-Bus start /usr/bin/fnott"
check "and relative to the home directory" \
    contains "$out" "$tmp/home/more/dunst.service lets D-Bus start /usr/bin/dunst"
check "includes are followed through an includedir, and a cycle ends" \
    contains "$out" "$tmp/nested/nested.service lets D-Bus start /usr/bin/nested"
check "a commented-out service directory isn't searched" test -z "$(grep commented "$tmp/out")"
check "nor is one spread over lines" test -z "$(grep spread "$tmp/out")"
rm "$tmp/extra/mako.service" "$tmp/datadir/dbus-1/session.d/more/fnott.service" "$tmp/nested/nested.service" \
    "$tmp/home/more/dunst.service"
run HOME="$tmp/home"
check "a bus config adding only clean directories is no problem" test "$out" = "No problems found."
chmod 000 "$tmp/sysconf/dbus-1/session-local.conf"
if ! cat "$tmp/sysconf/dbus-1/session-local.conf" >/dev/null 2>&1; then
    run
    check "an unreadable bus config file is reported" \
        contains "$out" "couldn't read $tmp/sysconf/dbus-1/session-local.conf (Permission denied) while reading the session bus's config, so the activatable-services check may miss a service directory it adds"
fi # root reads it anyway
chmod 644 "$tmp/sysconf/dbus-1/session-local.conf"
chmod 000 "$tmp/sysconf/dbus-1/session.d"
if ! ls "$tmp/sysconf/dbus-1/session.d" >/dev/null 2>&1; then
    run
    check "an unreadable bus config directory is reported" \
        contains "$out" "couldn't read $tmp/sysconf/dbus-1/session.d (Permission denied) while reading"
fi # root lists it anyway
chmod 755 "$tmp/sysconf/dbus-1/session.d"
printf '<busconfig><servicedir>\n' > "$tmp/sysconf/dbus-1/session-local.conf"
run
check "a bus config file that isn't XML is reported" \
    contains "$out" "couldn't read $tmp/sysconf/dbus-1/session-local.conf (not valid XML:"
bus_conf "  <include>$tmp/sysconf/dbus-1/gone.conf</include>"
rm "$tmp/sysconf/dbus-1/session-local.conf"
run
check "a missing include is reported" \
    contains "$out" "couldn't read $tmp/sysconf/dbus-1/gone.conf (it doesn't exist) while reading"
check "a missing ignore_missing one isn't" test -z "$(grep session-local "$tmp/out")"

# SELinux decides two of the includes, as libselinux decides it for both
# buses: one marked if_selinux_enabled is read only while selinuxfs is
# mounted and SELinux's config exists, and one marked selinux_root_relative
# is relative to the policy root SELINUXTYPE names.
healthy
mkdir -p "$tmp/selinux-only" "$tmp/sysconf/selinux/mls/contexts" "$tmp/proc/self"
bus_conf "  <include if_selinux_enabled=\"yes\">$tmp/selinux-only.conf</include>"
printf '<busconfig><servicedir>%s</servicedir></busconfig>\n' "$tmp/selinux-only" > "$tmp/selinux-only.conf"
printf '[D-BUS Service]\nName=org.freedesktop.Notifications\nExec=/usr/bin/gated\n' > "$tmp/selinux-only/gated.service"
printf '<busconfig><servicedir>%s</servicedir></busconfig>\n' "$tmp/selinux-only" \
    > "$tmp/sysconf/selinux/mls/contexts/dbus_contexts"
printf 'proc /proc proc rw 0 0\n' > "$tmp/proc/self/mounts"
printf '# SELINUXTYPE=targeted\nSELINUXTYPE=mls\n' > "$tmp/sysconf/selinux/config"
run
check "with selinuxfs unmounted, an if_selinux_enabled include isn't read" \
    test "$out" = "No problems found."
printf 'selinuxfs /sys/fs/selinux selinuxfs rw 0 0\n' >> "$tmp/proc/self/mounts"
rm "$tmp/sysconf/selinux/config"
run
check "nor without SELinux's config" test "$out" = "No problems found."
printf '# SELINUXTYPE=targeted\nSELINUXTYPE=mls\n' > "$tmp/sysconf/selinux/config"
run
check "with SELinux on, an if_selinux_enabled include is read" \
    contains "$out" "$tmp/selinux-only/gated.service lets D-Bus start /usr/bin/gated"
rm "$tmp/selinux-only.conf"
bus_conf
run
check "and a root-relative one is read from the policy root" \
    contains "$out" "$tmp/selinux-only/gated.service lets D-Bus start /usr/bin/gated"
rm "$tmp/sysconf/selinux/mls/contexts/dbus_contexts"
run
check "a missing root-relative include with ignore_missing unset is reported" \
    contains "$out" "couldn't read $tmp/sysconf/selinux/mls/contexts/dbus_contexts (it doesn't exist)"

healthy
service "$tmp/datadir" org.example.Watcher.service Name=org.kde.StatusNotifierWatcher Exec=/usr/bin/snixembed
service "$tmp/datadir" org.example.Saver.service Name=org.freedesktop.ScreenSaver Exec=/usr/bin/saver
service "$tmp/datadir" org.example.Near.service Name=org.freedesktop.NotificationsX Exec=/usr/bin/near
run
check "an activatable tray watcher is a problem" \
    contains "$out" "lets D-Bus start /usr/bin/snixembed whenever org.kde.StatusNotifierWatcher has no owner"
check "an activatable screensaver is a problem" \
    contains "$out" "lets D-Bus start /usr/bin/saver whenever org.freedesktop.ScreenSaver has no owner"
check "a name is matched whole" test -z "$(grep 'near' "$tmp/out")"

# A name the bus can start that no file claims is reported.
healthy
run FAKE_ACTIVATABLE="org.freedesktop.Notifications org.example.Other"
check "a name the bus can start with no file left is a problem" \
    contains "$out" "D-Bus can start something for org.freedesktop.Notifications whenever it has no owner, but no activation file doctor reads names it"
check "another activatable name isn't" test -z "$(grep 'org.example.Other' "$tmp/out")"
dunst "$tmp/datadir"
run FAKE_ACTIVATABLE="org.freedesktop.Notifications" FAKE_LOADSTATE="dunst.service=masked"
check "a name a judged file claims isn't reported again" test "$out" = "No problems found."
run FAKE_ACTIVATABLE_FAILS="Failed to connect to bus: No such file or directory"
check "failing to ask the bus is reported" \
    contains "$out" "couldn't ask the session bus which names it can start (Failed to connect to bus: No such file or directory)"

# The bus trims a value's trailing space, so doctor does too.
healthy
service "$tmp/datadir" org.example.Spaced.service "Name=org.freedesktop.Notifications   " \
    "Exec=/usr/bin/spaced  " "SystemdService=spaced.service  "
run
check "a value's trailing space doesn't hide its name or unit" \
    contains "$out" "lets D-Bus start spaced.service whenever org.freedesktop.Notifications has no owner, and it would then keep the name from tide: \`systemctl --user mask spaced.service\`"
run FAKE_LOADSTATE="spaced.service=masked"
check "the trimmed unit is the one looked up" test "$out" = "No problems found."

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
printf 'TIDE_POLKIT=1\0' > "$tmp/proc/100/environ"
run FAKE_PROCS="hypridle swaync waybar qs"
check "with the shell as polkit agent, no other agent is fine" test "$out" = "No problems found."
run FAKE_PROCS="hypridle swaync waybar"
check "with TIDE_POLKIT=1 but no shell running (waybar), no agent is still a problem" \
    contains "$out" "no polkit agent is running"
mkdir -p "$tmp/proc/300"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-qs.scope" > "$tmp/proc/300/cgroup"
run FAKE_PROCS="hypridle swaync waybar qs" FAKE_PID_qs=300
check "a qs outside tide.service isn't the shell's agent" contains "$out" "no polkit agent is running"
mkdir -p "$tmp/proc/200"
printf '%s\n' '0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-polkit\x2dgnome@autostart.service' > "$tmp/proc/200/cgroup"
run FAKE_PROCS="hypridle swaync waybar qs polkit-gnome-au" FAKE_PID_polkit_gnome_au=200
check "with the shell as polkit agent, another agent holding the session is a problem" \
    contains "$out" "a polkit agent (pid 200) runs in app-polkit\\x2dgnome@autostart.service, and polkit lets one agent register per session, so the shell's own (TIDE_POLKIT=1) can't"
run FAKE_PROCS="hypridle swaync waybar qs" FAKE_QS_POLKIT=missing
check "a shell that couldn't make its agent is a problem, with the fix" \
    contains "$out" "the shell couldn't make its polkit agent, and with TIDE_POLKIT=1 tide-shell starts no other, so apps can't ask for a password"
run FAKE_PROCS="hypridle swaync waybar qs" FAKE_QS_POLKIT=unregistered
check "a shell agent polkitd hasn't taken is a problem" \
    contains "$out" "the shell's polkit agent hasn't registered with polkitd"
run FAKE_PROCS="hypridle swaync waybar qs polkit-gnome-au" FAKE_PID_polkit_gnome_au=200 FAKE_QS_POLKIT=unregistered
check "one held off by another agent is named once, by that agent" \
    test "$(grep -c polkit "$tmp/out")" -eq 1
run FAKE_PROCS="hypridle swaync waybar qs" FAKE_QS_IPC_FAILS="ipc: no running instance"
check "failing to ask the shell is reported" \
    contains "$out" "couldn't ask the shell whether its polkit agent works (qs ipc: ipc: no running instance)"
# Under waybar tide-shell starts an agent of its own in the unit.
run FAKE_PROCS="hypridle swaync waybar hyprpolkitagent"
check "with the shell as polkit agent, tide-shell's stand-in under waybar is fine" test "$out" = "No problems found."
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
    XDG_DATA_HOME="$tmp/no-data-home" XDG_RUNTIME_DIR="$tmp/runtime" TIDE_DATADIR="$tmp/datadir" TIDE_SYSCONFDIR="$tmp/sysconf" \
    FAKE_PROCS="hypridle swaync waybar hyprpolkitagent" FAKE_PID_hypridle=101 \
    "$tmp/no-jq/sh" "$doctor" 2>&1)
check "no jq is reported" contains "$out" "jq isn't installed, so the one-bar-per-monitor check is skipped"
check "no python3 is reported" \
    contains "$out" "python3 isn't installed, so service directories the session bus's config adds aren't searched"
check "no qs isn't a problem: waybar is the bar" test -z "$(printf '%s\n' "$out" | grep Quickshell)"

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
