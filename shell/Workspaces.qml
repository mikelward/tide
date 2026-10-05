import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Widgets
import "lib/dispatch.mjs" as Dispatch
import "lib/workspaces.mjs" as Ws

// Workspaces 1-9 on one monitor's bar (SPEC.md §7.2). shell/lib/workspaces.mjs
// decides what each shows; this only draws it and sends clicks to Hyprland.
Row {
    id: root

    // This bar's monitor, as Hyprland names it.
    required property string monitorName

    spacing: 3

    readonly property var monitors: Hyprland.monitors.values.map(m => ({
        name: m.name,
        workspace: m.activeWorkspace ? m.activeWorkspace.id : null,
    }))
    readonly property var windows: Hyprland.toplevels.values.map(t => ({
        address: Ws.normalizeAddress(t.address),
        workspace: t.workspace ? t.workspace.id : null,
        app: t.lastIpcObject?.class || t.wayland?.appId || "",
        urgent: t.urgent,
        fullscreen: t.lastIpcObject?.fullscreen ?? 0,
    }))
    // Hyprland's own urgent flag, and the focus guard's and notifications'
    // marks (MarkData).
    readonly property var list: Ws.barWorkspaces({
        monitor: root.monitorName,
        monitors: root.monitors,
        windows: root.windows,
        marks: MarkData.marks,
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

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onClicked: Hyprland.dispatch(Dispatch.focusWorkspace(chip.modelData.id, Hyprland.usingLua))
            }

            Row {
                id: content

                anchors.centerIn: parent
                spacing: 5

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: chip.modelData.id
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

                        // Middle-click focuses that window (SPEC.md §7.2).
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.MiddleButton
                            onClicked: Hyprland.dispatch(Dispatch.focusWindow(icon.modelData.address, Hyprland.usingLua))
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

    // Scrolling steps through the workspaces, one per notch, stopping at
    // 1 and 9 (SPEC.md §7.2); touchpads' small deltas add up to a notch,
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
            const target = Ws.scrollTarget(root.current, notches);
            if (target !== null) {
                Hyprland.dispatch(Dispatch.focusWorkspace(target, Hyprland.usingLua));
            }
        }
    }
}
