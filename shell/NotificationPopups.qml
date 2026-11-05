import QtQuick
import Quickshell
import Quickshell.Wayland
import "lib/notifications.mjs" as Notes

// The notification popups (SPEC.md §9), top right of the focused monitor
// under the bar, newest on top. There's one per monitor, and only the
// focused monitor's shows.
PanelWindow {
    id: root

    required property var modelData
    readonly property bool focused: Compositor.focusedMonitorName !== "" && Compositor.focusedMonitorName === (screen?.name ?? "")
    // Only the focused monitor makes popups, so a hidden one can't hold or
    // act on a notification. None show under an open notification center,
    // which takes the same corner and lists them anyway; a critical one comes
    // back when it closes. (Drafts live in NotificationData, so a reply being
    // typed survives.)
    readonly property bool centerOpen: HistoryData.openOn !== "" && HistoryData.openOn === (screen?.name ?? "")
    readonly property var shown: focused && !centerOpen ? Notes.shown(NotificationData.queue) : []

    screen: modelData
    visible: shown.length > 0
    anchors {
        top: true
        right: true
    }
    margins {
        top: 10
        right: 12
    }
    // Below the bar's exclusive zone, reserving none of its own.
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    // A layer rule can find the popups by this name, to keep them out of a
    // screen share (§9's no_screen_share; TODO.md).
    WlrLayershell.namespace: "tide-notifications"
    WlrLayershell.layer: WlrLayer.Overlay
    // Keyboard focus only for a reply field you click into.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    color: "transparent"
    implicitWidth: 360
    // Three tall popups can outgrow a small output; past the room below
    // the bar, the stack scrolls.
    implicitHeight: Notes.stackHeight(column.implicitHeight, screen?.height ?? 0, Theme.barHeight + margins.top, 12)

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: column

            width: parent.width
            spacing: 10

            Repeater {
                // A ScriptModel adds and removes only the popups that changed,
                // so a notification arriving or going doesn't rebuild the
                // others and lose a reply being typed into one.
                model: ScriptModel {
                    values: root.shown
                }

                NotificationPopup {
                    required property var modelData

                    width: column.width
                    notification: modelData
                }
            }
        }
    }
}
