import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "lib/polkit.mjs" as Polkit

// The polkit prompt (SPEC.md §14.1), for PolkitData's request: what the app
// is asking to do, whose password, and the field, centered on the focused
// monitor over a dimmed backdrop, like the launcher. It takes the keyboard
// when PolkitData says it may (after your key press, or the notification's
// Authenticate); otherwise it waits for a click. Enter submits, Escape or
// Cancel says no; a click on the backdrop does nothing, so a stray click
// can't turn the app down.
PanelWindow {
    id: root

    readonly property var flow: PolkitData.flow
    readonly property bool wanted: PolkitData.showing === "prompt" && root.flow !== null
    readonly property var identity: root.flow?.selectedIdentity ?? null
    readonly property var identities: root.flow?.identities ?? []
    readonly property var status: Polkit.statusLine(root.flow?.supplementaryMessage, root.flow?.supplementaryIsError, root.flow?.failed)

    // It opens on the monitor you're on, and stays there.
    onWantedChanged: {
        if (wanted) {
            const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor);
            if (focused) {
                screen = focused;
            }
            field.text = "";
        }
        visible = wanted;
        if (wanted && PolkitData.focused) {
            field.forceActiveFocus();
        }
    }

    function submit() {
        if (!root.flow || !root.flow.isResponseRequired) {
            return;
        }
        const answer = field.text;
        field.text = "";
        root.flow.submit(answer);
    }

    function cancel() {
        root.flow?.cancelAuthenticationRequest();
    }

    // The next identity polkit allows, for an action several accounts may
    // authorize; choosing one starts the conversation over.
    function nextIdentity() {
        const list = root.identities;
        if (!root.flow || list.length < 2) {
            return;
        }
        let i = 0;
        while (i < list.length && list[i] !== root.identity) {
            i++;
        }
        root.flow.selectedIdentity = list[(i + 1) % list.length];
        field.text = "";
    }

    // A failed try starts a fresh conversation; the field starts empty too.
    Connections {
        target: root.flow

        function onAuthenticationFailed() {
            field.text = "";
        }
    }

    visible: false
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-polkit"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive only when it may take the keyboard (§14.1), so the window
    // under the pointer can't take it back while you type the password;
    // otherwise a click on it gives it the keyboard.
    WlrLayershell.keyboardFocus: PolkitData.focused ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
    color: Qt.rgba(0, 0, 0, 0.35)

    // The backdrop takes clicks, so nothing under it does, but they do
    // nothing here.
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        id: card

        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 3)
        width: 440
        height: column.implicitHeight + 40
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        MouseArea {
            anchors.fill: parent
            onClicked: field.forceActiveFocus()
        }

        Column {
            id: column

            x: 20
            y: 20
            width: parent.width - 40
            spacing: 12

            Row {
                spacing: 10

                SymbolicIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: 22
                    implicitHeight: 22
                    name: "changes-prevent-symbolic"
                    color: Theme.accent
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Authentication required"
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }
            }

            // From the action's polkit description: plain text.
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.flow?.message ?? ""
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 13
            }

            Item {
                width: parent.width
                height: 22

                SymbolicIcon {
                    id: avatar

                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: 16
                    implicitHeight: 16
                    name: "avatar-default-symbolic"
                    color: Theme.fgDim
                }

                Text {
                    anchors.left: avatar.right
                    anchors.leftMargin: 8
                    anchors.right: other.visible ? other.left : parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Polkit.identityLabel(root.identity)
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 12
                }

                Text {
                    id: other

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.identities.length > 1
                    text: "Another account"
                    color: Theme.accent
                    font.family: Theme.font
                    font.pixelSize: 12
                    font.weight: Font.DemiBold

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.nextIdentity()
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 40
                radius: 10
                color: Theme.surface2
                border.color: field.activeFocus ? Theme.accent : "transparent"

                TextInput {
                    id: field

                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    clip: true
                    // PAM says whether its question is a secret.
                    echoMode: root.flow?.responseVisible ? TextInput.Normal : TextInput.Password
                    // Until PAM asks, there's nothing to answer.
                    readOnly: !(root.flow?.isResponseRequired ?? false)
                    color: Theme.fg
                    selectionColor: Theme.accentBg
                    font.family: Theme.font
                    font.pixelSize: 15

                    Keys.onReturnPressed: root.submit()
                    Keys.onEnterPressed: root.submit()
                    Keys.onEscapePressed: root.cancel()

                    Text {
                        visible: field.text === ""
                        anchors.verticalCenter: parent.verticalCenter
                        text: Polkit.promptText(root.flow?.inputPrompt)
                        color: Theme.fgFaint
                        font: field.font
                    }
                }
            }

            // PAM's message, or a failed try's.
            Text {
                visible: root.status.text !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.status.text
                color: root.status.error ? Theme.danger : Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 12
            }

            Row {
                anchors.right: parent.right
                spacing: 8

                Repeater {
                    model: [{
                            label: "Cancel",
                            primary: false
                        }, {
                            label: "Authenticate",
                            primary: true
                        }]

                    Rectangle {
                        required property var modelData

                        width: label.implicitWidth + 28
                        height: 32
                        radius: 8
                        color: modelData.primary ? Theme.accentBg : hover.hovered ? Theme.surface2 : "transparent"
                        border.color: modelData.primary ? "transparent" : Theme.edge

                        HoverHandler {
                            id: hover
                        }

                        TapHandler {
                            onTapped: parent.modelData.primary ? root.submit() : root.cancel()
                        }

                        Text {
                            id: label

                            anchors.centerIn: parent
                            text: parent.modelData.label
                            color: parent.modelData.primary ? Theme.accentFg : Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                        }
                    }
                }
            }
        }
    }
}
