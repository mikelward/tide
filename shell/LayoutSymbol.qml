import QtQuick
import Quickshell.Hyprland
import "lib/barsettings.mjs" as BarSettings
import "lib/layouts.mjs" as Layouts
import "lib/tidewm.mjs" as Tw

// The layout of the workspace shown on this bar's monitor (SPEC.md §6.1,
// §7.1): its symbol, or `[n]` in monocle with n windows hidden. On
// tidewm, from its layout events and outputs (Tw.barSymbol).
Text {
    id: root

    // This bar's HyprlandMonitor, or null on tidewm.
    required property var monitor
    // This bar's screen's name, its output's, which is all tidewm's needs.
    required property string screenName

    readonly property var workspace: monitor?.activeWorkspace ?? null
    readonly property string mode: {
        if (Compositor.tidewm || !root.workspace || !root.monitor) {
            return "";
        }
        return LayoutData.modes[root.workspace.id] ?? Layouts.defaultMode({
            width: root.monitor.width,
            height: root.monitor.height,
            scale: root.monitor.scale,
            transform: root.monitor.lastIpcObject?.transform ?? 0,
        }, Theme.barHeight, LayoutsData.effective);
    }
    readonly property int tiled: Compositor.tidewm ? 0 : Hyprland.toplevels.values.filter(t => t.workspace === root.workspace && !t.lastIpcObject?.floating).length

    text: Compositor.tidewm
        ? Tw.barSymbol({
            heard: LayoutData.tidewmHeard,
            output: Compositor.tidewmOutputs.find(o => o?.name === root.screenName) ?? null,
            current: Compositor.tidewmListed.find(w => w?.focused === true) ?? null,
            tiled: Tw.tiledOn(Compositor.windows, Compositor.tidewmCurrentName, root.screenName),
            layouts: LayoutsData.effective
        })
        : Layouts.layoutSymbol(root.mode, root.tiled)
    color: Theme.fgDim
    font.family: Theme.monoFont
    font.pixelSize: 14
    font.weight: Font.Medium
    font.letterSpacing: -0.27

    // A right-click opens its settings page (SPEC.md §7.1); it takes no
    // other click.
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: SettingsData.open(BarSettings.page("layout"))
    }
}
