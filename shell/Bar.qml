import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "lib/barclick.mjs" as Click
import "lib/title.mjs" as Title

// One bar per monitor (SPEC.md §7.1): a plain rectangle flush with the top
// edge and both sides, its exclusive zone keeping tiling below it. Its
// layer is named tide-bar, which `tide doctor` looks for to tell the space
// it reserves from another bar's.
PanelWindow {
    id: bar

    required property var modelData
    readonly property var monitor: Hyprland.monitorFor(bar.screen)

    // How far each click target on the right reaches past its ends: the
    // gaps between them split, so none is dead, whatever their spacing.
    readonly property var reaches: Click.chainReaches([presenter, sharing, mic, tray, statusIcons, clocks].map(item => ({
        left: item.x,
        right: item.x + item.width,
        shown: item.visible
    })), { end: bar.width })

    screen: modelData
    WlrLayershell.namespace: "tide-bar"
    // Only while a popover is open, so a click into one (the network
    // password) can take the keyboard; otherwise hovering the bar would.
    WlrLayershell.keyboardFocus: PopoverData.open !== null ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight
    color: Theme.barBg

    // How far the wave logo and the workspaces reach past their ends: the
    // logo out to the bar's left edge, and the gap between them split.
    readonly property var leftReaches: Click.chainReaches([logo, workspaces].map(item => ({
        left: item.x,
        right: item.x + item.width,
        shown: item.visible
    })), { start: 0 })

    // tide's logo, two waves, first on the left (§7.1): a tap opens the
    // launcher on this monitor, or closes it.
    SymbolicIcon {
        id: logo

        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        file: "tide-symbolic.svg"
        color: Theme.accent

        BarHit {
            reach: bar.leftReaches[0]

            TapHandler {
                onTapped: LauncherData.toggle(bar.screen)
            }
        }
    }

    Workspaces {
        id: workspaces

        anchors.left: logo.right
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        monitorName: bar.monitor?.name ?? ""
        // The layout symbol after it isn't a target.
        reach: bar.leftReaches[1]
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
            right: presenter.x,
            gap: 32
        })
        monitor: bar.monitor
    }

    // Presenter mode's pill, then the privacy pills, come first on the
    // right (§7.1).
    PresenterPill {
        id: presenter

        reach: bar.reaches[0]
        anchors.right: sharing.left
        anchors.rightMargin: visible ? 4 : 0
        anchors.verticalCenter: parent.verticalCenter
    }

    SharingPill {
        id: sharing

        reach: bar.reaches[1]
        anchors.right: mic.left
        anchors.rightMargin: visible ? 4 : 0
        anchors.verticalCenter: parent.verticalCenter
    }

    MicPill {
        id: mic

        reach: bar.reaches[2]
        anchors.right: tray.left
        anchors.rightMargin: visible ? 10 : 0
        anchors.verticalCenter: parent.verticalCenter
    }

    Tray {
        id: tray

        reach: bar.reaches[3]
        anchors.right: statusIcons.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
    }

    StatusIcons {
        id: statusIcons

        reach: bar.reaches[4]
        monitorName: bar.monitor?.name ?? ""
        anchors.right: clocks.left
        // With a clock's own 5 px, the session icon sits as far from the
        // first clock as the status items sit from each other (§7.4).
        anchors.rightMargin: 5
        anchors.verticalCenter: parent.verticalCenter
    }

    // Only local's clock when the title would otherwise be squeezed
    // (SPEC.md §7.3, Title.collapseClocks).
    Clocks {
        id: clocks

        reach: bar.reaches[5]
        compact: Title.collapseClocks({
            barWidth: bar.width,
            left: layoutSymbol.x + layoutSymbol.width,
            right: presenter.x,
            gap: 32,
            clocksWidth: clocks.width,
            fullClocksWidth: clocks.fullWidth
        })
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
    }

    // Every bar is in the notification center's focus grab, so the bell
    // can close it rather than a press outside closing it and the bell's
    // tap reopening it, and a press on another monitor's bar reaches it.
    // Any press but the bell's closes it, as outside the center. Every bar
    // is in a popover's grab too, and a press closes the popover the same
    // way unless it's on the popover's own target (PopoverData.pressed). A PointHandler only watches, so the press
    // still reaches the control under it.
    Item {
        readonly property var barWindow: QsWindow.window

        anchors.fill: parent
        z: 1

        PointHandler {
            acceptedButtons: Qt.AllButtons
            onActiveChanged: {
                if (active && Click.closesOnPress(HistoryData.openOn !== "", statusIcons.onBell(point.scenePosition))) {
                    HistoryData.close();
                }
                if (active) {
                    PopoverData.pressed(parent.barWindow, point.scenePosition);
                }
            }
        }
    }

    Component.onCompleted: PopoverData.addBar(bar)
    Component.onDestruction: PopoverData.removeBar(bar)

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
