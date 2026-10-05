#!/bin/sh
#
# Loads the shell and the lock in Quickshell, as tide.service and
# tide-lock.service start them (`qs -c tide`, `qs -p .../lock.qml`, over
# what `make install` puts in place), and fails on anything that keeps
# either from loading, or that the shell's own files report as it starts: a
# type or property error, a module Qt's JavaScript engine can't parse, a
# binding that throws. The Node tests can't see these; they only show up in
# Quickshell (SPEC.md §20).
#
# The bar is a layer-shell panel and the lock an ext-session-lock surface,
# which need a Wayland compositor that speaks both, as Hyprland does; sway,
# run headless, is the one here. Both run in a scratch home and runtime
# directory, on a D-Bus session bus of their own, and with no Hyprland to
# reach, so a run inside a tide session leaves that session alone.
#
# Every file's types and properties are checked, since Quickshell compiles
# them all, but only what runs at startup reports: the bindings of what
# exists then, and what they queue. A popover's contents, or a delegate
# made from data that arrives later (a clock, a notification), aren't
# covered.
#
# Given the password of the user running it, it also unlocks the lock: it
# types a wrong password and then the right one, and expects PAM to turn
# down the first and the lock to unlock and exit on the second. That needs
# wtype and tide-lock's PAM service in /etc/pam.d (`make install-session`).
#
#   $QS                  the Quickshell command (default: qs)
#   $TIDE_REQUIRE_QS     set (CI sets it) to fail, not skip, without qs or sway
#   $TIDE_LOAD_WAIT      seconds to wait for each step (default: 60)
#   $TIDE_KEEP_LOG       a file to copy Quickshell's logs to
#   $TIDE_LOCK_PASSWORD  the running user's password, to unlock the lock with.
#                        CI sets one in its throwaway container. It goes on
#                        wtype's command line, so never give it a real one.

cd "$(dirname "$0")/.." || exit 1
prog=shell/shell_test.sh

# Qt's font.pixelSize is an int: a fractional literal fails the whole
# config as it loads, and a fractional value in an expression is cut short.
# The mocks' sizes are CSS, where half pixels are common, so this is checked
# here, with no Quickshell needed, to catch one wherever make test runs.
if fractional=$(grep -n -E 'pixelSize:.*[0-9]\.[0-9]' shell/*.qml); then
    echo "FAIL: font.pixelSize takes whole pixels (SPEC.md §2):" >&2
    printf '%s\n' "$fractional" >&2
    exit 1
fi

# The shell and the lock name their icon theme, since Qt picks none for
# tide's desktop. Quickshell reads the pragma only above the first import,
# and its loss shows only as missing icons, which no load reports.
for entry in shell/shell.qml shell/lock.qml; do
    if ! sed '/^import /q' "$entry" | grep -q '^//@ pragma IconTheme Adwaita$'; then
        echo "FAIL: $entry doesn't name the Adwaita icon theme above its imports (SPEC.md §15)" >&2
        exit 1
    fi
done

# missing WHAT: skips the test, or fails it under $TIDE_REQUIRE_QS.
missing() {
    if test -n "${TIDE_REQUIRE_QS:-}"; then
        echo "FAIL: $prog: no $1 on PATH" >&2
        exit 1
    fi
    echo "SKIP: $prog: no $1 on PATH, so the shell isn't loaded; CI loads it" >&2
    exit 0
}
qs=${QS:-qs}
qs_path=$(command -v "$qs") || missing "$qs (Quickshell)"
sway_path=$(command -v sway) || missing "sway (to run headless)"
if test -n "${TIDE_LOCK_PASSWORD:-}" && ! wtype_path=$(command -v wtype); then
    echo "FAIL: $prog: TIDE_LOCK_PASSWORD is set, but there's no wtype on PATH to type it" >&2
    exit 1
fi

wait=${TIDE_LOAD_WAIT:-60}
case "$wait" in
    '' | *[!0-9]* | 0*)
        echo "$prog: TIDE_LOAD_WAIT must be a whole number of seconds, not '$wait'" >&2
        exit 1
        ;;
esac

tmp=$(mktemp -d) || exit 1
qs_pid=
keyboard_pid=
sway_pid=
bus_pid=
cleanup() {
    _status=$?
    for pid in $qs_pid $keyboard_pid $sway_pid; do
        # It may have exited already.
        kill "$pid" 2>/dev/null
        wait "$pid"
    done
    # The daemon forked away, so it isn't this shell's child to wait for.
    test -z "$bus_pid" || kill "$bus_pid"
    # Logs asked for and lost fail the run, even one that passed.
    if test -n "${TIDE_KEEP_LOG:-}" && ! cat "$tmp"/*.qs.log >"$TIDE_KEEP_LOG"; then
        echo "FAIL: $prog: couldn't keep the logs in $TIDE_KEEP_LOG" >&2
        _status=1
    fi
    rm -rf "$tmp"
    exit "$_status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$tmp/home" "$tmp/run" || exit 1
chmod 700 "$tmp/run" || exit 1

if ! make -s install-shell SHELL_DIR="$tmp/home/.config/quickshell/tide" >"$tmp/install.log" 2>&1; then
    echo "FAIL: make install-shell: $(cat "$tmp/install.log")" >&2
    exit 1
fi

# A session bus of the test's own; dbus-daemon returns once it's ready.
# Without one, the shell's D-Bus services can't start, which Quickshell
# reports as its own warnings, not the shell's.
bus_address=
if command -v dbus-daemon >/dev/null 2>&1; then
    bus_address=unix:path=$tmp/run/bus
    if ! bus_pid=$(dbus-daemon --session --address="$bus_address" --fork --print-pid=1 --nopidfile); then
        echo "FAIL: couldn't start a session bus for the shell" >&2
        exit 1
    fi
else
    echo "$prog: no dbus-daemon, so the shell runs without a session bus" >&2
fi

# waited FAILURE N: whether N tenths of a second have passed, which ends a
# wait by failing the test with FAILURE.
waited() {
    test "$2" -lt "$((wait * 10))" && return 1
    echo "FAIL: $1 in $wait s" >&2
    return 0
}

# Headless sway, with nothing to draw on and no X server: a compositor for
# the shell's windows, and no more.
printf 'xwayland disable\n' >"$tmp/sway.conf" || exit 1
env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
    WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    "$sway_path" -c "$tmp/sway.conf" >"$tmp/sway.log" 2>&1 &
sway_pid=$!
i=0
until test -S "$tmp/run/wayland-1"; do
    if ! kill -0 "$sway_pid" 2>/dev/null || waited "sway didn't start" "$i"; then
        echo "FAIL: headless sway didn't start:" >&2
        cat "$tmp/sway.log" >&2
        exit 1
    fi
    sleep 0.1
    i=$((i + 1))
done

# load NAME WHAT ARG...: starts `qs ARG...` on the headless sway, and fails
# the test unless it loads WHAT with nothing reported by the shell's own
# files. Its log is $tmp/NAME.qs.log. Nothing edits the files during the
# test, so the file watcher is off, as tide-lock.service has it.
load() {
    _what=$2
    log=$tmp/$1.qs.log
    shift 2
    : >"$log" || exit 1
    env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
        ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} \
        LANG=C.UTF-8 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        QS_DISABLE_FILE_WATCHER=1 \
        "$qs_path" "$@" >"$log" 2>&1 &
    qs_pid=$!

    # Quickshell says either, once the config has compiled and its objects
    # exist, so every binding it starts with has run.
    i=0
    while :; do
        if grep -q 'Configuration Loaded\|Failed to load configuration' "$log"; then
            break
        fi
        if ! kill -0 "$qs_pid" 2>/dev/null; then
            break
        fi
        if waited "Quickshell didn't start" "$i"; then
            cat "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    # Loading is synchronous, but what it queued (a Qt.callLater, a queued
    # signal) runs on the event loop afterward. Quickshell answers IPC on
    # that same loop, so once it has answered, those have run and reported
    # too; a loop that's stuck never answers, so the wait has the same
    # limit. What waits on the world outside (a process's output, a file
    # read) can't be waited for without a timer, and isn't covered.
    if grep -q 'Configuration Loaded' "$log" && ! timeout "$wait" env -i PATH="$PATH" HOME="$tmp/home" \
        XDG_RUNTIME_DIR="$tmp/run" LANG=C.UTF-8 "$qs_path" ipc --pid "$qs_pid" show >"$tmp/ipc.log" 2>&1; then
        echo "FAIL: $_what loaded, but didn't answer IPC within $wait s:" >&2
        cat "$tmp/ipc.log" "$log" >&2
        exit 1
    fi
    # It may have exited already, having failed.
    kill "$qs_pid" 2>/dev/null
    wait "$qs_pid"
    qs_pid=

    if ! grep -q 'Configuration Loaded' "$log"; then
        echo "FAIL: Quickshell couldn't load $_what:" >&2
        cat "$log" >&2
        exit 1
    fi
    reports "$_what loaded"
    echo "ok: Quickshell loads $_what"
}

# reports CONTEXT: fails the test on anything the shell's own files reported
# in $log. Quickshell names them @File.qml or @lib/file.mjs.
reports() {
    if grep -E '@[A-Za-z]+\.qml|@lib/[a-z_]+\.mjs' "$log" >"$tmp/reports"; then
        echo "FAIL: $1, but its files reported:" >&2
        cat "$tmp/reports" >&2
        exit 1
    fi
}

# unlock: starts the lock again, types a wrong password and the right one
# in one go, and fails the test unless PAM turns down the first and the
# lock unlocks and exits on the second. Keys typed while PAM checks are
# kept, and an Enter among them waits for that check (SPEC.md §10), so the
# typing needn't wait on PAM. Its log is $tmp/unlock.qs.log.
unlock() {
    log=$tmp/unlock.qs.log
    : >"$log" || exit 1
    # The headless seat has no keyboard, and the one wtype makes comes and
    # goes with it: the lock would get its keyboard after the first keys
    # had gone. One held from the start keeps every key.
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        "$wtype_path" -s 3600000 >"$tmp/keyboard.log" 2>&1 &
    keyboard_pid=$!
    # WAYLAND_DEBUG logs the protocol, so the log shows the moment the lock
    # surface takes the keyboard (wl_keyboard.enter); keys typed before it
    # would go nowhere.
    env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
        ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} \
        LANG=C.UTF-8 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        QS_DISABLE_FILE_WATCHER=1 WAYLAND_DEBUG=client \
        "$qs_path" -p "$tmp/home/.config/quickshell/tide/lock.qml" >"$log" 2>&1 &
    qs_pid=$!
    i=0
    until grep -q '} wl_keyboard#[0-9]*\.enter(' "$log"; do
        if ! kill -0 "$qs_pid" 2>/dev/null; then
            echo "FAIL: the lock exited before it took the keyboard:" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        if waited "the lock didn't take the keyboard" "$i"; then
            cat "$tmp/keyboard.log" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    # wtype reads its text in the locale's encoding, so a password beyond
    # ASCII needs a UTF-8 one.
    timeout "$wait" env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        LANG=C.UTF-8 "$wtype_path" "not-$TIDE_LOCK_PASSWORD
$TIDE_LOCK_PASSWORD
" >"$tmp/wtype.log" 2>&1
    case $? in
        0) ;;
        124)
            echo "FAIL: wtype didn't finish typing into the lock in $wait s" >&2
            exit 1
            ;;
        *)
            echo "FAIL: wtype couldn't type into the lock: $(cat "$tmp/wtype.log")" >&2
            exit 1
            ;;
    esac
    i=0
    while kill -0 "$qs_pid" 2>/dev/null; do
        if waited "the lock didn't unlock" "$i"; then
            echo "Is TIDE_LOCK_PASSWORD right, and tide-lock's PAM service installed (make install-session)?" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    wait "$qs_pid"
    _status=$?
    qs_pid=
    if test "$_status" -ne 0; then
        echo "FAIL: the lock exited $_status on unlocking:" >&2
        grep -v '^\[' "$log" >&2
        exit 1
    fi
    # Quickshell's PAM subprocess logs each conversation's end.
    _results=$(grep -o 'Failed to authenticate\|Authenticated successfully' "$log" | tr '\n' ' ')
    if test "$_results" != "Failed to authenticate Authenticated successfully "; then
        echo "FAIL: PAM should turn down the wrong password, then take the right one; it said: $_results" >&2
        exit 1
    fi
    reports "the lock unlocked"
    echo "ok: the lock turns down a wrong password and unlocks on the right one"
}

load shell "the shell" -c tide
load lock "the lock" -p "$tmp/home/.config/quickshell/tide/lock.qml"
if test -n "${TIDE_LOCK_PASSWORD:-}"; then
    unlock
else
    echo "$prog: no TIDE_LOCK_PASSWORD, so the lock isn't unlocked; CI unlocks it" >&2
fi
