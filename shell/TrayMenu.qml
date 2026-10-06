import QtQuick
import Quickshell
import "lib/tray.mjs" as Tray

// A tray item's menu (SPEC.md §7.4), drawn as the bar's other menus are,
// from the app's DBusMenu as Quickshell reads it. A click on an entry sends
// it to the app and closes the menu; a submenu opens in the menu's place,
// under a row that goes back.
PopupWindow {
    id: root

    required property Item icon
    // The SystemTray item whose menu this is.
    required property var item
    // The submenus opened, outermost first.
    property var path: []
    readonly property var rows: Tray.menuRows((path.length > 0 ? sub : top).children?.values ?? [])
    // Labels line up when any row has an icon.
    readonly property bool indent: rows.some(r => !r.separator && r.icon !== "")

    function toggle() {
        visible = !visible;
    }

    function click(row) {
        switch (Tray.rowClick(row)) {
        case "open":
            path = path.concat([row.entry]);
            break;
        case "trigger":
            row.entry.triggered();
            visible = false;
            break;
        }
    }

    // However it closes, it opens at the top next time.
    onVisibleChanged: {
        if (!visible) {
            path = [];
        }
    }
    onPathChanged: flick.contentY = 0

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 260
    // No taller than most of the screen; the rows scroll past that.
    implicitHeight: Math.min(list.implicitHeight + 12, (screen?.height ?? 800) * 0.8)

    // The app's menu, held while open: holding it has the app send its
    // entries, and letting go of it drops them all, a submenu's included,
    // so it's held for as long as any submenu is shown.
    QsMenuOpener {
        id: top

        menu: root.visible ? root.item.menu : null
    }

    // The submenu shown. An app that rebuilds its menu drops it, so the
    // menu goes back to the top.
    QsMenuOpener {
        id: sub

        menu: root.visible && root.path.length > 0 ? root.path[root.path.length - 1] : null
        onMenuChanged: {
            if (menu === null && root.visible && root.path.length > 0) {
                root.path = [];
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Flickable {
            id: flick

            anchors.fill: parent
            anchors.margins: 6
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: list

                width: parent.width
                spacing: 2

                // Back out of a submenu, which it names.
                MenuRow {
                    visible: root.path.length > 0
                    width: list.width
                    icon: "go-previous-symbolic"
                    label: root.path.length > 0 ? root.path[root.path.length - 1]?.text ?? "" : ""
                    onClicked: root.path = root.path.slice(0, -1)
                }

                Repeater {
                    model: root.rows

                    Item {
                        id: slot

                        required property var modelData

                        width: list.width
                        implicitHeight: modelData.separator ? 9 : row.implicitHeight

                        Rectangle {
                            visible: slot.modelData.separator
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            height: 1
                            color: Theme.edge
                        }

                        MenuRow {
                            id: row

                            visible: !slot.modelData.separator
                            width: parent.width
                            enabled: slot.modelData.enabled ?? false
                            image: slot.modelData.icon ?? ""
                            indent: root.indent
                            label: slot.modelData.label ?? ""
                            selected: slot.modelData.checked ?? false
                            submenu: slot.modelData.submenu ?? false
                            onClicked: root.click(slot.modelData)
                        }
                    }
                }
            }
        }
    }
}
