#!/bin/sh
#
# Tests for shell/shell_test.sh itself, with stand-ins for qs, sway,
# wtype, notify-send and go, so they run without Quickshell: what the load
# test does with a shell that loads cleanly, one whose files report an
# error, one whose event loop never answers, one that ignores Hyprland, one
# that doesn't run tide-tz or whose tide-tz never ends, one whose clocks
# or system monitor warn, one whose icon won't load, a notification server
# that records what it's sent or doesn't, a launcher that runs the app typed
# or doesn't, a lock that unlocks or doesn't, and a greeter that logs in or
# doesn't. The stand-in Hyprland, tide-sysmon and greetd are the load test's
# own.

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

# stubs DIR IPC LOAD [UNLOCK [LAUNCH [HYPRLAND [COMMANDS [TZ [LATE [LOGIN]]]]]]]:
# a sway that listens on wayland-1 until it's killed; a qs whose `ipc`
# runs IPC, and otherwise talks to Hyprland as HYPRLAND says, then prints
# LOAD and waits, but started as the unlock step starts the lock
# (WAYLAND_DEBUG, -p .../lock.qml) runs UNLOCK first, as the login step
# starts the greeter (WAYLAND_DEBUG, -p .../greeter.qml) runs LOGIN first,
# which defaults to a greeter that logs in as it should, and as the launch
# step starts the
# shell (WAYLAND_DEBUG, -c) prints LOAD and then runs LAUNCH, which
# defaults to a launcher that runs the app typed; and a wtype that keeps
# what it types in DIR/typed, and in the runtime directory for qs to see.
# HYPRLAND is `full` (the default: listen for events, and ask for the
# status and the windows), `deaf` (no listening) or `windowless` (no
# asking for windows). Loaded as the shell (-c), qs also starts COMMANDS in
# the background, tide-tz and tide-sysmon by default, and reaps them as
# they end, as Quickshell does; with LATE, it starts tide-tz that many
# seconds late, as the shell does once it has read its clock files. Its
# notify-send prints an id and adds the summary to the
# history, as the shell's server would. Its go builds a tide-tz that runs
# TZ, by default one that ends at once.
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
    case "\$2" in
        *greeter.qml) ${10:-$greeter} ;;
        *) ${4:-:} ;;
    esac
fi
# Talked to before it says it loaded, as Quickshell does.
if test -n "\$HYPRLAND_INSTANCE_SIGNATURE"; then
    python3 "\$(dirname "\$0")/hyprland_client.py" ${6:-full} &
    until test -e "\$XDG_RUNTIME_DIR/hyprland_client.ready"; do sleep 0.1; done
    rm "\$XDG_RUNTIME_DIR/hyprland_client.ready" || exit 1
    if test "\$1" = -c; then
        case " ${7-tide-tz tide-sysmon} " in
            *" tide-tz "*) { ${9:+sleep $9;} tide-tz -- America/Los_Angeles; } >/dev/null 2>&1 & ;;
        esac
        case " ${7-tide-tz tide-sysmon} " in
            *" tide-sysmon "*) tide-sysmon probe >/dev/null 2>&1 & ;;
        esac
    fi
fi
printf '%s\n' '$3'
if test -n "\$WAYLAND_DEBUG" && test "\$1" = -c; then
    ${5:-$launcher}
fi
# Reaps what it started as each ends, until it's killed.
wait
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
    # A greeter on greetd's IPC: each password wtype types is an attempt,
    # whatever wtype types next answers greetd's next prompt, and a login
    # starts a session, as $1 says: `tide`, as it should; `alpha`, the
    # wrong one; `forgetful`, tide without remembering it; `stays`,
    # nothing; `codeless`, tide without answering the prompt after the
    # password.
    cat >"$1/greeter_client.py" <<'EOF'
import json, os, socket, struct, sys, time
mode = sys.argv[1]
header = struct.Struct("=I")
conn = socket.socket(socket.AF_UNIX)
conn.connect(os.environ["GREETD_SOCK"])
def read(n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            sys.exit("greetd hung up")
        data += chunk
    return data
def ask(request):
    data = json.dumps(request).encode()
    conn.sendall(header.pack(len(data)) + data)
    return json.loads(read(header.unpack(read(header.size))[0]))
typed = os.path.join(os.environ["XDG_RUNTIME_DIR"], "typed")
def take():
    while not os.path.exists(typed) or os.path.getsize(typed) == 0:
        time.sleep(0.1)
    with open(typed) as f:
        text = f.read().rstrip("\n")
    os.remove(typed)
    return text
while True:
    password = take()
    ask({"type": "create_session", "username": "probe"})
    reply = ask({"type": "post_auth_message_response", "response": password})
    while reply["type"] == "auth_message" and mode != "codeless":
        reply = ask({"type": "post_auth_message_response", "response": take()})
    if reply["type"] == "error":
        ask({"type": "cancel_session"})
        continue
    if mode == "stays":
        time.sleep(3600)
    session = "alpha" if mode == "alpha" else "tide"
    if mode != "forgetful":
        state = os.path.join(os.environ["HOME"], ".local/state/tide-greeter")
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "last.json"), "w") as f:
            f.write(json.dumps({"user": "probe", "session": session}, separators=(",", ":")) + "\n")
    env = ["XDG_SESSION_TYPE=wayland", "XDG_SESSION_DESKTOP=" + session]
    if session == "tide":
        env.append("XDG_CURRENT_DESKTOP=tide:Hyprland")
    cmd = "uwsm start -e -D tide:Hyprland -N tide -- tide-hyprland" if session == "tide" else "alpha-session"
    ask({"type": "start_session", "cmd": [cmd], "env": env})
    break
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
    cat >"$1/notify-send" <<'EOF'
#!/bin/sh
summary=
while test $# -gt 0; do
    case $1 in
        -p) ;;
        -a | -i | -u) shift ;;
        *) test -n "$summary" || summary=$1 ;;
    esac
    shift
done
mkdir -p "$HOME/.local/state/tide" || exit 1
printf '{"summary":"%s"}\n' "$summary" >>"$HOME/.local/state/tide/notifications.json"
echo 1
EOF
    cat >"$1/go" <<EOF
#!/bin/sh
# As the load test runs it: go build -buildvcs=false -o OUT ./cmd/tide-tz.
test "\$1 \$2 \$3 \$5" = "build -buildvcs=false -o ./cmd/tide-tz" || exit 2
printf '#!/bin/sh\n%s\n' '${8:-:}' >"\$4" && chmod +x "\$4"
EOF
    chmod +x "$1/sway" "$1/qs" "$1/wtype" "$1/notify-send" "$1/go" || exit 1
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
# What a greeter does once the login step starts it: it takes the keyboard,
# then logs in on the passwords typed, as greeter_client.py's MODE says.
login_as() {
    printf '%s; python3 "$(dirname "$0")/greeter_client.py" %s; exit 0' "$focused" "$1"
}
greeter=$(login_as tide)

stubs "$tmp/clean" "exit 0" "  INFO: Configuration Loaded"
run "$tmp/clean"
check "a shell that loads and answers passes" test "$code" -eq 0
check "and says the lock loaded" contains "$out" "ok: Quickshell loads the lock"
check "and says the greeter loaded" contains "$out" "ok: Quickshell loads the greeter"

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

run "$tmp/clean"
check "a server that records what it's sent passes" contains "$out" "ok: the notification server takes notifications and records them"

stubs "$tmp/forgets" "exit 0" "  INFO: Configuration Loaded"
printf '#!/bin/sh\necho 1\n' >"$tmp/forgets/notify-send"
run "$tmp/forgets"
check "a server that records nothing fails" test "$code" -ne 0
check "and says so" contains "$out" "the notification server didn't record \"Probe\" in its history"

stubs "$tmp/refuses" "exit 0" "  INFO: Configuration Loaded"
printf '#!/bin/sh\necho "no server" >&2\nexit 1\n' >"$tmp/refuses/notify-send"
run "$tmp/refuses"
check "a server that refuses a notification fails" test "$code" -ne 0
check "and says so" contains "$out" "the notification server didn't take \"Probe\": no server"

stubs "$tmp/placeholder" "exit 0" "  WARN: Could not load icon \"no-such\" at size QSize(16, 16) from request
  INFO: Configuration Loaded"
run "$tmp/placeholder"
check "a shell whose icon won't load fails" test "$code" -ne 0
check "and says so" contains "$out" "an icon wouldn't load"

stubs "$tmp/late" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon" ":" 0.5
run "$tmp/late"
check "a shell that runs tide-tz only after reading its files passes" test "$code" -eq 0
check "having waited for it" contains "$out" "ok: Quickshell loads the shell"

stubs "$tmp/no-clocks" "exit 0" "$loaded" ":" "" full "tide-sysmon"
run "$tmp/no-clocks"
check "a shell that never runs tide-tz fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell never ran tide-tz in 2 s"

# A tide-tz that lasts as long as the shell that started it: kill -0 fails
# once the shell is gone, which is when it ends.
stubs "$tmp/endless" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon" \
    'while kill -0 "$PPID" 2>/dev/null; do sleep 0.1; done'
run "$tmp/endless"
check "a tide-tz that never ends fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell wasn't done with tide-tz in 2 s"
check "within the limit ($took s)" test "$took" -lt 30

stubs "$tmp/warns" "exit 0" "  WARN qml: tide: tide-tz exited 1
$loaded"
run "$tmp/warns"
check "a shell whose clocks warn fails" test "$code" -ne 0
check "and says what they said" contains "$out" "tide: tide-tz exited 1"

stubs "$tmp/probe-fails" "exit 0" "  WARN qml: tide: tide-sysmon probe exited 2: no probe
$loaded"
run "$tmp/probe-fails"
check "a shell whose system monitor warns fails" test "$code" -ne 0
check "and says what it said" contains "$out" "tide: tide-sysmon probe exited 2"

run "$tmp/clean" GO=tide-test-no-such-go
check "without Go, a run that requires Quickshell fails" test "$code" -ne 0
check "and says so" contains "$out" "no tide-test-no-such-go (to build tide-tz, which the bar's clocks run) on PATH"

run "$tmp/clean" GO=tide-test-no-such-go TIDE_REQUIRE_QS=
check "without Go, any other run is skipped" test "$code" -eq 0
check "whole, as without Quickshell" contains "$out" "SKIP: shell/shell_test.sh: no tide-test-no-such-go"
check "and loads nothing" test "$(printf '%s\n' "$out" | grep -c '^ok:')" -eq 0

stubs "$tmp/deaf" "exit 0" "  INFO: Configuration Loaded" ":" "" deaf
run "$tmp/deaf"
check "a shell that never listens for Hyprland's events fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell never listened for the stand-in Hyprland's events"

stubs "$tmp/windowless" "exit 0" "  INFO: Configuration Loaded" ":" "" windowless
run "$tmp/windowless"
check "a shell that never asks Hyprland for its windows fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell never asked the stand-in Hyprland for its windows"

# What a lock started for unlocking says: that it took the keyboard, then,
# once the passwords are typed, PAM's verdicts. It takes what was typed, as
# the launcher does, so the greeter that follows never reads it.
typed='until test -s "$XDG_RUNTIME_DIR/typed"; do sleep 0.1; done; rm "$XDG_RUNTIME_DIR/typed"'

stubs "$tmp/unlocks" "exit 0" "$loaded" "$focused; $typed
echo 'Failed to authenticate.'; echo 'Authenticated successfully.'; exit 0"
run "$tmp/unlocks" TIDE_LOCK_PASSWORD=pw
check "a lock that unlocks on the right password passes" test "$code" -eq 0
check "and says so" contains "$out" "ok: the lock turns down a wrong password and unlocks on the right one"
check "having typed a wrong password, then the right one" test "$(sed -n 2,3p "$tmp/unlocks/typed")" = "not-pw
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

run "$tmp/clean"
check "a greeter that logs in to tide on the right password passes" \
    contains "$out" "ok: the greeter turns down a wrong password, and logs in to tide on the right one and a visible code"
check "having typed a wrong password, then the right one, then the code" \
    test "$(sed -n 2,4p "$tmp/clean/typed")" = "not-tide-greeter-test
tide-greeter-test
246810"

stubs "$tmp/greeter-alpha" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon" "" "" "$(login_as alpha)"
run "$tmp/greeter-alpha"
check "a greeter that starts another session fails" test "$code" -ne 0
check "and says what greetd saw" contains "$out" "start_session {\"cmd\": [\"alpha-session\"]"

stubs "$tmp/greeter-forgets" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon" "" "" "$(login_as forgetful)"
run "$tmp/greeter-forgets"
check "a greeter that doesn't remember the login fails" test "$code" -ne 0
check "and says so" contains "$out" "the greeter should remember probe and tide"

stubs "$tmp/greeter-codeless" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon" "" "" "$(login_as codeless)"
run "$tmp/greeter-codeless"
check "a greeter that doesn't answer the visible prompt fails" test "$code" -ne 0
check "and says what greetd saw" contains "$out" "start_session refused: session is not ready"

stubs "$tmp/greeter-stays" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon" "" "" "$(login_as stays)"
run "$tmp/greeter-stays"
check "a greeter that never logs in fails" test "$code" -ne 0
check "and says so" contains "$out" "the greeter didn't log in in 2 s"
check "within the limit ($took s)" test "$took" -lt 30

stubs "$tmp/greeter-unfocused" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon" "" "" "exec sleep 3600"
run "$tmp/greeter-unfocused"
check "a greeter that never takes the keyboard fails" test "$code" -ne 0
check "and says so" contains "$out" "the greeter didn't take the keyboard in 2 s"

printf 'shell_test_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
