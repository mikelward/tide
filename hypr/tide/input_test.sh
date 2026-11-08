#!/bin/sh
#
# Tests for tide's input scripts, apply-input.sh, next-layout.sh and
# watch-input.sh, against fakes of hyprctl and udevadm. From the repo root:
# `sh hypr/tide/input_test.sh`.

cd "$(dirname "$0")/../.." || exit 1
_apply=$PWD/hypr/tide/apply-input.sh
_nextlayout=$PWD/hypr/tide/next-layout.sh
_watch=$PWD/hypr/tide/watch-input.sh

passes=0
failures=0
_current_test=
start_test() { _current_test="$*"; }
_fail() { failures=$((failures + 1)); printf 'FAIL: %s\n  %s\n' "$_current_test" "$1" >&2; }
assert_equal() { if test "$1" = "$2"; then passes=$((passes + 1)); else _fail "want '$1', got '$2'"; fi; }
assert_true() { if "$@"; then passes=$((passes + 1)); else _fail "failed: $*"; fi; }
assert_contains() { case "$2" in *"$1"*) passes=$((passes + 1)) ;; *) _fail "'$1' not in '$2'" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) _fail "'$1' in '$2'" ;; *) passes=$((passes + 1)) ;; esac; }
skip_block() { echo "SKIP: $1"; }

################################################################################
# apply-input.sh, against a fake hyprctl: each mouse goes through
# hyprland.lua's conf_input.mouse() by `hyprctl eval`, each touchpad through
# conf_input.touchpad(), and each keyboard through conf_input.keyboard().
################################################################################
_fake=$(mktemp -d)
cat > "$_fake/hyprctl" <<'FAKE'
#!/bin/sh
case "$1" in
    devices)
        test -z "$FAKE_DEVICES_FAIL" || exit 1
        if test -n "$FAKE_DEVICES"; then
            printf '%s\n' "$FAKE_DEVICES"
        else
            printf '%s\n' '{"mice": [{"name": "logitech-usb-receiver"}, {"name": "synps/2-synaptics-touchpad"}, {"name": "odd \"quoted\" mouse"}], "keyboards": [{"name": "at-keyboard"}, {"name": "logitech-usb-receiver"}]}'
        fi
        ;;
    eval)
        printf '%s\n' "$2" >> "$FAKE_LOG"
        printf '%s\n' "${FAKE_EVAL_REPLY:-ok}"
        ;;
esac
FAKE
chmod +x "$_fake/hyprctl"
_apply_run() {
    : > "$_fake/log"
    PATH="$_fake:${APPLY_PATH:-$PATH}" FAKE_LOG="$_fake/log" sh "$_apply" 2>"$_fake/err"
}

start_test "apply-input configures each mouse (its wheel left to hyprland.lua), touchpad and keyboard through conf_input"
_apply_run
assert_equal 0 "$?"
_apply_log=$(cat "$_fake/log")
assert_contains 'conf_input.mouse("logitech-usb-receiver", nil)' "$_apply_log"
assert_contains 'conf_input.touchpad("synps/2-synaptics-touchpad")' "$_apply_log"
assert_not_contains 'conf_input.mouse("synps/2-synaptics-touchpad"' "$_apply_log"
assert_contains 'conf_input.keyboard("at-keyboard")' "$_apply_log"
assert_not_contains 'conf_input.mouse("at-keyboard"' "$_apply_log"

start_test "apply-input configures a receiver that's a mouse and a keyboard as both"
assert_contains 'conf_input.keyboard("logitech-usb-receiver")' "$_apply_log"

start_test "apply-input escapes quotes in a device name for Lua"
assert_contains 'conf_input.mouse("odd \"quoted\" mouse", nil)' "$_apply_log"

start_test "apply-input reads hyprctl's own layout without jq, keeping each list apart"
mkdir "$_fake/nojq-apply"
for _tool in sh sed grep cut; do
    _path=$(command -v "$_tool") && ln -s "$_path" "$_fake/nojq-apply/$_tool"
done
FAKE_DEVICES='{
    "mice": [
        {
            "address": "0x1",
            "name": "trackball",
            "defaultSpeed": 0.00000
        }
    ],
    "keyboards": [
        {
            "address": "0x2",
            "name": "at-keyboard",
            "layout": "us",
            "main": true
        }
    ],
    "tablets": [
        {
            "address": "0x3",
            "name": "pen-tablet"
        }
    ]
}' APPLY_PATH="$_fake/nojq-apply" _apply_run
assert_equal 0 "$?"
_apply_log=$(cat "$_fake/log")
assert_contains 'conf_input.mouse("trackball", nil)' "$_apply_log"
assert_contains 'conf_input.keyboard("at-keyboard")' "$_apply_log"
assert_not_contains 'conf_input.mouse("at-keyboard"' "$_apply_log"
assert_not_contains "pen-tablet" "$_apply_log"

start_test "apply-input gives a laptop's built-in pointers the touchpad's settings"
# A ThinkPad's: an I2C touchpad named only by its IDs, the same touchpad's
# HID mouse node, and the TrackPoint, whose buttons sit above the touchpad.
FAKE_DEVICES='{"mice": [{"name": "abcd1234:00-0a0b:0c0d-mouse"}, {"name": "abcd1234:00-0a0b:0c0d-touchpad"}, {"name": "elan0001:00-04f3:3000"}, {"name": "tpps/2-elan-trackpoint"}, {"name": "alps-dualpoint-stick"}, {"name": "bcm5974"}, {"name": "usb-optical-mouse"}], "keyboards": []}' _apply_run
assert_equal 0 "$?"
_apply_log=$(cat "$_fake/log")
for _dev in abcd1234:00-0a0b:0c0d-mouse abcd1234:00-0a0b:0c0d-touchpad elan0001:00-04f3:3000 tpps/2-elan-trackpoint alps-dualpoint-stick bcm5974; do
    assert_contains "conf_input.touchpad(\"$_dev\")" "$_apply_log"
    assert_not_contains "conf_input.mouse(\"$_dev\"" "$_apply_log"
done
assert_contains 'conf_input.mouse("usb-optical-mouse", nil)' "$_apply_log"

start_test "apply-input reports a device listing hyprctl couldn't give"
FAKE_DEVICES_FAIL=1 _apply_run
assert_equal 1 "$?"
assert_equal "" "$(cat "$_fake/log")"
assert_contains "hyprctl devices -j failed" "$(cat "$_fake/err")"

start_test "apply-input honors HYPR_MOUSE_SCROLL_FACTOR"
HYPR_MOUSE_SCROLL_FACTOR=2.25 _apply_run
assert_contains '"logitech-usb-receiver", 2.25)' "$(cat "$_fake/log")"

start_test "apply-input refuses a scroll factor that isn't a number"
HYPR_MOUSE_SCROLL_FACTOR='1) os.exit(' _apply_run
assert_equal 1 "$?"
assert_equal "" "$(cat "$_fake/log")"
assert_contains "must be a number" "$(cat "$_fake/err")"

start_test "apply-input reports a device Hyprland rejected"
FAKE_EVAL_REPLY='error: hl.device: unknown field' _apply_run
assert_equal 1 "$?"
assert_contains "couldn't configure mouse 'logitech-usb-receiver'" "$(cat "$_fake/err")"
assert_contains "couldn't configure keyboard 'at-keyboard': error: hl.device: unknown field" "$(cat "$_fake/err")"
rm -rf "$_fake"

################################################################################
# next-layout.sh, against a fake hyprctl: every keyboard goes to the layout
# after the main keyboard's, by its index, so keyboards out of step come back
# into it. Run with jq, then with python3 alone, since it takes either.
################################################################################
_fake=$(mktemp -d)
cat > "$_fake/hyprctl" <<'FAKE'
#!/bin/sh
case "$1" in
    devices)
        printf '%s\n' "$FAKE_DEVICES"
        ;;
    switchxkblayout)
        printf '%s\n' "$*" >> "$FAKE_LOG"
        printf '%s\n' "${FAKE_SWITCH_REPLY:-ok}"
        ;;
esac
FAKE
chmod +x "$_fake/hyprctl"
# A PATH of the fake hyprctl and only the tools the script may use: with
# python3 and without jq, so the fallback runs even where jq is installed.
# python3 is linked as the interpreter itself, not a version manager's shim
# (pyenv, asdf), which needs more of the PATH than this one has.
mkdir "$_fake/nojq"
for _tool in sh tr wc; do
    _path=$(command -v "$_tool") && ln -s "$_path" "$_fake/nojq/$_tool"
done
if _python=$(python3 -c 'import sys; print(sys.executable)' 2>"$_fake/err") && test -n "$_python"; then
    ln -s "$_python" "$_fake/nojq/python3"
else
    # Without it, the python3 runs below fail on their own.
    echo "input_test.sh: couldn't find python3's interpreter: $(cat "$_fake/err")" >&2
fi
_next_run() {
    : > "$_fake/log"
    FAKE_DEVICES=$1 PATH="$_fake:${2:-$PATH}" FAKE_LOG="$_fake/log" sh "$_nextlayout" 2>"$_fake/err"
}
_kb() {
    printf '{"name": "%s", "layout": "%s", "active_layout_index": %s, "main": %s}' "$1" "$2" "$3" "$4"
}
for _with in jq python3; do
    _p=
    test "$_with" = python3 && _p="$_fake/nojq"
    if test "$_with" = jq && ! command -v jq >/dev/null 2>&1; then
        skip_block "next-layout.sh with jq (jq isn't installed)"
        continue
    fi

    start_test "next-layout ($_with) goes from the main keyboard's first layout to its second"
    _next_run "{\"keyboards\": [$(_kb at-keyboard us,de 0 true)]}" "$_p"
    assert_equal 0 "$?"
    assert_equal "switchxkblayout all 1" "$(cat "$_fake/log")"

    start_test "next-layout ($_with) goes from the last layout back to the first"
    _next_run "{\"keyboards\": [$(_kb at-keyboard us,de,fr 2 true)]}" "$_p"
    assert_equal "switchxkblayout all 0" "$(cat "$_fake/log")"

    start_test "next-layout ($_with) follows the main keyboard, bringing the others into step"
    _next_run "{\"keyboards\": [$(_kb usb-keyboard us,de 0 false), $(_kb at-keyboard us,de 1 true)]}" "$_p"
    assert_equal "switchxkblayout all 0" "$(cat "$_fake/log")"

    start_test "next-layout ($_with) takes the first keyboard when none is main"
    _next_run "{\"keyboards\": [$(_kb at-keyboard us,de 1 false), $(_kb usb-keyboard us,de 0 false)]}" "$_p"
    assert_equal "switchxkblayout all 0" "$(cat "$_fake/log")"

    start_test "next-layout ($_with) with one layout sets it again"
    _next_run "{\"keyboards\": [$(_kb at-keyboard us 0 true)]}" "$_p"
    assert_equal 0 "$?"
    assert_equal "switchxkblayout all 0" "$(cat "$_fake/log")"

    start_test "next-layout ($_with) reports a keyboard it couldn't find a layout for"
    _next_run '{"keyboards": []}' "$_p"
    assert_equal 1 "$?"
    assert_equal "" "$(cat "$_fake/log")"
    assert_contains "next-layout.sh:" "$(cat "$_fake/err")"
done

start_test "next-layout reports a keyboard Hyprland couldn't switch"
FAKE_SWITCH_REPLY='layout idx out of range of 1' _next_run "{\"keyboards\": [$(_kb at-keyboard us,de 0 true)]}"
assert_equal 1 "$?"
assert_contains "couldn't switch every keyboard to layout 1: layout idx out of range of 1" "$(cat "$_fake/err")"

start_test "next-layout says what it needs when it has neither jq nor python3"
rm "$_fake/nojq/python3"
_next_run "{\"keyboards\": [$(_kb at-keyboard us,de 0 true)]}" "$_fake/nojq"
assert_equal 1 "$?"
assert_contains "needs jq or python3" "$(cat "$_fake/err")"
rm -rf "$_fake"

start_test "apply-input parses as shell and is executable"
assert_true sh -n "$_apply"
assert_true test -x "$_apply"

################################################################################
# watch-input.sh, against a fake udevadm that prints a plug-in's events and
# ends, and a fake apply-input.sh that logs each run.
################################################################################
_wfake=$(mktemp -d)
cat > "$_wfake/udevadm" <<'FAKE'
#!/bin/sh
printf '%s\n' "$FAKE_EVENTS"
# A monitor runs until it's stopped; this one, only when asked.
test -z "$FAKE_MONITOR_STAYS" || exec sleep 1000
FAKE
cat > "$_wfake/hyprctl" <<'FAKE'
#!/bin/sh
test -z "$FAKE_HYPR_GONE"
FAKE
cat > "$_wfake/apply" <<'FAKE'
#!/bin/sh
echo ran >> "$FAKE_LOG"
FAKE
chmod +x "$_wfake/udevadm" "$_wfake/hyprctl" "$_wfake/apply"
_watch_run() {
    : > "$_wfake/log"
    PATH="$_wfake:$PATH" FAKE_LOG="$_wfake/log" WATCH_INPUT_DELAY=0 \
        WATCH_INPUT_APPLY="$_wfake/apply" sh "$_watch" 2>"$_wfake/err"
}
_plug='KERNEL[100.1] add      /devices/usb1/1-1/input/input23 (input)
UDEV  [100.2] add      /devices/usb1/1-1/input/input23 (input)
UDEV  [100.3] add      /devices/usb1/1-1/input/input23/mouse2 (input)
UDEV  [100.4] add      /devices/usb1/1-1/input/input23/event5 (input)'

start_test "watch-input applies the settings when a mouse is plugged in"
FAKE_EVENTS="$_plug" _watch_run
assert_equal "ran" "$(cat "$_wfake/log")"

start_test "watch-input ignores a device that's unplugged"
FAKE_EVENTS='UDEV  [101.0] remove   /devices/usb1/1-1/input/input23/event5 (input)' _watch_run
assert_equal "" "$(cat "$_wfake/log")"

# Run under load, this and the two above stop the guard just as it starts,
# where a signal it doesn't take would leave it, and watch-input, running.
start_test "watch-input ends, saying so, when udevadm's monitor ends at once"
: > "$_wfake/log"
PATH="$_wfake:$PATH" FAKE_LOG="$_wfake/log" WATCH_INPUT_DELAY=0 FAKE_EVENTS='' \
    WATCH_INPUT_APPLY="$_wfake/apply" timeout 10 sh "$_watch" 2>"$_wfake/err"
assert_equal 0 "$?"
assert_contains "udevadm monitor ended" "$(cat "$_wfake/err")"

start_test "watch-input stops its monitor, saying so, once Hyprland has gone"
FAKE_HYPR_GONE=1 FAKE_MONITOR_STAYS=1 WATCH_INPUT_POLL=0 FAKE_EVENTS='' _watch_run
assert_equal 0 "$?"
assert_contains "Hyprland has gone" "$(cat "$_wfake/err")"

start_test "watch-input refuses a poll that isn't a number"
PATH="$_wfake:$PATH" WATCH_INPUT_POLL=often sh "$_watch" 2>"$_wfake/err"
assert_equal 1 "$?"
assert_contains "WATCH_INPUT_POLL must be a number" "$(cat "$_wfake/err")"

start_test "watch-input refuses a delay that isn't a number"
PATH="$_wfake:$PATH" WATCH_INPUT_DELAY=soon sh "$_watch" 2>"$_wfake/err"
assert_equal 1 "$?"
assert_contains "WATCH_INPUT_DELAY must be a number" "$(cat "$_wfake/err")"
rm -rf "$_wfake"

start_test "watch-input parses as shell and is executable"
assert_true sh -n "$_watch"
assert_true test -x "$_watch"

if command -v shellcheck >/dev/null 2>&1; then
    start_test "shellcheck passes"
    assert_true shellcheck -s sh "$_apply" "$_nextlayout" "$_watch"
fi

printf 'input_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
