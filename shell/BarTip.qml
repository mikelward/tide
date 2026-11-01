import QtQuick
import Quickshell

// A bar item's hover text (SPEC.md §7.4): one line under `item` while
// `shown`, which is its BarHit's `hovered`, so the whole click target
// counts, the % beside an icon too. It stays away while any popover or
// the notification center is open, so it never sits over one; the center
// isn't a popover, so it's checked by itself. Plain text, since some of it (a Wi-Fi
// network's name, a device's) is whatever someone else set.
PopupWindow {
    id: root

    required property Item item
    property string text: ""
    property bool shown: false

    visible: shown && text !== "" && PopoverData.open === null && HistoryData.openOn === ""
    anchor.item: item
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.bottom: -8
    color: "transparent"
    implicitWidth: label.implicitWidth + 18
    implicitHeight: label.implicitHeight + 10

    Rectangle {
        anchors.fill: parent
        radius: 7
        color: Theme.surface2
        border.color: Theme.edge

        Text {
            id: label

            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.text
            color: Theme.fg
            font.family: Theme.font
            font.pixelSize: 12
        }
    }
}
