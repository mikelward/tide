pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/title.mjs" as Title
import "lib/workspaces.mjs" as Ws

// The focused window, for every part of the shell that needs it: the bar's
// title (WindowTitle.qml) and the picker's paste (PickerWindow.qml).
// Hyprland.activeToplevel alone gets two cases wrong on Quickshell 0.3
// (shell/lib/title.mjs): after focus moves to an empty workspace it still
// names the last window, and until the first focus change after the shell
// starts it's null.
Singleton {
    id: root

    // Nothing has focus after focus moves to an empty workspace, which
    // Hyprland.activeToplevel doesn't show (Title.hasFocus).
    property bool focusGone: false
    // Hyprland.activeToplevel stays null until the first activewindowv2
    // event, so until then the focused window is the one `hyprctl
    // activewindow -j` names when the shell starts (Title.activeAtStart).
    property bool focusSeen: false
    property string startAddress: ""
    readonly property var startFocus: {
        if (root.focusSeen || root.startAddress === "") {
            return null;
        }
        return Hyprland.toplevels.values.find(t => Ws.normalizeAddress(t.address) === root.startAddress) ?? null;
    }
    readonly property var active: root.focusGone ? null : (Hyprland.activeToplevel ?? root.startFocus)

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "activewindowv2") {
                root.focusSeen = true;
                root.focusGone = !Title.hasFocus(event.data);
            }
        }
    }

    Process {
        id: activeWindow

        // Quickshell reports a command that can't start (no hyprctl on
        // PATH) only by stopping without `started` (shell/lib/launch.mjs).
        property bool started: false

        command: ["hyprctl", "activewindow", "-j"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: {
                const address = Title.activeAtStart(text);
                if (address === undefined) {
                    console.warn("tide: focus: hyprctl activewindow gave no window; the focused window is known at the next focus change");
                    return;
                }
                root.startAddress = address ?? "";
            }
        }
        onStarted: started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: focus: hyprctl activewindow exited ${code}`);
            }
        }
        onRunningChanged: {
            if (!running && !started) {
                console.warn("tide: focus: couldn't start hyprctl; the focused window is known at the next focus change");
            }
        }
    }
}
