pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/title.mjs" as Title
import "lib/workspaces.mjs" as Ws

// The focused window, for every part of the shell that needs it: the bar's
// title (WindowTitle.qml), the picker's paste (PickerWindow.qml) and the
// launcher's screenshot (LauncherWindow.qml). On tidewm it's
// Compositor.qml's. Hyprland.activeToplevel alone gets two cases wrong on
// Quickshell 0.3
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
    readonly property var active: Compositor.tidewm ? null : root.focusGone ? null : (Hyprland.activeToplevel ?? root.startFocus)
    // The focused window as plain data, on either compositor, or null:
    // {address, title, monitor, app}, monitor being its monitor's name.
    readonly property var focused: Compositor.tidewm
        ? (Compositor.tidewmActive ? {
            address: Compositor.tidewmActive.address,
            title: Compositor.tidewmActive.title,
            monitor: Compositor.tidewmActive.monitor,
            app: Compositor.tidewmActive.app
        } : null)
        : (root.active ? {
            address: Ws.normalizeAddress(root.active.address),
            title: root.active.title ?? "",
            monitor: root.active.monitor?.name ?? null,
            app: root.active.lastIpcObject?.class || root.active.wayland?.appId || ""
        } : null)

    Connections {
        target: Compositor.tidewm ? null : Hyprland

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
        running: !Compositor.tidewm

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
