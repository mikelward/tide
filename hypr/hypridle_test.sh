#!/bin/sh
#
# Tests for hypr/hypridle.conf, tide's hypridle config, which the installer
# copies to ~/.config/hypr/hypridle.conf when there's none: its listeners
# and timeouts, and its commands, run as hypridle runs them (/bin/sh -c)
# against fakes that log what they're given. From the repo root:
# `sh hypr/hypridle_test.sh`.

cd "$(dirname "$0")/.." || exit 1
_idle=$PWD/hypr/hypridle.conf

passes=0
failures=0
_current_test=
start_test() { _current_test="$*"; }
_fail() { failures=$((failures + 1)); printf 'FAIL: %s\n  %s\n' "$_current_test" "$1" >&2; }
assert_equal() { if test "$1" = "$2"; then passes=$((passes + 1)); else _fail "want '$1', got '$2'"; fi; }
assert_contains() { case "$2" in *"$1"*) passes=$((passes + 1)) ;; *) _fail "'$1' not in '$2'" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) _fail "'$1' in '$2'" ;; *) passes=$((passes + 1)) ;; esac; }

# hypridle: dim, lock, and screen-off listeners exist.
_idle_body=$(cat "$_idle")
start_test "hypridle dims the backlight"
assert_contains "brightnessctl -s set" "$_idle_body"
start_test "hypridle locks the session"
assert_contains "loginctl lock-session" "$_idle_body"
start_test "hypridle turns the display off (DPMS)"
assert_contains "hl.dsp.dpms({ action = \"off\" })" "$_idle_body"

# The timeouts are tide's settings: tide writes them to tide-idle.conf, which
# this sources after its own defaults, tide's SPEC.md §10 timeline, so a
# missing file keeps that timeline; and every listener times out on one.
_idle_vars=$(sed -n 's/^\$\(tide_idle_[a-z_]*\) = \([0-9]*\)$/\1=\2/p' "$_idle" | tr '\n' ' ')
start_test "hypridle's default timeouts are tide's timeline"
assert_equal "tide_idle_dim=150 tide_idle_lock=300 tide_idle_displays_off=330 tide_idle_suspend=1800 " "$_idle_vars"
_idle_source_line=$(grep -n '^source = tide-idle.conf$' "$_idle" | cut -d: -f1)
_idle_last_default=$(grep -n '^\$tide_idle_' "$_idle" | tail -n 1 | cut -d: -f1)
_idle_first_listener=$(grep -n '^listener {' "$_idle" | head -n 1 | cut -d: -f1)
start_test "hypridle sources tide's timeouts after its defaults and before any listener"
assert_equal "yes" "$(test -n "$_idle_source_line" && test "$_idle_source_line" -gt "${_idle_last_default:-0}" && test "$_idle_source_line" -lt "${_idle_first_listener:-0}" && echo yes)"
start_test "every hypridle listener times out on one of tide's settings"
assert_equal "\$tide_idle_dim \$tide_idle_lock \$tide_idle_displays_off \$tide_idle_suspend " "$(sed -n 's/^ *timeout = //p' "$_idle" | tr '\n' ' ')"

# The lock command and the five-minute idle step, run as hypridle runs them
# (/bin/sh -c) against fake tools that log their arguments: the tide session
# goes to tide-lock, a plain Hyprland login to hyprlock.
_idle_lock_cmd=$(sed -n 's/^ *lock_cmd = //p' "$_idle")
_idle_lock_step=$(sed -n '/^listener {/,/^}/{/timeout = \$tide_idle_lock$/,/^}/s/^ *on-timeout = //p}' "$_idle")
_idle_suspend_step=$(sed -n '/^listener {/,/^}/{/timeout = \$tide_idle_suspend$/,/^}/s/^ *on-timeout = //p}' "$_idle")
_idle_suspend_resume=$(sed -n '/^listener {/,/^}/{/timeout = \$tide_idle_suspend$/,/^}/s/^ *on-resume = //p}' "$_idle")
_idle_off_step=$(sed -n '/^listener {/,/^}/{/timeout = \$tide_idle_displays_off$/,/^}/s/^ *on-timeout = //p}' "$_idle")
_idle_off_resume=$(sed -n '/^listener {/,/^}/{/timeout = \$tide_idle_displays_off$/,/^}/s/^ *on-resume = //p}' "$_idle")
_idle_after_sleep=$(sed -n 's/^ *after_sleep_cmd = //p' "$_idle")
start_test "hypridle's lock command and idle lock and suspend steps are found"
assert_contains "esac" "$_idle_lock_cmd"
assert_contains "esac" "$_idle_lock_step"
assert_contains "esac" "$_idle_suspend_step"
assert_contains "esac" "$_idle_suspend_resume"
assert_contains "esac" "$_idle_off_step"
assert_contains "esac" "$_idle_off_resume"
assert_contains "esac" "$_idle_after_sleep"

_ifake=$(mktemp -d)
for _t in hyprlock hyprctl tide loginctl notify-send; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/log"\n' "$_t" "$_ifake" > "$_ifake/$_t"
    chmod +x "$_ifake/$_t"
done
# systemctl logs its arguments too, and `show` prints tide-lock.service's
# LoadState from $FAKE_LOADSTATE: loaded unless a test says otherwise, and
# a failure to reach the user manager when it's "fail".
cat > "$_ifake/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$_ifake/log"
case "\$*" in
    *" show "*)
        if test "\$FAKE_LOADSTATE" = fail; then
            echo "Failed to connect to bus: No medium found" >&2
            exit 1
        fi
        echo "\${FAKE_LOADSTATE:-loaded}"
        ;;
esac
EOF
chmod +x "$_ifake/systemctl"
# No lock running, so pgrep finds nothing, unless $FAKE_PGREP says this
# user has one: it's found only when this user's is asked for.
printf '#!/bin/sh\ntest -n "$FAKE_PGREP" && test "$1" = -u && test "$2" = "$(id -u)" && test "$3 $4" = "-x hyprlock"\n' > "$_ifake/pgrep"
chmod +x "$_ifake/pgrep"
_idle_run() {
    : > "$_ifake/log"
    XDG_CURRENT_DESKTOP="$1" PATH="$_ifake:$PATH" sh -c "$2" 2>"$_ifake/err"
    cat "$_ifake/log"
}
_idle_show="systemctl --user show -p LoadState --value tide-lock.service"
_idle_notice='notify-send --urgency=critical --app-name=tide The tide lock failed hyprlock locked the session instead. Run tide doctor to see why.'
start_test "in the tide session, a lock starts tide-lock.service"
assert_equal "$_idle_show
systemctl --user start tide-lock.service" "$(_idle_run tide:Hyprland "$_idle_lock_cmd")"
start_test "in the tide session, a lock with tide-lock.service loaded runs no hyprlock"
assert_not_contains "hyprlock" "$(_idle_run tide:Hyprland "$_idle_lock_cmd")"
# A unit that isn't installed or is masked never fails, so its OnFailure=
# never starts the fallback: hyprlock locks from here instead.
start_test "in the tide session, a lock without tide-lock.service runs hyprlock"
_out=$(FAKE_LOADSTATE=not-found _idle_run tide:Hyprland "$_idle_lock_cmd")
assert_contains "hyprlock " "$_out"
start_test "and doesn't start the missing unit"
assert_not_contains "start tide-lock.service" "$_out"
start_test "and says the lock fell back, as the unit's fallback does"
assert_contains "$_idle_notice" "$_out"
start_test "and logs why"
assert_equal "hypridle lock_cmd: tide-lock.service is not-found, so hyprlock locks instead" "$(cat "$_ifake/err")"
start_test "in the tide session, a lock with tide-lock.service masked runs hyprlock"
_out=$(FAKE_LOADSTATE=masked _idle_run tide:Hyprland "$_idle_lock_cmd")
assert_contains "hyprlock " "$_out"
assert_not_contains "start tide-lock.service" "$_out"
start_test "in the tide session, a lock that can't ask systemd runs hyprlock"
_out=$(FAKE_LOADSTATE=fail _idle_run tide:Hyprland "$_idle_lock_cmd")
assert_contains "hyprlock " "$_out"
assert_contains "tide-lock.service is Failed to connect to bus: No medium found, so hyprlock locks instead" "$(cat "$_ifake/err")"
start_test "in the tide session, a lock without tide-lock.service stacks no second hyprlock"
assert_equal "$_idle_show" "$(FAKE_LOADSTATE=not-found FAKE_PGREP=1 _idle_run tide:Hyprland "$_idle_lock_cmd")"
start_test "in a plain Hyprland login, a lock stacks no second hyprlock"
assert_equal "" "$(FAKE_PGREP=1 _idle_run Hyprland "$_idle_lock_cmd")"
start_test "in the tide session, the idle step runs tide idle-lock"
assert_equal "tide idle-lock" "$(_idle_run tide:Hyprland "$_idle_lock_step")"
start_test "in a plain Hyprland login, a lock runs hyprlock"
assert_equal "hyprlock " "$(_idle_run Hyprland "$_idle_lock_cmd")"
start_test "in a plain Hyprland login, the idle step locks through logind"
assert_equal "loginctl lock-session" "$(_idle_run Hyprland "$_idle_lock_step")"
start_test "with no desktop set, a lock runs hyprlock"
assert_equal "hyprlock " "$(_idle_run "" "$_idle_lock_cmd")"
# In tide's sessions, `tide displays` turns the displays off and on, on
# Hyprland or tidewm; a plain Hyprland login asks Hyprland itself.
for _desktop in tide:Hyprland tidewm:tide; do
    start_test "in $_desktop's session, the displays-off step runs tide displays off"
    assert_equal "tide displays off" "$(_idle_run "$_desktop" "$_idle_off_step")"
    start_test "in $_desktop's session, input turns them on with tide displays on"
    assert_equal "tide displays on" "$(_idle_run "$_desktop" "$_idle_off_resume")"
    start_test "in $_desktop's session, waking from sleep turns them on with tide displays on"
    assert_equal "tide displays on" "$(_idle_run "$_desktop" "$_idle_after_sleep")"
done
start_test "in a plain Hyprland login, the displays-off step is Hyprland's dpms"
assert_equal 'hyprctl dispatch hl.dsp.dpms({ action = "off" })' "$(_idle_run Hyprland "$_idle_off_step")"
start_test "in a plain Hyprland login, input turns them on through Hyprland"
assert_equal 'hyprctl dispatch hl.dsp.dpms({ action = "on" })' "$(_idle_run Hyprland "$_idle_off_resume")"
start_test "in a plain Hyprland login, waking from sleep turns them on through Hyprland"
assert_equal 'hyprctl dispatch hl.dsp.dpms({ action = "on" })' "$(_idle_run Hyprland "$_idle_after_sleep")"
# tide decides whether to suspend (on battery only).
start_test "in the tide session, the suspend step runs tide idle-suspend"
assert_equal "tide idle-suspend" "$(_idle_run tide:Hyprland "$_idle_suspend_step")"
start_test "in a plain Hyprland login, the suspend step suspends"
assert_equal "systemctl suspend" "$(_idle_run Hyprland "$_idle_suspend_step")"
# On AC, tide notes the skipped suspend for an unplug; coming back forgets it.
start_test "in the tide session, input after the suspend step cancels tide's unplug suspend"
assert_equal "tide idle-suspend --cancel" "$(_idle_run tide:Hyprland "$_idle_suspend_resume")"
start_test "in a plain Hyprland login, input after the suspend step runs nothing"
assert_equal "" "$(_idle_run Hyprland "$_idle_suspend_resume")"
rm -rf "$_ifake"

printf 'hypridle_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
