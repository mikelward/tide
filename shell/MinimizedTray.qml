import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "lib/dispatch.mjs" as Dispatch
import "lib/minimized.mjs" as Min
import "lib/workspaces.mjs" as Ws

// One monitor's tray of minimized windows (SPEC.md §6.7): in the
// bottom-right corner, an app icon per window minimized from the workspace
// this monitor shows, the latest used nearest the corner. Hovering one
// shows its title, and a click restores it. It floats, reserving no space,
// and is there only while it has something in it.
PanelWindow {
    id: root

    required property var modelData
    readonly property var monitor: Hyprland.monitorFor(root.screen)
    readonly property var list: Min.trayWindows(Hyprland.toplevels.values.map(t => {
        const address = Ws.normalizeAddress(t.address);
        return {
            address: address,
            app: t.lastIpcObject?.class || t.wayland?.appId || "",
            title: t.title ?? "",
            workspace: t.workspace?.name ?? "",
            focus: Ws.focusRank(MarkData.focusOrder, address, t.lastIpcObject?.focusHistoryID)
        };
    }), root.monitor?.activeWorkspace?.name ?? "")

    screen: modelData
    visible: root.list.length > 0
    anchors.bottom: true
    anchors.right: true
    margins.bottom: 12
    margins.right: 12
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-minimized"
    WlrLayershell.layer: WlrLayer.Top
    color: "transparent"
    implicitWidth: icons.implicitWidth + 10
    implicitHeight: 38

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Theme.barBg
        border.color: Theme.edge

        Row {
            id: icons

            anchors.centerIn: parent
            spacing: 6

            Repeater {
                model: root.list

                Item {
                    id: slot

                    required property var modelData

                    width: 28
                    height: 28

                    IconImage {
                        anchors.fill: parent
                        source: Quickshell.iconPath(
                            DesktopEntries.heuristicLookup(slot.modelData.app)?.icon ?? slot.modelData.app,
                            "application-x-executable")
                    }

                    MouseArea {
                        id: mouse

                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onClicked: Hyprland.dispatch(Dispatch.moveWindowToWorkspace(
                            slot.modelData.address, root.monitor?.activeWorkspace?.name ?? "", Hyprland.usingLua))
                    }

                    // The title, above the icon while it's hovered.
                    PopupWindow {
                        visible: mouse.containsMouse
                        anchor.item: slot
                        anchor.edges: Edges.Top
                        anchor.gravity: Edges.Top
                        anchor.margins.top: -8
                        color: "transparent"
                        implicitWidth: title.implicitWidth + 18
                        implicitHeight: title.implicitHeight + 10

                        Rectangle {
                            anchors.fill: parent
                            radius: 7
                            color: Theme.surface2
                            border.color: Theme.edge

                            Text {
                                id: title

                                anchors.centerIn: parent
                                // A title is whatever the app set: plain text.
                                textFormat: Text.PlainText
                                text: slot.modelData.title
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }
        }
    }
}
