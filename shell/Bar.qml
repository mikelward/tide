import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "lib/title.mjs" as Title

// One bar per monitor (SPEC.md §7.1): a plain rectangle flush with the top
// edge and both sides, its exclusive zone keeping tiling below it. Its
// layer is named tide-bar, which `tide doctor` looks for to tell the space
// it reserves from another bar's.
PanelWindow {
    id: bar

    required property var modelData
    readonly property var monitor: Hyprland.monitorFor(bar.screen)

    screen: modelData
    WlrLayershell.namespace: "tide-bar"
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight
    color: Theme.barBg

    Workspaces {
        id: workspaces

        anchors.left: parent.left
        anchors.leftMargin: 5
        anchors.verticalCenter: parent.verticalCenter
        monitorName: bar.monitor?.name ?? ""
    }

    LayoutSymbol {
        id: layoutSymbol

        anchors.left: workspaces.right
        anchors.leftMargin: 7
        anchors.verticalCenter: parent.verticalCenter
        monitor: bar.monitor
    }

    // Centered on the bar, and no wider than the room between the left and
    // right groups allows on both sides, so it stays centered.
    WindowTitle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Title.titleWidth({
            implicit: implicitWidth,
            max: maxWidth,
            barWidth: bar.width,
            left: layoutSymbol.x + layoutSymbol.width,
            right: sharing.x,
            gap: 32
        })
        monitor: bar.monitor
    }

    // Privacy pills come first on the right (§7.1).
    SharingPill {
        id: sharing

        anchors.right: mic.left
        anchors.rightMargin: visible ? 4 : 0
        anchors.verticalCenter: parent.verticalCenter
    }

    MicPill {
        id: mic

        anchors.right: tray.left
        anchors.rightMargin: visible ? 10 : 0
        anchors.verticalCenter: parent.verticalCenter
    }

    Tray {
        id: tray

        anchors.right: statusIcons.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
    }

    StatusIcons {
        id: statusIcons

        monitorName: bar.monitor?.name ?? ""
        anchors.right: clocks.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
    }

    // Only local's clock when the title would otherwise be squeezed
    // (SPEC.md §7.3, Title.collapseClocks).
    Clocks {
        id: clocks

        compact: Title.collapseClocks({
            barWidth: bar.width,
            left: layoutSymbol.x + layoutSymbol.width,
            right: sharing.x,
            gap: 32,
            clocksWidth: clocks.width,
            fullClocksWidth: clocks.fullWidth
        })
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
    }

    // The bar is in the notification center's focus grab, so the bell can
    // close it rather than a press outside closing it and the bell's tap
    // reopening it. Any other press on the bar closes it, as outside the
    // center. A PointHandler only watches, so the press still reaches the
    // control under it.
    Item {
        anchors.fill: parent
        z: 1

        PointHandler {
            acceptedButtons: Qt.AllButtons
            onActiveChanged: {
                if (active && !statusIcons.onBell(point.scenePosition)) {
                    HistoryData.close();
                }
            }
        }
    }

    // Keep awake (SPEC.md §10): every bar holds one while it's on, so it
    // holds on whichever monitors are lit.
    IdleInhibitor {
        window: bar
        enabled: KeepAwakeData.on
    }

    // Only while the shell is the notification server (NotificationData).
    LazyLoader {
        active: NotificationData.enabled

        NotificationCenter {
            panel: bar
        }
    }
}
