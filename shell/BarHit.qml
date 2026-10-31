import QtQuick
import Quickshell
import "lib/barclick.mjs" as Click

// A bar item's click target (SPEC.md §7.1): its whole span, the bar's full
// height, and `reach` past its ends, {left, right}, which splits the gap
// with its neighbors so none of it is dead. Hovered, it shows as a rounded
// rect, a touch darker while pressed. Its handlers go in it. It takes no
// room of its own, so it never changes the visual spacing.
//
// Never make it a Row's own child: a positioner culls a child with no
// width or height, which then gets no pointer events (Qt 6.10,
// qquickpositioners.cpp prePositioning). For a Row's span, put it in the
// Row's first child and name the Row as `span`. barhit_test.mjs checks.
Item {
    id: root

    // The item whose span it covers: its parent, or its parent's parent.
    property Item span: parent
    property var reach: ({ left: Click.PAD, right: Click.PAD })
    // How tall the target is, centered on the span: the bar's height, or
    // less for one inside another (a window's icon in its workspace).
    property real targetHeight: Theme.barHeight
    // Behind the item, for one with no fill of its own. One with a fill (a
    // pill, a workspace) sets it false and puts this first, so the rect
    // goes over the fill and under the content.
    property bool behind: true
    // The click target itself, which a popover's toggle names as its opener.
    readonly property alias area: area
    readonly property bool hovered: hover.hovered
    readonly property bool pressed: press.active
    default property alias content: area.data

    width: 0
    height: 0
    z: behind ? -1 : 0

    Item {
        id: area

        // The bar it's on, for PopoverData.pressed.
        readonly property var barWindow: QsWindow.window
        readonly property var rect: Click.hitRect({
            width: root.span?.width ?? 0,
            height: root.span?.height ?? 0,
            barHeight: root.targetHeight,
            left: root.reach.left,
            right: root.reach.right
        })
        // Where its parent sits in the span, when that's not the span.
        readonly property real dx: root.parent !== root.span ? (root.parent?.x ?? 0) : 0
        readonly property real dy: root.parent !== root.span ? (root.parent?.y ?? 0) : 0

        x: rect.x - dx
        y: rect.y - dy
        width: rect.width
        height: rect.height

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: Math.min(Theme.chipHeight, parent.height)
            radius: Theme.chipRadius
            color: root.pressed ? Theme.pressed : Theme.hover
            visible: root.hovered || root.pressed
        }

        HoverHandler {
            id: hover
        }

        // Only watches, so the press still reaches the handlers here.
        PointHandler {
            id: press

            acceptedButtons: Qt.AllButtons
        }
    }
}
