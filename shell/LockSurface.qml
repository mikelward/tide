import QtQuick
import Quickshell
import Quickshell.Wayland
import "lib/lock.mjs" as Lock

// One output's lock face (SPEC.md §10, docs/mocks/lock.png). The password
// face: the short hostname, the time and date, the user and the password
// field, with PAM's messages under it. The screensaver face, for an idle
// lock: black, the hostname and a large time in low contrast, moved to a
// new spot each minute. lock.qml owns the state; this draws it and sends it
// each key and pointer motion. Nothing here animates, and every key changes
// what the field shows (shell/lib/lock.mjs), so each keystroke is visible on
// the next frame, even while PAM is checking the last attempt.
WlSessionLockSurface {
    id: surface

    property var lockState: Lock.INITIAL
    property string hostname: ""
    property string user: ""
    property date lockedAt: new Date()

    signal event(var event)

    color: "#000000"

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // Takes every key, on either face. It's never hidden: Qt drops focus
    // from an invisible item, which would lose the key that wakes the
    // screensaver.
    Item {
        id: keys

        anchors.fill: parent
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
            } else if (surface.lockState.saver) {
                // Shift, say: it types nothing, but wakes the screensaver.
                surface.event({ type: "wake" });
            } else {
                keyEvent.accepted = false;
            }
        }

        // Pointer motion wakes the screensaver. The first position seen is
        // only where the pointer was: the compositor reports one as the
        // lock appears, which isn't a move. A move past a few pixels from it
        // is.
        MouseArea {
            property real fromX: -1
            property real fromY: -1

            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: mouse => {
                if (!surface.lockState.saver) {
                    return;
                }
                if (fromX < 0) {
                    fromX = mouse.x;
                    fromY = mouse.y;
                } else if (Math.abs(mouse.x - fromX) + Math.abs(mouse.y - fromY) > 8) {
                    surface.event({ type: "wake" });
                }
            }
            onPressed: surface.event({ type: "wake" })
            // A wheel or a two-finger scroll is input too, with no move.
            onWheel: wheel => {
                wheel.accepted = surface.lockState.saver;
                if (surface.lockState.saver) {
                    surface.event({ type: "wake" });
                }
            }
        }

        // --- The password face -------------------------------------------
        Rectangle {
            anchors.fill: parent
            visible: !surface.lockState.saver
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#13303a" }
                GradientStop { position: 1.0; color: "#241a3a" }
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

                // The password field. The keys come from `keys` above.
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
                        readonly property bool dots: surface.lockState.input !== ""

                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        text: field.shown || "Password"
                        color: dots ? "#f2f2f6" : Qt.rgba(1, 1, 1, 0.45)
                        font.family: "Inter"
                        font.pixelSize: dots ? 14 : 13
                        font.letterSpacing: dots ? 3 : 0
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

        // --- The screensaver face ----------------------------------------
        // Black, low contrast, and a new spot each minute (Lock.saverPosition)
        // to spare OLED panels. The window behind is black too.
        Column {
            id: saver

            readonly property var spot: Lock.saverPosition(
                Math.floor(clock.date.getTime() / 60000),
                surface.width, surface.height, saver.width, saver.height)

            visible: surface.lockState.saver
            x: spot.x
            y: spot.y
            spacing: 6

            Text {
                text: surface.hostname
                color: Qt.rgba(1, 1, 1, 0.42)
                font.family: "Inter"
                font.pixelSize: 26
                font.weight: Font.Bold
            }

            Text {
                text: Qt.formatTime(clock.date, "HH:mm")
                color: Qt.rgba(1, 1, 1, 0.5)
                font.family: "Inter"
                font.pixelSize: 64
                font.weight: Font.Light
                font.features: { "tnum": 1 }
            }

            Text {
                text: Qt.formatDate(clock.date, "dddd, MMMM d")
                color: Qt.rgba(1, 1, 1, 0.35)
                font.family: "Inter"
                font.pixelSize: 13
            }
        }
    }
}
