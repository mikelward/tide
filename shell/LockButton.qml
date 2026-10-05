import QtQuick

// A button on the lock's password face (docs/mocks/lock.png): a translucent
// pill with an icon and, for Suspend, a label; round when it's only an icon.
// Its press shows at once, like every key on the lock.
Rectangle {
    id: root

    property string icon: ""
    property string label: ""
    // What an icon-only button does, for screen readers.
    property string tip: ""

    signal clicked

    implicitWidth: label !== "" ? row.implicitWidth + 24 : 32
    implicitHeight: label !== "" ? 28 : 32
    radius: height / 2
    color: mouse.pressed ? Qt.rgba(1, 1, 1, 0.2) : Qt.rgba(1, 1, 1, 0.1)
    opacity: enabled ? 1 : 0.5

    Accessible.role: Accessible.Button
    Accessible.name: label !== "" ? label : tip

    Row {
        id: row

        anchors.centerIn: parent
        spacing: 6

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: root.icon
            color: "#f2f2f6"
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.label !== ""
            text: root.label
            color: "#f2f2f6"
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        enabled: root.enabled
        // Either button is a click on the lock (TODO.md).
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.clicked()
    }
}
