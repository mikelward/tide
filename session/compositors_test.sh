#!/bin/sh
#
# Starts tide's tidewm and tidesway sessions as a login does, on wlroots'
# headless backend, and checks that tide's config loads whole and its keys
# run. The config is laid out as a user has it: ~/.config/tidewm/config a
# symlink into a dotfiles checkout, including the tide.conf `make install`
# puts beside the link, and the files tide's shell writes
# (session/shell_files.mjs). uwsm, logger, systemd-cat, systemctl and qs
# are stand-ins; the binding events say which of the shell's commands a
# key ran. It does
# so with a config that includes tide.conf and the shell's files itself,
# as configs from before the session layered them did, and with one that
# only says what it changes, as the session reads tide's first and the
# shell's after it (tidewm/session.conf). Then it starts each again without
# tide.conf, and checks a terminal still opens (SPEC.md §16: quit, the
# terminal and the launcher always keep a key).
#
# Usage: session/compositors_test.sh [tidewm] [tidesway]
# Each named compositor must be on PATH, with tide-msg (make
# build/tide-msg), wtype, python3 and node.

cd "$(dirname "$0")/.." || exit 1
repo=$(pwd)

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

# within SECONDS COMMAND...: COMMAND, given SECONDS to finish
within() { _s=$1; shift; timeout "$_s" "$@"; }

for tool in tide-msg wtype python3 node timeout setsid; do
    command -v "$tool" >/dev/null 2>&1 || { echo "compositors_test.sh: no $tool on PATH" >&2; exit 1; }
done

compositors=${*:-tidewm tidesway}

session() {
    wm=$1
    kind=${2:-}
    broken=
    test "$kind" != broken || broken=yes
    tmp=$(mktemp -d) || exit 1
    home=$tmp/home
    stub=$tmp/stub
    mkdir -p "$home/.config/tidewm" "$home/checkout" "$stub" "$tmp/run"
    chmod 700 "$tmp/run"

    # As `make install` and a dotfiles checkout lay it out; broken, without
    # tide.conf, as a config that lost the file with most of its keys
    cp tidewm/session.conf "$home/.config/tidewm/"
    test -n "$broken" || cp tidewm/tide.conf "$home/.config/tidewm/"
    if ! node --import ./shell/lib/qtjs_env_test.mjs session/shell_files.mjs "$home/.config/tidewm"; then
        fail "$wm${kind:+ ($kind)}: the shell's files can't be written"
        rm -rf "$tmp"
        return
    fi
    # Your own: the terminal and a screenshot key, and the launcher moved,
    # which the Keyboard shortcuts page moves again
    own='bindsym --name=terminal $mod+t exec xdg-terminal-exec
bindsym --name=screenshot Print exec true
bindsym --name=launcher $mod+z exec qs -c tide ipc call launcher toggle
bindsym F12 exec qs marker'
    if test "$kind" = overrides; then
        printf '%s\n' "$own" > "$home/checkout/config"
    else
        printf '%s\n' "include tide.conf" "$own" "include tide-*.conf" > "$home/checkout/config"
    fi
    ln -s "$home/checkout/config" "$home/.config/tidewm/config"

    # Stand-ins: uwsm finalize says the session is ready, uwsm start runs
    # the compositor command; xdg-terminal-exec says it ran. The binding
    # events say what qs was given.
    mkfifo "$tmp/ready" "$tmp/qs"
    cat > "$stub/uwsm" <<STUB
#!/bin/sh
echo "uwsm \$*" >> "$tmp/stub.log"
case \$1 in
finalize) printf 'SWAYSOCK=%s\nWAYLAND_DISPLAY=%s\n' "\$SWAYSOCK" "\$WAYLAND_DISPLAY" > "$tmp/env"; echo ready > "$tmp/ready" ;;
start) while test "\$1" != --; do shift; done; shift; exec "\$@" ;;
esac
STUB
    printf '#!/bin/sh\nexit 0\n' > "$stub/qs"
    printf '#!/bin/sh\nexit 0\n' > "$stub/logger"
    printf '#!/bin/sh\nwhile test "$1" != --; do shift; done\nshift\nexec "$@"\n' > "$stub/systemd-cat"
    printf '#!/bin/sh\nexit 0\n' > "$stub/systemctl"
    printf '#!/bin/sh\necho terminal > %s\n' "$tmp/qs" > "$stub/xdg-terminal-exec"
    chmod +x "$stub"/*

    env -i PATH="$stub:$repo/bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
        XDG_RUNTIME_DIR="$tmp/run" WLR_BACKENDS=headless WLR_RENDERER=pixman \
        WLR_LIBINPUT_NO_DEVICES=1 \
        setsid sh bin/tide-session "$wm" > "$tmp/session.log" 2>&1 &
    session_pid=$!
    if ! within 20 cat "$tmp/ready" >/dev/null; then
        fail "$wm${kind:+ ($kind)}: the session never said it was ready"
        tail -n 20 "$tmp/session.log" >&2
        cat "$tmp/stub.log" >&2 2>/dev/null
        # Stop the whole session, so the next one's wait doesn't wait on it
        # (python3, as dash's kill can't signal a process group)
        python3 -c 'import os, signal, sys; os.killpg(int(sys.argv[1]), signal.SIGKILL)' "$session_pid"
        wait "$session_pid" 2>/dev/null
        rm -rf "$tmp"
        return
    fi
    pass
    . "$tmp/env"
    XDG_RUNTIME_DIR=$tmp/run
    export SWAYSOCK WAYLAND_DISPLAY XDG_RUNTIME_DIR

    if test -n "$broken"; then
        # Quit, a terminal and the launcher always keep a key (SPEC.md §16)
        within 10 wtype -M alt -M shift -k Return -m shift -m alt &
        ran=$(within 10 cat "$tmp/qs")
        wait $! 2>/dev/null
        check "$wm${kind:+ ($kind)}: without tide.conf, Alt+Shift+Return still opens a terminal (ran '$ran')" test "$ran" = terminal
        tide-msg exit >/dev/null 2>&1
        wait
        rm -rf "$tmp"
        return
    fi

    # An unreadable reply, or one with no errors list, is a failure, not "no errors"
    if errors=$(tide-msg --type get_config | python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)["errors"]))'); then
        check "$wm${kind:+ ($kind)}: tide's config, through a linked config, loads with no errors${errors:+: $errors}" test -z "$errors"
    else
        check "$wm${kind:+ ($kind)}: get_config answers with its errors" false
    fi
    named=$(tide-msg --type get_named_bindings | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')
    check "$wm${kind:+ ($kind)}: tide.conf's named bindings are there (not $named)" test "$named" -gt 40
    home_ws=$(tide-msg --type get_workspaces | python3 -c 'import json, sys; print([w["name"] for w in json.load(sys.stdin) if w["focused"]][0])')
    check "$wm${kind:+ ($kind)}: the session starts on home, in (not $home_ws)" test "$home_ws" = in

    # Each of tide's keys that runs a shell command runs that command and
    # nothing else, in the keymap the config gives the keyboard, Super_L
    # pressed round it as a hand does: the binding events say what each key
    # ran, in the order the compositor ran it, and F12's, the config's
    # marker, says it's done, so a second binding (the Super tap's
    # launcher, say) shows. Super+x is the launcher's on the Keyboard
    # shortcuts page, which wins over the config's Super+z.
    # The subscriber says "subscribed" once the compositor has taken the
    # subscription, then, at each marker, the commands run since the last,
    # qs's arguments, the fallback after || left out, on one line.
    mkfifo "$tmp/bindings"
    python3 -c '
import json, os, socket, struct, sys
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["SWAYSOCK"])
f = s.makefile("rb")
def send(kind, payload):
    data = payload.encode()
    s.sendall(b"i3-ipc" + struct.pack("=II", len(data), kind) + data)
def receive():
    magic, length, kind = struct.unpack("=6sII", f.read(14))
    return kind, json.loads(f.read(length))
send(2, json.dumps(["binding"]))
kind, reply = receive()
if not reply.get("success"):
    sys.exit("the binding subscription was refused")
print("subscribed", flush=True)
ran = []
while True:
    kind, event = receive()
    command = event["binding"]["command"]
    if command == "exec qs marker":
        print("; ".join(ran), flush=True)
        ran = []
    else:
        ran.append(command.removeprefix("exec qs ").split(" || ")[0])
' > "$tmp/bindings" &
    exec 3<"$tmp/bindings"
    # The next line, in 10 seconds at most (sh reads no further than it)
    next_line() { within 10 sh -c 'IFS= read -r line && printf %s "$line"' <&3; }
    # What a key ran: a key that can't be sent, or no marker in time, says
    # so, as no command does.
    ran_by() {
        if ! within 10 wtype "$@" || ! within 10 wtype -k F12; then
            ran="(the keys couldn't be sent)"
            return
        fi
        ran=$(next_line) || ran="(no marker in 10 seconds)"
    }
    subscribed=$(next_line)
    check "$wm${kind:+ ($kind)}: the binding events come (not '$subscribed')" test "$subscribed" = subscribed
    tide-msg --type get_named_bindings | python3 -c '
import json, sys
mods = {"Mod4": "logo", "Shift": "shift", "Ctrl": "ctrl", "Control": "ctrl", "Mod1": "alt"}
for b in json.load(sys.stdin):
    if not b.get("command", "").startswith("exec qs "):
        continue
    for k in b.get("keys", []):
        parts = k.split("+")
        ms = [mods.get(p) for p in parts[:-1]]
        if None not in ms:
            # What qs is given: a fallback after || runs in sh
            print(" ".join(ms) + "|" + parts[-1] + "|" + b["command"][len("exec qs "):].split(" || ")[0])
' > "$tmp/keys"
    check "$wm${kind:+ ($kind)}: tide's shell keys are there" grep -qix "logo|x|-c tide ipc call launcher toggle" "$tmp/keys"
    while IFS='|' read -r ms k want; do
        set -- -P Super_L
        for m in $ms; do set -- "$@" -M "$m"; done
        set -- "$@" -k "$k"
        for m in $ms; do set -- "$@" -m "$m"; done
        ran_by "$@" -p Super_L
        check "$wm${kind:+ ($kind)}: $ms+$k runs '$want' alone (ran '$ran')" test "$ran" = "$want"
    done < "$tmp/keys"
    # The Super tap alone runs the launcher, once
    ran_by -P Super_L -p Super_L
    check "$wm${kind:+ ($kind)}: a Super tap runs the launcher once (ran '$ran')" test "$ran" = "-c tide ipc call launcher toggle"
    exec 3<&-

    tide-msg exit >/dev/null 2>&1
    wait
    rm -rf "$tmp"
}

for wm in $compositors; do
    if ! command -v "$wm" >/dev/null 2>&1; then
        fail "$wm isn't on PATH"
        continue
    fi
    session "$wm"
    session "$wm" overrides
    session "$wm" broken
done

echo "compositors_test.sh: $passes passed, $failures failed"
test "$failures" -eq 0
