import QtQuick

// A picker's list on the greeter (LockFace.qml): a row per choice, the
// chosen one checked, under the chip that opens it. Either button picks,
// as on the rest of the face. A list longer than the room below the chip
// scrolls, so no choice is ever off the screen.
Rectangle {
    id: menu

    property bool open: false
    // [{key, label}]
    property var rows: []
    property string selected: ""
    // The row the keyboard is on, highlighted as the pointer's is.
    property int current: -1
    // The most height it may take, frame included.
    property real maxHeight: 400

    // The row picked, by its index.
    signal picked(int row)

    visible: open
    x: Math.round((parent.width - width) / 2)
    y: parent.height + 6
    width: 220
    // At least one row, whatever the room.
    height: Math.min(list.contentHeight, Math.max(30, maxHeight - 12)) + 12
    radius: 10
    color: "#1c1f2b"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.16)

    // Opened scrolled to the chosen row, and kept on the keyboard's.
    onOpenChanged: {
        if (open) {
            list.positionViewAtIndex(Math.max(0, menu.rows.findIndex(r => r.key === menu.selected)), ListView.Contain);
        }
    }
    onCurrentChanged: {
        if (open && current >= 0) {
            list.positionViewAtIndex(current, ListView.Contain);
        }
    }

    ListView {
        id: list

        x: 6
        y: 6
        width: parent.width - 12
        height: parent.height - 12
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: menu.rows

        delegate: Rectangle {
            required property var modelData
            required property int index

            width: list.width
            height: 30
            radius: 7
            color: row.containsMouse || index === menu.current ? Qt.rgba(1, 1, 1, 0.1) : "transparent"

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.right: check.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                // Names from session files and passwd: never markup.
                textFormat: Text.PlainText
                text: parent.modelData.label
                color: "#f2f2f6"
                font.family: "Inter"
                font.pixelSize: 13
            }

            SymbolicIcon {
                id: check

                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: parent.modelData.key === menu.selected
                name: "object-select-symbolic"
                color: "#f2f2f6"
            }

            MouseArea {
                id: row

                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: menu.picked(parent.index)
            }
        }
    }
}
