import QtQuick
import "lib/barsettings.mjs" as BarSettings

// The last row of a bar item's dropdown (SPEC.md §7.1): Settings…, under a
// line, which closes the dropdown and opens the page a right-click on the
// item opens. An item whose right-click opens the Bar page, as no page of
// its own fits, has no such row (barsettings_test.mjs checks).
Column {
    id: root

    // The bar item, as lib/barsettings.mjs names it.
    required property string item
    // The dropdown it's in, which it closes.
    required property var popover

    Item {
        width: root.width
        height: 9

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            height: 1
            color: Theme.edge
        }
    }

    MenuRow {
        width: root.width
        icon: "preferences-system-symbolic"
        label: "Settings…"
        onClicked: {
            root.popover.visible = false;
            SettingsData.open(BarSettings.page(root.item));
        }
    }
}
