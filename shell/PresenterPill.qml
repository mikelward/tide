import QtQuick
import "lib/barclick.mjs" as Click

// The Presenting pill (SPEC.md §7.4): shown while presenter mode is on
// (PresenterData), in the accent color, so it reads as something you
// turned on rather than a warning. A click turns presenter mode off.
Rectangle {
    id: root

    // How far its click target reaches past it (Bar.qml).
    property var reach: ({ left: Click.PAD, right: Click.PAD })

    visible: PresenterData.on
    implicitWidth: visible ? row.implicitWidth + 16 : 0
    implicitHeight: 24
    radius: 12
    color: Theme.accentBg

    // First, so its hover goes over the pill's fill and under its content.
    BarHit {
        reach: root.reach
        behind: false

        TapHandler {
            onTapped: PresenterData.toggle()
        }
    }

    Row {
        id: row

        x: 7
        anchors.verticalCenter: parent.verticalCenter
        spacing: 5

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "x-office-presentation-symbolic"
            color: Theme.accentFg
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Presenting"
            color: Theme.accentFg
            font.family: Theme.font
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }

}
