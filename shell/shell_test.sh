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
#   $QS               the Quickshell command (default: qs)
#   $TIDE_REQUIRE_QS  set (CI sets it) to fail, not skip, without qs or sway
#   $TIDE_LOAD_WAIT   seconds to wait for each to start (default: 60)
#   $TIDE_KEEP_LOG    a file to copy Quickshell's logs to

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

wait=${TIDE_LOAD_WAIT:-60}
case "$wait" in
    '' | *[!0-9]* | 0*)
        echo "$prog: TIDE_LOAD_WAIT must be a whole number of seconds, not '$wait'" >&2
        exit 1
        ;;
esac

tmp=$(mktemp -d) || exit 1
qs_pid=
sway_pid=
bus_pid=
cleanup() {
    _status=$?
    for pid in $qs_pid $sway_pid; do
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

# waited WHAT N: whether N tenths of a second have passed, which ends a
# wait for WHAT by failing the test.
waited() {
    test "$2" -lt "$((wait * 10))" && return 1
    echo "FAIL: $1 didn't start in $wait s" >&2
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
    if ! kill -0 "$sway_pid" 2>/dev/null || waited "sway" "$i"; then
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
        if waited "Quickshell" "$i"; then
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
    # What the shell's own files reported: Quickshell names them @File.qml
    # or @lib/file.mjs.
    if grep -E '@[A-Za-z]+\.qml|@lib/[a-z_]+\.mjs' "$log" >"$tmp/reports"; then
        echo "FAIL: $_what loaded, but its files reported:" >&2
        cat "$tmp/reports" >&2
        exit 1
    fi
    echo "ok: Quickshell loads $_what"
}

load shell "the shell" -c tide
load lock "the lock" -p "$tmp/home/.config/quickshell/tide/lock.qml"
