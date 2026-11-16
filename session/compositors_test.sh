#!/bin/sh
#
# Starts tide's tidewm and tidesway sessions as a login does, on wlroots'
# headless backend, and checks that tide's config loads whole and its keys
# run. The config is laid out as a user has it: ~/.config/tidewm/config a
# symlink into a dotfiles checkout, including the tide.conf `make install`
# puts beside the link, and the files tide's shell writes
# (session/shell_files.mjs). uwsm, logger, systemd-cat, systemctl and qs
# are stand-ins; qs says which of the shell's commands a key ran. It does
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
bindsym --name=launcher $mod+z exec qs -c tide ipc call launcher toggle'
    if test "$kind" = overrides; then
        printf '%s\n' "$own" > "$home/checkout/config"
    else
        printf '%s\n' "include tide.conf" "$own" "include tide-*.conf" > "$home/checkout/config"
    fi
    ln -s "$home/checkout/config" "$home/.config/tidewm/config"

    # Stand-ins: uwsm finalize says the session is ready, uwsm start runs
    # the compositor command; qs says each command it's given.
    mkfifo "$tmp/ready" "$tmp/qs"
    cat > "$stub/uwsm" <<STUB
#!/bin/sh
echo "uwsm \$*" >> "$tmp/stub.log"
case \$1 in
finalize) printf 'SWAYSOCK=%s\nWAYLAND_DISPLAY=%s\n' "\$SWAYSOCK" "\$WAYLAND_DISPLAY" > "$tmp/env"; echo ready > "$tmp/ready" ;;
start) while test "\$1" != --; do shift; done; shift; exec "\$@" ;;
esac
STUB
    printf '#!/bin/sh\necho "$*" > %s\n' "$tmp/qs" > "$stub/qs"
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

    # Each key runs the shell's command it's bound to, in the keymap the
    # config gives the keyboard; Super+x is the launcher's on the Keyboard
    # shortcuts page, which wins over the config's Super+z
    for key in "x launcher toggle" "Return prompt go" "v picker toggle clipboard"; do
        k=${key%% *}
        want=${key#* }
        within 10 wtype -M logo -k "$k" -m logo &
        ran=$(within 10 cat "$tmp/qs")
        wait $! 2>/dev/null
        check "$wm${kind:+ ($kind)}: Super+$k runs '$want' (ran '$ran')" sh -c 'case "$1" in *"$2"*) exit 0 ;; esac; exit 1' sh "$ran" "$want"
    done

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
