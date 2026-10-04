import QtQuick
import Quickshell
import Quickshell.Bluetooth
import "lib/bluetooth.mjs" as Bt

// The Bluetooth popover (SPEC.md §7.4): turn it on or off, connect or
// disconnect a paired device, and open blueman-manager to pair a new one.
PopupWindow {
    id: root

    required property Item icon
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var devices: Bt.pairedDevices(root.adapter?.devices.values ?? [])

    function toggle() {
        visible = !visible;
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 280
    // No taller than most of the screen; the rows scroll past that.
    implicitHeight: Math.min(list.implicitHeight + 12, (screen?.height ?? 800) * 0.8)

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Flickable {
            anchors.fill: parent
            anchors.margins: 6
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: list

                width: parent.width
                spacing: 2

                MenuRow {
                    width: list.width
                    icon: "bluetooth-active-symbolic"
                    label: "Bluetooth"
                    selected: root.adapter?.enabled ?? false
                    onClicked: {
                        if (root.adapter) {
                            root.adapter.enabled = !root.adapter.enabled;
                        }
                    }
                }

                Repeater {
                    model: root.adapter?.enabled ? root.devices : []

                    MenuRow {
                        required property var modelData
                        readonly property string status: Bt.deviceStatus(modelData)

                        width: list.width
                        icon: modelData.icon ? `${modelData.icon}-symbolic` : "bluetooth-active-symbolic"
                        label: status ? `${Bt.deviceName(modelData)} · ${status}` : Bt.deviceName(modelData)
                        selected: modelData.connected
                        onClicked: {
                            if (Bt.shouldConnect(modelData)) {
                                modelData.connect();
                            } else {
                                modelData.disconnect();
                            }
                        }
                    }
                }

                MenuRow {
                    width: list.width
                    icon: "list-add-symbolic"
                    label: "Pair a device…"
                    onClicked: {
                        root.visible = false;
                        Launcher.launch(["blueman-manager"]);
                    }
                }
            }
        }
    }
}
