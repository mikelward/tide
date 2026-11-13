import QtQuick
import Quickshell
import "lib/configerrors.mjs" as Errors

// The config errors' popover (SPEC.md §7.4): how many errors the
// compositor's config has, then each as it reported it, the file and line over
// what's wrong, and what to do about them. A long list is cut short
// (Errors.listed). Plain text, since an error quotes the config file.
PopupWindow {
    id: root

    required property Item icon
    readonly property var errors: ConfigErrorsData.errors
    readonly property var view: Errors.listed(errors, ConfigErrorsData.home)

    function toggle(opener) {
        PopoverData.toggle(root, opener);
    }

    anchor.item: icon
    anchor.edges: Theme.hangEdge | Edges.Right
    anchor.gravity: Theme.hangEdge | Edges.Left
    anchor.margins.top: Theme.hang(10).top
    anchor.margins.bottom: Theme.hang(10).bottom
    grabFocus: true
    color: "transparent"
    implicitWidth: 380
    implicitHeight: card.implicitHeight

    // Fixed, the errors have nothing left to show.
    onErrorsChanged: {
        if (errors.length === 0) {
            visible = false;
        }
    }

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
                rightPadding: 10
                topPadding: 6
                bottomPadding: 6
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: Errors.summary(root.errors, ConfigErrorsData.compositorName)
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }

            Repeater {
                model: root.view.rows

                Column {
                    id: row

                    required property var modelData

                    width: list.width
                    bottomPadding: 6

                    Text {
                        visible: row.modelData.where !== ""
                        width: row.width
                        leftPadding: 10
                        rightPadding: 10
                        wrapMode: Text.WrapAnywhere
                        textFormat: Text.PlainText
                        text: row.modelData.where
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 12
                    }

                    Text {
                        width: row.width
                        leftPadding: 10
                        rightPadding: 10
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: row.modelData.what
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 13
                    }
                }
            }

            Text {
                visible: root.view.more !== ""
                width: list.width
                leftPadding: 10
                rightPadding: 10
                bottomPadding: 6
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.view.more
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 12
            }

            Text {
                width: list.width
                leftPadding: 10
                rightPadding: 10
                topPadding: 2
                bottomPadding: 6
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: Errors.advice(root.errors, ConfigErrorsData.compositorName)
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 12
            }
        }
    }

    PopoverGrab {
        popover: root
    }
}
