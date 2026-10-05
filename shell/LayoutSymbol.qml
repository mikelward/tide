import QtQuick
import Quickshell.Hyprland
import "lib/layouts.mjs" as Layouts

// The layout of the workspace shown on this bar's monitor (SPEC.md §6.1,
// §7.1): its symbol, or `[n]` in monocle with n windows hidden.
Text {
    id: root

    // This bar's HyprlandMonitor.
    required property var monitor

    readonly property var workspace: monitor?.activeWorkspace ?? null
    readonly property string mode: {
        if (!root.workspace || !root.monitor) {
            return "";
        }
        return LayoutData.modes[root.workspace.id] ?? Layouts.defaultMode({
            width: root.monitor.width,
            height: root.monitor.height,
            scale: root.monitor.scale,
            transform: root.monitor.lastIpcObject?.transform ?? 0,
        }, Theme.barHeight);
    }
    readonly property int tiled: Hyprland.toplevels.values.filter(t => t.workspace === root.workspace && !t.lastIpcObject?.floating).length

    text: Layouts.layoutSymbol(root.mode, root.tiled)
    color: Theme.fgDim
    font.family: Theme.monoFont
    font.pixelSize: 14
    font.weight: Font.Medium
    font.letterSpacing: -0.27
}
