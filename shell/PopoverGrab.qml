import QtQuick
import Quickshell

// A bar popover's bookkeeping: it tells PopoverData when it opens, closes
// and goes away, so at most one is open (SPEC.md §7.1). The popover itself
// sets PopupWindow's grabFocus. Without it, Quickshell makes the popup a
// Qt::ToolTip window (0.3, src/window/popupwindow.cpp completeWindow),
// which takes no hover or clicks. A HyprlandFocusGrab in its place, tried
// so a press on the bar would reach the bar, left every popover dead.
Scope {
    id: root

    required property var popover

    Connections {
        target: root.popover

        function onVisibleChanged() {
            PopoverData.shown(root.popover);
        }
    }

    // Goes with its popover, which mustn't count as open after it.
    Component.onDestruction: PopoverData.gone(root.popover)
}
