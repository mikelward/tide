import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Widgets
import "lib/notifications.mjs" as Notes

// One notification popup (SPEC.md §9): the app's icon or the sender's
// image, the app, the summary and body, action buttons, and a reply field
// where the sender offers one. It goes when its time is up (NotificationData
// keeps the countdown), when it's clicked, or when its ✕ is.
Rectangle {
    id: root

    required property var notification

    implicitWidth: 360
    implicitHeight: content.implicitHeight + 24
    radius: 12
    color: Theme.surface
    border.color: notification.urgency === NotificationUrgency.Critical ? Theme.danger : Theme.edge

    // A click on the popup runs the default action (NotificationData.run);
    // without one there's nothing to bring up, and it just dismisses it.
    function run(action) {
        if (action) {
            NotificationData.run(notification, action);
        } else {
            notification.dismiss();
        }
    }

    // Its countdown lives in NotificationData; this popup only holds it
    // while the pointer is on it, and lets go if it goes away mid-hover.
    // An unsent reply holds it there too, by its draft, not by keyboard
    // focus, which another click on the popup can leave behind.
    readonly property bool holding: hover.hovered

    onHoldingChanged: NotificationData.hold(notification, "popup", holding)
    Component.onDestruction: NotificationData.hold(notification, "popup", false)

    HoverHandler {
        id: hover
    }

    // MouseAreas rather than TapHandlers, so a click on ✕, a button or the
    // reply field is that control's alone and doesn't also open the popup.
    MouseArea {
        anchors.fill: parent
        onClicked: root.run(Notes.defaultAction(root.notification.actions))
    }

    Row {
        id: content

        x: 12
        y: 12
        width: parent.width - 24
        spacing: 12

        Item {
            width: 40
            height: 40

            // The sender's image (an avatar, a thumbnail) beats the app's
            // icon.
            Image {
                id: image

                anchors.fill: parent
                visible: status === Image.Ready
                // A theme icon the theme lacks would draw Quickshell's placeholder.
                source: {
                    const name = Notes.themedImageName(root.notification.image);
                    return name !== null && !Quickshell.hasThemeIcon(name) ? "" : root.notification.image;
                }
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }

            IconImage {
                anchors.fill: parent
                visible: !image.visible
                source: Notes.iconFile(root.notification.appIcon) ?? Quickshell.iconPath(root.notification.appIcon || Notes.grantId(root.notification) || "", "application-x-executable")
            }
        }

        Column {
            width: content.width - 52
            spacing: 3

            Item {
                width: parent.width
                height: app.implicitHeight

                Text {
                    id: app

                    width: parent.width - 20
                    elide: Text.ElideRight
                    // Names come from other programs: never markup.
                    textFormat: Text.PlainText
                    // The site, for a web notification (§9).
                    text: Notes.joinLabel(root.notification.appName, Notes.originLabel(Notes.originText(root.notification)))
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 12
                }

                SymbolicIcon {
                    anchors.right: parent.right
                    anchors.verticalCenter: app.verticalCenter
                    width: 14
                    height: 14
                    name: "window-close-symbolic"
                    color: Theme.fgDim

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        onClicked: root.notification.dismiss()
                    }
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.notification.summary
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }

            Text {
                visible: text !== ""
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                // Only the markup notifications.mjs lets through.
                textFormat: Text.StyledText
                text: Notes.bodyStyled(root.notification.body)
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 13
            }

            // Buttons wrap, and a long label elides, so every action stays
            // inside the popup. Past two rows they scroll, so a sender with
            // many actions can't grow the popup off the screen.
            Flickable {
                id: actionArea

                width: parent.width
                visible: buttons.count > 0
                height: Math.min(actionRow.implicitHeight, 6 + 26 * 2 + 6)
                contentWidth: width
                contentHeight: actionRow.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Flow {
                    id: actionRow

                    width: actionArea.width
                    topPadding: 6
                    spacing: 6

                    Repeater {
                        id: buttons

                        model: Notes.buttons(root.notification.actions)

                        Rectangle {
                            required property var modelData

                            implicitWidth: Math.min(label.implicitWidth + 20, actionRow.width)
                            implicitHeight: 26
                            radius: 7
                            color: Theme.surface2

                            Text {
                                id: label

                                anchors.centerIn: parent
                                width: Math.min(implicitWidth, parent.width - 20)
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                                text: modelData.text
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 12
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.run(modelData)
                            }
                        }
                    }
                }
            }

            Rectangle {
                visible: root.notification.hasInlineReply
                width: parent.width
                height: visible ? 30 : 0
                radius: 7
                color: Theme.surface2

                TextInput {
                    id: reply

                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 13
                    // The field mirrors the notification's draft in
                    // NotificationData, the one source: it follows the popup
                    // to whichever monitor shows it, and goes when the draft
                    // is dropped (sent, or an update took the field away).
                    readonly property string draft: NotificationData.drafts[root.notification.id] ?? ""

                    Component.onCompleted: text = draft
                    onDraftChanged: {
                        if (text !== draft) {
                            text = draft;
                        }
                    }
                    onTextChanged: NotificationData.setDraft(root.notification, text)
                    onAccepted: {
                        if (text !== "") {
                            root.notification.sendInlineReply(text);
                            // A reply attends to it too, even when it stays.
                            MarkData.dismissed(root.notification.id);
                        }
                        // Sent, the draft is gone, so a resident notification
                        // that stays gets its time back.
                        text = "";
                        focus = false;
                    }

                    Text {
                        visible: reply.text === ""
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: root.notification.inlineReplyPlaceholder || "Reply…"
                        color: Theme.fgFaint
                        font: reply.font
                    }
                }
            }
        }
    }
}
