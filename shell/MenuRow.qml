import QtQuick
import Quickshell.Widgets

// One row of a bar menu: an icon and a label, highlighted on hover.
Item {
    id: root

    // A symbolic icon from the theme, or `image`, an app's own (a tray
    // menu's). With neither, the label starts where the icon would be,
    // unless `indent` lines it up with rows that have one.
    property string icon
    property string image: ""
    property bool indent: false
    property string label
    // A chosen option among rows, such as the current power profile.
    property bool selected: false
    // Shown as the current one without a check mark, such as a page.
    property bool highlighted: false
    // Opens a submenu, so it ends in an arrow.
    property bool submenu: false
    signal clicked

    implicitHeight: 32
    // A disabled row takes no clicks (its handlers follow `enabled`).
    opacity: enabled ? 1 : 0.5

    Rectangle {
        anchors.fill: parent
        radius: 7
        color: Theme.surface2
        visible: hover.hovered || root.selected || root.highlighted
    }

    Item {
        id: lead

        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        width: root.icon !== "" || root.image !== "" || root.indent ? 16 : 0
        height: 16

        SymbolicIcon {
            anchors.fill: parent
            visible: root.icon !== ""
            name: root.icon
            color: Theme.fg
        }

        IconImage {
            anchors.fill: parent
            visible: root.image !== ""
            source: root.image
            asynchronous: true
        }
    }

    // Between the icon and the check mark, cut short if it's too long.
    Text {
        anchors.left: lead.right
        anchors.leftMargin: lead.width > 0 ? 10 : 0
        anchors.right: end.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        // Labels can come from other programs (device names): never markup.
        textFormat: Text.PlainText
        text: root.label
        color: Theme.fg
        font.family: Theme.font
        font.pixelSize: 13
    }

    SymbolicIcon {
        id: end

        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: root.selected || root.submenu
        name: root.submenu ? "go-next-symbolic" : "object-select-symbolic"
        color: root.submenu ? Theme.fgDim : Theme.accent
    }

    HoverHandler {
        id: hover
    }

    TapHandler {
        onTapped: root.clicked()
    }
}
