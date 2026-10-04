import QtQuick
import Quickshell
import Quickshell.Networking
import "lib/network.mjs" as Net

// The network popover (SPEC.md §7.4): Wi-Fi on or off, the networks in
// range, and NetworkManager's editor for everything else. A network that
// needs a password asks for it here, once NetworkManager says so. There's
// one per monitor; what they share lives in NetworkData.
PopupWindow {
    id: root

    required property Item icon
    required property var devices
    // The network this popover last asked to connect, and so the only one
    // whose failure it answers, and the network waiting for its password
    // (Net.prompt).
    property var promptState: Net.NO_PROMPT
    readonly property var pending: promptState.pending
    readonly property var asking: promptState.asking

    function prompt(event) {
        promptState = Net.prompt(promptState, event);
    }

    onAskingChanged: {
        if (asking) {
            flick.contentY = 0;
        }
    }

    function toggle() {
        visible = !visible;
    }

    // However it closes (a click outside, or toggle), it forgets the
    // network it was asking about.
    onVisibleChanged: {
        // Scanning is shared across monitors' popovers (NetworkData).
        NetworkData.open = Net.trackOpen(NetworkData.open, root, visible);
        if (!visible) {
            prompt({ type: "cancel" });
        }
    }

    // A monitor unplugged with its popover open still counts it closed.
    Component.onDestruction: NetworkData.open = Net.trackOpen(NetworkData.open, root, false)

    // Only the network this popover asked to connect: every monitor's
    // popover hears every network, so this answers just its own request.
    Connections {
        target: root.pending

        function onConnectionFailed(reason) {
            const network = root.pending;
            const noSecrets = reason === ConnectionFailReason.NoSecrets;
            root.prompt({ type: "failed", network: network, noSecrets: noSecrets });
            if (!noSecrets) {
                console.warn(`tide: couldn't connect to ${network.name}: ${ConnectionFailReason.toString(reason)}`);
            }
        }
    }

    // Wi-Fi switched off by anything (this row, a key, another client)
    // cancels the prompt, so no password goes to a radio that's off.
    Connections {
        target: Networking

        function onWifiEnabledChanged() {
            root.prompt({ type: "wifi", enabled: Networking.wifiEnabled });
        }
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 300
    // No taller than most of the screen; the rows scroll past that.
    implicitHeight: Math.min(list.implicitHeight + 12, (screen?.height ?? 800) * 0.8)

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Flickable {
            id: flick

            anchors.fill: parent
            anchors.margins: 6
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: list

                width: parent.width
                spacing: 2

                MenuRow {
                    width: list.width
                    icon: "network-wireless-symbolic"
                    label: "Wi-Fi"
                    selected: Networking.wifiEnabled
                    onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
                }

                // The password, when NetworkManager has none saved for the
                // network this popover tried. It's at the top, where it's in
                // view however long the list below is.
                Rectangle {
                    visible: root.asking !== null
                    width: list.width
                    height: visible ? 52 : 0
                    radius: 7
                    color: Theme.surface2
                    // A password is never kept once the field hides.
                    onVisibleChanged: {
                        if (!visible) {
                            password.text = "";
                        }
                    }

                    Text {
                        x: 10
                        y: 6
                        width: parent.width - 20
                        elide: Text.ElideRight
                        // Network names come from the air: never markup.
                        textFormat: Text.PlainText
                        text: `Password for ${root.asking?.name ?? ""}`
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 11.5
                    }

                    TextInput {
                        id: password

                        x: 10
                        y: 26
                        width: parent.width - 20
                        height: 20
                        verticalAlignment: TextInput.AlignVCenter
                        echoMode: TextInput.Password
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 13
                        focus: parent.visible
                        onAccepted: {
                            // Hiding the field clears it, so read it first.
                            const network = root.asking;
                            const psk = text;
                            if (!network) {
                                return;
                            }
                            root.prompt({ type: "submit" });
                            network.connectWithPsk(psk);
                        }
                        Keys.onEscapePressed: root.prompt({ type: "cancel" })

                        Text {
                            visible: password.text === ""
                            anchors.verticalCenter: parent.verticalCenter
                            text: "then Enter"
                            color: Theme.fgFaint
                            font: password.font
                        }
                    }
                }

                // Scans rebuild these rows, so they hold no state of their
                // own: the pending connection and the password live elsewhere.
                Repeater {
                    model: Networking.wifiEnabled ? Net.wifiList(root.devices) : []

                    MenuRow {
                        required property var modelData
                        readonly property string status: Net.wifiStatus(modelData)

                        width: list.width
                        icon: Net.signalIcon(modelData.signalStrength)
                        label: status ? `${modelData.name} · ${status}` : modelData.name
                        selected: modelData.connected
                        onClicked: {
                            if (modelData.connected) {
                                modelData.disconnect();
                            } else {
                                root.prompt({ type: "connect", network: modelData });
                                modelData.connect();
                            }
                        }
                    }
                }

                MenuRow {
                    width: list.width
                    icon: "preferences-system-network-symbolic"
                    label: "Network settings…"
                    onClicked: {
                        root.visible = false;
                        // The same path as keys and the launcher (SPEC.md §5.4).
                        Launcher.launch(["nm-connection-editor"]);
                    }
                }
            }
        }
    }
}
