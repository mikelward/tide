import QtQuick
import Quickshell
import Quickshell.Wayland
import "lib/lock.mjs" as Lock

// One output's lock face (SPEC.md §10, docs/mocks/lock.png): the short
// hostname, the time and date, the user and the password field, with PAM's
// messages under it. lock.qml owns the state; this draws it and sends it
// each key. Nothing here animates, and every key changes what the field
// shows (shell/lib/lock.mjs), so each keystroke is visible on the next
// frame, even while PAM is checking the last attempt.
WlSessionLockSurface {
    id: surface

    property var lockState: Lock.INITIAL
    property string hostname: ""
    property string user: ""
    property date lockedAt: new Date()

    signal event(var event)

    color: "#10172a"

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "#13303a" }
            GradientStop { position: 1.0; color: "#241a3a" }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 12
        width: 320

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: surface.hostname
            color: "#f2f2f6"
            font.family: "Inter"
            font.pixelSize: 58
            font.weight: Font.Bold
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDateTime(clock.date, "ddd MMM d  HH:mm")
            color: Qt.rgba(1, 1, 1, 0.7)
            font.family: "Inter"
            font.pixelSize: 13
            font.features: { "tnum": 1 }
        }

        Item { width: 1; height: 14 }

        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 2

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: surface.user
                color: "#f2f2f6"
                font.family: "Inter"
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: `locked at ${Qt.formatTime(surface.lockedAt, "HH:mm")}`
                color: Qt.rgba(1, 1, 1, 0.6)
                font.family: "Inter"
                font.pixelSize: 11.5
            }
        }

        // The password field. It takes every key: the lock has nothing
        // else to type into.
        Rectangle {
            id: field

            anchors.horizontalCenter: parent.horizontalCenter
            width: 270
            height: 38
            radius: 10
            color: Qt.rgba(1, 1, 1, 0.1)
            border.width: surface.lockState.error ? 1.5 : 1
            border.color: surface.lockState.error ? "#ff7b63" : Qt.rgba(1, 1, 1, 0.16)

            readonly property string shown: Lock.fieldText(surface.lockState)

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 12
                readonly property bool dots: surface.lockState.input !== ""

                text: field.shown || "Password"
                color: dots ? "#f2f2f6" : Qt.rgba(1, 1, 1, 0.45)
                font.family: "Inter"
                font.pixelSize: dots ? 14 : 13
                font.letterSpacing: dots ? 3 : 0
            }

            focus: true
            Keys.onPressed: keyEvent => {
                keyEvent.accepted = true;
                if (keyEvent.key === Qt.Key_Return || keyEvent.key === Qt.Key_Enter) {
                    surface.event({ type: "submit" });
                } else if (keyEvent.key === Qt.Key_Backspace) {
                    surface.event({ type: "backspace" });
                } else if (keyEvent.key === Qt.Key_Escape) {
                    surface.event({ type: "clear" });
                } else if (keyEvent.text !== "" && keyEvent.text >= " ") {
                    surface.event({ type: "key", text: keyEvent.text });
                } else {
                    keyEvent.accepted = false;
                }
            }
        }

        // "Checking", PAM's message, or the failure, under the field.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: text !== ""
            text: Lock.statusText(surface.lockState)
            color: surface.lockState.error && !surface.lockState.checking ? "#ff9e8a" : Qt.rgba(1, 1, 1, 0.7)
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }
}
