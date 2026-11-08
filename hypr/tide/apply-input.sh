#!/bin/sh
#
# Auto-configure pointing devices so no device names need hardcoding.
#   TOUCHPADS keep the global defaults (LEFT button primary), plus the speed
#             and handedness tide's Touchpad settings give them. A laptop's
#             other built-in pointers count as touchpads too: its pointing
#             stick, whose buttons sit above the touchpad, and the extra
#             "-mouse" node of a touchpad wired over I2C.
#   MICE      get the handedness and wheel speed of hyprland.lua's `mouse`
#             option, or what tide's Mouse settings say instead.
#   KEYBOARDS get tide's keyboard settings, so one with settings of its own
#             can have them and lose them again.
#   Each takes tide's settings for that one device over its kind's.
#
# Devices are classified by name, the libinput name Hyprland lowercases and
# dashes (see is_touchpad; tide's Touchpad page decides the same way). Runs at
# login, after each reload, and from watch-input.sh when a mouse, touchpad or
# keyboard is plugged in.
# HYPR_MOUSE_SCROLL_FACTOR sets every mouse's wheel speed over the `mouse`
# option's.
#
# In tide's tidewm session (tide SPEC.md §5.3) the config's `input` lines do
# most of this: type:pointer's are every mouse's, conf's handedness and
# wheel speed among them, and type:touchpad's every touchpad's. But tidewm's
# pointer is anything that can't tap, so a laptop's pointing stick and its
# touchpad's "-mouse" node would take the mice's. So this writes
# ~/.config/tidewm/tide-devices.conf, which conf's tidewm config includes:
# an `input` block for each of those, by the name Hyprland would give it,
# with the touchpad's handedness, natural scrolling, speed and wheel speed,
# as tidewm's GET_INPUTS has them on the first touchpad, else libinput's
# defaults; and HYPR_MOUSE_SCROLL_FACTOR as type:pointer's scroll_factor.
# It sorts before tide-input.conf, so tide's own settings still win. tidewm
# reloads only when the file changes. watch-input.sh runs this again when
# a device comes, and after each reload, so a change to the touchpad's
# settings reaches the pointing stick too.

# nil, in Lua, leaves it to hyprland.lua.
MOUSE_SCROLL="${HYPR_MOUSE_SCROLL_FACTOR-nil}"

# It is spliced into Lua below, and tidewm's config, so it must be a plain
# number.
case "$MOUSE_SCROLL" in
    nil) ;;
    ''|*[!0-9.]*|*.*.*|.)
        echo "apply-input.sh: HYPR_MOUSE_SCROLL_FACTOR must be a number, not '$MOUSE_SCROLL'" >&2
        exit 1
        ;;
esac

# Whether pointer $1 is a touchpad or another of a laptop's built-in
# pointers, which take the touchpad's settings: one that says touchpad or
# trackpad (Apple's bcm5974 doesn't), a pointing stick (a TrackPoint, ALPS's
# DualPoint stick), and anything named by an ACPI ID such as
# "elan1200:00-04f3:309f-touchpad" or "syna8018:00-06cb:ce67-mouse", which is
# an I2C device built into the laptop. A TrackPoint's buttons, and a
# touchpad's, come through those, so left-handed there would swap the
# buttons above the touchpad. Everything else is a mouse. Keep in step with
# tide's shell/lib/input.mjs deviceKind.
is_touchpad() {
    case "$1" in
        *touchpad*|*trackpad*|*synaptics*|*bcm5974*) return 0 ;;
        *trackpoint*|*pointing-stick*|*pointingstick*|*dualpoint-stick*) return 0 ;;
        [a-z0-9][a-z0-9][a-z0-9][a-z0-9][0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) return 0 ;;
    esac
    return 1
}

# A plain number, which may be negative: a speed or a wheel speed as
# tidewm's GET_INPUTS gives it.
is_number() {
    case "${1#-}" in
        ''|*[!0-9.]*|*.*.*|.) return 1 ;;
    esac
    return 0
}

# tidewm's session: tide-devices.conf, as the top says.
apply_tidewm() {
    if ! command -v tide-msg >/dev/null 2>&1; then
        echo "apply-input.sh: no tide-msg, so a laptop's pointing stick takes the mice's settings" >&2
        return 1
    fi
    if ! inputs=$(tide-msg --type get_inputs); then
        echo "apply-input.sh: tide-msg --type get_inputs failed" >&2
        return 1
    fi
    # Each pointer's name, a line apiece, and the first touchpad's
    # left_handed, natural_scroll, accel_speed and scroll_factor, by
    # spaces, "-" for each it doesn't have, so the rest keep their places,
    # or nothing without one.
    if command -v jq >/dev/null 2>&1; then
        pointers=$(printf '%s\n' "$inputs" | jq -r '.[] | select(.type == "pointer") | .hyprland_name') \
            && touchpad=$(printf '%s\n' "$inputs" | jq -r '[.[] | select(.type == "touchpad")][0] // empty
                | [.libinput.left_handed, .libinput.natural_scroll, .libinput.accel_speed, .scroll_factor]
                | map(if . == null then "-" else tostring end) | join(" ")')
    elif command -v python3 >/dev/null 2>&1; then
        pointers=$(printf '%s\n' "$inputs" | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if d["type"] == "pointer":
        print(d["hyprland_name"])
') && touchpad=$(printf '%s\n' "$inputs" | python3 -c '
import json, sys
pads = [d for d in json.load(sys.stdin) if d["type"] == "touchpad"]
if pads:
    li = pads[0].get("libinput", {})
    values = [li.get("left_handed"), li.get("natural_scroll"), li.get("accel_speed"), pads[0].get("scroll_factor")]
    print(" ".join("-" if v is None else str(v) for v in values))
')
    else
        echo "apply-input.sh: reading tidewm's devices needs jq or python3" >&2
        return 1
    fi
    if test "$?" -ne 0; then
        echo "apply-input.sh: couldn't read tidewm's devices from: $inputs" >&2
        return 1
    fi

    # The touchpad's, else libinput's defaults; natural scrolling only
    # from a touchpad, else type:pointer's stands.
    left=disabled natural='' accel=0 scroll=1
    if test -n "$touchpad"; then
        set -f
        # shellcheck disable=SC2086 # Split on the spaces.
        set -- $touchpad
        set +f
        case "$1" in enabled|disabled) left=$1 ;; esac
        case "$2" in enabled|disabled) natural=$2 ;; esac
        is_number "$3" && accel=$3
        is_number "$4" && scroll=$4
    fi

    conf="# Written by tide's apply-input.sh from the devices tidewm has, and
# written again as they come and go: don't change it. A laptop's pointing
# stick and its touchpad's -mouse node take the touchpad's settings, not
# the mice's. tide-input.conf, tide's own settings, comes after it and wins."
    if test "$MOUSE_SCROLL" != nil; then
        conf="$conf
input type:pointer {
    scroll_factor $MOUSE_SCROLL
}"
    fi
    status=0
    set -f
    IFS='
'
    for name in $pointers; do
        test -n "$name" || continue
        is_touchpad "$name" || continue
        # tidewm's quotes take no escapes.
        case "$name" in
            *[\"\\\$]*)
                echo "apply-input.sh: can't give '$name' the touchpad's settings: tidewm's config can't name it" >&2
                status=1
                continue
                ;;
        esac
        conf="$conf
input \"$name\" {
    left_handed $left${natural:+
    natural_scroll $natural}
    pointer_accel $accel
    scroll_factor $scroll
}"
    done
    unset IFS
    set +f

    dir=${XDG_CONFIG_HOME:-$HOME/.config}/tidewm
    file=$dir/tide-devices.conf
    if test -f "$file" && test "$(cat "$file")" = "$conf"; then
        return $status
    fi
    # The last one is kept until tidewm has read this one, and put back if
    # it can't, so the file is what tidewm has, and the next run tries again.
    if ! mkdir -p "$dir" || ! printf '%s\n' "$conf" > "$file.new" \
        || { test -f "$file" && ! cp "$file" "$file.old"; } || ! mv "$file.new" "$file"; then
        echo "apply-input.sh: couldn't write $file" >&2
        rm -f "$file.new" "$file.old"
        return 1
    fi
    if ! result=$(tide-msg reload 2>&1); then
        echo "apply-input.sh: tidewm couldn't reload with $file, so it's as it was: $result" >&2
        if test -f "$file.old"; then
            mv "$file.old" "$file" || echo "apply-input.sh: couldn't put back $file.old" >&2
        else
            rm -f "$file" || echo "apply-input.sh: couldn't remove $file" >&2
        fi
        return 1
    fi
    rm -f "$file.old"
    return $status
}

case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:tidewm:*)
        apply_tidewm
        exit
        ;;
esac

command -v hyprctl >/dev/null 2>&1 || exit 0

if ! devices=$(hyprctl devices -j); then
    echo "apply-input.sh: hyprctl devices -j failed" >&2
    exit 1
fi

# The device names in one array of hyprctl devices -j: "mice" or
# "keyboards". Prefer jq; fall back to a narrow sed window so another array's
# names aren't picked up.
device_names() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$devices" | jq -r ".$1[].name"
    else
        printf '%s\n' "$devices" \
            | sed -n "/\"$1\"/,/\\]/p" \
            | grep -o '"name": *"[^"]*"' \
            | cut -d'"' -f4
    fi
}
if ! names=$(device_names mice) || ! keyboards=$(device_names keyboards); then
    echo "apply-input.sh: couldn't read the mice and keyboards hyprctl devices -j lists" >&2
    exit 1
fi

# Iterate line by line -- device names contain spaces before Hyprland's
# lowercasing/hyphenation on some setups, so don't split on spaces.
status=0
IFS='
'
for name in $names; do
    test -n "$name" || continue
    if is_touchpad "$name"; then
        # Touchpad: tide's touchpad speed and handedness, through
        # hyprland.lua's conf_input.touchpad(), which leaves alone what
        # hyprland.local.lua set for the device.
        lua_name=$(printf '%s' "$name" | sed 's/[\\"]/\\&/g')
        result=$(hyprctl eval "conf_input.touchpad(\"$lua_name\")" 2>&1)
        if test "$result" != ok; then
            echo "apply-input.sh: couldn't configure touchpad '$name': $result" >&2
            status=1
        fi
    else
        # Mouse: its handedness and wheel speed, through
        # hyprland.lua's conf_input.mouse(), which leaves alone what
        # hyprland.local.lua set for the device. The Lua config has no
        # keyword command, so this is an eval, with the name escaped
        # for a Lua string.
        lua_name=$(printf '%s' "$name" | sed 's/[\\"]/\\&/g')
        result=$(hyprctl eval "conf_input.mouse(\"$lua_name\", $MOUSE_SCROLL)" 2>&1)
        if test "$result" != ok; then
            echo "apply-input.sh: couldn't configure mouse '$name': $result" >&2
            status=1
        fi
    fi
done
# Keyboards: tide's keyboard settings, through hyprland.lua's
# conf_input.keyboard(), which leaves alone what hyprland.local.lua set for
# the keyboard.
for name in $keyboards; do
    test -n "$name" || continue
    lua_name=$(printf '%s' "$name" | sed 's/[\\"]/\\&/g')
    result=$(hyprctl eval "conf_input.keyboard(\"$lua_name\")" 2>&1)
    if test "$result" != ok; then
        echo "apply-input.sh: couldn't configure keyboard '$name': $result" >&2
        status=1
    fi
done
exit $status
