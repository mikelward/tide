import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import "lib/tray.mjs" as Tray

// Third-party tray icons (SPEC.md §7.4): apps' StatusNotifierItems. Using
// SystemTray makes the shell the org.kde.StatusNotifierWatcher, which
// tide-shell waits for before the session's apps start. A left or
// right click opens the app's menu (§7.4), which TrayMenu draws, a middle
// click activates the app, and scrolling goes to the app.
Row {
    id: root

    spacing: 8

    Repeater {
        model: ScriptModel {
            values: Tray.shownItems(SystemTray.items.values, Status.Passive)
        }

        Item {
            id: slot

            required property var modelData

            width: 18
            height: 18
            anchors.verticalCenter: parent?.verticalCenter

            IconImage {
                anchors.fill: parent
                source: slot.modelData.icon
                asynchronous: true
            }

            TrayMenu {
                id: menu

                icon: slot
                item: slot.modelData
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                onClicked: mouse => {
                    const button = mouse.button === Qt.LeftButton ? "left" : mouse.button === Qt.MiddleButton ? "middle" : "right";
                    switch (Tray.clickAction(button, slot.modelData)) {
                    case "activate":
                        slot.modelData.activate();
                        break;
                    case "secondary":
                        slot.modelData.secondaryActivate();
                        break;
                    case "menu":
                        menu.toggle();
                        break;
                    }
                }
                onWheel: wheel => {
                    const horizontal = wheel.angleDelta.x !== 0 && wheel.angleDelta.y === 0;
                    slot.modelData.scroll(horizontal ? wheel.angleDelta.x : wheel.angleDelta.y, horizontal);
                }
            }
        }
    }
}
