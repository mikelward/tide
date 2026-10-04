import QtQuick
import Quickshell
import "lib/audio.mjs" as Audio
import "lib/mic.mjs" as Mic

// The mic pill's popover (SPEC.md §7.4): each app recording from the
// microphone, and a click mutes or unmutes that app's recording, leaving
// the mic itself and other apps alone. MicData binds the streams, so their
// mute is live.
PopupWindow {
    id: root

    required property Item icon
    readonly property var rows: Mic.captureRows(MicData.captures, Audio.streamLabel)

    function toggle() {
        visible = !visible;
    }

    // Closes when the last app stops recording, rather than staying up empty.
    onRowsChanged: {
        if (rows.length === 0) {
            visible = false;
        }
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 280
    implicitHeight: list.implicitHeight + 12

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Column {
            id: list

            x: 6
            y: 6
            width: parent.width - 12
            spacing: 2

            Text {
                leftPadding: 10
                topPadding: 8
                bottomPadding: 2
                text: "USING THE MICROPHONE"
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 11
                font.weight: Font.Bold
                font.letterSpacing: 0.5
            }

            Repeater {
                model: root.rows

                MenuRow {
                    required property var modelData

                    width: list.width
                    icon: modelData.icon
                    label: modelData.label
                    onClicked: {
                        if (modelData.ready) {
                            modelData.node.audio.muted = !modelData.muted;
                        } else {
                            console.warn("tide: mic popover: that app's stream isn't bound yet, so it can't be muted");
                        }
                    }
                }
            }
        }
    }
}
