import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "lib/audio.mjs" as Audio

// The volume popover (SPEC.md §7.4): the output and input devices, with a
// level and mute for the one in use, and each app playing sound with its
// own. Clicking a device makes it the default.
PopupWindow {
    id: root

    required property Item icon
    readonly property var lists: Audio.audioLists(Pipewire.nodes.values, {
        sink: PwNodeType.AudioSink,
        source: PwNodeType.AudioSource,
        outStream: PwNodeType.AudioOutStream,
    })

    function toggle() {
        visible = !visible;
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 320
    // No taller than most of the screen; the rows scroll past that.
    implicitHeight: Math.min(list.implicitHeight + 12, (screen?.height ?? 800) * 0.8)

    // Levels and mute are only live on bound nodes; only while it's open.
    PwObjectTracker {
        objects: root.visible ? root.lists.apps.concat([Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]).filter(n => n) : []
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

    Rectangle {
        id: card

        anchors.fill: parent
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Flickable {
            anchors.fill: parent
            anchors.margins: 6
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: list

                width: parent.width
                spacing: 2

                Heading {
                    text: "OUTPUT"
                }

                VolumeControl {
                    width: list.width
                    visible: Pipewire.defaultAudioSink !== null
                    node: Pipewire.defaultAudioSink
                }

                Repeater {
                    model: root.lists.outputs

                    MenuRow {
                        required property var modelData

                        width: list.width
                        icon: "audio-speakers-symbolic"
                        label: Audio.deviceLabel(modelData)
                        selected: Pipewire.defaultAudioSink === modelData
                        onClicked: Pipewire.preferredDefaultAudioSink = modelData
                    }
                }

                Heading {
                    visible: root.lists.inputs.length > 0
                    text: "INPUT"
                }

                VolumeControl {
                    width: list.width
                    visible: Pipewire.defaultAudioSource !== null
                    node: Pipewire.defaultAudioSource
                }

                Repeater {
                    model: root.lists.inputs

                    MenuRow {
                        required property var modelData

                        width: list.width
                        icon: "audio-input-microphone-symbolic"
                        label: Audio.deviceLabel(modelData)
                        selected: Pipewire.defaultAudioSource === modelData
                        onClicked: Pipewire.preferredDefaultAudioSource = modelData
                    }
                }

                Heading {
                    visible: root.lists.apps.length > 0
                    text: "APPS"
                }

                Repeater {
                    model: root.lists.apps

                    Column {
                        required property var modelData

                        width: list.width

                        Text {
                            width: parent.width
                            leftPadding: 10
                            rightPadding: 10
                            elide: Text.ElideRight
                            // App names come from the apps: never markup.
                            textFormat: Text.PlainText
                            text: Audio.streamLabel(parent.modelData)
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 12.5
                        }

                        VolumeControl {
                            width: parent.width
                            node: parent.modelData
                        }
                    }
                }
            }
        }
    }
}
