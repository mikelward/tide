#!/bin/sh
#
# Loads the shell, the lock and the greeter in Quickshell, as tide.service,
# tide-lock.service and tide-greeter start them (`qs -c tide`, `qs -p
# .../lock.qml`, `qs -p .../greeter.qml`, over what `make install` puts in
# place), and fails on anything that keeps any of them from loading, or that the shell's own files report as it starts: a
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
# queue. The shell's own commands are on its PATH: tide-tz built for the
# run, so the clocks are drawn from tzdata; a stand-in tide-sysmon whose
# probe finds no sensors, so the system monitor parses one but reads no
# sensor files; a stand-in hyprctl, answering from the stand-in
# Hyprland's fixtures, for the bar's title, the lock's layout badge and
# the focus guard's calls, conf's conf_input.reload() and
# conf_appearance.reload() and the Keys page's bindings; stand-in
# gsettings and nmcli, for light and dark and the VPNs, whose monitors
# report nothing; and a stand-in systemctl, for restarting hypridle once
# the shell has written its timings, which it checks are the defaults, as
# it checks the mouse, touchpad and keyboard settings it writes are none. Data from a timer, a file
# read, a monitor, or any other command isn't covered.
#
# With notify-send, it also runs the shell as the notification server
# (TIDE_NOTIFICATIONS=1, SPEC.md §9), sends it notifications, and expects
# them in its history. That run makes the shell the polkit agent too
# (TIDE_POLKIT=1), so the agent is made, though with no polkitd or logind
# session here it can't register, and no request comes to prompt for. In every run, an icon that can't load fails the
# test: Quickshell draws a placeholder for it, which nothing else reports.
# Every icon the shell asks for is Adwaita's (§15), so that needs Adwaita
# installed.
#
# With wtype, it also types into them. It opens the launcher, types the
# name of an app only it installs, and expects Enter to run that app. Given
# the password of the user running it, it also unlocks the lock: it types a
# wrong password and then the right one, and expects PAM to turn down the
# first and the lock to unlock and exit on the second. That needs
# tide-lock's PAM service in /etc/pam.d (`make install-session`).
#
# With wtype, it also logs in at the greeter, on a stand-in greetd
# (shell/greetd_stand_in.py) that takes a password of the test's own: it
# types a wrong one, then the right one, and expects the greeter to log in
# to tide, with the environment pam_systemd reads, remember that for next
# time, and exit.
#
#   $QS                  the Quickshell command (default: qs)
#   $GO                  the Go command, to build tide-tz (default: go)
#   $TIDE_REQUIRE_QS     set (CI sets it) to fail, not skip, without qs,
#                        sway, python3, Go, wtype or notify-send
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

# Theme.qml takes its sizes from the mocks (SPEC.md §15), so the bar is
# as tall as the mocks show it.
theme_bar=$(sed -n 's/^ *readonly property int barHeight: \([0-9]*\)$/\1/p' shell/Theme.qml)
mock_bar=$(sed -n 's/^ *--bar-h: \([0-9]*\)px;$/\1/p' docs/mocks/common.css)
if test -z "$theme_bar" || test "$theme_bar" != "$mock_bar"; then
    echo "FAIL: Theme.qml's barHeight (${theme_bar:-none}) isn't docs/mocks/common.css's --bar-h (${mock_bar:-none})" >&2
    exit 1
fi

# The shell and the lock name their icon theme, since Qt picks none for
# tide's desktop. Quickshell reads the pragma only above the first import.
# Its loss also fails the load below, as icons that won't load, but this
# says why, and runs without qs.
for entry in shell/shell.qml shell/lock.qml shell/greeter.qml; do
    if ! sed '/^import /q' "$entry" | grep -q '^//@ pragma IconTheme Adwaita$'; then
        echo "FAIL: $entry doesn't name the Adwaita icon theme above its imports (SPEC.md §15)" >&2
        exit 1
    fi
done

# Quickshell's polkit module is optional (-DSERVICE_POLKIT=OFF), and an
# import of a missing module fails every file that has it. So it's
# imported only by polkit-agent.qml, which PolkitData loads only with
# TIDE_POLKIT=1; its lowercase name keeps it from being a type that
# anything compiles. A build without polkit isn't here to load, so this
# is checked as text, with no Quickshell needed.
if polkit_imports=$(grep -l '^import Quickshell\.Services\.Polkit' shell/*.qml) &&
    test "$polkit_imports" != shell/polkit-agent.qml; then
    echo "FAIL: only shell/polkit-agent.qml may import Quickshell.Services.Polkit, so the shell loads without it:" >&2
    printf '%s\n' "$polkit_imports" >&2
    exit 1
fi
if ! grep -q '^ *source: root\.enabled ? "polkit-agent\.qml" : ""$' shell/PolkitData.qml; then
    echo "FAIL: PolkitData.qml must load polkit-agent.qml only when TIDE_POLKIT=1, so the shell loads without Quickshell's polkit module" >&2
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
python_path=$(command -v python3) || missing "python3 (for the stand-in Hyprland)"
go_path=$(command -v "${GO:-go}") || missing "${GO:-go} (to build tide-tz, which the bar's clocks run)"
# Without wtype, nothing is typed, so the launcher, the lock's password and
# the greeter go untested.
if ! wtype_path=$(command -v wtype); then
    if test -n "${TIDE_REQUIRE_QS:-}" || test -n "${TIDE_LOCK_PASSWORD:-}"; then
        echo "FAIL: $prog: no wtype on PATH to type into the launcher, the lock and the greeter" >&2
        exit 1
    fi
    wtype_path=
fi
if ! notify_path=$(command -v notify-send); then
    if test -n "${TIDE_REQUIRE_QS:-}"; then
        echo "FAIL: $prog: no notify-send on PATH to send the shell notifications" >&2
        exit 1
    fi
    notify_path=
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
greetd_pid=
sway_pid=
bus_pid=
cleanup() {
    _status=$?
    for pid in $qs_pid $hypr_pid $greetd_pid $keyboard_pid $sway_pid; do
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

# The shell's own commands, first on its PATH. Each is a wrapper that adds
# its run to $tmp/helpers.log and then runs the real one, from
# $tmp/helpers/real, so a run's command line names $tmp/helpers throughout
# (children looks for that).
mkdir -p "$tmp/helpers/real" || exit 1
# The real tide-sysmon reads this machine's /proc and /sys, and the sensor
# files its probe names are read in the background, which nothing here can
# wait on. This one's probe is fixed, and names none.
cat >"$tmp/helpers/real/tide-sysmon" <<'EOF' || exit 1
#!/bin/sh
case $1 in
    probe) printf 'page\t4096\n' ;;
    *)
        echo "tide-sysmon: the load test's stand-in has only probe, not $1" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$tmp/helpers/real/tide-sysmon" || exit 1
# hyprctl answers from the stand-in Hyprland's fixtures, at once: the
# shell runs it as a command, which settle waits for, and a request on the
# stand-in's socket would wait for a drain. Python runs as its child, not
# in its place, so its command line still names $tmp/helpers until it ends.
cat >"$tmp/helpers/real/hyprctl" <<EOF || exit 1
#!/bin/sh
"$python_path" "$PWD/shell/hyprland_stand_in.py" ctl "\$@"
EOF
chmod +x "$tmp/helpers/real/hyprctl" || exit 1
# gsettings and nmcli, for light and dark and the VPNs (their stand-ins
# say what they answer), copied so their monitors can exec a tail that
# ends with the shell.
for _helper in gsettings nmcli systemctl; do
    cp "shell/${_helper}_stand_in.sh" "$tmp/helpers/real/$_helper" || exit 1
    chmod +x "$tmp/helpers/real/$_helper" || exit 1
done
# With the Go that's installed, as the Makefile builds. Without git's
# status, which git refuses for a checkout another user owns (CI's, in its
# container): a binary for this run needs no stamp.
if ! GOTOOLCHAIN=local "$go_path" build -buildvcs=false -o "$tmp/helpers/real/tide-tz" ./cmd/tide-tz >"$tmp/go.log" 2>&1; then
    echo "FAIL: couldn't build tide-tz: $(cat "$tmp/go.log")" >&2
    exit 1
fi
helpers="tide-sysmon tide-tz hyprctl gsettings nmcli systemctl"
: >"$tmp/helpers.log" || exit 1
for _helper in $helpers; do
    cat >"$tmp/helpers/$_helper" <<EOF || exit 1
#!/bin/sh
printf '%s\n' "$_helper \$*" >>"$tmp/helpers.log"
exec "$tmp/helpers/real/$_helper" "\$@"
EOF
    chmod +x "$tmp/helpers/$_helper" || exit 1
done

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

# children: names, one per line, what the shell has started and not yet
# taken in: one of its commands from $tmp/helpers still running, or any
# child that has exited and isn't yet reaped. Quickshell reaps a child
# when it handles its exit, so once there are none, a barrier means their
# output and their exits have been handled too.
children() {
    for _stat in /proc/[0-9]*/stat; do
        # A process that ended since the glob has no stat to read.
        read -r _line 2>/dev/null <"$_stat" || continue
        # After the command name, which is in parentheses and may hold
        # anything: the state, then the parent's PID.
        _fields=${_line##*) }
        _state=${_fields%% *}
        _fields=${_fields#* }
        test "${_fields%% *}" = "$qs_pid" || continue
        if test "$_state" = Z; then
            echo "a command that has exited"
            continue
        fi
        _pid=${_stat#/proc/}
        # Empty, so not one of the helpers, if it ended since its stat was
        # read.
        _command=$(tr '\0' ' ' 2>/dev/null <"/proc/${_pid%/stat}/cmdline")
        case $_command in
            *"$tmp/helpers/"*)
                _command=${_command#*"$tmp/helpers/"}
                _command=${_command#real/}
                echo "${_command%% *}"
                ;;
        esac
    done
}

# helpers: waits until children names nothing, failing the test unless
# that comes in time.
helpers() {
    i=0
    while _running=$(children) && test -n "$_running"; do
        if waited "$_what wasn't done with $(printf '%s\n' "$_running" | head -n 1)" "$i"; then
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
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

# runs: how many times the shell has run one of its commands.
runs() {
    wc -l <"$tmp/helpers.log"
}

# settle: answers the shell's Hyprland requests, and lets it take in the
# answers and its commands' output, until it has nothing more to ask or
# run. Each pass waits for the commands the shell has started to end,
# then takes a barrier, then drains the stand-in, which answers only
# then. The barrier comes after those commands' exits, as after the
# answers of the pass before, so it returns only once the shell has
# handled them, and sent any request or started any command that set off.
# A pass that drains no request and in which no command started ends it.
# A command started since the pass began has added its run to the log, or
# is still running its wrapper: Qt (6.10) starts a process with vfork
# semantics, so it has exec'd before the shell goes on. Each answered
# request is added to $tmp/answered.
settle() {
    _until=$(($(date +%s) + wait))
    while :; do
        _runs=$(runs) || exit 1
        helpers
        barrier
        _answered=$(hyprland drain) || exit 1
        if test -z "$_answered" && test "$(runs)" = "$_runs" && test -z "$(children)"; then
            return
        fi
        test -z "$_answered" || printf '%s\n' "$_answered" >>"$tmp/answered"
        if test "$(date +%s)" -ge "$_until"; then
            echo "FAIL: $_what was still asking Hyprland, or running commands, after $wait s" >&2
            exit 1
        fi
    done
}

# started FROM CALLS: waits until the shell has made each call in CALLS,
# a line each, since its run log had FROM lines, failing the test unless
# that comes in time. A call is the start of a run's line: the command,
# and as many of its arguments as tell it from the shell's other runs of
# that command. The shell may make one only once it has read files in the
# background (the clocks' tide-tz waits on their settings), which nothing
# else here can wait on.
started() {
    _from=$1
    while IFS= read -r _call; do
        i=0
        until tail -n "+$((_from + 1))" "$tmp/helpers.log" |
            awk -v call="$_call" 'index($0, call) == 1 { found = 1 } END { exit !found }'; do
            if ! kill -0 "$qs_pid" 2>/dev/null; then
                echo "FAIL: $_what exited before it ran \"$_call...\":" >&2
                grep -v '^\[' "$log" >&2
                exit 1
            fi
            if waited "$_what never ran \"$_call...\"" "$i"; then
                grep -v '^\[' "$log" >&2
                exit 1
            fi
            sleep 0.1
            i=$((i + 1))
        done
    done <<EOF
$2
EOF
}

# load NAME WHAT ARG...: starts `qs ARG...` on the headless sway, with a
# fresh stand-in Hyprland and the shell's commands, and fails the test
# unless it loads WHAT, asks Hyprland for its windows, takes in its events
# and its commands' output, and through all of that has nothing reported
# by the shell's own files, nor anything the clocks warn of. Local time is
# New York's, one of the default clocks, so it's hidden as local. With
# $load_env, it starts qs with those settings too; with $load_runs, it
# waits for the shell to make each of those calls (started) before it
# settles;
# and with $after_load, it runs that function once all of that has
# settled. Its log is $tmp/NAME.qs.log. Nothing edits the files during
# the test, so the file watcher is off, as tide-lock.service has it.
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

    _load_from=$(runs) || exit 1
    # shellcheck disable=SC2086 # $load_env is none, or one or more settings
    env -i PATH="$tmp/helpers:$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" \
        ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} \
        LANG=C.UTF-8 TZ=America/New_York QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        HYPRLAND_INSTANCE_SIGNATURE="$hypr_signature" QS_DISABLE_FILE_WATCHER=1 \
        ${load_env:-} "$qs_path" "$@" >"$log" 2>&1 &
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
    # answers and events and the shell's commands set off: settle waits for
    # all of it. What waits on anything else outside (another command, a
    # file read) can't be waited for without a timer, and isn't covered.
    _listeners=0
    if grep -q 'Configuration Loaded' "$log"; then
        if test -n "${load_runs:-}"; then
            started "$_load_from" "$load_runs"
        fi
        settle
        _listeners=$(hyprland play) || exit 1
        settle
        if test -n "${after_load:-}"; then
            "$after_load"
        fi
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
    # The commands' inputs are fixed (the default zones, $TZ, the system's
    # tzdata; the stand-ins' answers), so anything the shell's commands
    # warn of is a failure.
    if grep -E "tide: (tide-tz|tide-sysmon|clocks|bar title|gsettings|nmcli|no nmcli|systemctl|hyprctl binds)|tide: couldn't (start (tide-|hyprctl|gsettings|systemctl)|run (nmcli|hyprctl)|replay|tell|apply)|tide-(lock|greeter): (hyprctl|couldn't start hyprctl)" "$log" >"$tmp/reports"; then
        echo "FAIL: $_what loaded, but its commands warned:" >&2
        cat "$tmp/reports" >&2
        exit 1
    fi
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
    # Quickshell's word for an icon it drew as a placeholder.
    if grep 'Could not load icon' "$log" >"$tmp/reports"; then
        echo "FAIL: $1, but an icon wouldn't load; is the Adwaita icon theme installed?" >&2
        cat "$tmp/reports" >&2
        exit 1
    fi
}

# lock_clocks: waits for the lock to name the bad clocks.local.json the
# test gave it, as it reads it after loading. load runs it, as
# $after_load.
lock_clocks() {
    i=0
    until grep -qF 'tide-lock: clocks.local.json: hour24 must be true or false; the clock keeps its last settings' "$log"; do
        if waited "the lock didn't name the bad hour24 in $clocks_local" "$i"; then
            cat "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
}

# notify: sends the shell, the notification server in this run, a
# notification whose icon no theme has and a critical one, then lets it
# take them in. load runs it, as $after_load.
notify() {
    for _args in "-i tide-test-no-such-icon|Probe|An icon no theme has" \
        "-u critical|Probe critical|A critical one, which stays up"; do
        IFS='|' read -r _opts _summary _body <<EOF
$_args
EOF
        # The id it prints says the server took it.
        # shellcheck disable=SC2086 # $_opts is two words on purpose
        if ! _id=$(timeout "$wait" env -i PATH="$PATH" HOME="$tmp/home" \
            ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} LANG=C.UTF-8 \
            "$notify_path" -p -a Probe $_opts "$_summary" "$_body" 2>"$tmp/notify.err") || test -z "$_id"; then
            echo "FAIL: the notification server didn't take \"$_summary\": $(cat "$tmp/notify.err")" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
    done
    settle
}

# written_settings: fails the test unless the shell started by writing
# hypridle's default timings and no suspend on AC (SPEC.md §10), and no
# mouse or touchpad settings for conf's hyprland.lua (§16); then, for each,
# given a hand edit to its .local.json and straight after it settings over
# IPC as the settings panel's pages give them, wrote them all to its
# .local.json and to the file read, and restarted hypridle or reapplied the
# devices again. Then the same for the Clocks page: a zone added, labeled
# and moved, and one refused, written to clocks.local.json and looked up
# by the bar, then 24-hour time turned off there. Then the Layouts page: none written at startup, then two
# settings over a hand edit, written to layouts.local.json and the file
# layout.lua reads, and applied again. Then the Appearance page: two
# settings set over a hand edit, and sunrise and sunset refused without a
# longitude. Then the Displays page: no monitor settings written at
# startup, then a scale and a place for the stand-in's monitor over a hand
# edit, written to outputs.local.json and the file conf reads, and applied
# again; then the hand-edited monitor reset.
# The clicks come before the shell need have heard of the hand edit, and
# the second before the first could be written in the background. load
# runs it, as $after_load.
written_settings() {
    if ! grep -qxF '$tide_idle_lock = 300' "$idle_conf" 2>/dev/null ||
        ! grep -qxF '$tide_idle_suspend_on_ac = 0' "$idle_suspend_conf" 2>/dev/null; then
        echo "FAIL: the shell should write hypridle's default timings to $idle_conf, and no suspend on AC to $idle_suspend_conf; they have: $(cat "$idle_conf" "$idle_suspend_conf" 2>&1)" >&2
        exit 1
    fi
    _restarts=$(grep -c '^systemctl --user try-restart hypridle.service$' "$tmp/helpers.log")
    mkdir -p "${idle_local%/*}" || exit 1
    printf '{\n  "suspend": 900\n}\n' >"$idle_local" || exit 1
    ipc call settings setIdle lock 600 >/dev/null || exit 1
    ipc call settings setIdle dim 120 >/dev/null || exit 1
    ipc call settings setSuspendOnAC true >/dev/null || exit 1
    # Both files are written, and either can be last: wait for both.
    _want='{
  "dim": 120,
  "lock": 600,
  "suspend": 900,
  "suspendOnAC": true
}'
    i=0
    until grep -qxF '$tide_idle_lock = 600' "$idle_conf" 2>/dev/null &&
        grep -qxF '$tide_idle_dim = 120' "$idle_conf" &&
        grep -qxF '$tide_idle_suspend = 900' "$idle_conf" &&
        grep -qxF '$tide_idle_suspend_on_ac = 1' "$idle_suspend_conf" &&
        test "$(grep -c '^systemctl --user try-restart hypridle.service$' "$tmp/helpers.log")" -gt "$_restarts" &&
        test "$(cat "$idle_local")" = "$_want"; do
        if waited "the shell didn't write a lock time of 600, a dim time of 120 and suspend on AC, keeping the hand-edited suspend time of 900, to $idle_conf, $idle_suspend_conf and $idle_local, and restart hypridle" "$i"; then
            cat "$idle_conf" "$idle_suspend_conf" "$idle_local" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if ! grep -qxF '    mouse = {},' "$input_conf" 2>/dev/null; then
        echo "FAIL: the shell should write no mouse settings to $input_conf; it has: $(cat "$input_conf" 2>&1)" >&2
        exit 1
    fi
    _applies=$(grep -c '^hyprctl eval conf_input.reload()$' "$tmp/helpers.log")
    printf '{\n  "mouse": {\n    "speed": 0.5\n  }\n}\n' >"$input_local" || exit 1
    ipc call settings setInput mouse leftHanded false >/dev/null || exit 1
    ipc call settings setInput touchpad tapToClick false >/dev/null || exit 1
    # A name, which IPC passes as typed, not as a number.
    ipc call settings setInput keyboard layout us,de >/dev/null || exit 1
    # And one mouse's own speed, over every mouse's.
    ipc call settings setDevice logitech-usb-receiver speed 0.25 >/dev/null || exit 1
    # As idle's: wait for both files.
    _want='{
  "mouse": {
    "speed": 0.5,
    "leftHanded": false
  },
  "touchpad": {
    "tapToClick": false
  },
  "keyboard": {
    "layout": "us,de"
  },
  "devices": {
    "logitech-usb-receiver": {
      "speed": 0.25
    }
  }
}'
    i=0
    until grep -qxF '    mouse = { sensitivity = 0.5, left_handed = false },' "$input_conf" 2>/dev/null &&
        grep -qxF '    touchpad = { tap_to_click = false },' "$input_conf" &&
        grep -qxF '    keyboard = { kb_layout = "us,de" },' "$input_conf" &&
        grep -qxF '        ["logitech-usb-receiver"] = { sensitivity = 0.25 },' "$input_conf" &&
        test "$(grep -c '^hyprctl eval conf_input.reload()$' "$tmp/helpers.log")" -gt "$_applies" &&
        test "$(cat "$input_local")" = "$_want"; do
        if waited "the shell didn't write a right-handed mouse, a touchpad without tap to click, the us,de keyboard layouts and one mouse's own speed, keeping the hand-edited mouse speed of 0.5, to $input_conf and $input_local, and apply them" "$i"; then
            cat "$input_conf" "$input_local" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    printf '[\n  {\n    "zone": "UTC",\n    "label": ""\n  }\n]\n' >"$clocks_local" || exit 1
    ipc call settings addClock Asia/Kolkata >/dev/null || exit 1
    ipc call settings setClockLabel Asia/Kolkata IST >/dev/null || exit 1
    ipc call settings moveClock UTC 1 >/dev/null || exit 1
    # A link name, which the bar wouldn't take either, refused and said so.
    _refused=$(ipc call settings addClock US/Pacific) || exit 1
    case $_refused in
        *"unknown time zone US/Pacific"*) ;;
        *)
            echo "FAIL: the shell should refuse the clock US/Pacific, saying it's an unknown time zone; it answered: $_refused" >&2
            exit 1
            ;;
    esac
    _want='[
  {
    "zone": "Asia/Kolkata",
    "label": "IST"
  },
  {
    "zone": "UTC",
    "label": ""
  }
]'
    i=0
    until test "$(cat "$clocks_local")" = "$_want" &&
        grep -qxF 'tide-tz -- Asia/Kolkata UTC' "$tmp/helpers.log"; do
        if waited "the shell didn't write the clocks for Asia/Kolkata, labeled IST, then the hand-edited UTC to $clocks_local, and look them up" "$i"; then
            cat "$clocks_local" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    ipc call settings setClockSwitch hour24 false >/dev/null || exit 1
    _want='{
  "clocks": [
    {
      "zone": "Asia/Kolkata",
      "label": "IST"
    },
    {
      "zone": "UTC",
      "label": ""
    }
  ],
  "hour24": false
}'
    i=0
    until test "$(cat "$clocks_local")" = "$_want"; do
        if waited "the shell didn't turn 24-hour time off in $clocks_local, keeping its clocks" "$i"; then
            cat "$clocks_local" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if ! grep -qxF 'return {' "$layouts_conf" 2>/dev/null || grep -q '=' "$layouts_conf"; then
        echo "FAIL: the shell should write no layout settings to $layouts_conf; it has: $(cat "$layouts_conf" 2>&1)" >&2
        exit 1
    fi
    _reloads=$(grep -c '^hyprctl eval tide_layout.reload()$' "$tmp/helpers.log")
    printf '{\n  "modes": {\n    "tile": {\n      "nmaster": 2\n    }\n  }\n}\n' >"$layouts_local" || exit 1
    ipc call settings setLayout modes.tile.mfact 0.6 >/dev/null || exit 1
    ipc call settings setLayout defaultMode.ultrawide twocol >/dev/null || exit 1
    ipc call settings setLayout newWindow top >/dev/null || exit 1
    _want='{
  "modes": {
    "tile": {
      "nmaster": 2,
      "mfact": 0.6
    }
  },
  "defaultMode": {
    "ultrawide": "twocol"
  },
  "newWindow": "top"
}'
    i=0
    until grep -qxF '    modes = { tile = { mfact = 0.6, nmaster = 2 } },' "$layouts_conf" 2>/dev/null &&
        grep -qxF '    default_mode = { ultrawide = "twocol" },' "$layouts_conf" &&
        grep -qxF '    new_window = "top",' "$layouts_conf" &&
        test "$(grep -c '^hyprctl eval tide_layout.reload()$' "$tmp/helpers.log")" -gt "$_reloads" &&
        test "$(cat "$layouts_local")" = "$_want"; do
        if waited "the shell didn't write tile's mfact of 0.6, twocol for ultrawides and new windows at the top of the stack, keeping the hand-edited two masters, to $layouts_conf and $layouts_local, and apply them" "$i"; then
            cat "$layouts_conf" "$layouts_local" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if ! grep -qxF 'return {' "$appearance_conf" 2>/dev/null || grep -q '=' "$appearance_conf"; then
        echo "FAIL: the shell should write no dim strength to $appearance_conf; it has: $(cat "$appearance_conf" 2>&1)" >&2
        exit 1
    fi
    _dims=$(grep -c '^hyprctl eval conf_appearance.reload()$' "$tmp/helpers.log")
    printf '{\n  "dark": "20:00"\n}\n' >"$appearance_local" || exit 1
    ipc call settings setAppearance light 06:30 >/dev/null || exit 1
    ipc call settings setAppearance latitude 51.5 >/dev/null || exit 1
    ipc call settings setAppearance dimStrength 0.12 >/dev/null || exit 1
    _refused=$(ipc call settings setAppearance mode sun) || exit 1
    case $_refused in
        *'mode "sun" needs latitude and longitude'*) ;;
        *)
            echo "FAIL: the shell should refuse sunrise and sunset without a longitude, saying so; it answered: $_refused" >&2
            exit 1
            ;;
    esac
    _want='{
  "light": "06:30",
  "dark": "20:00",
  "latitude": 51.5,
  "dimStrength": 0.12
}'
    i=0
    until test "$(cat "$appearance_local")" = "$_want" &&
        grep -qxF '    dim_strength = 0.12,' "$appearance_conf" &&
        test "$(grep -c '^hyprctl eval conf_appearance.reload()$' "$tmp/helpers.log")" -gt "$_dims"; do
        if waited "the shell didn't write light from 06:30, a latitude of 51.5 and a dim strength of 0.12, keeping the hand-edited dark from 20:00, to $appearance_local and $appearance_conf, and apply the dim" "$i"; then
            cat "$appearance_local" "$appearance_conf" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if ! grep -qxF 'return {' "$outputs_conf" 2>/dev/null || grep -q '=' "$outputs_conf"; then
        echo "FAIL: the shell should write no monitor settings to $outputs_conf; it has: $(cat "$outputs_conf" 2>&1)" >&2
        exit 1
    fi
    _outputs=$(grep -c '^hyprctl eval conf_outputs.reload()$' "$tmp/helpers.log")
    printf '{\n  "monitors": {\n    "Spare": {\n      "scale": 2\n    }\n  }\n}\n' >"$outputs_local" || exit 1
    ipc call settings setDisplay Headless scale 1.5 >/dev/null || exit 1
    ipc call settings setDisplay Headless position auto-left >/dev/null || exit 1
    _want='{
  "monitors": {
    "Spare": {
      "scale": 2
    },
    "Headless": {
      "scale": 1.5,
      "position": "auto-left"
    }
  }
}'
    i=0
    until grep -qxF '    ["desc:Headless"] = { scale = 1.5, position = "auto-left" },' "$outputs_conf" 2>/dev/null &&
        grep -qxF '    ["desc:Spare"] = { scale = 2 },' "$outputs_conf" &&
        test "$(grep -c '^hyprctl eval conf_outputs.reload()$' "$tmp/helpers.log")" -gt "$_outputs" &&
        test "$(cat "$outputs_local")" = "$_want"; do
        if waited "the shell didn't write a scale of 1.5 to the left for the Headless monitor, keeping the hand-edited Spare one, to $outputs_conf and $outputs_local, and apply them" "$i"; then
            cat "$outputs_conf" "$outputs_local" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    _outputs=$(grep -c '^hyprctl eval conf_outputs.reload()$' "$tmp/helpers.log")
    _listed=$(grep -c '^hyprctl monitors all -j$' "$tmp/helpers.log")
    ipc call settings resetDisplay Spare >/dev/null || exit 1
    _want='{
  "monitors": {
    "Headless": {
      "scale": 1.5,
      "position": "auto-left"
    }
  }
}'
    i=0
    until test "$(cat "$outputs_local" 2>/dev/null)" = "$_want" &&
        ! grep -qF '"desc:Spare"' "$outputs_conf" &&
        test "$(grep -c '^hyprctl eval conf_outputs.reload()$' "$tmp/helpers.log")" -gt "$_outputs" &&
        test "$(grep -c '^hyprctl monitors all -j$' "$tmp/helpers.log")" -gt "$_listed"; do
        if waited "the shell didn't reset the Spare monitor in $outputs_local and $outputs_conf, apply it, and list the monitors again" "$i"; then
            cat "$outputs_conf" "$outputs_local" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    settle
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
# accent folding runs in Qt's engine. Then it opens the settings panel and
# expects Down twice, past Idle and Sound, and Enter to open the Network
# page's app. A stand-in tide on
# the shell's PATH keeps each command rather than running it. Its log is
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
    _launched=$(cat "$tmp/launched")
    if test "$_launched" != "launch --app tide-test-probe -- tide-test-probe --flag"; then
        echo "FAIL: the launcher should run Café Probe as \`tide launch --app tide-test-probe -- tide-test-probe --flag\`; it ran \`tide $_launched\`" >&2
        exit 1
    fi
    _what="the settings panel"
    _focus=$(($(grep -c '} wl_keyboard#[0-9]*\.enter(' "$log") + 1))
    ipc call settings open >/dev/null || exit 1
    focused "$_focus"
    timeout "$wait" env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        LANG=C.UTF-8 "$wtype_path" -k Down -k Down -k Return >"$tmp/wtype.log" 2>&1
    typed $? "the settings panel"
    i=0
    until test "$(wc -l <"$tmp/launched")" -ge 2; do
        if waited "the settings panel didn't open the Network page's app" "$i"; then
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    kill "$qs_pid"
    wait "$qs_pid"
    qs_pid=
    _launched=$(sed -n 2p "$tmp/launched")
    if test "$_launched" != "launch -- nm-connection-editor"; then
        echo "FAIL: the settings panel's Network page should run \`tide launch -- nm-connection-editor\`; it ran \`tide $_launched\`" >&2
        exit 1
    fi
    reports "the launcher ran an app and the settings panel opened one"
    echo "ok: the launcher finds an app by a query without its accent, and runs it"
    echo "ok: the settings panel changes page with the arrows and opens the page's app"
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

# login: starts the greeter on a stand-in greetd, as tide-greeter does
# (`qs -p .../greeter.qml`), with a getent that lists root and one person,
# and two session files, tide's own and one whose name sorts first. It types
# a wrong password and then, once greetd has turned it down and Quickshell
# has taken in the answer, the right one: an Enter while greetd checks isn't
# held at the greeter (shell/lib/greeter.mjs), so the two can't go in one
# go as at the lock. greetd then asks for a code as a visible prompt, and
# once Quickshell has that, the code goes in. It fails the test unless
# greetd sees exactly those two attempts and the code, then a request to
# start tide, with the environment pam_systemd reads, and the greeter
# remembers that login and exits. Its log is $tmp/login.qs.log.
login() {
    _what="the greeter"
    log=$tmp/login.qs.log
    : >"$log" || exit 1
    _bin=$tmp/greeter-bin
    _data=$tmp/greeter-data
    mkdir -p "$_bin" "$_data/wayland-sessions" || exit 1
    printf '#!/bin/sh\nprintf "%%s\\n" "root:x:0:0:root:/root:/bin/sh" "probe:x:1000:1000:Probe User,,,:/home/probe:/bin/sh"\n' \
        >"$_bin/getent" || exit 1
    # tide.desktop's TryExec.
    printf '#!/bin/sh\n' >"$_bin/uwsm" || exit 1
    chmod +x "$_bin/getent" "$_bin/uwsm" || exit 1
    cp session/tide.desktop "$_data/wayland-sessions/" || exit 1
    printf '[Desktop Entry]\nName=Alpha\nExec=alpha-session\n' >"$_data/wayland-sessions/alpha.desktop" || exit 1
    _password=tide-greeter-test
    _code=246810
    _socket=$tmp/run/greetd.sock
    : >"$tmp/greetd.log" || exit 1
    "$python_path" shell/greetd_stand_in.py "$_socket" "$tmp/greetd.log" probe "$_password" "$_code" >"$tmp/greetd.err" 2>&1 &
    greetd_pid=$!
    i=0
    until test -S "$_socket"; do
        if ! kill -0 "$greetd_pid" 2>/dev/null || waited "the stand-in greetd didn't start" "$i"; then
            cat "$tmp/greetd.err" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    keyboard
    env -i PATH="$_bin:$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" XDG_DATA_DIRS="$_data" \
        GREETD_SOCK="$_socket" ${bus_address:+DBUS_SESSION_BUS_ADDRESS="$bus_address"} \
        LANG=C.UTF-8 QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-1 \
        QS_DISABLE_FILE_WATCHER=1 WAYLAND_DEBUG=client \
        "$qs_path" -p "$tmp/home/.config/quickshell/tide/greeter.qml" >"$log" 2>&1 &
    qs_pid=$!
    focused 1
    timeout "$wait" env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        LANG=C.UTF-8 "$wtype_path" "not-$_password
" >"$tmp/wtype.log" 2>&1
    typed $? "the greeter"
    # Quickshell cancels greetd's session after a failure; once greetd has
    # answered that, a barrier makes sure Quickshell has taken the answer in.
    i=0
    until grep -qx cancel_session "$tmp/greetd.log"; do
        if ! kill -0 "$qs_pid" 2>/dev/null || waited "the greeter didn't try the wrong password" "$i"; then
            cat "$tmp/greetd.log" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    barrier
    timeout "$wait" env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        LANG=C.UTF-8 "$wtype_path" "$_password
" >"$tmp/wtype.log" 2>&1
    typed $? "the greeter"
    # The right password brings greetd's visible prompt for the code; the
    # code goes in once Quickshell has taken that prompt in.
    i=0
    until grep -qx "answer right" "$tmp/greetd.log"; do
        if ! kill -0 "$qs_pid" 2>/dev/null || waited "the greeter didn't try the right password" "$i"; then
            cat "$tmp/greetd.log" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    barrier
    timeout "$wait" env -i PATH="$PATH" XDG_RUNTIME_DIR="$tmp/run" WAYLAND_DISPLAY=wayland-1 \
        LANG=C.UTF-8 "$wtype_path" "$_code
" >"$tmp/wtype.log" 2>&1
    typed $? "the greeter"
    i=0
    while kill -0 "$qs_pid" 2>/dev/null; do
        if waited "the greeter didn't log in" "$i"; then
            cat "$tmp/greetd.log" >&2
            grep -v '^\[' "$log" >&2
            exit 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    wait "$qs_pid"
    _status=$?
    qs_pid=
    kill "$greetd_pid"
    wait "$greetd_pid"
    greetd_pid=
    if test "$_status" -ne 0; then
        echo "FAIL: the greeter exited $_status on logging in:" >&2
        grep -v '^\[' "$log" >&2
        exit 1
    fi
    _want='create_session probe
answer wrong
cancel_session
create_session probe
answer right
answer code right
start_session {"cmd": ["uwsm start -e -D tide:Hyprland -N tide -- tide-hyprland"], "env": ["XDG_SESSION_TYPE=wayland", "XDG_SESSION_DESKTOP=tide", "XDG_CURRENT_DESKTOP=tide:Hyprland"]}'
    if test "$(cat "$tmp/greetd.log")" != "$_want"; then
        echo "FAIL: greetd should see a wrong password, then the right one and the code, then tide started; it saw:" >&2
        cat "$tmp/greetd.log" >&2
        exit 1
    fi
    _remembered=$tmp/home/.local/state/tide-greeter/last.json
    if test "$(cat "$_remembered" 2>/dev/null)" != '{"user":"probe","session":"tide"}'; then
        echo "FAIL: the greeter should remember probe and tide in $_remembered; it has: $(cat "$_remembered" 2>&1)" >&2
        exit 1
    fi
    reports "the greeter logged in"
    echo "ok: the greeter turns down a wrong password, and logs in to tide on the right one and a visible code"
}

# The shell makes all these calls; without them, the run says nothing
# about the clocks, the system monitor, the title, the focus guard (its
# replay of the waiting windows, and its order for Super+Tab), light and
# dark, the VPNs, hypridle's timings, the mouse, touchpad and keyboard
# settings, the list of mice and touchpads, the key bindings, the layout
# settings, the monitors and their settings, or the dim strength.
# The lock and the greeter only ask for the keyboards, for their layout
# badges.
shell_runs='tide-tz
tide-sysmon probe
hyprctl activewindow -j
hyprctl eval tide_focus.announce_waiting()
hyprctl eval tide_focus.set_order(
gsettings monitor org.gnome.desktop.interface color-scheme
gsettings set org.gnome.desktop.interface color-scheme
gsettings set org.gnome.desktop.interface gtk-theme
nmcli monitor
nmcli -t -f NAME,UUID,TYPE,ACTIVE,STATE connection show
systemctl --user try-restart hypridle.service
hyprctl eval conf_input.reload()
hyprctl devices -j
hyprctl binds -j
hyprctl eval tide_layout.reload()
hyprctl monitors all -j
hyprctl eval conf_outputs.reload()
hyprctl eval conf_appearance.reload()'
load_runs=$shell_runs
idle_conf=$tmp/home/.config/hypr/tide-idle.conf
idle_suspend_conf=$tmp/home/.config/hypr/tide-idle-suspend.conf
idle_local=$tmp/home/.config/tide/idle.local.json
input_conf=$tmp/home/.config/hypr/tide-input.lua
input_local=$tmp/home/.config/tide/input.local.json
clocks_local=$tmp/home/.config/tide/clocks.local.json
layouts_conf=$tmp/home/.config/hypr/tide-layouts.lua
layouts_local=$tmp/home/.config/tide/layouts.local.json
appearance_local=$tmp/home/.config/tide/appearance.local.json
appearance_conf=$tmp/home/.config/hypr/tide-appearance.lua
outputs_conf=$tmp/home/.config/hypr/tide-outputs.lua
outputs_local=$tmp/home/.config/tide/outputs.local.json
after_load=written_settings
load shell "the shell" -c tide
after_load=
# Gone again, so the next shell starts from the defaults, writes them, and
# restarts hypridle and reapplies the devices, too.
rm "$idle_conf" "$idle_suspend_conf" "$idle_local" "$input_conf" "$input_local" "$clocks_local" "$layouts_conf" "$layouts_local" "$appearance_local" "$appearance_conf" "$outputs_conf" "$outputs_local" || exit 1
echo "ok: the shell writes hypridle's timings, and a new one, and restarts it each time"
echo "ok: the shell writes the mouse, touchpad and keyboard settings, and new ones, and applies them each time"
echo "ok: the shell changes the clocks as the Clocks page asks, and looks them up"
echo "ok: the shell writes the layout settings, and new ones, and applies them"
echo "ok: the shell sets the Appearance page's settings, applies the dim, and refuses one that wouldn't work"
echo "ok: the shell writes the display settings, and new ones, and applies them"
load_runs='hyprctl devices -j'
# A clocks.local.json the lock refuses, which it should name.
printf '{\n  "hour24": "no"\n}\n' >"$clocks_local" || exit 1
after_load=lock_clocks
load lock "the lock" -p "$tmp/home/.config/quickshell/tide/lock.qml"
after_load=
# Gone again, or the shell after the greeter would report it too.
rm "$clocks_local" || exit 1
echo "ok: the lock names a clocks.local.json it can't take, and keeps its clock's settings"
load greeter "the greeter" -p "$tmp/home/.config/quickshell/tide/greeter.qml"
load_runs=
if test -n "$notify_path"; then
    load_env="TIDE_NOTIFICATIONS=1 TIDE_POLKIT=1"
    load_runs=$shell_runs
    after_load=notify
    load notifications "the notification server and polkit agent" -c tide
    load_env=
    load_runs=
    after_load=
    # The history keeps both; a summary is plain text, so it's in the JSON
    # as it was sent.
    for _summary in '"Probe"' '"Probe critical"'; do
        if ! grep -q "\"summary\":$_summary" "$tmp/home/.local/state/tide/notifications.json" 2>"$tmp/history.err"; then
            echo "FAIL: the notification server didn't record $_summary in its history: $(cat "$tmp/history.err")" >&2
            exit 1
        fi
    done
    echo "ok: the notification server takes notifications and records them"
else
    echo "$prog: no notify-send, so the shell isn't sent notifications; CI sends them" >&2
fi
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
if test -n "$wtype_path"; then
    login
else
    echo "$prog: no wtype, so nothing logs in at the greeter; CI logs in" >&2
fi
