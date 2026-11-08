#!/bin/sh
#
# Tests for tide's input scripts, apply-input.sh, next-layout.sh and
# watch-input.sh, against fakes of hyprctl, tide-msg and udevadm. From the repo root:
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
# apply-input.sh in tidewm's session, against a fake tide-msg: it writes
# tide-devices.conf, giving a laptop's pointing stick and its touchpad's
# -mouse node the first touchpad's settings, and reloads tidewm when that
# changes. Run with jq, then with python3 alone, since it takes either.
################################################################################
_fake=$(mktemp -d)
cat > "$_fake/tide-msg" <<'FAKE'
#!/bin/sh
case "$*" in
    "--type get_inputs")
        test -z "$FAKE_INPUTS_FAIL" || { echo "tide-msg: couldn't ask tidewm" >&2; exit 2; }
        printf '%s\n' "$FAKE_INPUTS"
        ;;
    reload)
        echo reload >> "$FAKE_LOG"
        test -z "$FAKE_RELOAD_FAIL" || { echo "tide-msg: reload: $FAKE_RELOAD_FAIL" >&2; exit 1; }
        ;;
    *) echo "unexpected: $*" >> "$FAKE_LOG" ;;
esac
FAKE
# It mustn't ask Hyprland.
cat > "$_fake/hyprctl" <<'FAKE'
#!/bin/sh
echo "hyprctl $*" >> "$FAKE_LOG"
FAKE
chmod +x "$_fake/tide-msg" "$_fake/hyprctl"
mkdir "$_fake/nojq"
for _tool in sh cat cp mv rm mkdir; do
    _path=$(command -v "$_tool") && ln -s "$_path" "$_fake/nojq/$_tool"
done
if _python=$(python3 -c 'import sys; print(sys.executable)' 2>"$_fake/err") && test -n "$_python"; then
    ln -s "$_python" "$_fake/nojq/python3"
else
    echo "input_test.sh: couldn't find python3's interpreter: $(cat "$_fake/err")" >&2
fi
_devices=$_fake/config/tidewm/tide-devices.conf
_tw_run() {
    : > "$_fake/log"
    PATH="$_fake:${_tw_path:-$PATH}" FAKE_LOG="$_fake/log" XDG_CURRENT_DESKTOP=tidewm:tide \
        XDG_CONFIG_HOME="$_fake/config" sh "$_apply" 2>"$_fake/err"
}
_tw_input() {
    printf '{"identifier": "%s", "hyprland_name": "%s", "type": "%s"%s}' "$1" "$1" "$2" "$3"
}
_tw_pad=$(_tw_input abcd1234:00-0a0b:0c0d-touchpad touchpad ', "scroll_factor": 1.5, "libinput": {"tap": "enabled", "left_handed": "disabled", "natural_scroll": "enabled", "accel_speed": 0.5}')
_tw_stick=$(_tw_input tpps/2-elan-trackpoint pointer ', "scroll_factor": 3, "libinput": {"left_handed": "enabled"}')
_tw_node=$(_tw_input abcd1234:00-0a0b:0c0d-mouse pointer ', "scroll_factor": 3')
_tw_mouse=$(_tw_input logitech-usb-receiver pointer ', "scroll_factor": 3')
_tw_kb=$(_tw_input at-translated-set-2-keyboard keyboard '')
_tw_laptop="[$_tw_kb, $_tw_pad, $_tw_stick, $_tw_node, $_tw_mouse]"
_tw_block() {
    printf 'input "%s" {\n    left_handed %s\n' "$1" "$2"
    test -z "$3" || printf '    natural_scroll %s\n' "$3"
    printf '    pointer_accel %s\n    scroll_factor %s\n}' "$4" "$5"
}
for _with in jq python3; do
    _tw_path=
    test "$_with" = python3 && _tw_path="$_fake/nojq"
    if test "$_with" = jq && ! command -v jq >/dev/null 2>&1; then
        skip_block "apply-input.sh on tidewm with jq (jq isn't installed)"
        continue
    fi
    rm -rf "$_fake/config"

    start_test "apply-input ($_with) on tidewm gives a laptop's pointing stick and -mouse node the touchpad's settings"
    FAKE_INPUTS=$_tw_laptop _tw_run
    assert_equal 0 "$?"
    _conf=$(cat "$_devices")
    assert_contains "$(_tw_block tpps/2-elan-trackpoint disabled enabled 0.5 1.5)" "$_conf"
    assert_contains "$(_tw_block abcd1234:00-0a0b:0c0d-mouse disabled enabled 0.5 1.5)" "$_conf"
    assert_equal reload "$(cat "$_fake/log")"
    assert_equal "" "$(cat "$_fake/err")"

    start_test "apply-input ($_with) on tidewm leaves mice, touchpads and keyboards to the config"
    assert_not_contains logitech-usb-receiver "$_conf"
    assert_not_contains '-touchpad"' "$_conf"
    assert_not_contains keyboard "$_conf"
    assert_not_contains "type:pointer" "$_conf"

    start_test "apply-input ($_with) on tidewm leaves tidewm alone when nothing changed"
    FAKE_INPUTS=$_tw_laptop _tw_run
    assert_equal 0 "$?"
    assert_equal "" "$(cat "$_fake/log")"
    assert_equal "$_conf" "$(cat "$_devices")"

    start_test "apply-input ($_with) on tidewm follows a change to the touchpad's settings"
    FAKE_INPUTS="[$(_tw_input pad touchpad ', "scroll_factor": 1, "libinput": {"left_handed": "enabled", "natural_scroll": "disabled", "accel_speed": -0.25}'), $_tw_stick]" _tw_run
    assert_equal 0 "$?"
    assert_contains "$(_tw_block tpps/2-elan-trackpoint enabled disabled -0.25 1)" "$(cat "$_devices")"
    assert_equal reload "$(cat "$_fake/log")"

    start_test "apply-input ($_with) on tidewm keeps each of the touchpad's settings in its place when one is missing"
    # As tide's stand-in for tidewm gives a touchpad, with no left_handed.
    FAKE_INPUTS="[$(_tw_input pad touchpad ', "scroll_factor": 1.5, "libinput": {"natural_scroll": "enabled", "accel_speed": 0.5}'), $_tw_stick]" _tw_run
    assert_equal 0 "$?"
    assert_contains "$(_tw_block tpps/2-elan-trackpoint disabled enabled 0.5 1.5)" "$(cat "$_devices")"

    start_test "apply-input ($_with) on tidewm gives a pointing stick libinput's defaults without a touchpad"
    FAKE_INPUTS="[$_tw_stick, $_tw_mouse]" _tw_run
    assert_equal 0 "$?"
    assert_contains "$(_tw_block tpps/2-elan-trackpoint disabled '' 0 1)" "$(cat "$_devices")"

    start_test "apply-input ($_with) on tidewm makes HYPR_MOUSE_SCROLL_FACTOR every mouse's wheel speed"
    FAKE_INPUTS="[$_tw_mouse]" HYPR_MOUSE_SCROLL_FACTOR=2.25 _tw_run
    assert_equal 0 "$?"
    assert_contains "input type:pointer {
    scroll_factor 2.25
}" "$(cat "$_devices")"
done

start_test "apply-input on tidewm writes a file tidewm reads before tide's own settings"
# conf's tidewm config ends with `include tide-*.conf`, in glob order, and
# the later line for a name wins.
: > "$_fake/config/tidewm/tide-input.conf"
set -- "$_fake/config/tidewm"/tide-*.conf
assert_equal "$_devices" "$1"
assert_equal "$_fake/config/tidewm/tide-input.conf" "$2"
rm "$_fake/config/tidewm/tide-input.conf"

start_test "apply-input on tidewm never asks Hyprland"
FAKE_INPUTS=$_tw_laptop _tw_run
assert_not_contains hyprctl "$(cat "$_fake/log")"

start_test "apply-input on tidewm leaves out a name tidewm's config can't hold, saying so"
FAKE_INPUTS="[$(_tw_input 'odd\"trackpoint' pointer ''), $_tw_stick]" _tw_run
assert_equal 1 "$?"
assert_contains "can't give 'odd\"trackpoint' the touchpad's settings" "$(cat "$_fake/err")"
assert_not_contains 'odd' "$(cat "$_devices")"
assert_contains 'input "tpps/2-elan-trackpoint" {' "$(cat "$_devices")"

start_test "apply-input on tidewm reports devices tide-msg couldn't list"
_before=$(cat "$_devices")
FAKE_INPUTS_FAIL=1 _tw_run
assert_equal 1 "$?"
assert_contains "tide-msg --type get_inputs failed" "$(cat "$_fake/err")"
assert_equal "" "$(cat "$_fake/log")"
assert_equal "$_before" "$(cat "$_devices")"

start_test "apply-input on tidewm puts the file back when tidewm can't reload, and tries again next time"
FAKE_INPUTS=$_tw_laptop FAKE_RELOAD_FAIL="config error" _tw_run
assert_equal 1 "$?"
assert_contains "tidewm couldn't reload with $_devices, so it's as it was: tide-msg: reload: config error" "$(cat "$_fake/err")"
assert_equal "$_before" "$(cat "$_devices")"
FAKE_INPUTS=$_tw_laptop _tw_run
assert_equal 0 "$?"
assert_equal reload "$(cat "$_fake/log")"

start_test "apply-input on tidewm removes a new file tidewm couldn't reload with"
rm -rf "$_fake/config"
FAKE_INPUTS=$_tw_laptop FAKE_RELOAD_FAIL="config error" _tw_run
assert_equal 1 "$?"
assert_true test ! -e "$_devices"
assert_true test ! -e "$_devices.old"
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

################################################################################
# watch-input.sh in tidewm's session, against a fake tide-msg that prints
# tidewm's input events and ends, as when tidewm exits.
################################################################################
_wfake=$(mktemp -d)
cat > "$_wfake/tide-msg" <<'FAKE'
#!/bin/sh
test "$*" = "--subscribe input" || { echo "unexpected: $*" >> "$FAKE_LOG"; exit 2; }
test -z "$FAKE_EVENTS" || printf '%s\n' "$FAKE_EVENTS"
exit "${FAKE_SUBSCRIBE_STATUS:-0}"
FAKE
# It mustn't listen to udev.
cat > "$_wfake/udevadm" <<'FAKE'
#!/bin/sh
echo "udevadm $*" >> "$FAKE_LOG"
FAKE
cat > "$_wfake/apply" <<'FAKE'
#!/bin/sh
echo ran >> "$FAKE_LOG"
FAKE
chmod +x "$_wfake/tide-msg" "$_wfake/udevadm" "$_wfake/apply"
_tw_watch_run() {
    : > "$_wfake/log"
    PATH="$_wfake:$PATH" FAKE_LOG="$_wfake/log" WATCH_INPUT_DELAY=0 XDG_CURRENT_DESKTOP=tidewm:tide \
        WATCH_INPUT_APPLY="$_wfake/apply" timeout 10 sh "$_watch" 2>"$_wfake/err"
}

start_test "watch-input on tidewm applies the settings when a device is added"
FAKE_EVENTS='{ "change": "added", "input": { "identifier": "1:2:TPPS/2_Elan_TrackPoint", "type": "pointer" } }' _tw_watch_run
assert_equal 0 "$?"
assert_equal "ran" "$(cat "$_wfake/log")"

start_test "watch-input on tidewm applies the settings again when a reload sets a device's"
FAKE_EVENTS='{"change":"libinput_config","input":{"identifier":"1:2:SynPS/2_Synaptics_TouchPad","type":"touchpad"}}' _tw_watch_run
assert_equal "ran" "$(cat "$_wfake/log")"

start_test "watch-input on tidewm applies the settings again when a device is removed"
# The first touchpad, whose settings a pointing stick takes, may be gone.
FAKE_EVENTS='{ "change": "removed", "input": { "type": "touchpad" } }' _tw_watch_run
assert_equal "ran" "$(cat "$_wfake/log")"

start_test "watch-input on tidewm ignores a keyboard's layout and keymap"
FAKE_EVENTS='{ "change": "xkb_layout", "input": { "type": "keyboard", "xkb_active_layout_name": "added" } }
{ "change": "xkb_keymap", "input": { "type": "keyboard" } }' _tw_watch_run
assert_equal "" "$(cat "$_wfake/log")"

start_test "watch-input on tidewm ends, saying so, once tidewm has gone"
FAKE_EVENTS='' _tw_watch_run
assert_equal 0 "$?"
assert_contains "tidewm has gone" "$(cat "$_wfake/err")"

start_test "watch-input on tidewm says so when it can't follow tidewm's events"
FAKE_EVENTS='' FAKE_SUBSCRIBE_STATUS=2 _tw_watch_run
assert_equal 1 "$?"
assert_contains "tide-msg stopped following tidewm's input events (2)" "$(cat "$_wfake/err")"
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
