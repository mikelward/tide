#!/bin/bash
# A spike (not a test): can Arch's packaged Hyprland and Quickshell run in a
# container on a GitHub runner, given the runner's vkms device? Each stage
# says PASS or FAIL and carries on, so one run answers every question.
set -u
pass() { echo "::notice::PASS $*"; }
fail() { echo "::error::FAIL $*"; }
stage() { echo "::group::$*"; }
end() { echo "::endgroup::"; }

stage "1. packages"
if pacman -Syu --noconfirm --needed hyprland quickshell mesa jq qt6-wayland >/tmp/pacman.log 2>&1; then
    pass "installed $(pacman -Q hyprland quickshell | tr '\n' ' ')"
else
    tail -30 /tmp/pacman.log
    fail "pacman couldn't install hyprland and quickshell"
fi
end

stage "2. Hyprland starts"
export XDG_RUNTIME_DIR=/tmp/run
mkdir -m 700 -p "$XDG_RUNTIME_DIR"
export LIBSEAT_BACKEND=noop
ls -l /dev/dri || true
for dev in /sys/class/drm/card*; do echo "$dev: $(readlink -f "$dev/device/driver" 2>/dev/null)"; done
: > /tmp/empty.lua
vkms=
# vkms is a faux device on newer kernels, so it's found by its path, not
# its driver's name.
for dev in /sys/class/drm/card[0-9]; do
    case "$(readlink -f "$dev")" in */vkms/*) vkms=/dev/dri/${dev##*/} ;; esac
done
echo "vkms is ${vkms:-not found}"
if test -z "$vkms"; then
    fail "no vkms device to give Hyprland"
fi
# Each try: a name, then the environment it adds. The first that starts wins.
up=
for try in \
    "vkms+kms_swrast|AQ_DRM_DEVICES=$vkms MESA_LOADER_DRIVER_OVERRIDE=kms_swrast" \
    "vkms+software|AQ_DRM_DEVICES=$vkms LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe" \
    "vkms+swrast-gbm|AQ_DRM_DEVICES=$vkms MESA_LOADER_DRIVER_OVERRIDE=kms_swrast LIBGL_ALWAYS_SOFTWARE=1 GBM_BACKEND=dri"; do
    name=${try%%|*}
    rm -rf "$XDG_RUNTIME_DIR/hypr"
    # shellcheck disable=SC2086 # the try's words are separate variables
    env ${try#*|} Hyprland --i-am-really-stupid -c /tmp/empty.lua >"/tmp/hyprland-$name.log" 2>&1 &
    hypr=$!
    for _ in $(seq 40); do
        if hyprctl version >/dev/null 2>&1; then up=$name; break; fi
        kill -0 "$hypr" 2>/dev/null || break
        sleep 0.5
    done
    if test -n "$up"; then
        break
    fi
    echo "--- $name didn't start:"
    grep -E 'ERR|CRIT|renderer|EGL' "/tmp/hyprland-$name.log" | grep -v eglQueryDeviceStringEXT | sort -u | head -15
    find "$XDG_RUNTIME_DIR/hypr" -name hyprland.log -exec grep -E 'ERR|CRIT' {} + 2>/dev/null | sort -u | head -15
    kill "$hypr" 2>/dev/null; wait "$hypr" 2>/dev/null
done
if test -n "$up"; then
    pass "Hyprland is up with $up: $(hyprctl version | head -1)"
    hyprctl monitors | head -5
else
    fail "Hyprland didn't start with any of the tries"
fi
end

if test -n "$up"; then
    stage "3. a named workspace"
    hyprctl dispatch 'hl.dsp.focus({ workspace = "name:docs" })'
    active=$(hyprctl activeworkspace -j)
    echo "$active"
    if test "$(printf '%s' "$active" | jq -r .name)" = docs; then
        pass "went to a named workspace; its id is $(printf '%s' "$active" | jq -c '.id // "none"'), its address $(printf '%s' "$active" | jq -c '.address // "none"')"
    else
        fail "didn't go to the named workspace"
    fi
    end

    stage "4. Quickshell sees it"
    qs -p /tide/ci/hyprland-spike/probe.qml >/tmp/qs.log 2>&1 &
    seen=
    for _ in $(seq 40); do
        if out=$(qs -p /tide/ci/hyprland-spike/probe.qml ipc call probe focused 2>/dev/null) && test -n "$out"; then seen=$out; break; fi
        sleep 0.5
    done
    qs -p /tide/ci/hyprland-spike/probe.qml ipc call probe workspaces 2>&1 || true
    if test "$seen" = "docs|docs"; then
        pass "Quickshell follows the named workspace: $seen"
    else
        tail -30 /tmp/qs.log
        fail "Quickshell's focused workspace is ${seen:-unknown}, not docs"
    fi
    end

    stage "5. tide's config loads"
    mkdir -p "$HOME/.config/hypr/tide"
    cp -r /tide/hypr/tide/. "$HOME/.config/hypr/tide/"
    cp /tide/hypr/hyprland.lua "$HOME/.config/hypr/tide/hyprland.lua"
    hyprctl kill >/dev/null 2>&1 || true
    kill "$hypr" 2>/dev/null; wait "$hypr" 2>/dev/null
    winner=$(printf '%s\n' "vkms+kms_swrast|AQ_DRM_DEVICES=$vkms MESA_LOADER_DRIVER_OVERRIDE=kms_swrast" \
        "vkms+software|AQ_DRM_DEVICES=$vkms LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe" \
        "vkms+swrast-gbm|AQ_DRM_DEVICES=$vkms MESA_LOADER_DRIVER_OVERRIDE=kms_swrast LIBGL_ALWAYS_SOFTWARE=1 GBM_BACKEND=dri" \
        | grep "^$up|" | cut -d'|' -f2)
    # shellcheck disable=SC2086
    env $winner Hyprland --i-am-really-stupid -c "$HOME/.config/hypr/tide/hyprland.lua" >/tmp/tide-hyprland.log 2>&1 &
    hypr=$!
    up=
    for _ in $(seq 60); do
        if hyprctl version >/dev/null 2>&1; then up=1; break; fi
        kill -0 "$hypr" 2>/dev/null || break
        sleep 0.5
    done
    if test -n "$up"; then
        errors=$(hyprctl configerrors)
        echo "config errors: ${errors:-none}"
        hyprctl eval 'conf_workspaces.go("docs")'
        name=$(hyprctl activeworkspace -j | jq -r .name)
        if test -z "$errors" && test "$name" = docs; then
            pass "tide's config loads, and conf_workspaces.go reaches a named workspace"
        else
            fail "tide's config: errors '${errors}', active workspace '${name}'"
        fi
    else
        tail -60 /tmp/tide-hyprland.log
        fail "Hyprland didn't start with tide's config"
    fi
    end
fi
