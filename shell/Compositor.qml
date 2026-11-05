pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import "lib/compositor.mjs" as Comp

// What the shell asks of the compositor the session runs (SPEC.md §5.3):
// Hyprland's, the default, through Quickshell's Hyprland module, or
// tidewm's, through its I3 module, which speaks sway's IPC as tidewm does.
// Each binding reads only the one in use, so the other isn't asked. It
// says which monitor has focus, for the popups, prompts and launcher that
// open there.
Singleton {
    id: root

    readonly property bool tidewm: Comp.isTidewm(Quickshell.env("XDG_CURRENT_DESKTOP"))
    // The focused monitor's name, its Wayland output's, or "" before one
    // has focus. tidewm says when focus moves to another monitor in an
    // output event, which has the I3 module ask for the outputs again.
    readonly property string focusedMonitorName: (root.tidewm ? I3.focusedMonitor?.name : Hyprland.focusedMonitor?.name) ?? ""
    // The screen of the focused monitor, or null.
    readonly property var focusedScreen: Comp.screenNamed(Quickshell.screens, root.focusedMonitorName)
}
