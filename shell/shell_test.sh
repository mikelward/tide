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
# run headless, is the one here. Hyprland's IPC is a stand-in
# (shell/hyprland_stand_in.py) with workspaces, windows and a script of
# events, so the bar's workspaces, window icons, title and layout symbol
# are built from them. Both run in a scratch home and runtime directory, on
# a D-Bus session bus of their own, so a run inside a tide session leaves
# that session alone.
#
# Every file's types and properties are checked, since Quickshell compiles
# them all, but only what runs reports: the bindings of what exists at
# startup and what the stand-in's answers and events make, and what they
# queue. A popover's contents, or a delegate made from data the stand-in
# doesn't give (a clock's process, a notification), aren't covered.
#
# With wtype, it also types into them. It opens the launcher, types the
# name of an app only it installs, and expects Enter to run that app. Given
# the password of the user running it, it also unlocks the lock: it types a
# wrong password and then the right one, and expects PAM to turn down the
# first and the lock to unlock and exit on the second. That needs
# tide-lock's PAM service in /etc/pam.d (`make install-session`).
#
#   $QS                  the Quickshell command (default: qs)
#   $TIDE_REQUIRE_QS     set (CI sets it) to fail, not skip, without qs,
#                        sway or wtype
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
python_path=$(command -v python3) || missing "python3 (for the stand-in Hyprland)"
# Without wtype, nothing is typed, so the launcher and the lock's password
# go untested.
if ! wtype_path=$(command -v wtype); then
    if test -n "${TIDE_REQUIRE_QS:-}" || test -n "${TIDE_LOCK_PASSWORD:-}"; then
        echo "FAIL: $prog: no wtype on PATH to type into the launcher and the lock" >&2
        exit 1
    fi
    wtype_path=
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
hypr_pid=
keyboard_pid=
sway_pid=
bus_pid=
cleanup() {
    _status=$?
    for pid in $qs_pid $hypr_pid $keyboard_pid $sway_pid; do
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

# barrier: returns once Quickshell has handled everything that reached it
# before the call. It answers IPC on its event loop, which takes, in one
# pass, all that's arrived since the last; it may answer before the rest of
# that pass, but a second request is only taken in a later pass. A loop
# that's stuck never answers, so each wait has the limit.
barrier() {
    for _ in 1 2; do
        if ! timeout "$wait" env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
            LANG=C.UTF-8 "$qs_path" ipc --pid "$qs_pid" show >"$tmp/ipc.log" 2>&1; then
            echo "FAIL: $_what loaded, but didn't answer IPC within $wait s:" >&2
            cat "$tmp/ipc.log" "$log" >&2
            exit 1
        fi
    done
}

# hyprland COMMAND: asks the stand-in Hyprland to drain or play, and prints
# its answer.
hyprland() {
    if ! timeout "$wait" "$python_path" shell/hyprland_stand_in.py "$1" "$hypr_dir" 2>"$tmp/hypr.err"; then
        echo "FAIL: the stand-in Hyprland didn't $1: $(cat "$tmp/hypr.err")" >&2
        cat "$tmp/hypr.log" >&2
        exit 1
    fi
}

# settle: answers the shell's Hyprland requests, and lets it take in the
# answers, until it has nothing more to ask. The stand-in answers only when
# drained, and a request the shell makes while handling an answer or an
# event has been sent by the time a barrier returns: so a drain that finds
# none after a barrier means every request was answered and every answer
# taken in. Each answered request is added to $tmp/answered.
settle() {
    _until=$(($(date +%s) + wait))
    while :; do
        barrier
        _answered=$(hyprland drain) || exit 1
        test -z "$_answered" && return
        printf '%s\n' "$_answered" >>"$tmp/answered"
        if test "$(date +%s)" -ge "$_until"; then
            echo "FAIL: $_what was still asking Hyprland after $wait s" >&2
            exit 1
        fi
    done
}

# load NAME WHAT ARG...: starts `qs ARG...` on the headless sway, with a
# fresh stand-in Hyprland, and fails the test unless it loads WHAT, asks
# Hyprland for its windows, takes in its events, and through all of that
# has nothing reported by the shell's own files. Its log is
# $tmp/NAME.qs.log. Nothing edits the files during the test, so the file
# watcher is off, as tide-lock.service has it.
load() {
    _what=$2
    log=$tmp/$1.qs.log
    shift 2
    : >"$log" || exit 1
    : >"$tmp/answered" || exit 1

    # Quickshell finds Hyprland by HYPRLAND_INSTANCE_SIGNATURE, and only if
    # its directory is there as it starts.
    hypr_signature=tide-test
    hypr_dir=$tmp/run/hypr/$hypr_signature
    "$python_path" shell/hyprland_stand_in.py serve "$hypr_dir" >"$tmp/hypr.log" 2>&1 &
    hypr_pid=$!
    i=0
    until test -S "$hypr_dir/control.sock"; do
        if ! kill -0 "$hypr_pid" 2>/dev/null || waited "the stand-in Hyprland didn't start" "$i"; then
            echo "FAIL: the stand-in Hyprland didn't start:" >&2
            cat "$tmp/hypr.log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done

    env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
        ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} \
        LANG=C.UTF-8 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        HYPRLAND_INSTANCE_SIGNATURE="$hypr_signature" QS_DISABLE_FILE_WATCHER=1 \
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
    # signal) runs on the event loop afterward, and so does what Hyprland's
    # answers and events set off: settle waits for all of it. What waits on
    # the world outside (a process's output, a file read) can't be waited
    # for without a timer, and isn't covered.
    _listeners=0
    if grep -q 'Configuration Loaded' "$log"; then
        settle
        _listeners=$(hyprland play) || exit 1
        settle
    fi
    # It may have exited already, having failed.
    kill "$qs_pid" 2>/dev/null
    wait "$qs_pid"
    qs_pid=
    kill "$hypr_pid"
    wait "$hypr_pid"
    hypr_pid=
    rm -rf "$hypr_dir"

    if ! grep -q 'Configuration Loaded' "$log"; then
        echo "FAIL: Quickshell couldn't load $_what:" >&2
        cat "$log" >&2
        exit 1
    fi
    reports "$_what loaded"
    # Without these, the run says nothing about Hyprland's data.
    if ! grep -qx 'j/clients' "$tmp/answered"; then
        echo "FAIL: $_what never asked the stand-in Hyprland for its windows" >&2
        exit 1
    fi
    if test "$_listeners" -lt 1; then
        echo "FAIL: $_what never listened for the stand-in Hyprland's events" >&2
        exit 1
    fi
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

# keyboard: holds a keyboard on the seat, if nothing does yet. The headless
# seat has none, and the one wtype makes comes and goes with it: a window
# would get its keyboard after the first keys had gone. One held from the
# start keeps every key.
keyboard() {
    test -n "$keyboard_pid" && return
    env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        "$wtype_path" -s 3600000 >"$tmp/keyboard.log" 2>&1 &
    keyboard_pid=$!
}

# typed STATUS WHERE: fails the test unless wtype, which exited STATUS
# under timeout, finished typing into WHERE.
typed() {
    case $1 in
        0) ;;
        124)
            echo "FAIL: wtype didn't finish typing into $2 in $wait s" >&2
            exit 1
            ;;
        *)
            echo "FAIL: wtype couldn't type into $2: $(cat "$tmp/wtype.log")" >&2
            exit 1
            ;;
    esac
}

# focused N: waits until the log shows the shell's Nth keyboard focus,
# failing the test unless it comes in time. WAYLAND_DEBUG logs the protocol,
# so the log shows each time a surface takes the keyboard
# (wl_keyboard.enter); keys typed before it would go nowhere.
focused() {
    i=0
    until test "$(grep -c '} wl_keyboard#[0-9]*\.enter(' "$log")" -ge "$1"; do
        if ! kill -0 "$qs_pid" 2>/dev/null; then
            echo "FAIL: $_what exited before it took the keyboard:" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        if waited "$_what didn't take the keyboard" "$i"; then
            cat "$tmp/keyboard.log" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
}

# launch: starts the shell again, opens its launcher, types a query, and
# fails the test unless Enter runs the app the query names, through `tide
# launch`. The app is a desktop entry only this test installs, and the
# query leaves out its accent ("Café"), so the match also checks the
# accent folding runs in Qt's engine. A stand-in tide on the shell's PATH
# keeps the command rather than running it. Its log is
# $tmp/launch.qs.log.
launch() {
    _what="the launcher"
    log=$tmp/launch.qs.log
    : >"$log" || exit 1
    mkdir -p "$tmp/home/.local/share/applications" "$tmp/bin" || exit 1
    printf '[Desktop Entry]\nType=Application\nName=Café Probe\nExec=tide-test-probe --flag\n' \
        >"$tmp/home/.local/share/applications/tide-test-probe.desktop" || exit 1
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/launched"\n' "$tmp" >"$tmp/bin/tide" || exit 1
    chmod +x "$tmp/bin/tide" || exit 1
    keyboard
    env -i PATH="$tmp/bin:$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
        ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} \
        LANG=C.UTF-8 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        QS_DISABLE_FILE_WATCHER=1 WAYLAND_DEBUG=client \
        "$qs_path" -c tide >"$log" 2>&1 &
    qs_pid=$!
    i=0
    until grep -q 'Configuration Loaded' "$log"; do
        if ! kill -0 "$qs_pid" 2>/dev/null || waited "Quickshell didn't start" "$i"; then
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    # What loading queued, the desktop entries Quickshell scanned among it,
    # has been handed over once the shell has answered twice: it may answer
    # before the rest of the pass a request arrives in, but a second
    # request is only taken in a later pass.
    for _ in 1 2; do
        ipc show >/dev/null || exit 1
    done
    # The launcher's keyboard focus is the next one the log shows.
    _focus=$(($(grep -c '} wl_keyboard#[0-9]*\.enter(' "$log") + 1))
    ipc call launcher open >/dev/null || exit 1
    focused "$_focus"
    timeout "$wait" env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        LANG=C.UTF-8 "$wtype_path" "cafepro
" >"$tmp/wtype.log" 2>&1
    typed $? "the launcher"
    i=0
    until test -s "$tmp/launched"; do
        if waited "the launcher didn't run Café Probe" "$i"; then
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    kill "$qs_pid"
    wait "$qs_pid"
    qs_pid=
    _launched=$(cat "$tmp/launched")
    if test "$_launched" != "launch --app tide-test-probe -- tide-test-probe --flag"; then
        echo "FAIL: the launcher should run Café Probe as \`tide launch --app tide-test-probe -- tide-test-probe --flag\`; it ran \`tide $_launched\`" >&2
        exit 1
    fi
    reports "the launcher ran an app"
    echo "ok: the launcher finds an app by a query without its accent, and runs it"
}

# ipc ARG...: runs `qs ipc --pid` on the running shell, within the limit.
ipc() {
    if ! timeout "$wait" env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
        LANG=C.UTF-8 "$qs_path" ipc --pid "$qs_pid" "$@" 2>"$tmp/ipc.log"; then
        echo "FAIL: $_what didn't answer \`qs ipc $*\` within $wait s:" >&2
        cat "$tmp/ipc.log" >&2
        grep -v '^\[' "$log" >&2
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
    keyboard
    env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
        ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} \
        LANG=C.UTF-8 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        QS_DISABLE_FILE_WATCHER=1 WAYLAND_DEBUG=client \
        "$qs_path" -p "$tmp/home/.config/quickshell/tide/lock.qml" >"$log" 2>&1 &
    qs_pid=$!
    _what="the lock"
    focused 1
    # wtype reads its text in the locale's encoding, so a password beyond
    # ASCII needs a UTF-8 one.
    timeout "$wait" env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        LANG=C.UTF-8 "$wtype_path" "not-$TIDE_LOCK_PASSWORD
$TIDE_LOCK_PASSWORD
" >"$tmp/wtype.log" 2>&1
    typed $? "the lock"
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
if test -n "$wtype_path"; then
    launch
else
    echo "$prog: no wtype, so nothing is typed into the launcher; CI types into it" >&2
fi
if test -n "${TIDE_LOCK_PASSWORD:-}"; then
    unlock
else
    echo "$prog: no TIDE_LOCK_PASSWORD, so the lock isn't unlocked; CI unlocks it" >&2
fi
