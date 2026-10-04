import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets

// A symbolic icon from the desktop's icon theme in `color`, or, with `file`,
// one of tide's own from shell/icons, for the few the theme has no icon for
// (SPEC.md §15). Symbolic icons come drawn in near-black, and colorizing
// keeps their darkness, so the icon is only a mask: its alpha cuts a fill
// of `color`.
Item {
    id: root

    property string name
    property string file: ""
    property color color: Theme.fg

    implicitWidth: 16
    implicitHeight: 16

    Rectangle {
        id: fill

        anchors.fill: parent
        color: root.color
        visible: false
        layer.enabled: true
    }

    IconImage {
        id: icon

        anchors.fill: parent
        source: root.file !== "" ? Qt.resolvedUrl("icons/" + root.file) : Quickshell.iconPath(root.name, true)
        visible: false
        layer.enabled: true
    }

    // A soft threshold keeps the icon's antialiased edges.
    MultiEffect {
        anchors.fill: parent
        source: fill
        maskEnabled: true
        maskSource: icon
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }
}
