import QtQuick
import "lib/share.mjs" as Share

// The red Sharing pill (SPEC.md §7.4): shown while a screen share is live
// (ShareData), so you can see from any monitor that the screen is going
// out. A click says what's shared; stopping it is the app's business.
Rectangle {
    id: root

    visible: Share.sharingPill(ShareData.shares)
    implicitWidth: visible ? row.implicitWidth + 16 : 0
    implicitHeight: 24
    radius: 12
    color: Theme.dangerBg

    Row {
        id: row

        x: 7
        anchors.verticalCenter: parent.verticalCenter
        spacing: 5

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "video-display-symbolic"
            color: "white"
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Sharing"
            color: "white"
            font.family: Theme.font
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }

    TapHandler {
        onTapped: popover.toggle()
    }

    SharingPopover {
        id: popover

        icon: root
    }
}
