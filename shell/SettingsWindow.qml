import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import "lib/audio.mjs" as Audio
import "lib/settings.mjs" as Settings

// The settings panel (SPEC.md §16), centered on the focused monitor over a
// dimmed backdrop, as the launcher is: the pages down the side, the one
// chosen beside them, and at its foot the app that does the rest. The
// launcher's Settings action or `qs -c tide ipc call settings toggle` opens
// and closes it; Escape or a click on the backdrop closes it. Up and Down
// change the page, and Enter opens its app.
PanelWindow {
    id: root

    property int page: 0
    readonly property var current: Settings.PAGES[page]

    function open() {
        if (visible) {
            return;
        }
        const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor);
        if (focused) {
            screen = focused;
        }
        page = 0;
        visible = true;
        keys.forceActiveFocus();
    }

    function close() {
        visible = false;
    }

    function toggle() {
        if (visible) {
            close();
        } else {
            open();
        }
    }

    // Closes first, so the app opens over the desktop, not under the panel.
    function advanced() {
        const command = current.advanced.command;
        close();
        Launcher.launch(command);
    }

    visible: false
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive, as the launcher's, so the window under the pointer can't
    // take the keyboard back while it's open (§14.2).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.35)

    IpcHandler {
        target: "settings"

        function toggle(): void {
            root.toggle();
        }
        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
    }

    Connections {
        target: SettingsData

        function onOpenRequested() {
            root.open();
        }
    }

    // The Sound page's levels are only live on bound nodes; only while it shows.
    PwObjectTracker {
        objects: root.visible && root.current.id === "sound" ? [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource].filter(n => n) : []
    }

    component Heading: Text {
        leftPadding: 10
        topPadding: 8
        bottomPadding: 2
        color: Theme.fgDim
        font.family: Theme.font
        font.pixelSize: 11
        font.weight: Font.Bold
        font.letterSpacing: 0.5
    }

    // A click on the backdrop closes it; the card takes its own clicks.
    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    Rectangle {
        id: card

        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 3)
        width: 640
        height: 440
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        MouseArea {
            anchors.fill: parent
        }

        // Holds the keyboard while it's open.
        Item {
            id: keys

            focus: true
            Keys.onEscapePressed: root.close()
            Keys.onUpPressed: root.page = Settings.movedPage(root.page, -1)
            Keys.onDownPressed: root.page = Settings.movedPage(root.page, 1)
            Keys.onReturnPressed: root.advanced()
            Keys.onEnterPressed: root.advanced()
        }

        Column {
            id: sidebar

            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 6
            width: 180
            spacing: 2

            Repeater {
                model: Settings.PAGES

                MenuRow {
                    required property var modelData
                    required property int index

                    width: sidebar.width
                    icon: modelData.icon
                    label: modelData.label
                    highlighted: index === root.page
                    onClicked: root.page = index
                }
            }
        }

        Rectangle {
            id: divider

            anchors.left: sidebar.right
            anchors.leftMargin: 6
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: Theme.edge
        }

        Item {
            anchors.left: divider.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: 6

            Text {
                id: title

                width: parent.width
                leftPadding: 10
                topPadding: 6
                bottomPadding: 6
                text: root.current.label
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 20
                font.weight: Font.Bold
            }

            Flickable {
                anchors.top: title.bottom
                anchors.bottom: advancedRow.top
                anchors.bottomMargin: 6
                width: parent.width
                contentHeight: pageColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: pageColumn

                    width: parent.width
                    spacing: 2

                    Text {
                        visible: root.current.about !== ""
                        width: parent.width
                        leftPadding: 10
                        rightPadding: 10
                        wrapMode: Text.WordWrap
                        text: root.current.about
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 13
                    }

                    // Sound: the output and input devices, as the volume
                    // popover lists them, with the level and mute of each
                    // one in use.
                    Column {
                        id: sound

                        readonly property var lists: Audio.audioLists(Pipewire.nodes.values, {
                            sink: PwNodeType.AudioSink,
                            source: PwNodeType.AudioSource,
                            outStream: PwNodeType.AudioOutStream,
                        })

                        visible: root.current.id === "sound"
                        width: parent.width
                        spacing: 2

                        Heading {
                            text: "OUTPUT"
                        }

                        VolumeControl {
                            width: sound.width
                            visible: Pipewire.defaultAudioSink !== null
                            node: Pipewire.defaultAudioSink
                        }

                        Repeater {
                            model: sound.lists.outputs

                            MenuRow {
                                required property var modelData

                                width: sound.width
                                icon: "audio-speakers-symbolic"
                                label: Audio.deviceLabel(modelData)
                                selected: Pipewire.defaultAudioSink === modelData
                                onClicked: Pipewire.preferredDefaultAudioSink = modelData
                            }
                        }

                        Heading {
                            visible: sound.lists.inputs.length > 0
                            text: "INPUT"
                        }

                        VolumeControl {
                            width: sound.width
                            visible: Pipewire.defaultAudioSource !== null
                            node: Pipewire.defaultAudioSource
                        }

                        Repeater {
                            model: sound.lists.inputs

                            MenuRow {
                                required property var modelData

                                width: sound.width
                                icon: "audio-input-microphone-symbolic"
                                label: Audio.deviceLabel(modelData)
                                selected: Pipewire.defaultAudioSource === modelData
                                onClicked: Pipewire.preferredDefaultAudioSource = modelData
                            }
                        }
                    }
                }
            }

            MenuRow {
                id: advancedRow

                anchors.bottom: parent.bottom
                width: parent.width
                icon: "window-new-symbolic"
                label: root.current.advanced.label
                onClicked: root.advanced()
            }
        }
    }
}
