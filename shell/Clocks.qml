import QtQuick
import "lib/barclick.mjs" as Click
import "lib/title.mjs" as Title

// The clocks at the bar's right end (SPEC.md §7.3): each listed zone as
// "LABEL HH:MM", then local as "MMM d HH:MM", with a small −1 / +1 on a zone
// whose date differs from local's. A click opens the popover; scrolling
// moves them all in quarter hours, until the pointer leaves. When the bar
// is short of room for its title, `compact` leaves local alone on the bar;
// the popover still lists every zone. An Item around the Row, so the
// click target isn't a Row's child (BarHit.qml).
Item {
    id: root

    property real wheel: 0
    property bool compact: false
    // How far the click target reaches past the clocks (Bar.qml).
    property var reach: ({ left: Click.PAD, right: Click.PAD })
    // Bumped as the Repeater builds or drops a clock; see fullWidth.
    property int built: 0
    // What every clock would take, compact or not, for Bar.qml's decision.
    readonly property real fullWidth: {
        // itemAt() isn't a dependency, and a delegate can be built after
        // count changes (a monitor plugged in once the zones are loaded),
        // so the delegates' coming and going is read here explicitly.
        void root.built;
        let width = 0;
        for (let i = 0; i < clocks.count; i++) {
            const item = clocks.itemAt(i);
            if (item) {
                width += item.implicitWidth + (i > 0 ? clockRow.spacing : 0);
            }
        }
        return width;
    }

    implicitWidth: clockRow.implicitWidth
    implicitHeight: clockRow.implicitHeight

    // One click target for every clock, labels, times and the room
    // between them, so no gap in the span is dead.
    BarHit {
        reach: root.reach

        TapHandler {
            onTapped: popover.toggle(parent)
        }

        WheelHandler {
            onWheel: event => {
                // Up is later.
                root.wheel += event.angleDelta.y;
                const notches = Math.trunc(root.wheel / 120);
                if (notches === 0) {
                    return;
                }
                root.wheel -= notches * 120;
                ClockData.scrub(notches);
            }
        }

        HoverHandler {
            onHoveredChanged: {
                if (!hovered) {
                    root.wheel = 0;
                    ClockData.unscrub();
                }
            }
        }
    }

    ClocksPopover {
        id: popover

        clocks: root
    }

    Row {
        id: clockRow

        spacing: 2

        Repeater {
            id: clocks

            model: ClockData.items
            onItemAdded: root.built++
            onItemRemoved: root.built++

            Item {
                id: clock

                required property var modelData
                readonly property string label: modelData.label
                readonly property string time: modelData.time

                visible: Title.clockShown(root.compact, clock.modelData)
                height: Theme.chipHeight
                // 5 px either side, so clocks sit 12 px apart with the Row's 2.
                implicitWidth: row.implicitWidth + 10

                Row {
                    id: row

                    anchors.centerIn: parent
                    spacing: 5

                    Text {
                        visible: clock.label !== ""
                        anchors.baseline: time.baseline
                        // Labels are any text (SPEC.md §7.3), never markup.
                        textFormat: Text.PlainText
                        text: clock.label
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: clock.modelData.local ? 12 : 11
                        font.weight: clock.modelData.local ? Font.Medium : Font.DemiBold
                        font.letterSpacing: clock.modelData.local ? 0 : 0.4
                    }

                    Text {
                        id: time

                        text: clock.time
                        // Accent while scrubbed, so a moved time isn't taken for now.
                        color: ClockData.scrubAt !== 0 ? Theme.accent : Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 15
                        font.weight: clock.modelData.local ? Font.Bold : Font.Medium
                        font.features: ({ "tnum": 1 })
                    }

                    Text {
                        visible: clock.modelData.dayOffset !== 0
                        anchors.top: time.top
                        text: clock.modelData.dayOffset > 0 ? `+${clock.modelData.dayOffset}` : `−${-clock.modelData.dayOffset}`
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 10
                        font.weight: Font.Bold
                    }
                }
            }
        }
    }
}
