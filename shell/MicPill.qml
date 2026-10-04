import QtQuick

// The orange mic pill (SPEC.md §7.4): shown while an app is recording from
// the microphone (MicData), next to the Sharing pill. A click lists the apps
// recording, each of which can be muted.
Rectangle {
    id: root

    visible: MicData.live
    implicitWidth: visible ? 30 : 0
    implicitHeight: 24
    radius: 12
    color: Theme.warnBg

    SymbolicIcon {
        anchors.centerIn: parent
        name: "audio-input-microphone-symbolic"
        color: Theme.warn
    }

    TapHandler {
        onTapped: popover.toggle()
    }

    MicPopover {
        id: popover

        icon: root
    }
}
