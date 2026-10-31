import QtQuick
import Quickshell
import Quickshell.Hyprland

// A bar popover's focus grab, in place of PopupWindow's grabFocus. That one
// is an xdg_popup grab, which Hyprland gives only the popup and its xdg
// parent, never a layer-shell parent like the bar; so a press on the bar
// went to the popup and only ended the grab, and the first click on another
// icon did nothing (Hyprland 0.56.2, InputManager.cpp mouseMoveUnified and
// processMouseDownNormal; protocols/XDGShell.cpp addOrStartGrab). This grab
// takes in every bar, so a press there reaches the bar, which closes the
// popover itself (PopoverData.pressed); a press anywhere else clears it.
Scope {
    id: root

    required property var popover

    HyprlandFocusGrab {
        windows: [root.popover].concat(PopoverData.bars)
        active: root.popover.visible
        onCleared: root.popover.visible = false
    }

    Connections {
        target: root.popover

        function onVisibleChanged() {
            PopoverData.shown(root.popover);
        }
    }

    // Goes with its popover, which mustn't count as open after it.
    Component.onDestruction: PopoverData.gone(root.popover)
}
