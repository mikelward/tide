import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "lib/agent.mjs" as Agent

// The network prompt (SPEC.md §5.6), for AgentData's request: the
// connection, what it needs, and a field for each thing tide-agent asks
// for, centered on the focused monitor over a dimmed backdrop, like the
// polkit prompt. It takes the keyboard when AgentData says it may (§14.1);
// otherwise it waits for a click. Enter moves to the next field and
// submits from the last; Escape or Cancel says no, which stops
// NetworkManager asking anyone else. A click on the backdrop does nothing,
// so a stray click can't cancel.
PanelWindow {
    id: root

    readonly property var request: AgentData.current
    readonly property bool wanted: AgentData.showing === "prompt" && root.request !== null
    readonly property var fields: root.request?.fields ?? []

    onWantedChanged: {
        if (wanted) {
            const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor);
            if (focused) {
                screen = focused;
            }
        }
        visible = wanted;
        if (wanted && AgentData.focused) {
            Qt.callLater(root.focusField, 0);
        }
    }

    function focusField(i) {
        const item = inputs.itemAt(i);
        if (item) {
            item.input.forceActiveFocus();
        }
    }

    // What's typed, read off the fields; each field forgets it as the
    // prompt closes.
    function submit() {
        if (!root.request) {
            return;
        }
        const typed = [];
        for (let i = 0; i < inputs.count; i++) {
            typed.push(inputs.itemAt(i).input.text);
        }
        AgentData.reply(root.request.id, Agent.values(root.fields, typed));
    }

    function cancel() {
        if (root.request) {
            AgentData.cancel(root.request.id);
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
    WlrLayershell.namespace: "tide-network-prompt"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: AgentData.focused ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
    color: Qt.rgba(0, 0, 0, 0.35)

    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 3)
        width: 440
        height: column.implicitHeight + 40
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        MouseArea {
            anchors.fill: parent
            onClicked: root.focusField(0)
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
                    name: root.request?.kind === "wifi" ? "network-wireless-symbolic" : root.request?.kind === "vpn" ? "network-vpn-symbolic" : "dialog-password-symbolic"
                    color: Theme.accent
                }

                // Names come from the air or a VPN plugin: never markup.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.request?.title ?? ""
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.request?.message ?? ""
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 13
            }

            Repeater {
                id: inputs

                model: root.fields

                Column {
                    id: entry

                    required property var modelData
                    required property int index
                    property alias input: field

                    width: column.width
                    spacing: 4

                    Text {
                        textFormat: Text.PlainText
                        text: String(entry.modelData.label ?? "").replace(/:$/, "")
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 12
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
                            echoMode: entry.modelData.secret ? TextInput.Password : TextInput.Normal
                            // A saved value tide-agent found, to change or keep.
                            text: entry.modelData.value ?? ""
                            color: Theme.fg
                            selectionColor: Theme.accentBg
                            font.family: Theme.font
                            font.pixelSize: 15

                            Keys.onReturnPressed: entry.enter()
                            Keys.onEnterPressed: entry.enter()
                            Keys.onEscapePressed: root.cancel()
                        }
                    }

                    function enter() {
                        if (entry.index + 1 < inputs.count) {
                            root.focusField(entry.index + 1);
                        } else {
                            root.submit();
                        }
                    }

                    // A password is never kept once the prompt hides.
                    Connections {
                        target: root

                        function onWantedChanged() {
                            if (!root.wanted) {
                                field.text = "";
                            }
                        }
                    }
                }
            }

            Row {
                anchors.right: parent.right
                spacing: 8

                Repeater {
                    model: [{
                            label: "Cancel",
                            primary: false
                        }, {
                            label: "Connect",
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
