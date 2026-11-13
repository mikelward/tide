import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "lib/clocks.mjs" as Clocks
import "lib/greeter.mjs" as Greeter
import "lib/lock.mjs" as Lock
import "lib/status.mjs" as Status

// One output's login or lock face (SPEC.md §10, §11, docs/mocks/lock.png):
// one component, drawn by tide-lock on a session-lock surface
// (LockSurface.qml) and by the greeter on a panel (greeter.qml).
//
// The password face: the short hostname, the time and date, the user and the
// password field, with PAM's messages under it. The lock adds the
// notification count, the battery and Suspend; the greeter adds the
// session and user pickers in their place. The
// screensaver face, for an idle lock: black, the hostname and a large time
// in low contrast, moved to a new spot each minute.
//
// The process owns the state; this draws it and sends it each key, pointer
// motion and pick. Nothing here animates but the caret's blink, and every
// key changes what the field shows (shell/lib/lock.mjs), so each keystroke
// is visible on the next frame, even while PAM is checking the last
// attempt.
//
// The field shows where the keys go (Lock.fieldLook): an accent border and
// a caret while this face has the keyboard focus and there's a keyboard to
// type with (LockKeyboards.qml), a quieter border otherwise.
Item {
    id: face

    // "lock" or "login".
    property string mode: "lock"
    readonly property bool login: mode === "login"

    property var lockState: Lock.INITIAL
    property string hostname: ""
    // Who is shown over the field: the user's name.
    property string user: ""
    // 24-hour time, or "4:30 PM", as clocks.json's hour24 says (SPEC.md
    // §7.3); the greeter, with no one's settings to read, keeps 24-hour.
    property bool hour24: true
    // The wallpaper's path, drawn blurred behind the password face (SPEC.md
    // §15), or "" for the face's own gradient: the shell's on the lock, the
    // last user's copy (lookDir) on the greeter.
    property string wallpaper: ""
    // A color wallpaper, #rrggbb, drawn darkened instead (no blur), or "".
    property string wallpaperColor: ""
    // How the picture is placed, as the shell places it (Appearance.POSITIONS).
    property string wallpaperPosition: "fill"
    // The line under the field (Lock.statusLine); the greeter says which
    // session is starting.
    readonly property var line: Lock.statusLine(lockState)
    property string status: line.text
    // The last power action's trouble, if any (Lock.powerMessage).
    property string powerMessage: ""
    property bool powerBusy: false
    // How many notifications arrived since the center was last open (lock).
    property int unread: 0
    // The keyboard layout's name (Lock.layoutName), "" when unknown.
    property string layout: ""
    // Whether there's a keyboard to type with (LockKeyboards.present).
    property bool keyboard: true

    // Light or dark (SPEC.md §10, §11): the lock's follows the shell's
    // mode, the greeter's the last user's. The screensaver stays black.
    property bool dark: true
    readonly property var palette: Lock.facePalette(face.dark)

    // The face's see-through ink at `alpha`: white on dark, black on light.
    function ink(alpha) {
        return Qt.rgba(face.palette.ink, face.palette.ink, face.palette.ink, alpha);
    }

    readonly property var look: Lock.fieldLook({
        focused: keys.activeFocus && face.picker.focus === "field",
        keyboard: face.keyboard,
        error: face.lockState.error,
        dark: face.dark,
    })
    // Half-periods of the caret's blink since the last key or the focus
    // arriving (Lock.caretShown).
    property int caretTicks: 0

    // A key, PAM, the focus or the keyboard: the caret shows at once and
    // blinks afresh, or stops with the focus.
    function caretAgain() {
        caretTicks = 0;
        if (look.caret && !lockState.saver) {
            blink.restart();
        } else {
            blink.stop();
        }
    }

    onLockStateChanged: caretAgain()
    onLookChanged: caretAgain()

    Timer {
        id: blink

        interval: Lock.CARET_BLINK_MS
        repeat: true
        onTriggered: {
            face.caretTicks++;
            if (!Lock.caretBlinks(face.caretTicks)) {
                stop();
            }
        }
    }

    // The greeter's pickers: [{name, label}] and [{id, name}], and the
    // chosen ones.
    property var users: []
    property string userName: ""
    property var sessions: []
    property string sessionId: ""
    readonly property string sessionName: sessions.find(s => s.id === sessionId)?.name ?? ""
    // Whether another user can be picked now; the greeter says no once the
    // session is starting (Greeter.canPickUser).
    property bool userPickable: true
    // Where the keys go on the greeter, and which picker's list is open
    // ("", "session" or "user"), with its highlighted row
    // (Greeter.pickerKey).
    property var picker: Greeter.PICKER_INITIAL
    readonly property string menu: picker.menu
    readonly property int sessionRow: sessions.findIndex(s => s.id === sessionId)
    readonly property int userRow: users.findIndex(u => u.name === userName)
    readonly property var chips: ({
        session: login ? sessions.length : 0,
        user: login && users.length > 1 && userPickable ? users.length : 0,
        sessionRow: sessionRow,
        userRow: userRow,
    })

    // A chip clicked: its list opens, or closes if it was open, and the
    // keys follow it there.
    function toggleMenu(chip) {
        face.picker = {
            focus: chip,
            menu: face.menu === chip ? "" : chip,
            row: Math.max(0, chip === "session" ? face.sessionRow : face.userRow),
        };
    }

    // A row picked, by the keyboard or the pointer.
    function pickRow(chip, row) {
        face.picker = { focus: chip, menu: "", row: row };
        if (chip === "session") {
            face.pickSession(face.sessions[row].id);
        } else {
            face.pickUser(face.users[row].name);
        }
    }
    // The room a picker's list has under its chip: the rest of the face
    // below the middle column, less a margin.
    readonly property real menuRoom: face.height - (middle.y + middle.height) - 6 - 16

    onUserPickableChanged: {
        if (!userPickable && picker.focus === "user") {
            picker = Greeter.PICKER_INITIAL;
        }
    }

    signal event(var event)
    signal power(string id)
    signal pickUser(string name)
    signal pickSession(string id)

    // The greeter has no session to show a battery for.
    readonly property var battery: login ? null : UPower.displayDevice

    // Each minute, and at once on waking from sleep.
    WallClock {
        id: clock
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
            const event = Lock.keyEvent({
                key: keyEvent.key === Qt.Key_Return || keyEvent.key === Qt.Key_Enter ? "enter"
                    : keyEvent.key === Qt.Key_Backspace ? "backspace"
                    : keyEvent.key === Qt.Key_Escape ? "escape"
                    // Ctrl+U types U+0015, so the key code says it was U.
                    : keyEvent.key === Qt.Key_U ? "u" : "",
                text: keyEvent.text,
                ctrl: (keyEvent.modifiers & Qt.ControlModifier) !== 0,
            });
            // On the greeter, Tab reaches the pickers (Greeter.pickerKey).
            // A key that types nothing, like Shift, leaves the focus be.
            const pickerName = keyEvent.key === Qt.Key_Tab ? "tab"
                : keyEvent.key === Qt.Key_Backtab ? "backtab"
                : keyEvent.key === Qt.Key_Up ? "up"
                : keyEvent.key === Qt.Key_Down ? "down"
                : keyEvent.key === Qt.Key_Space ? "space"
                : keyEvent.key === Qt.Key_Escape ? "escape"
                : event?.type === "submit" ? "enter"
                : event !== null ? "other" : "";
            if (face.login && !face.lockState.saver && pickerName !== "") {
                const r = Greeter.pickerKey(face.picker, face.chips, pickerName);
                face.picker = r.state;
                if (r.pick !== null) {
                    face.pickRow(r.pick.menu, r.pick.row);
                }
                if (!r.pass) {
                    return;
                }
            }
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
                face.picker = Greeter.PICKER_INITIAL;
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
        Backdrop {
            anchors.fill: parent
            visible: !face.lockState.saver
            dark: face.dark
            wallpaper: face.wallpaper
            wallpaperColor: face.wallpaperColor
            wallpaperPosition: face.wallpaperPosition

            // The battery and the notification count, top right, in the
            // bar's order, as the mock shows. A count, never what the
            // notifications say.
            Row {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 16
                spacing: 12
                visible: !face.login

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
                        color: parent.view.low ? face.palette.warn : face.ink(0.55)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: parent.view.text
                        color: parent.view.low ? face.palette.warn : face.ink(0.55)
                        font.family: "Inter"
                        font.pixelSize: 12
                    }
                }

                Row {
                    visible: face.unread > 0
                    spacing: 4

                    SymbolicIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "preferences-system-notifications-symbolic"
                        color: face.ink(0.55)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: face.unread
                        color: face.ink(0.55)
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
                    dark: face.dark
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
                    dark: face.dark
                    icon: "system-reboot-symbolic"
                    tip: "Restart"
                    enabled: !face.powerBusy
                    onClicked: face.power("reboot")
                }

                LockButton {
                    dark: face.dark
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
                color: face.palette.warn
                font.family: "Inter"
                font.pixelSize: 12
            }

            Column {
                id: middle

                // Centered as if the line under the field held one line,
                // so a message coming, going or wrapping never moves it.
                anchors.horizontalCenter: parent.horizontalCenter
                y: Lock.faceTop(parent.height, height, statusLine.height, statusMetrics.height)
                spacing: 12
                width: 320

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: face.hostname
                    color: face.palette.text
                    font.family: "Inter"
                    font.pixelSize: 32
                    font.weight: Font.Bold
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: `${Qt.formatDate(clock.date, "ddd MMM d")}  ${Clocks.formatWall(clock.date.getHours(), clock.date.getMinutes(), face.hour24)}`
                    color: face.ink(0.7)
                    font.family: "Inter"
                    font.pixelSize: 13
                    font.features: { "tnum": 1 }
                }

                Item { width: 1; height: 14 }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    // A GECOS name is anyone's to set: never markup.
                    textFormat: Text.PlainText
                    text: face.user
                    color: face.palette.text
                    font.family: "Inter"
                    font.pixelSize: 20
                    font.weight: Font.DemiBold
                }

                // The password field. The keys come from `keys` above.
                Rectangle {
                    id: field

                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 240
                    height: 38
                    radius: 10
                    color: face.ink(0.1)
                    border.width: face.look.borderWidth
                    border.color: face.look.border

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
                        color: typed ? face.palette.text : face.ink(0.45)
                        font.family: "Inter"
                        font.pixelSize: typed ? 14 : 13
                        // Spaced out for dots, not for a visible answer.
                        font.letterSpacing: typed && !face.lockState.echo ? 3 : 0
                    }

                    // Where the next key lands: after what's typed, or before
                    // the placeholder.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        x: entry.typed ? entry.x + entry.implicitWidth + 1 : entry.x - 4
                        width: 2
                        height: 18
                        radius: 1
                        visible: face.look.caret && Lock.caretShown(face.caretTicks)
                        color: face.palette.text
                    }
                }

                // The keyboard layout, so a failed password isn't a layout
                // mystery, or "No keyboard" while there's none
                // (Lock.layoutLine), where the boot splash names it: under
                // the field, in dim text. It keeps its height when empty,
                // so the name appearing moves nothing.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: layoutText.implicitHeight
                    spacing: 5

                    SymbolicIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: layoutText.text !== ""
                        name: "input-keyboard-symbolic"
                        color: face.ink(0.55)
                    }

                    Text {
                        id: layoutText

                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, field.width)
                        elide: Text.ElideRight
                        // Hyprland's text, never markup.
                        textFormat: Text.PlainText
                        text: Lock.layoutLine(face.layout, face.keyboard)
                        color: face.ink(0.55)
                        font.family: "Inter"
                        font.pixelSize: 12
                    }
                }

                // "Checking", PAM's message, or the failure, under the
                // layout.
                // It keeps a line's room when empty, so one appearing moves
                // nothing.
                Text {
                    id: statusLine

                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width
                    height: Math.max(implicitHeight, statusMetrics.height)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    // PAM's and greetd's words: never markup.
                    textFormat: Text.PlainText
                    text: face.status
                    color: face.line.error ? face.palette.warn : face.ink(0.7)
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.DemiBold

                    FontMetrics {
                        id: statusMetrics

                        font: statusLine.font
                    }
                }

                // The greeter's pickers: the session, and another user when
                // there's more than one. Each opens its list under it. The
                // row keeps a chip's height while the sessions and users
                // load, so their chips appearing moves nothing.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: face.login
                    height: 28
                    spacing: 8

                    LockButton {
                        dark: face.dark
                        icon: "computer-symbolic"
                        label: face.sessionName
                        trailing: "pan-down-symbolic"
                        visible: face.sessions.length > 0
                        focused: face.picker.focus === "session"
                        onClicked: face.toggleMenu("session")

                        LockMenu {
                            open: face.menu === "session"
                            maxHeight: face.menuRoom
                            rows: face.sessions.map(s => ({ key: s.id, label: s.name }))
                            selected: face.sessionId
                            current: face.picker.row
                            onPicked: row => face.pickRow("session", row)
                        }
                    }

                    LockButton {
                        dark: face.dark
                        icon: "avatar-default-symbolic"
                        label: "Other user"
                        trailing: "pan-down-symbolic"
                        visible: face.users.length > 1
                        enabled: face.userPickable
                        focused: face.picker.focus === "user"
                        onClicked: face.toggleMenu("user")

                        LockMenu {
                            open: face.menu === "user"
                            maxHeight: face.menuRoom
                            rows: face.users.map(u => ({ key: u.name, label: u.label }))
                            selected: face.userName
                            current: face.picker.row
                            onPicked: row => face.pickRow("user", row)
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
                text: Clocks.formatWall(clock.date.getHours(), clock.date.getMinutes(), face.hour24)
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
