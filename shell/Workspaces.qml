import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Widgets
import "lib/barclick.mjs" as Click
import "lib/dispatch.mjs" as Dispatch
import "lib/workspaces.mjs" as Ws

// Every workspace on one monitor's bar, by name (SPEC.md §6.5, §7.2): the
// standing ones first, home first, then the rest in the order they were
// made, each with an app icon only for a window wanting attention.
// shell/lib/workspaces.mjs decides what each shows; this only draws
// it and sends clicks to Hyprland, which makes a standing workspace that
// isn't made yet as it's clicked.
Row {
    id: root

    // This bar's monitor, as Hyprland names it.
    required property string monitorName
    // How far the click targets at the ends reach past them (Bar.qml).
    property var reach: ({ left: Click.PAD, right: Click.PAD })

    spacing: 3

    readonly property var monitors: Hyprland.monitors.values.map(m => ({
        name: m.name,
        workspace: m.activeWorkspace ? m.activeWorkspace.id : null,
    }))
    readonly property var workspaces: Hyprland.workspaces.values.map(w => ({
        id: w.id,
        name: w.name,
    }))
    readonly property var windows: Hyprland.toplevels.values.map(t => ({
        address: Ws.normalizeAddress(t.address),
        workspace: t.workspace ? t.workspace.id : null,
        workspaceName: t.workspace?.name ?? "",
        app: t.lastIpcObject?.class || t.wayland?.appId || "",
        urgent: t.urgent,
        fullscreen: t.lastIpcObject?.fullscreen ?? 0,
    }))
    // Hyprland's own urgent flag, and the focus guard's and notifications'
    // marks (MarkData).
    readonly property var list: Ws.barWorkspaces({
        monitor: root.monitorName,
        monitors: root.monitors,
        workspaces: root.workspaces,
        windows: root.windows,
        marks: MarkData.marks,
        standing: WorkspacesData.standing,
        // A muted app's windows are never marked (SPEC.md §9, Muted apps).
        muted: WorkspacesData.muted,
    })
    readonly property var current: root.monitors.find(m => m.name === root.monitorName)?.workspace ?? null

    Repeater {
        model: root.list

        Rectangle {
            id: chip

            required property var modelData
            readonly property bool empty: modelData.state === "empty"
            readonly property color ink: modelData.urgent ? Theme.urgent
                : modelData.state === "current" ? Theme.accentFg
                : empty ? Theme.fgFaint : Theme.fg

            height: Theme.chipHeight
            width: Math.max(empty ? 24 : 28, content.implicitWidth + (empty ? 8 : 14))
            radius: Theme.chipRadius
            color: modelData.urgent ? Theme.urgentBg
                : modelData.state === "current" ? Theme.accentBg
                : empty ? "transparent" : Theme.surface
            border.width: modelData.urgent || modelData.state === "elsewhere" ? 1.5 : 0
            border.color: modelData.urgent ? Theme.urgentRing : Theme.accent

            // First, so its hover goes over the chip's fill and under its
            // name and icons, whose own targets are over it.
            BarHit {
                reach: Click.groupReach({
                    x: chip.x,
                    width: chip.width,
                    groupWidth: root.width,
                    spacing: root.spacing,
                    left: root.reach.left,
                    right: root.reach.right
                })
                behind: false

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onClicked: Hyprland.dispatch(Dispatch.focusWorkspaceName(chip.modelData.name, Hyprland.usingLua))
                }
            }

            Row {
                id: content

                anchors.centerIn: parent
                spacing: 5

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    // A name is whatever was typed: plain text, never markup.
                    textFormat: Text.PlainText
                    text: chip.modelData.label
                    color: chip.ink
                    font.family: Theme.font
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }

                Repeater {
                    model: chip.modelData.icons

                    Rectangle {
                        id: icon

                        required property var modelData

                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        radius: 4
                        color: "transparent"
                        border.width: icon.modelData.marked ? 2 : 0
                        border.color: Theme.urgentRing

                        IconImage {
                            anchors.fill: parent
                            anchors.margins: icon.modelData.marked ? 2 : 0
                            source: Quickshell.iconPath(
                                DesktopEntries.heuristicLookup(icon.modelData.app)?.icon ?? icon.modelData.app,
                                "application-x-executable")
                        }

                        // A click focuses that window (SPEC.md §7.2), which
                        // clears its mark, or restores a minimized one
                        // (§6.7); the chip's own click, under it, doesn't
                        // fire as well.
                        BarHit {
                            reach: ({ left: 2, right: 2 })
                            targetHeight: icon.height + 4

                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton
                                onClicked: Hyprland.dispatch(icon.modelData.restoreTo !== null
                                    ? Dispatch.moveWindowToWorkspace(icon.modelData.address, icon.modelData.restoreTo, Hyprland.usingLua)
                                    : Dispatch.focusWindow(icon.modelData.address, Hyprland.usingLua))
                            }
                        }
                    }
                }

                Text {
                    visible: chip.modelData.more > 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: `+${chip.modelData.more}`
                    color: chip.ink
                    font.family: Theme.font
                    font.pixelSize: 11
                }
            }

            // The corner glyph for a maximized or fullscreen window (SPEC.md §6.3).
            Rectangle {
                visible: chip.modelData.big
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.margins: 3
                width: 5
                height: 5
                radius: 1
                color: chip.ink
            }

            // The urgent dot.
            Rectangle {
                visible: chip.modelData.urgent
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 3
                width: 6
                height: 6
                radius: 3
                color: Theme.urgentRing
            }
        }
    }

    // Scrolling steps through the workspaces in the bar's order, one per
    // notch, stopping at either end (SPEC.md §7.2); touchpads' small deltas add up to a notch,
    // and what's left over counts toward the next.
    property real wheel: 0

    WheelHandler {
        onWheel: event => {
            root.wheel -= event.angleDelta.y;
            const notches = Math.trunc(root.wheel / 120);
            if (notches === 0) {
                return;
            }
            root.wheel -= notches * 120;
            const target = Ws.scrollTarget(root.list, root.current, notches);
            if (target !== null) {
                Hyprland.dispatch(Dispatch.focusWorkspaceName(target, Hyprland.usingLua));
            }
        }
    }
}
