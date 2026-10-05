import QtQuick
import "lib/clocks.mjs" as Clocks

// The zone clocks on the lock (SPEC.md §10, docs/mocks/lock.png): each
// listed zone as "LABEL HH:MM", with a small −1 / +1 where its date differs
// from local's, from the bar's ClockData. Local's time is the lock's own, so
// it isn't repeated here. clocks.json takes any number of zones and any
// label, so the lock keeps them to one line within `maxWidth`: as many as
// fit, then "+N" for the rest (Clocks.fitCount), and a label too long for
// the line is elided. The popover on the bar lists them all.
Row {
    id: root

    // The label's, the time's and the day marker's color: bright on the
    // password face, low contrast on the screensaver.
    property color labelColor: Qt.rgba(1, 1, 1, 0.55)
    property color timeColor: "#ffffff"
    property real maxWidth: Infinity
    // Bumped as the Repeater builds or drops a clock; see shown.
    property int built: 0
    // How many show: itemAt() isn't a dependency, so the delegates' coming
    // and going is read explicitly, as in Clocks.qml. A hidden clock keeps
    // its implicit width, so this doesn't feed back on itself.
    readonly property int shown: {
        void root.built;
        const widths = [];
        for (let i = 0; i < clocks.count; i++) {
            const item = clocks.itemAt(i);
            widths.push(item ? item.implicitWidth : 0);
        }
        return Clocks.fitCount(widths, root.spacing, root.maxWidth, moreWidth.width);
    }

    spacing: 14

    TextMetrics {
        id: moreWidth

        font: more.font
        text: `+${clocks.count}`
    }

    Repeater {
        id: clocks

        model: Clocks.zoneClocks(ClockData.items)
        onItemAdded: root.built++
        onItemRemoved: root.built++

        Row {
            id: clock

            required property var modelData
            required property int index
            // barClocks's text is "LABEL HH:MM", the time last.
            readonly property int cut: modelData.text.lastIndexOf(" ")

            visible: index < root.shown
            spacing: 4

            Text {
                id: label

                visible: text !== ""
                anchors.baseline: time.baseline
                // Never wider than a line leaves beside the time.
                width: Math.min(implicitWidth, Math.max(0, root.maxWidth - time.implicitWidth - day.implicitWidth - 2 * clock.spacing))
                elide: Text.ElideRight
                // One line, whatever the label holds.
                maximumLineCount: 1
                wrapMode: Text.NoWrap
                // Labels are any text (SPEC.md §7.3), never markup.
                textFormat: Text.PlainText
                text: clock.cut < 0 ? "" : clock.modelData.text.slice(0, clock.cut)
                color: root.labelColor
                font.family: "Inter"
                font.pixelSize: 10
                font.weight: Font.Bold
                font.letterSpacing: 0.5
            }

            Text {
                id: time

                text: clock.modelData.text.slice(clock.cut + 1)
                color: root.timeColor
                font.family: "Inter"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.features: ({ "tnum": 1 })
            }

            Text {
                id: day

                visible: clock.modelData.dayOffset !== 0
                anchors.top: time.top
                text: clock.modelData.dayOffset > 0 ? `+${clock.modelData.dayOffset}` : `−${-clock.modelData.dayOffset}`
                color: root.labelColor
                font.family: "Inter"
                font.pixelSize: 9.5
                font.weight: Font.Bold
            }
        }
    }

    // The clocks that didn't fit.
    Text {
        id: more

        visible: root.shown < clocks.count
        text: `+${clocks.count - root.shown}`
        color: root.labelColor
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.Bold
    }
}
