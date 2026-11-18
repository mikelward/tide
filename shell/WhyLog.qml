import QtQuick
import Quickshell
import Quickshell.Hyprland
import "lib/why.mjs" as Why

// What `tide report-bug` reads besides the moves the shell asks for
// (SPEC.md §5.4, Reporting a bug): a journal line for each workspace that
// comes up, whatever brought it, and on tidewm, for each window that takes
// focus. Hyprland's focus changes are the focus guard's to log, with
// Hyprland's reason for each (hypr/tide/focus.lua); tidewm's reasons are
// its own, so the shell logs what it sees.
Scope {
    id: root

    readonly property string current: Compositor.tidewm
        ? Compositor.tidewmCurrentName
        : (Hyprland.focusedMonitor?.activeWorkspace?.name ?? "")
    property string lastWorkspace: ""
    readonly property var focused: Compositor.tidewm ? FocusData.focused : null
    property var lastFocused: null

    onCurrentChanged: {
        const line = Why.workspaceShown(root.lastWorkspace, root.current);
        if (line !== null) {
            console.log(line);
        }
        root.lastWorkspace = root.current;
    }

    onFocusedChanged: {
        if (!Compositor.tidewm) {
            return;
        }
        const line = Why.focusMoved(root.lastFocused, root.focused, root.current);
        if (line !== null) {
            console.log(line);
        }
        root.lastFocused = root.focused;
    }
}
