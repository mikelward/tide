import QtQuick
import QtQuick.Layouts
import Quickshell
import "lib/popover.mjs" as Pop
import "lib/dst.mjs" as Dst
import "lib/tzdata.mjs" as Tz

// The clocks popover (SPEC.md §7.3, docs/mocks/clocks.png): the time and
// date, each zone with its offset from local and a 24-hour strip, the next
// DST change, and a month calendar. It hangs from the clocks' bottom-right
// corner and closes on a click outside.
PopupWindow {
    id: root

    required property Item clocks

    readonly property var table: ClockData.table
    readonly property real now: ClockData.now
    readonly property var listed: table ? ClockData.good.filter(c => table.periods.has(c.zone)) : []
    readonly property int localOffset: table ? Tz.offsetOf(table)(table.localZone, now) : 0
    readonly property var rows: table ? Pop.popoverZones({
        clocks: listed,
        localZone: table.localZone,
        instant: now,
        offsetOf: Tz.offsetOf(table),
        abbrOf: Tz.abbrOf(table),
    }) : []
    readonly property var change: table ? Dst.nextDstChange({
        clocks: Pop.dstClocks(listed, table.localZone),
        periodsOf: zone => table.periods.get(zone),
        now: now,
    }) : null
    readonly property var today: Pop.localDate(now, localOffset)

    // The month the calendar shows; back to today's each time it opens.
    property int year: today.year
    property int month: today.month

    function toggle() {
        if (!visible) {
            year = today.year;
            month = today.month;
        }
        visible = !visible;
    }

    function step(by) {
        const m = Pop.stepMonth(year, month, by);
        year = m.year;
        month = m.month;
    }

    anchor.item: clocks
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -6
    grabFocus: true
    color: "transparent"
    implicitWidth: 640
    implicitHeight: card.implicitHeight

    Rectangle {
        id: card

        anchors.fill: parent
        implicitHeight: content.implicitHeight + 32
        radius: 16
        color: Theme.surface
        border.color: Theme.edge

        ColumnLayout {
            id: content

            anchors.fill: parent
            anchors.margins: 18
            anchors.bottomMargin: 14
            spacing: 0

            Row {
                spacing: 12

                Text {
                    id: big

                    text: Pop.heading(root.now, root.localOffset).time
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 34
                    font.weight: Font.Bold
                    font.features: ({ "tnum": 1 })
                }

                Text {
                    anchors.baseline: big.baseline
                    text: Pop.heading(root.now, root.localOffset).date
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 15
                    font.weight: Font.Medium
                }
            }

            Repeater {
                model: root.rows

                RowLayout {
                    id: zone

                    required property var modelData
                    required property int index

                    Layout.topMargin: index === 0 ? 14 : 4
                    Layout.preferredHeight: 34
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        Layout.preferredWidth: 40
                        // Labels are any text (SPEC.md §7.3), never markup,
                        // and a long one is cut to its column.
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: zone.modelData.label || (zone.modelData.local ? "—" : "")
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        font.letterSpacing: 0.5
                    }

                    Text {
                        Layout.preferredWidth: 150
                        elide: Text.ElideRight
                        textFormat: Text.StyledText
                        text: `${Pop.escapeStyled(zone.modelData.city)} <font color="${Theme.fgFaint}">${Pop.escapeStyled(zone.modelData.abbr)}</font>`
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 13
                        font.weight: zone.modelData.local ? Font.Bold : Font.Normal
                    }

                    Text {
                        Layout.preferredWidth: 58
                        text: zone.modelData.time
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                        font.features: ({ "tnum": 1 })
                    }

                    DayStrip {
                        Layout.fillWidth: true
                        day: zone.modelData.day
                        work: zone.modelData.work
                        now: Pop.nowFraction(root.now, root.localOffset)
                    }

                    Text {
                        Layout.preferredWidth: 54
                        horizontalAlignment: Text.AlignRight
                        text: zone.modelData.offset
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 12
                        font.features: ({ "tnum": 1 })
                    }
                }
            }

            // The strip's hours, under the strips' column.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: 2
                Layout.leftMargin: 40 + 150 + 58 + 30
                Layout.rightMargin: 54 + 10
                implicitHeight: 14

                Repeater {
                    model: [0, 6, 12, 18, 24]

                    Text {
                        required property int modelData

                        x: parent.width * modelData / 24 - width / 2
                        text: modelData
                        color: Theme.fgFaint
                        font.family: Theme.font
                        font.pixelSize: 10
                    }
                }
            }

            Rectangle {
                visible: root.change !== null
                Layout.fillWidth: true
                Layout.topMargin: 12
                implicitHeight: dst.implicitHeight + 18
                radius: 10
                color: Theme.surface2

                Row {
                    anchors.fill: parent
                    anchors.margins: 9
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 8

                    SymbolicIcon {
                        name: "preferences-system-time-symbolic"
                        color: Theme.warn
                        width: 16
                        height: 16
                    }

                    Text {
                        id: dst

                        width: parent.width - 24
                        wrapMode: Text.WordWrap
                        textFormat: Text.StyledText
                        lineHeight: 1.2
                        // Labels are any text (SPEC.md §7.3), so the message is escaped.
                        text: `<b>${Pop.dstLead(root.change, root.now)}</b> ${Pop.escapeStyled(Dst.dstMessage(root.change))}`
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 12.5
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 16
                spacing: 6

                CalendarButton {
                    icon: "go-previous-symbolic"
                    onClicked: root.step(-1)
                }

                Text {
                    text: Pop.monthTitle(root.year, root.month)
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 13.5
                    font.weight: Font.Bold
                }

                CalendarButton {
                    icon: "go-next-symbolic"
                    onClicked: root.step(1)
                }

                Item {
                    Layout.fillWidth: true
                }

                Text {
                    text: `week ${Pop.isoWeek(root.today.year, root.today.month, root.today.date)}`
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 11.5
                    font.weight: Font.Medium
                }
            }

            // ISO week numbers down the left (SPEC.md §7.3), then Monday to Sunday.
            GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                columns: 8
                rowSpacing: 2
                columnSpacing: 2

                Repeater {
                    model: ["", "M", "T", "W", "T", "F", "S", "S"]

                    Text {
                        required property string modelData
                        required property int index

                        Layout.fillWidth: index > 0
                        Layout.preferredWidth: index > 0 ? -1 : 28
                        Layout.preferredHeight: 24
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: modelData
                        color: Theme.fgFaint
                        font.family: Theme.font
                        font.pixelSize: 10.5
                        font.weight: Font.Bold
                    }
                }

                Repeater {
                    model: Pop.calendarCells(Pop.monthGrid(root.year, root.month, root.today, Pop.changeDays(root.change, ms => Tz.offsetOf(root.table)(root.table.localZone, ms))))

                    Rectangle {
                        required property var modelData
                        readonly property bool isWeek: modelData.week !== undefined

                        Layout.fillWidth: !isWeek
                        Layout.preferredWidth: isWeek ? 28 : -1
                        Layout.preferredHeight: 26
                        radius: 7
                        color: modelData.today ? Theme.accentBg : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: parent.isWeek ? parent.modelData.week : parent.modelData.date
                            color: parent.modelData.today ? Theme.accentFg : parent.isWeek || parent.modelData.outside ? Theme.fgFaint : Theme.fg
                            font.family: Theme.font
                            font.pixelSize: parent.isWeek ? 10.5 : 12.5
                            font.weight: parent.modelData.today ? Font.Bold : Font.Normal
                            font.features: ({ "tnum": 1 })
                        }

                        // A day the clocks change.
                        Rectangle {
                            visible: parent.modelData.mark === true
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: parent.width - 8
                            height: 2
                            color: Theme.warn
                        }
                    }
                }
            }
        }
    }
}
