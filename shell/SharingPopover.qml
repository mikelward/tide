import QtQuick
import Quickshell

// The Sharing pill's popover (SPEC.md §7.4): what each live share is, from
// the share picker's choice paired with its stream (ShareData), and that
// stopping one is up to the app sharing it.
PopupWindow {
    id: root

    required property Item icon

    function toggle() {
        visible = !visible;
    }

    // Closes when the last share ends, rather than staying up empty.
    Connections {
        target: ShareData

        function onRowsChanged() {
            if (ShareData.rows.length === 0) {
                root.visible = false;
            }
        }
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 300
    implicitHeight: list.implicitHeight + 12

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Column {
            id: list

            x: 6
            y: 6
            width: parent.width - 12
            spacing: 2

            Text {
                leftPadding: 10
                topPadding: 8
                bottomPadding: 2
                text: "SHARING"
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 11
                font.weight: Font.Bold
                font.letterSpacing: 0.5
            }

            Repeater {
                model: ShareData.rows

                MenuRow {
                    required property var modelData

                    width: list.width
                    icon: modelData.icon
                    label: modelData.label
                }
            }

            Text {
                width: list.width
                leftPadding: 10
                rightPadding: 10
                topPadding: 4
                bottomPadding: 8
                wrapMode: Text.Wrap
                text: "Stop sharing from the app that's sharing."
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 12
            }
        }
    }
}
