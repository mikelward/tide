// Qt picks an icon theme only for a desktop it knows, and tide's
// (XDG_CURRENT_DESKTOP=tide:Hyprland) isn't one: without this, no theme
// icon loads, so symbolic icons are blank and app icons placeholders.
// Quickshell reads pragmas only above the first import (SPEC.md §15).
//@ pragma IconTheme Adwaita
import QtQuick
import Quickshell
import Quickshell.Hyprland

// tide's shell (SPEC.md §3.2): for now, the bar, the OSD and the
// notification popups (opt-in; see NotificationData.qml) on every monitor,
// and the launcher.
ShellRoot {
    Variants {
        model: Quickshell.screens

        Bar {}
    }

    Variants {
        model: Quickshell.screens

        Osd {}
    }

    Variants {
        model: Quickshell.screens

        NotificationPopups {}
    }

    // One launcher, which moves to the focused monitor as it opens.
    LauncherWindow {}

    // A toplevel's class and fullscreen state come from Hyprland's client
    // list, which Quickshell reads on request; ask again when they change.
    Connections {
        target: Hyprland

        // Windows that were open before the shell started need it too.
        Component.onCompleted: {
            Hyprland.refreshToplevels();
            Hyprland.refreshWorkspaces();
            Hyprland.refreshMonitors();
        }

        function onRawEvent(event) {
            if (["openwindow", "closewindow", "movewindowv2", "fullscreen", "changefloatingmode"].includes(event.name)) {
                Hyprland.refreshToplevels();
            }
            // Each workspace's last focused window, for the bar's title.
            if (["activewindowv2", "openwindow", "closewindow", "movewindowv2"].includes(event.name)) {
                Hyprland.refreshWorkspaces();
            }
            // Which special workspace each monitor shows, for the same.
            if (["activespecial", "activespecialv2"].includes(event.name)) {
                Hyprland.refreshMonitors();
            }
        }
    }
}
