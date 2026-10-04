import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// The OSD (SPEC.md §9): a pill at the bottom center of the focused monitor
// for a volume or mic-mute change, from OsdData. There's one per monitor,
// and only the focused monitor's shows. It takes no input.
PanelWindow {
    id: root

    required property var modelData

    screen: modelData
    visible: OsdData.showing && OsdData.pill !== null && Hyprland.focusedMonitor !== null && Hyprland.focusedMonitor === Hyprland.monitorFor(screen)
    anchors.bottom: true
    margins.bottom: 60
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    color: "transparent"
    implicitWidth: 300
    implicitHeight: 52
    // Clicks go through to whatever is under it.
    mask: Region {}

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.surface
        border.color: Theme.edge

        Row {
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            spacing: 12

            SymbolicIcon {
                anchors.verticalCenter: parent.verticalCenter
                width: 22
                height: 22
                name: OsdData.pill?.icon ?? "audio-volume-muted-symbolic"
                color: Theme.fg
            }

            // The level, for the output; the mic has none.
            Rectangle {
                id: track

                visible: OsdData.pill?.level !== null && OsdData.pill?.level !== undefined
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 22 - label.width - parent.spacing * 2
                height: 6
                radius: 3
                color: Theme.surface2

                Rectangle {
                    width: parent.width * (OsdData.pill?.level ?? 0)
                    height: parent.height
                    radius: parent.radius
                    color: Theme.accentBg
                }
            }

            Text {
                id: label

                anchors.verticalCenter: parent.verticalCenter
                width: track.visible ? 44 : parent.width - 22 - parent.spacing
                horizontalAlignment: track.visible ? Text.AlignRight : Text.AlignLeft
                text: OsdData.pill?.label ?? ""
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
        }
    }
}
