import QtQuick
import "lib/barclick.mjs" as Click

// The orange mic pill (SPEC.md §7.4): shown while an app is recording from
// the microphone (MicData), next to the Sharing pill. A click lists the apps
// recording, each of which can be muted.
Rectangle {
    id: root

    // How far its click target reaches past it (Bar.qml).
    property var reach: ({ left: Click.PAD, right: Click.PAD })

    visible: MicData.live
    implicitWidth: visible ? 30 : 0
    implicitHeight: 24
    radius: 12
    color: Theme.warnBg

    // First, so its hover goes over the pill's fill and under its content.
    BarHit {
        reach: root.reach
        behind: false

        TapHandler {
            onTapped: popover.toggle(parent)
        }
    }

    SymbolicIcon {
        anchors.centerIn: parent
        name: "audio-input-microphone-symbolic"
        color: Theme.warn
    }

    MicPopover {
        id: popover

        icon: root
    }
}
