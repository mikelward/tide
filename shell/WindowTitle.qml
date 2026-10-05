import QtQuick
import Quickshell.Hyprland
import Quickshell.Io
import "lib/dispatch.mjs" as Dispatch
import "lib/title.mjs" as Title
import "lib/workspaces.mjs" as Ws

// The window title in the middle of this monitor's bar (SPEC.md §7.1):
// the focused window's when it's on this monitor, else nothing, from
// shell/lib/title.mjs.
Text {
    id: root

    // This bar's HyprlandMonitor.
    required property var monitor

    // About Title.MAX_TITLE characters wide, as waybar's max-length had
    // it. Past that, and past the room Bar.qml gives it, the text elides,
    // which Qt does only between whole characters.
    readonly property real maxWidth: metrics.averageCharacterWidth * Title.MAX_TITLE

    FontMetrics {
        id: metrics

        font: root.font
    }

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
                    console.warn("tide: bar title: hyprctl activewindow gave no window; the title waits for the next focus change");
                    return;
                }
                root.startAddress = address ?? "";
            }
        }
        onStarted: started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: bar title: hyprctl activewindow exited ${code}`);
            }
        }
        onRunningChanged: {
            if (!running && !started) {
                console.warn("tide: bar title: couldn't start hyprctl; it waits for the next focus change");
            }
        }
    }

    // The window the title stands for, {address, title}, or null.
    readonly property var window: Title.barWindow({
        monitor: root.monitor?.name ?? null,
        active: root.active ? {
            monitor: root.active.monitor?.name ?? null,
            address: root.active.address,
            title: root.active.title
        } : null
    })

    text: root.window?.title ?? ""

    // Double-clicking it toggles maximize on that window, like a title
    // bar (SPEC.md §7.1). It's always the focused window, so the dispatch
    // needs no address.
    TapHandler {
        onDoubleTapped: {
            if (root.window) {
                Hyprland.dispatch(Dispatch.toggleMaximize(Hyprland.usingLua));
            }
        }
    }
    // Titles come from apps: never markup.
    textFormat: Text.PlainText
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignHCenter
    color: Theme.fg
    font.family: Theme.font
    font.pixelSize: 13
}
