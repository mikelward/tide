import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "lib/lock.mjs" as Lock
import "lib/status.mjs" as Status

// One output's login or lock face (SPEC.md §10, §11, docs/mocks/lock.png):
// one component, drawn by tide-lock on a session-lock surface
// (LockSurface.qml) and by the greeter on a panel (greeter.qml).
//
// The password face: the short hostname, the time and date, the user and the
// password field, with PAM's messages under it. The lock adds the
// notification count and the battery, Suspend, and when it locked; the
// greeter adds the session and user pickers in their place. The
// screensaver face, for an idle lock: black, the hostname and a large time
// in low contrast, moved to a new spot each minute.
//
// The process owns the state; this draws it and sends it each key, pointer
// motion and pick. Nothing here animates, and every key changes what the
// field shows (shell/lib/lock.mjs), so each keystroke is visible on the next
// frame, even while PAM is checking the last attempt.
Item {
    id: face

    // "lock" or "login".
    property string mode: "lock"
    readonly property bool login: mode === "login"

    property var lockState: Lock.INITIAL
    property string hostname: ""
    // Who is shown over the field: the user's name.
    property string user: ""
    property date lockedAt: new Date()
    // The line under the field; the greeter says which session is starting.
    property string status: Lock.statusText(lockState)
    // The last power action's trouble, if any (Lock.powerMessage).
    property string powerMessage: ""
    property bool powerBusy: false
    // How many notifications arrived since the center was last open (lock).
    property int unread: 0
    // The keyboard layout badge (Lock.layoutBadge), "" when unknown.
    property string layout: ""

    // The greeter's pickers: [{name, label}] and [{id, name}], and the
    // chosen ones.
    property var users: []
    property string userName: ""
    property var sessions: []
    property string sessionId: ""
    readonly property string sessionName: sessions.find(s => s.id === sessionId)?.name ?? ""
    // Whether another user can be picked now; the greeter says no while a
    // login is under way (Greeter.canPickUser).
    property bool userPickable: true
    // Which picker's list is open: "", "session" or "user".
    property string menu: ""
    // The room a picker's list has under its chip: the rest of the face
    // below the middle column, less a margin.
    readonly property real menuRoom: face.height - (middle.y + middle.height) - 6 - 16

    onUserPickableChanged: {
        if (!userPickable && menu === "user") {
            menu = "";
        }
    }

    signal event(var event)
    signal power(string id)
    signal pickUser(string name)
    signal pickSession(string id)

    // The greeter has no session to show a battery for.
    readonly property var battery: login ? null : UPower.displayDevice

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
            // Escape closes an open picker before it clears the field.
            if (keyEvent.key === Qt.Key_Escape && face.menu !== "") {
                face.menu = "";
                return;
            }
            const event = Lock.keyEvent({
                key: keyEvent.key === Qt.Key_Return || keyEvent.key === Qt.Key_Enter ? "enter"
                    : keyEvent.key === Qt.Key_Backspace ? "backspace"
                    : keyEvent.key === Qt.Key_Escape ? "escape"
                    // Ctrl+U types U+0015, so the key code says it was U.
                    : keyEvent.key === Qt.Key_U ? "u" : "",
                text: keyEvent.text,
                ctrl: (keyEvent.modifiers & Qt.ControlModifier) !== 0,
            });
            if (event !== null) {
                face.event(event);
            } else if (face.lockState.saver) {
                // Shift, say: it types nothing, but wakes the screensaver.
                face.event({ type: "wake" });
            } else {
                keyEvent.accepted = false;
            }
        }

        // Pointer motion wakes the screensaver. The first position seen is
        // only where the pointer was: the compositor reports one as the
        // lock appears, which isn't a move. A move past a few pixels from it
        // is. A press anywhere else closes an open picker.
        MouseArea {
            property real fromX: -1
            property real fromY: -1

            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPositionChanged: mouse => {
                if (!face.lockState.saver) {
                    return;
                }
                if (fromX < 0) {
                    fromX = mouse.x;
                    fromY = mouse.y;
                } else if (Math.abs(mouse.x - fromX) + Math.abs(mouse.y - fromY) > 8) {
                    face.event({ type: "wake" });
                }
            }
            onPressed: {
                face.menu = "";
                face.event({ type: "wake" });
            }
            // A wheel or a two-finger scroll is input too, with no move.
            onWheel: wheel => {
                wheel.accepted = face.lockState.saver;
                if (face.lockState.saver) {
                    face.event({ type: "wake" });
                }
            }
        }

        // --- The password face -------------------------------------------
        Rectangle {
            anchors.fill: parent
            visible: !face.lockState.saver
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#13303a" }
                GradientStop { position: 1.0; color: "#241a3a" }
            }

            // The notification count and the battery, top left, as the mock
            // shows. A count, never what the notifications say.
            Row {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 16
                spacing: 12
                visible: !face.login

                Row {
                    visible: face.unread > 0
                    spacing: 4

                    SymbolicIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "preferences-system-notifications-symbolic"
                        color: Qt.rgba(1, 1, 1, 0.55)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: face.unread
                        color: Qt.rgba(1, 1, 1, 0.55)
                        font.family: "Inter"
                        font.pixelSize: 12
                    }
                }

                Row {
                    readonly property var view: Status.batteryView({
                        present: face.battery?.isPresent ?? false,
                        percentage: face.battery?.percentage,
                        state: face.battery?.state,
                    })

                    visible: view.visible
                    spacing: 4

                    SymbolicIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: parent.view.icon
                        color: parent.view.low ? "#ff9e8a" : Qt.rgba(1, 1, 1, 0.55)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: parent.view.text
                        color: parent.view.low ? "#ff9e8a" : Qt.rgba(1, 1, 1, 0.55)
                        font.family: "Inter"
                        font.pixelSize: 12
                    }
                }
            }

            // Suspend, bottom left, on the lock; Restart and Shut down, bottom
            // right, on both. logind's inhibitors are checked, never
            // overridden here.
            Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 16
                visible: !face.login

                LockButton {
                    icon: "weather-clear-night-symbolic"
                    label: "Suspend"
                    enabled: !face.powerBusy
                    onClicked: face.power("suspend")
                }
            }

            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 16
                spacing: 8

                LockButton {
                    icon: "system-reboot-symbolic"
                    tip: "Restart"
                    enabled: !face.powerBusy
                    onClicked: face.power("reboot")
                }

                LockButton {
                    icon: "system-shutdown-symbolic"
                    tip: "Shut down"
                    enabled: !face.powerBusy
                    onClicked: face.power("poweroff")
                }
            }

            // What blocked or broke the last power action.
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
                width: Math.min(parent.width - 400, 560)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                visible: text !== ""
                // Inhibitor names come from other programs: never markup.
                textFormat: Text.PlainText
                text: face.powerMessage
                color: "#ff9e8a"
                font.family: "Inter"
                font.pixelSize: 12
            }

            Column {
                id: middle

                anchors.centerIn: parent
                spacing: 12
                width: 320

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: face.hostname
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
                        // A GECOS name is anyone's to set: never markup.
                        textFormat: Text.PlainText
                        text: face.user
                        color: "#f2f2f6"
                        font.family: "Inter"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: !face.login
                        text: `locked at ${Qt.formatTime(face.lockedAt, "HH:mm")}`
                        color: Qt.rgba(1, 1, 1, 0.6)
                        font.family: "Inter"
                        font.pixelSize: 12
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
                    border.width: face.lockState.error ? 1.5 : 1
                    border.color: face.lockState.error ? "#ff7b63" : Qt.rgba(1, 1, 1, 0.16)

                    readonly property string shown: Lock.fieldText(face.lockState)

                    Text {
                        id: entry

                        readonly property bool typed: face.lockState.input !== ""

                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        text: field.shown || "Password"
                        // A visible answer and PAM's prompt: never markup.
                        textFormat: Text.PlainText
                        color: typed ? "#f2f2f6" : Qt.rgba(1, 1, 1, 0.45)
                        font.family: "Inter"
                        font.pixelSize: typed ? 14 : 13
                        // Spaced out for dots, not for a visible answer.
                        font.letterSpacing: typed && !face.lockState.echo ? 3 : 0
                    }

                    // The keyboard layout, so a failed password isn't a
                    // layout mystery. It takes only the room the field's
                    // text leaves, elided to fit and hidden below a few
                    // letters, so it never covers a keystroke.
                    Rectangle {
                        readonly property real room: parent.width - entry.anchors.leftMargin - entry.implicitWidth - 8 - anchors.rightMargin

                        visible: face.layout !== "" && room >= 36
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        width: Math.min(badge.implicitWidth + 12, 108, room)
                        height: 20
                        radius: 5
                        color: Qt.rgba(1, 1, 1, 0.14)

                        Text {
                            id: badge

                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, parent.width - 12)
                            elide: Text.ElideRight
                            // Hyprland's text, never markup.
                            textFormat: Text.PlainText
                            text: face.layout
                            color: Qt.rgba(1, 1, 1, 0.85)
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.weight: Font.Bold
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
                    // PAM's and greetd's words: never markup.
                    textFormat: Text.PlainText
                    text: face.status
                    color: face.lockState.error && !face.lockState.checking ? "#ff9e8a" : Qt.rgba(1, 1, 1, 0.7)
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }

                // The greeter's pickers: the session, and another user when
                // there's more than one. Each opens its list under it.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: face.login
                    spacing: 8

                    LockButton {
                        icon: "computer-symbolic"
                        label: face.sessionName
                        trailing: "pan-down-symbolic"
                        visible: face.sessions.length > 0
                        onClicked: face.menu = face.menu === "session" ? "" : "session"

                        LockMenu {
                            open: face.menu === "session"
                            maxHeight: face.menuRoom
                            rows: face.sessions.map(s => ({ key: s.id, label: s.name }))
                            selected: face.sessionId
                            onPicked: key => {
                                face.menu = "";
                                face.pickSession(key);
                            }
                        }
                    }

                    LockButton {
                        icon: "avatar-default-symbolic"
                        label: "Other user"
                        trailing: "pan-down-symbolic"
                        visible: face.users.length > 1
                        enabled: face.userPickable
                        onClicked: face.menu = face.menu === "user" ? "" : "user"

                        LockMenu {
                            open: face.menu === "user"
                            maxHeight: face.menuRoom
                            rows: face.users.map(u => ({ key: u.name, label: u.label }))
                            selected: face.userName
                            onPicked: key => {
                                face.menu = "";
                                face.pickUser(key);
                            }
                        }
                    }
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
                face.width, face.height, saver.width, saver.height)

            visible: face.lockState.saver
            x: spot.x
            y: spot.y
            spacing: 6

            Text {
                text: face.hostname
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
