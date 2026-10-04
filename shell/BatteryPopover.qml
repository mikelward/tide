import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "lib/status.mjs" as Status

// The battery popover (SPEC.md §7.4): the charge and time left, and the
// power profile, which power-profiles-daemon sets for the whole machine.
PopupWindow {
    id: root

    required property Item icon
    readonly property var battery: UPower.displayDevice

    function toggle() {
        visible = !visible;
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 260
    implicitHeight: card.implicitHeight

    Rectangle {
        id: card

        anchors.fill: parent
        implicitHeight: list.implicitHeight + 12
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Column {
            id: list

            anchors.fill: parent
            anchors.margins: 6
            spacing: 2

            Text {
                width: list.width
                leftPadding: 10
                topPadding: 6
                text: Status.batteryView({
                    present: root.battery?.isPresent ?? false,
                    percentage: root.battery?.percentage,
                    state: root.battery?.state,
                }).text
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 20
                font.weight: Font.Bold
                font.features: ({ "tnum": 1 })
            }

            Text {
                width: list.width
                leftPadding: 10
                bottomPadding: 8
                text: Status.batteryStatus({
                    state: root.battery?.state,
                    timeToEmpty: root.battery?.timeToEmpty,
                    timeToFull: root.battery?.timeToFull,
                })
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 12.5
            }

            Repeater {
                model: Status.profileChoices(PowerProfiles.hasPerformanceProfile)

                MenuRow {
                    required property var modelData

                    width: list.width
                    icon: modelData.icon
                    label: modelData.label
                    selected: PowerProfiles.profile === modelData.profile
                    onClicked: PowerProfiles.profile = modelData.profile
                }
            }

            Text {
                readonly property string why: Status.degradedText(PowerProfiles.degradationReason)

                visible: why !== ""
                width: list.width
                leftPadding: 10
                rightPadding: 10
                topPadding: 4
                bottomPadding: 4
                wrapMode: Text.WordWrap
                text: why
                color: Theme.warn
                font.family: Theme.font
                font.pixelSize: 12
            }
        }
    }
}
