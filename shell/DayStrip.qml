import QtQuick

// One zone's 24 hours on the clocks popover's local strip: night, its day
// (07-20) and working hours (09-17), and a line at now. `day` and `work`
// are popover.mjs's stripSegments; `now` is 0-1.
Rectangle {
    id: root

    property var day: []
    property var work: []
    property real now: 0

    implicitHeight: 14
    radius: 4
    color: Theme.stripNight
    clip: true

    Repeater {
        model: root.day

        Rectangle {
            required property var modelData

            x: root.width * modelData.x
            width: root.width * modelData.width
            height: root.height
            color: Theme.stripDay
        }
    }

    Repeater {
        model: root.work

        Rectangle {
            required property var modelData

            x: root.width * modelData.x
            y: 3
            width: root.width * modelData.width
            height: root.height - 6
            radius: 3
            color: Theme.accent
            opacity: 0.85
        }
    }

    Rectangle {
        x: root.width * root.now - 1
        width: 2
        height: root.height
        color: Theme.stripNow
    }
}
