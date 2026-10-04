import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import "lib/history.mjs" as History
import "lib/notifications.mjs" as Notes

// The notification center (SPEC.md §9): the history, grouped by app, under
// the bar at the top right of its monitor. The bell and Super+Shift+N open
// it (HistoryData); a click outside it, or Escape, closes it.
PanelWindow {
    id: root

    // The bar it opens under, which is in its focus grab so the bell can
    // close it again; the bar closes it on any other press (Bar.qml). Not
    // named `bar`, which Bar.qml's `bar: bar` would bind to itself.
    required property var panel

    screen: root.panel.screen
    visible: HistoryData.openOn !== "" && HistoryData.openOn === (root.panel.monitor?.name ?? "")
    anchors {
        top: true
        right: true
    }
    margins {
        top: 8
        right: 10
    }
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    WlrLayershell.namespace: "tide-notifications"
    WlrLayershell.layer: WlrLayer.Overlay
    // The keyboard is its while it's open, so Escape always reaches it
    // (the bar in its focus grab takes no keyboard focus).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: "transparent"
    implicitWidth: 430
    // As tall as its groups, up to the room below the bar; past that the
    // groups scroll.
    implicitHeight: Notes.stackHeight(card.implicitHeight, screen?.height ?? 0, Theme.barHeight + margins.top, 10)

    // The ages tick only while it's open.
    property real now: Date.now()
    // Which groups show all their entries, by app.
    property var expanded: ({})

    onVisibleChanged: {
        now = Date.now();
        if (!visible) {
            expanded = {};
            // The banner has been seen; once the share is over, it goes.
            ShareData.seen();
        }
    }

    Timer {
        running: root.visible
        repeat: true
        interval: 30000
        onTriggered: root.now = Date.now()
    }

    HyprlandFocusGrab {
        windows: [root, root.panel]
        active: root.visible
        onCleared: HistoryData.close()
    }

    Rectangle {
        id: card

        anchors.fill: parent
        implicitHeight: 14 + header.implicitHeight + 12 + dndTile.height + 12 + (heldBanner.visible ? heldBanner.height + 12 : 0) + (list.count > 0 ? groupColumn.implicitHeight : empty.implicitHeight) + 14
        radius: 12
        color: Theme.surface
        border.color: Theme.edge
        focus: true
        Keys.onEscapePressed: HistoryData.close()

        Item {
            id: header

            x: 14
            y: 14
            width: parent.width - 28
            implicitHeight: Math.max(title.implicitHeight, clearAll.implicitHeight)

            Text {
                id: title

                anchors.verticalCenter: parent.verticalCenter
                text: "Notifications"
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 16
                font.weight: Font.Bold
            }

            Rectangle {
                id: clearAll

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: list.count > 0
                implicitWidth: clearLabel.implicitWidth + 20
                implicitHeight: 26
                radius: 7
                color: Theme.surface2

                Text {
                    id: clearLabel

                    anchors.centerIn: parent
                    text: "Clear all"
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 12
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: HistoryData.clearAll()
                }
            }
        }

        // Do not disturb (§9): the mock's quick toggle.
        Rectangle {
            id: dndTile

            x: 14
            y: header.y + header.height + 12
            width: parent.width - 28
            height: 48
            radius: 12
            color: NotificationData.dnd ? Theme.accentBg : Theme.surface2

            SymbolicIcon {
                id: dndIcon

                x: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 20
                height: 20
                name: NotificationData.dnd ? "notifications-disabled-symbolic" : "preferences-system-notifications-symbolic"
                color: NotificationData.dnd ? Theme.accentFg : Theme.fg
            }

            Column {
                anchors.left: dndIcon.right
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    text: "Do not disturb"
                    color: NotificationData.dnd ? Theme.accentFg : Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }

                Text {
                    text: NotificationData.dnd ? "On" : "Off"
                    color: NotificationData.dnd ? Qt.rgba(1, 1, 1, 0.8) : Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 11.5
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: NotificationData.setDnd(!NotificationData.dnd)
            }
        }

        // How many popups a screen share held (§9), until the share after it
        // or the center closes once it's over. Collapsed when there are none.
        Rectangle {
            id: heldBanner

            x: 14
            y: dndTile.y + dndTile.height + (visible ? 12 : 0)
            width: parent.width - 28
            height: visible ? heldText.implicitHeight + 16 : 0
            visible: ShareData.held > 0
            radius: 10
            color: Theme.urgentBg

            Text {
                id: heldText

                anchors.verticalCenter: parent.verticalCenter
                x: 12
                width: parent.width - 24
                text: ShareData.holdingPopups ? `${ShareData.held} held while you're sharing` : `${ShareData.held} held while you were sharing`
                color: Theme.urgent
                font.family: Theme.font
                font.pixelSize: 12.5
                font.weight: Font.DemiBold
            }
        }

        Text {
            id: empty

            x: 14
            y: heldBanner.y + heldBanner.height + 12
            visible: list.count === 0
            text: "No notifications"
            color: Theme.fgDim
            font.family: Theme.font
            font.pixelSize: 12.5
        }

        Flickable {
            x: 14
            y: heldBanner.y + heldBanner.height + 12
            width: parent.width - 28
            height: parent.height - y - 14
            contentWidth: width
            contentHeight: groupColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: groupColumn

                width: parent.width
                spacing: 8

                Repeater {
                    id: list

                    model: ScriptModel {
                        values: History.groups(HistoryData.entries)
                    }

                    Rectangle {
                        id: group

                        required property var modelData
                        readonly property var view: History.shownItems(modelData.items, root.expanded[modelData.app] === true)

                        width: groupColumn.width
                        implicitHeight: groupBody.implicitHeight + 20
                        radius: 12
                        color: Theme.surface2

                        Column {
                            id: groupBody

                            x: 12
                            y: 10
                            width: parent.width - 24
                            spacing: 6

                            Item {
                                width: parent.width
                                height: 18

                                IconImage {
                                    id: appIcon

                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 16
                                    height: 16
                                    source: Notes.iconFile(group.modelData.icon) ?? Quickshell.iconPath(group.modelData.icon || group.modelData.entry || "", "dialog-information")
                                }

                                Text {
                                    anchors.left: appIcon.right
                                    anchors.leftMargin: 8
                                    anchors.right: close.left
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    // Names come from other programs: never markup.
                                    textFormat: Text.PlainText
                                    text: group.modelData.app
                                    color: Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                }

                                SymbolicIcon {
                                    id: close

                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 14
                                    height: 14
                                    name: "window-close-symbolic"
                                    color: Theme.fgDim

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        onClicked: HistoryData.clearApp(group.modelData.app)
                                    }
                                }
                            }

                            Repeater {
                                model: group.view.items

                                Item {
                                    required property var modelData
                                    required property int index

                                    width: groupBody.width
                                    implicitHeight: texts.implicitHeight + 12

                                    // A click runs its action or brings up its
                                    // app (NotificationData.openEntry), and the
                                    // center closes, as it does for any choice.
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            NotificationData.openEntry(modelData);
                                            HistoryData.close();
                                        }
                                    }

                                    Rectangle {
                                        visible: index > 0
                                        width: parent.width
                                        height: 1
                                        color: Theme.edge
                                    }

                                    Column {
                                        id: texts

                                        y: 6
                                        width: parent.width - when.implicitWidth - 10
                                        spacing: 2

                                        Text {
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 2
                                            elide: Text.ElideRight
                                            textFormat: Text.PlainText
                                            text: modelData.summary
                                            color: modelData.critical ? Theme.danger : Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 13
                                            font.weight: Font.DemiBold
                                        }

                                        Text {
                                            visible: text !== ""
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 3
                                            elide: Text.ElideRight
                                            // Only the markup notifications.mjs lets through.
                                            textFormat: Text.StyledText
                                            text: Notes.bodyStyled(modelData.body)
                                            color: Theme.fgDim
                                            font.family: Theme.font
                                            font.pixelSize: 12.5
                                        }
                                    }

                                    Text {
                                        id: when

                                        anchors.right: parent.right
                                        y: 8
                                        text: History.age(modelData.time, root.now)
                                        color: Theme.fgFaint
                                        font.family: Theme.font
                                        font.pixelSize: 11
                                    }
                                }
                            }

                            Text {
                                visible: group.view.more > 0
                                text: `Show ${group.view.more} more`
                                color: Theme.accent
                                font.family: Theme.font
                                font.pixelSize: 12
                                font.weight: Font.DemiBold

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.expanded = Object.assign({}, root.expanded, {
                                        [group.modelData.app]: true
                                    })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
