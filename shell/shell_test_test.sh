#!/bin/sh
#
# Tests for shell/shell_test.sh itself, with stand-ins for qs, sway and
# wtype, so they run without Quickshell: what the load test does with a
# shell that loads cleanly, one whose files report an error, one whose event
# loop never answers, one that ignores Hyprland, a launcher that runs the
# app typed or doesn't, and a lock that unlocks or doesn't. The stand-in
# Hyprland is the real one.

cd "$(dirname "$0")/.." || exit 1

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

# The stand-in sway has to make a real Wayland socket for the test to find.
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: shell/shell_test_test.sh: no python3 for the stand-in sway"
    exit 0
fi

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# stubs DIR IPC LOAD [UNLOCK [LAUNCH [HYPRLAND]]]: a sway that listens on
# wayland-1 until it's killed; a qs whose `ipc` runs IPC, and otherwise
# talks to Hyprland as HYPRLAND says, then prints LOAD and waits, but
# started as the unlock step starts the lock (WAYLAND_DEBUG, -p) runs
# UNLOCK first, and as the launch step starts the shell (WAYLAND_DEBUG, -c)
# prints LOAD and then runs LAUNCH, which defaults to a launcher that runs
# the app typed; and a wtype that keeps what it types in DIR/typed, and in
# the runtime directory for qs to see. HYPRLAND is `full` (the default:
# listen for events, and ask for the status and the windows), `deaf` (no
# listening) or `windowless` (no asking for windows).
stubs() {
    mkdir -p "$1" || exit 1
    cat >"$1/sway" <<'EOF'
#!/bin/sh
exec python3 -c 'import os, socket, time
s = socket.socket(socket.AF_UNIX)
s.bind(os.environ["XDG_RUNTIME_DIR"] + "/wayland-1")
time.sleep(3600)'
EOF
    cat >"$1/qs" <<EOF
#!/bin/sh
if test "\$1" = ipc; then
    case "\$*" in
        *"call launcher open"*) : >"\$XDG_RUNTIME_DIR/launcher-open" ;;
    esac
    $2
fi
if test -n "\$WAYLAND_DEBUG" && test "\$1" = -p; then
    ${4:-:}
fi
# Talked to before it says it loaded, as Quickshell does.
if test -n "\$HYPRLAND_INSTANCE_SIGNATURE"; then
    python3 "\$(dirname "\$0")/hyprland_client.py" ${6:-full} &
    until test -e "\$XDG_RUNTIME_DIR/hyprland_client.ready"; do sleep 0.1; done
    rm "\$XDG_RUNTIME_DIR/hyprland_client.ready" || exit 1
fi
printf '%s\n' '$3'
if test -n "\$WAYLAND_DEBUG" && test "\$1" = -c; then
    ${5:-$launcher}
fi
exec sleep 3600
EOF
    cat >"$1/hyprland_client.py" <<'EOF'
import os, socket, sys, time
directory = os.path.join(os.environ["XDG_RUNTIME_DIR"], "hypr", os.environ["HYPRLAND_INSTANCE_SIGNATURE"])
held = []
if sys.argv[1] != "deaf":
    held.append(socket.socket(socket.AF_UNIX))
    held[-1].connect(directory + "/.socket2.sock")
for request in ["j/status"] if sys.argv[1] == "windowless" else ["j/status", "j/clients"]:
    held.append(socket.socket(socket.AF_UNIX))
    held[-1].connect(directory + "/.socket.sock")
    held[-1].sendall(request.encode())
open(os.environ["XDG_RUNTIME_DIR"] + "/hyprland_client.ready", "w").close()
# Gone with the qs that started it.
parent = os.getppid()
while os.getppid() == parent:
    time.sleep(0.2)
EOF
    cat >"$1/wtype" <<'EOF'
#!/bin/sh
if test "$1" = -s; then
    exec sleep 3600
fi
printf '%s' "$1" >>"$(dirname "$0")/typed"
printf '%s\n' "$LANG" >>"$(dirname "$0")/typed-lang"
printf '%s' "$1" >"$XDG_RUNTIME_DIR/typed"
EOF
    chmod +x "$1/sway" "$1/qs" "$1/wtype" || exit 1
}

# run DIR [VAR=VALUE...]: the load test with DIR's stand-ins, a 2 s limit,
# Quickshell required, so a missing stand-in fails instead of skipping, and
# any settings given. Sets $out, $code and $took (seconds).
run() {
    _dir=$1
    shift
    _start=$(date +%s)
    out=$(env PATH="$_dir:$PATH" TIDE_REQUIRE_QS=1 TIDE_LOAD_WAIT=2 "$@" sh shell/shell_test.sh 2>&1)
    code=$?
    took=$(($(date +%s) - _start))
}

# What a launcher says and does once the launch step opens it: it takes the
# keyboard, then, once the query is typed, runs the app.
opened='until test -e "$XDG_RUNTIME_DIR/launcher-open"; do sleep 0.1; done'
focused="echo '[1.0] {Default Queue} wl_keyboard#3.enter(1, wl_surface#2, array[0])'"
typed='until test -s "$XDG_RUNTIME_DIR/typed"; do sleep 0.1; done; rm "$XDG_RUNTIME_DIR/typed"'
launcher="$opened; $focused; $typed; tide launch --app tide-test-probe -- tide-test-probe --flag"

stubs "$tmp/clean" "exit 0" "  INFO: Configuration Loaded"
run "$tmp/clean"
check "a shell that loads and answers passes" test "$code" -eq 0
check "and says both loaded" contains "$out" "ok: Quickshell loads the lock"

run "$tmp/clean" TIDE_KEEP_LOG="$tmp/kept.log"
check "a log asked for is kept" test "$code" -eq 0
check "with Quickshell's lines in it" grep -q 'Configuration Loaded' "$tmp/kept.log"

run "$tmp/clean" TIDE_KEEP_LOG="$tmp/no-such-dir/kept.log"
check "a log that can't be kept fails a run that passed" test "$code" -ne 0
check "and says so" contains "$out" "couldn't keep the logs in $tmp/no-such-dir/kept.log"

stubs "$tmp/reports" "exit 0" "  WARN scene: @Bar.qml[31:-1]: ReferenceError: x is not defined
  INFO: Configuration Loaded"
run "$tmp/reports"
check "a shell whose file reports an error fails" test "$code" -ne 0
check "and names the report" contains "$out" "@Bar.qml[31:-1]: ReferenceError"

stubs "$tmp/stuck" "exec sleep 3600" "  INFO: Configuration Loaded"
run "$tmp/stuck"
check "a shell that loads but never answers IPC fails" test "$code" -ne 0
check "and says so" contains "$out" "didn't answer IPC within 2 s"
check "within the limit, not hanging ($took s)" test "$took" -lt 30

stubs "$tmp/broken" "exit 0" " ERROR: Failed to load configuration"
run "$tmp/broken"
check "a shell that fails to load fails" test "$code" -ne 0
check "and shows Quickshell's log" contains "$out" "Failed to load configuration"

loaded="  INFO: Configuration Loaded"

run "$tmp/clean"
check "a launcher that runs the app typed passes" contains "$out" "ok: the launcher finds an app by a query without its accent, and runs it"
check "having typed the query and Enter" test "$(head -n 1 "$tmp/clean/typed")" = cafepro

stubs "$tmp/runs-nothing" "exit 0" "$loaded" ":" "$opened; $focused; $typed"
run "$tmp/runs-nothing"
check "a launcher that runs nothing fails" test "$code" -ne 0
check "and says so" contains "$out" "the launcher didn't run Café Probe in 2 s"
check "within the limit ($took s)" test "$took" -lt 30

stubs "$tmp/runs-wrong" "exit 0" "$loaded" ":" "$opened; $focused; $typed; tide launch -- other"
run "$tmp/runs-wrong"
check "a launcher that runs the wrong app fails" test "$code" -ne 0
check "and says what it ran" contains "$out" "it ran \`tide launch -- other\`"

stubs "$tmp/launcher-unfocused" "exit 0" "$loaded" ":" "$opened"
run "$tmp/launcher-unfocused"
check "a launcher that never takes the keyboard fails" test "$code" -ne 0
check "and says so" contains "$out" "the launcher didn't take the keyboard in 2 s"

stubs "$tmp/deaf" "exit 0" "  INFO: Configuration Loaded" ":" "" deaf
run "$tmp/deaf"
check "a shell that never listens for Hyprland's events fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell never listened for the stand-in Hyprland's events"

stubs "$tmp/windowless" "exit 0" "  INFO: Configuration Loaded" ":" "" windowless
run "$tmp/windowless"
check "a shell that never asks Hyprland for its windows fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell never asked the stand-in Hyprland for its windows"

# What a lock started for unlocking says: that it took the keyboard, then,
# once the passwords are typed, PAM's verdicts.
typed='until test -s "$XDG_RUNTIME_DIR/typed"; do sleep 0.1; done'

stubs "$tmp/unlocks" "exit 0" "$loaded" "$focused; $typed
echo 'Failed to authenticate.'; echo 'Authenticated successfully.'; exit 0"
run "$tmp/unlocks" TIDE_LOCK_PASSWORD=pw
check "a lock that unlocks on the right password passes" test "$code" -eq 0
check "and says so" contains "$out" "ok: the lock turns down a wrong password and unlocks on the right one"
check "having typed a wrong password, then the right one" test "$(sed 1d "$tmp/unlocks/typed")" = "not-pw
pw"
check "in a UTF-8 locale, for a password beyond ASCII" test "$(sort -u "$tmp/unlocks/typed-lang")" = C.UTF-8

run "$tmp/clean"
check "without a password, the lock isn't unlocked" contains "$out" "no TIDE_LOCK_PASSWORD, so the lock isn't unlocked"

stubs "$tmp/unfocused" "exit 0" "$loaded" "exec sleep 3600"
run "$tmp/unfocused" TIDE_LOCK_PASSWORD=pw
check "a lock that never takes the keyboard fails" test "$code" -ne 0
check "and says so" contains "$out" "the lock didn't take the keyboard in 2 s"
check "within the limit ($took s)" test "$took" -lt 30

stubs "$tmp/dies" "exit 0" "$loaded" "exit 1"
run "$tmp/dies" TIDE_LOCK_PASSWORD=pw
check "a lock that exits before it takes the keyboard fails" test "$code" -ne 0
check "and says so" contains "$out" "the lock exited before it took the keyboard"

stubs "$tmp/stays" "exit 0" "$loaded" "$focused; exec sleep 3600"
run "$tmp/stays" TIDE_LOCK_PASSWORD=pw
check "a lock that never unlocks fails" test "$code" -ne 0
check "and says so" contains "$out" "the lock didn't unlock in 2 s"
check "within the limit ($took s)" test "$took" -lt 30

stubs "$tmp/stuck-typing" "exit 0" "$loaded" "$focused; exec sleep 3600"
cat >"$tmp/stuck-typing/wtype" <<'EOF'
#!/bin/sh
exec sleep 3600
EOF
run "$tmp/stuck-typing" TIDE_LOCK_PASSWORD=pw
check "a wtype that never finishes typing fails" test "$code" -ne 0
check "and says so" contains "$out" "wtype didn't finish typing into the launcher in 2 s"
check "within the limit ($took s)" test "$took" -lt 30

stubs "$tmp/lets-in" "exit 0" "$loaded" "$focused; $typed
echo 'Authenticated successfully.'; exit 0"
run "$tmp/lets-in" TIDE_LOCK_PASSWORD=pw
check "a lock that takes the wrong password fails" test "$code" -ne 0
check "and says so" contains "$out" "PAM should turn down the wrong password"

stubs "$tmp/crashes" "exit 0" "$loaded" "$focused; $typed
echo 'Failed to authenticate.'; echo 'Authenticated successfully.'; exit 3"
run "$tmp/crashes" TIDE_LOCK_PASSWORD=pw
check "a lock that exits with an error on unlocking fails" test "$code" -ne 0
check "and says so" contains "$out" "the lock exited 3 on unlocking"

stubs "$tmp/unlock-reports" "exit 0" "$loaded" "$focused; $typed
echo '  WARN scene: @lock.qml[40:-1]: TypeError: x is undefined'
echo 'Failed to authenticate.'; echo 'Authenticated successfully.'; exit 0"
run "$tmp/unlock-reports" TIDE_LOCK_PASSWORD=pw
check "a lock whose file reports an error while unlocking fails" test "$code" -ne 0
check "and names the report" contains "$out" "@lock.qml[40:-1]: TypeError"

printf 'shell_test_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
