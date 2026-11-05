// Which compositor the session runs (SPEC.md §5.3), for Compositor.qml.
// Hyprland's session is the default; tidewm's names tidewm first in
// XDG_CURRENT_DESKTOP (session/tide-tidewm.desktop's DesktopNames), which
// is what bin/tide's in_tidewm reads too.

// Whether `desktop`, XDG_CURRENT_DESKTOP's value, is tidewm's session:
// tidewm is one of its colon-separated names, as the desktop entry spec
// reads them.
export function isTidewm(desktop) {
    return String(desktop ?? "").split(":").indexOf("tidewm") >= 0;
}

// The screen in `screens` named `name`, or null. A monitor's name is its
// Wayland output's, on Hyprland and tidewm alike, and so is a screen's.
export function screenNamed(screens, name) {
    if (!name) {
        return null;
    }
    for (const s of Array.from(screens ?? [])) {
        if (s && s.name === name) {
            return s;
        }
    }
    return null;
}
