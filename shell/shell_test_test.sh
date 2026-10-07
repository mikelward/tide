#!/bin/sh
#
# Tests for shell/shell_test.sh itself, with stand-ins for qs, sway,
# wtype, notify-send and go, so they run without Quickshell: what the load
# test does with a shell that loads cleanly, one whose files report an
# error, one whose event loop never answers, one that ignores Hyprland, one
# that skips a call to tide-tz, hyprctl, gsettings, nmcli or systemctl,
# or whose
# tide-tz never ends, one whose clocks, system monitor, title, focus guard
# calls, color scheme or VPNs warn, one whose icon won't load, a
# notification server that records what it's sent or doesn't, a launcher
# that runs the app typed or doesn't, a settings panel that opens the
# Network page's app or doesn't, a lock that can't read its
# keyboards, or unlocks or doesn't, and a greeter that logs in or doesn't.
# The stand-in Hyprland, hyprctl, tide-sysmon, gsettings, nmcli and greetd
# are the load test's own, and the stand-in gsettings and nmcli answer as
# GNOME's and NetworkManager's would.

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

# The calls the stub qs makes, as the shell and as the lock or the greeter.
all_runs="tide-tz tide-sysmon title replay order scheme scheme-monitor vpns vpn-monitor idle input devices keyboards"

# stubs DIR IPC LOAD [UNLOCK [LAUNCH [HYPRLAND [COMMANDS [TZ [LATE [LOGIN [IDLE [HANDED [LABEL]]]]]]]]]]:
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
# asking for windows). Loaded, qs also makes the calls COMMANDS names in
# the background, all of $all_runs by default, and reaps them as they end,
# as Quickshell does: as the shell (-c) tide-tz, tide-sysmon, the title's
# hyprctl, the focus guard's replay and order, gsettings for the color
# scheme and its monitor, nmcli for the VPNs and its monitor, and
# hypridle's timings written and systemctl restarting it, and hyprctl
# for the mice and touchpads, as the lock or the greeter (-p) hyprctl for
# the keyboards. With LATE, it runs tide-tz that
# many seconds late, as the shell does once it has read its clock files. Its
# notify-send prints an id and adds the summary to the history, as the
# shell's server would. Its go builds a tide-tz that runs TZ, by default
# one that ends at once. Its shell writes the default lock time for
# hypridle and no suspend on AC for idle-suspend, then a dim time of 120, a
# lock time of IDLE (600 by default), suspend on AC and the hand-edited
# suspend time once all three are set over IPC; and no mouse settings,
# then the hand-edited mouse speed, a touchpad without tap
# to click, the us,de keyboard layouts, one mouse's own speed and the
# mouse's left_handed as HANDED (false by default) once all four are set
# over IPC, applying each. With tide-tz, it answers the Clocks page's
# refused zone, and writes and looks up Asia/Kolkata labeled LABEL (IST by
# default) then the hand-edited UTC once the last clock is moved over IPC.
# DIR/load-CONFIG.txt, if it's there, is printed
# before LOAD by that config alone: shell (-c), lock or greeter.
stubs() {
    mkdir -p "$1" || exit 1
    # Kept in a file, so LOAD can be any text.
    printf '%s\n' "$3" >"$1/load.txt" || exit 1
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
        *"call settings open"*) : >"\$XDG_RUNTIME_DIR/settings-open" ;;
        *"call settings setSuspendOnAC true"*) : >"\$XDG_RUNTIME_DIR/idle-set" ;;
        *"call settings setDevice logitech-usb-receiver speed 0.25"*) : >"\$XDG_RUNTIME_DIR/input-set" ;;
        *"call settings moveClock UTC 1"*) : >"\$XDG_RUNTIME_DIR/clocks-set" ;;
        *"call settings addClock US/Pacific"*) echo "unknown time zone US/Pacific; use a zone ID from timedatectl list-timezones, such as America/Los_Angeles; not changing the clocks" ;;
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
        case " ${7-$all_runs} " in
            *" tide-tz "*)
                { ${9:+sleep $9;} tide-tz -- America/Los_Angeles; } >/dev/null 2>&1 &
                # The clocks changed over IPC, as the Clocks page changes
                # them; gone with qs, as the idle one is.
                {
                    until test -e "\$XDG_RUNTIME_DIR/clocks-set"; do
                        kill -0 \$\$ 2>/dev/null || exit 0
                        sleep 0.1
                    done
                    rm "\$XDG_RUNTIME_DIR/clocks-set"
                    printf '[\n  {\n    "zone": "Asia/Kolkata",\n    "label": "${13:-IST}"\n  },\n  {\n    "zone": "UTC",\n    "label": ""\n  }\n]\n' >"\$HOME/.config/tide/clocks.local.json"
                    tide-tz -- Asia/Kolkata UTC >/dev/null 2>&1
                } &
                ;;
        esac
        case " ${7-$all_runs} " in
            *" tide-sysmon "*) tide-sysmon probe >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" title "*) hyprctl activewindow -j >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" replay "*) hyprctl eval 'tide_focus.announce_waiting()' >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" order "*) hyprctl eval 'tide_focus.set_order({})' >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" scheme "*)
                gsettings set org.gnome.desktop.interface color-scheme prefer-dark >/dev/null 2>&1 &
                gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark >/dev/null 2>&1 &
                ;;
        esac
        case " ${7-$all_runs} " in
            *" scheme-monitor "*) gsettings monitor org.gnome.desktop.interface color-scheme >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" vpns "*) env LC_ALL=C nmcli -t -f NAME,UUID,TYPE,ACTIVE,STATE connection show >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" vpn-monitor "*) nmcli monitor >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" idle "*)
                {
                    mkdir -p "\$HOME/.config/hypr" "\$HOME/.config/tide" &&
                        printf '%s\n' '\$tide_idle_lock = 300' >"\$HOME/.config/hypr/tide-idle.conf" &&
                        printf '%s\n' '\$tide_idle_suspend_on_ac = 0' >"\$HOME/.config/hypr/tide-idle-suspend.conf" &&
                        systemctl --user try-restart hypridle.service >/dev/null 2>&1
                    # A time set over IPC, as the settings panel's Idle page
                    # sets one; gone with the qs that started it, since
                    # killing qs leaves this behind.
                    until test -e "\$XDG_RUNTIME_DIR/idle-set"; do
                        kill -0 \$\$ 2>/dev/null || exit 0
                        sleep 0.1
                    done
                    rm "\$XDG_RUNTIME_DIR/idle-set"
                    printf '{\n  "dim": 120,\n  "lock": ${11:-600},\n  "suspend": 900,\n  "suspendOnAC": true\n}\n' >"\$HOME/.config/tide/idle.local.json"
                    printf '%s\n' '\$tide_idle_suspend_on_ac = 1' >"\$HOME/.config/hypr/tide-idle-suspend.conf"
                    printf '%s\n' '\$tide_idle_dim = 120' '\$tide_idle_lock = ${11:-600}' '\$tide_idle_suspend = 900' >"\$HOME/.config/hypr/tide-idle.conf"
                    systemctl --user try-restart hypridle.service >/dev/null 2>&1
                } &
                ;;
        esac
        case " ${7-$all_runs} " in
            *" devices "*) hyprctl devices -j >/dev/null 2>&1 & ;;
        esac
        case " ${7-$all_runs} " in
            *" input "*)
                {
                    mkdir -p "\$HOME/.config/hypr" "\$HOME/.config/tide" &&
                        printf '%s\n' '    mouse = {},' >"\$HOME/.config/hypr/tide-input.lua" &&
                        hyprctl eval 'conf_input.reload()' >/dev/null 2>&1
                    # Settings made over IPC, as the Mouse, Touchpad and Keyboard pages
                    # make them; gone with qs, as the idle one is.
                    until test -e "\$XDG_RUNTIME_DIR/input-set"; do
                        kill -0 \$\$ 2>/dev/null || exit 0
                        sleep 0.1
                    done
                    rm "\$XDG_RUNTIME_DIR/input-set"
                    printf '{\n  "mouse": {\n    "speed": 0.5,\n    "leftHanded": ${12:-false}\n  },\n  "touchpad": {\n    "tapToClick": false\n  },\n  "keyboard": {\n    "layout": "us,de"\n  },\n  "devices": {\n    "logitech-usb-receiver": {\n      "speed": 0.25\n    }\n  }\n}\n' >"\$HOME/.config/tide/input.local.json"
                    printf '%s\n' '    mouse = { sensitivity = 0.5, left_handed = ${12:-false} },' '    touchpad = { tap_to_click = false },' '    keyboard = { kb_layout = "us,de" },' '    devices = {' '        ["logitech-usb-receiver"] = { sensitivity = 0.25 },' '    },' >"\$HOME/.config/hypr/tide-input.lua"
                    hyprctl eval 'conf_input.reload()' >/dev/null 2>&1
                } &
                ;;
        esac
    else
        case " ${7-$all_runs} " in
            *" keyboards "*) hyprctl devices -j >/dev/null 2>&1 & ;;
        esac
    fi
fi
case "\$1" in
    -c) config=shell ;;
    *) config=\$(basename "\$2" .qml) ;;
esac
if test -f "\$(dirname "\$0")/load-\$config.txt"; then
    cat "\$(dirname "\$0")/load-\$config.txt"
fi
cat "\$(dirname "\$0")/load.txt"
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
# Keys pressed by name (-k) are a line of their own.
if test "$1" = -k; then
    printf '%s\n' "$*" >>"$(dirname "$0")/typed"
    printf '%s\n' "$LANG" >>"$(dirname "$0")/typed-lang"
    printf '%s\n' "$*" >"$XDG_RUNTIME_DIR/typed"
    exit 0
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
# keyboard, then, once the query is typed, runs the app. Then the settings
# panel does the same once it's opened and its keys are typed, running the
# Network page's app.
opened='until test -e "$XDG_RUNTIME_DIR/launcher-open"; do sleep 0.1; done'
focused="echo '[1.0] {Default Queue} wl_keyboard#3.enter(1, wl_surface#2, array[0])'"
typed='until test -s "$XDG_RUNTIME_DIR/typed"; do sleep 0.1; done; rm "$XDG_RUNTIME_DIR/typed"'
ran="$opened; $focused; $typed; tide launch --app tide-test-probe -- tide-test-probe --flag"
settings_opened='until test -e "$XDG_RUNTIME_DIR/settings-open"; do sleep 0.1; done'
launcher="$ran; $settings_opened; $focused; $typed; tide launch -- nm-connection-editor"
# What a greeter does once the login step starts it: it takes the keyboard,
# then logs in on the passwords typed, as greeter_client.py's MODE says.
login_as() {
    printf '%s; python3 "$(dirname "$0")/greeter_client.py" %s; exit 0' "$focused" "$1"
}
greeter=$(login_as tide)

stubs "$tmp/clean" "exit 0" "  INFO: Configuration Loaded"
run "$tmp/clean"
check "a shell that loads and answers passes" test "$code" -eq 0
check "and says it wrote hypridle's timings" contains "$out" "ok: the shell writes hypridle's timings, and a new one, and restarts it each time"
check "and the mouse, touchpad and keyboard settings" contains "$out" "ok: the shell writes the mouse, touchpad and keyboard settings, and new ones, and applies them each time"
check "and the clocks" contains "$out" "ok: the shell changes the clocks as the Clocks page asks, and looks them up"
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
check "and a settings panel that opens the Network page's app passes" contains "$out" "ok: the settings panel changes page with the arrows and opens the page's app"
check "having pressed Down twice and Enter" test "$(sed -n 2p "$tmp/clean/typed")" = "-k Down -k Down -k Return"

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

stubs "$tmp/settings-nothing" "exit 0" "$loaded" ":" "$ran; $settings_opened; $focused; $typed"
run "$tmp/settings-nothing"
check "a settings panel that runs nothing fails" test "$code" -ne 0
check "and says so" contains "$out" "the settings panel didn't open the Network page's app in 2 s"

stubs "$tmp/settings-wrong" "exit 0" "$loaded" ":" "$ran; $settings_opened; $focused; $typed; tide launch -- other"
run "$tmp/settings-wrong"
check "a settings panel that runs the wrong app fails" test "$code" -ne 0
check "and says what it ran" contains "$out" "it ran \`tide launch -- other\`"

stubs "$tmp/settings-unfocused" "exit 0" "$loaded" ":" "$ran; $settings_opened"
run "$tmp/settings-unfocused"
check "a settings panel that never takes the keyboard fails" test "$code" -ne 0
check "and says so" contains "$out" "the settings panel didn't take the keyboard in 2 s"

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

stubs "$tmp/late" "exit 0" "$loaded" ":" "" full "$all_runs" ":" 0.5
run "$tmp/late"
check "a shell that runs tide-tz only after reading its files passes" test "$code" -eq 0
check "having waited for it" contains "$out" "ok: Quickshell loads the shell"

stubs "$tmp/no-clocks" "exit 0" "$loaded" ":" "" full "tide-sysmon title replay order scheme scheme-monitor vpns vpn-monitor idle input devices keyboards"
run "$tmp/no-clocks"
check "a shell that never runs tide-tz fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "tide-tz..." in 2 s'

# A tide-tz that lasts as long as the shell that started it: kill -0 fails
# once the shell is gone, which is when it ends.
stubs "$tmp/endless" "exit 0" "$loaded" ":" "" full "$all_runs" \
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

stubs "$tmp/no-title" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon replay order scheme scheme-monitor vpns vpn-monitor idle input devices keyboards"
run "$tmp/no-title"
check "a shell that never asks hyprctl for the focused window fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "hyprctl activewindow -j..." in 2 s'

stubs "$tmp/no-replay" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title order scheme scheme-monitor vpns vpn-monitor idle input devices keyboards"
run "$tmp/no-replay"
check "a shell that never has the focus guard replay its windows fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "hyprctl eval tide_focus.announce_waiting()..." in 2 s'

stubs "$tmp/no-order" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay scheme scheme-monitor vpns vpn-monitor idle input devices keyboards"
run "$tmp/no-order"
check "a shell that never tells the focus guard its marks fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "hyprctl eval tide_focus.set_order(..." in 2 s'

stubs "$tmp/no-keyboards" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme scheme-monitor vpns vpn-monitor idle input devices"
run "$tmp/no-keyboards"
check "a lock that never asks hyprctl for the keyboards fails" test "$code" -ne 0
check "and says so" contains "$out" 'the lock never ran "hyprctl devices -j..." in 2 s'

stubs "$tmp/no-scheme" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme-monitor vpns vpn-monitor idle input devices keyboards"
run "$tmp/no-scheme"
check "a shell that never tells apps the color scheme fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "gsettings set org.gnome.desktop.interface color-scheme..." in 2 s'

stubs "$tmp/no-scheme-monitor" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme vpns vpn-monitor idle input devices keyboards"
run "$tmp/no-scheme-monitor"
check "a shell that never follows the color scheme fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "gsettings monitor org.gnome.desktop.interface color-scheme..." in 2 s'

stubs "$tmp/no-vpns" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme scheme-monitor vpn-monitor idle input devices keyboards"
run "$tmp/no-vpns"
check "a shell that never lists the VPNs fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "nmcli -t -f NAME,UUID,TYPE,ACTIVE,STATE connection show..." in 2 s'

stubs "$tmp/no-vpn-monitor" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme scheme-monitor vpns idle input devices keyboards"
run "$tmp/no-vpn-monitor"
check "a shell that never follows the VPNs fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "nmcli monitor..." in 2 s'

stubs "$tmp/no-idle" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme scheme-monitor vpns vpn-monitor input devices keyboards"
run "$tmp/no-idle"
check "a shell that never restarts hypridle on its timings fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "systemctl --user try-restart hypridle.service..." in 2 s'

stubs "$tmp/idle-unset" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "" 300
run "$tmp/idle-unset"
check "a shell that loses the first of two quick changes fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell didn't write a lock time of 600, a dim time of 120 and suspend on AC, keeping the hand-edited suspend time of 900, to"

stubs "$tmp/no-input" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme scheme-monitor vpns vpn-monitor idle devices keyboards"
run "$tmp/no-input"
check "a shell that never applies the mouse, touchpad and keyboard settings fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "hyprctl eval conf_input.reload()..." in 2 s'

stubs "$tmp/no-devices" "exit 0" "$loaded" ":" "" full "tide-tz tide-sysmon title replay order scheme scheme-monitor vpns vpn-monitor idle input keyboards"
run "$tmp/no-devices"
check "a shell that never lists the mice and touchpads fails" test "$code" -ne 0
check "and says so" contains "$out" 'the shell never ran "hyprctl devices -j..." in 2 s'

stubs "$tmp/input-unset" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "" "" true
run "$tmp/input-unset"
check "a shell that loses the first of four quick device settings fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell didn't write a right-handed mouse, a touchpad without tap to click, the us,de keyboard layouts and one mouse's own speed, keeping the hand-edited mouse speed of 0.5, to"

stubs "$tmp/clocks-unset" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "" "" "" Kolkata
run "$tmp/clocks-unset"
check "a shell that loses a clock's label fails" test "$code" -ne 0
check "and says so" contains "$out" "the shell didn't write the clocks for Asia/Kolkata, labeled IST, then the hand-edited UTC to"

stubs "$tmp/input-warns" "exit 0" "  WARN qml: tide: couldn't apply the mouse, touchpad and keyboard settings: no conf_input
$loaded"
run "$tmp/input-warns"
check "a shell whose settings don't apply fails" test "$code" -ne 0
check "and says what it warned" contains "$out" "tide: couldn't apply the mouse, touchpad and keyboard settings"

stubs "$tmp/idle-warns" "exit 0" "  WARN qml: tide: systemctl --user try-restart hypridle.service exited 1: Failed to connect to bus
$loaded"
run "$tmp/idle-warns"
check "a shell whose hypridle restart warns fails" test "$code" -ne 0
check "and says what it warned" contains "$out" "tide: systemctl --user try-restart hypridle.service exited 1"

stubs "$tmp/scheme-warns" "exit 0" "  WARN qml: tide: gsettings set org.gnome.desktop.interface color-scheme prefer-dark exited 1: No schemas installed
$loaded"
run "$tmp/scheme-warns"
check "a shell that can't set the color scheme fails" test "$code" -ne 0
check "and says what it said" contains "$out" "tide: gsettings set org.gnome.desktop.interface color-scheme prefer-dark exited 1"

stubs "$tmp/vpns-warn" "exit 0" "  WARN qml: tide: nmcli: can't read connection line \"Home\"
$loaded"
run "$tmp/vpns-warn"
check "a shell that can't read the VPNs fails" test "$code" -ne 0
check "and says what it said" contains "$out" "tide: nmcli: can't read connection line"

# The stand-in gsettings and nmcli answer the shell's calls as GNOME's and
# NetworkManager's would, and refuse what they wouldn't.
# stand_in NAME ARG...: what NAME's stand-in says to ARG..., in out and code.
stand_in() {
    _name=$1
    shift
    out=$(sh "shell/${_name}_stand_in.sh" "$@" 2>&1)
    code=$?
}
stand_in gsettings set org.gnome.desktop.interface color-scheme prefer-dark
check "the stand-in gsettings takes a color scheme" test "$code:$out" = 0:
stand_in gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark
check "and a GTK theme" test "$code:$out" = 0:
stand_in gsettings set org.gnome.desktop.interface color-scheme prefer-darker
check "but not a color scheme GNOME doesn't have" test "$code" -eq 1
check "and says so" contains "$out" "outside of the valid range"
stand_in gsettings set org.gnome.desktop.interface cursor-theme Adwaita
check "or a key the shell doesn't set" test "$code" -eq 2
stand_in gsettings set org.gnome.desktop.interface color-scheme prefer-dark extra
check "or a set with more arguments than gsettings takes" test "$code" -eq 1
check "and says how it's used" contains "$out" "set SCHEMA[:PATH] KEY VALUE"
stand_in gsettings set org.gnome.desktop.interface gtk-theme
check "or fewer" test "$code" -eq 1
out=$(env LC_ALL=C sh shell/nmcli_stand_in.sh -t -f NAME,UUID,TYPE,ACTIVE,STATE connection show 2>&1)
code=$?
check "the stand-in nmcli lists the connections" contains "$code:$out" "0:Home:"
check "with a VPN that's up" contains "$out" "Office VPN:6c0d4c3e-1a2b-4c5d-8e9f-000000000002:vpn:yes:activated"
check "and one with an escaped colon" contains "$out" 'Lab\: WireGuard:'
out=$(env LC_ALL=en_US.UTF-8 sh shell/nmcli_stand_in.sh -t -f NAME,UUID,TYPE,ACTIVE,STATE connection show 2>&1)
code=$?
check "but only in the C locale" test "$code" -eq 2
stand_in nmcli connection up uuid 6c0d4c3e-1a2b-4c5d-8e9f-000000000003
check "and answers nothing else" test "$code" -eq 2
stand_in nmcli monitor extra
check "not even its own calls with more arguments" test "$code" -eq 2
out=$(env LC_ALL=C sh shell/nmcli_stand_in.sh "-t -f" NAME,UUID,TYPE,ACTIVE,STATE connection show 2>&1)
code=$?
check "or with two of them run together" test "$code" -eq 2

stubs "$tmp/title-warns" "exit 0" "  WARN qml: tide: bar title: hyprctl activewindow gave no window; the title waits for the next focus change
$loaded"
run "$tmp/title-warns"
check "a shell whose title can't read hyprctl fails" test "$code" -ne 0
check "and says what it said" contains "$out" "tide: bar title: hyprctl activewindow gave no window"

stubs "$tmp/guard-warns" "exit 0" "  WARN qml: tide: couldn't tell the focus guard which windows are marked: no guard
$loaded"
run "$tmp/guard-warns"
check "a shell whose focus guard calls fail fails" test "$code" -ne 0
check "and says what it said" contains "$out" "couldn't tell the focus guard"

# The stand-in hyprctl answers the focus guard's calls as Hyprland would:
# ok only for the two MarkData.qml makes, of functions focus.lua defines.
# ctl CODE [STAND_IN]: what it says to `hyprctl eval CODE`, in out and code.
ctl() {
    out=$(python3 "${2-shell/hyprland_stand_in.py}" ctl eval "$1" 2>&1)
    code=$?
}
ctl 'tide_focus.announce_waiting()'
check "the stand-in hyprctl replays the guard's waiting windows" test "$code:$out" = 0:ok
ctl 'tide_focus.set_order({})'
check "and takes no marks" test "$code:$out" = 0:ok
ctl 'tide_focus.set_order({"0x55aa04","0x55aa05"})'
check "and takes marks in order" test "$code:$out" = 0:ok
ctl 'tide_focus.set_ordr({})'
check "but not a misspelled call" test "$code" -ne 0
check "and says so" contains "$out" "doesn't evaluate 'tide_focus.set_ordr({})'"
ctl 'tide_focus.set_order({0x55aa04})'
check "or an address that isn't a string" test "$code" -ne 0
ctl 'tide_focus.set_order({"0x55aa04",,})'
check "or a list that isn't Lua" test "$code" -ne 0
mkdir -p "$tmp/renamed/shell" "$tmp/renamed/hypr/tide" || exit 1
cp shell/hyprland_stand_in.py "$tmp/renamed/shell/" || exit 1
sed 's/function M\.set_order(/function M.set_marks(/' hypr/tide/focus.lua >"$tmp/renamed/hypr/tide/focus.lua" || exit 1
ctl 'tide_focus.set_order({})' "$tmp/renamed/shell/hyprland_stand_in.py"
check "or a call focus.lua doesn't define" test "$code" -ne 0
check "and says so" contains "$out" "hypr/tide/focus.lua has no tide_focus.set_order"

stubs "$tmp/badge-warns" "exit 0" "$loaded"
echo "  WARN qml: tide-lock: hyprctl devices gave no keyboard; the layout badge stays hidden" >"$tmp/badge-warns/load-lock.txt" || exit 1
run "$tmp/badge-warns"
check "a lock that can't read its keyboards fails" test "$code" -ne 0
check "as the lock loads" contains "$out" "the lock loaded, but its commands warned"
check "and says what it said" contains "$out" "tide-lock: hyprctl devices gave no keyboard"

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
check "having typed a wrong password, then the right one" test "$(sed -n 3,4p "$tmp/unlocks/typed")" = "not-pw
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
    test "$(sed -n 3,5p "$tmp/clean/typed")" = "not-tide-greeter-test
tide-greeter-test
246810"

stubs "$tmp/greeter-alpha" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "$(login_as alpha)"
run "$tmp/greeter-alpha"
check "a greeter that starts another session fails" test "$code" -ne 0
check "and says what greetd saw" contains "$out" "start_session {\"cmd\": [\"alpha-session\"]"

stubs "$tmp/greeter-forgets" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "$(login_as forgetful)"
run "$tmp/greeter-forgets"
check "a greeter that doesn't remember the login fails" test "$code" -ne 0
check "and says so" contains "$out" "the greeter should remember probe and tide"

stubs "$tmp/greeter-codeless" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "$(login_as codeless)"
run "$tmp/greeter-codeless"
check "a greeter that doesn't answer the visible prompt fails" test "$code" -ne 0
check "and says what greetd saw" contains "$out" "start_session refused: session is not ready"

stubs "$tmp/greeter-stays" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "$(login_as stays)"
run "$tmp/greeter-stays"
check "a greeter that never logs in fails" test "$code" -ne 0
check "and says so" contains "$out" "the greeter didn't log in in 2 s"
check "within the limit ($took s)" test "$took" -lt 30

stubs "$tmp/greeter-unfocused" "exit 0" "$loaded" ":" "" full "$all_runs" "" "" "exec sleep 3600"
run "$tmp/greeter-unfocused"
check "a greeter that never takes the keyboard fails" test "$code" -ne 0
check "and says so" contains "$out" "the greeter didn't take the keyboard in 2 s"

printf 'shell_test_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
