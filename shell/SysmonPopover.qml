import QtQuick
import Quickshell
import "lib/sysmon.mjs" as Sysmon

// The system monitor popover (SPEC.md §7.4): a readout of CPU, memory and
// the CPU's temperature, then a CPU tab (temperature, clock, throttling and
// the processes using the most CPU) and a Memory tab (memory, swap and the
// processes using the most). It opens on CPU. The readings are
// SysmonData's, shared across monitors.
PopupWindow {
    id: root

    required property Item icon
    property string tab: "cpu"

    function toggle() {
        visible = !visible;
    }

    onVisibleChanged: {
        SysmonData.open = Sysmon.trackOpen(SysmonData.open, root, visible);
        if (visible) {
            root.tab = "cpu";
        }
    }

    // A monitor unplugged with its popover open still counts it closed.
    Component.onDestruction: SysmonData.open = Sysmon.trackOpen(SysmonData.open, root, false)

    function toneColor(tone) {
        return tone === "danger" ? Theme.danger : tone === "warn" ? Theme.warn : Theme.fg;
    }

    readonly property string tempTone: {
        const level = Sysmon.tempLevel(SysmonData.temp, SysmonData.sensor);
        return level === "critical" ? "danger" : level === "hot" ? "warn" : "normal";
    }
    readonly property string memoryTone: {
        const m = SysmonData.memory;
        return m && m.total > 0 && m.used / m.total >= Sysmon.MEMORY_HIGH ? "warn" : "normal";
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 300
    implicitHeight: card.implicitHeight

    component Readout: Column {
        property string label
        property string value
        property color ink: Theme.fg

        spacing: 2

        Text {
            text: parent.label
            color: Theme.fgDim
            font.family: Theme.font
            font.pixelSize: 11.5
        }

        Text {
            text: parent.value || "–"
            color: parent.ink
            font.family: Theme.font
            font.pixelSize: 18
            font.weight: Font.Bold
            font.features: ({ "tnum": 1 })
        }
    }

    // Inline components can't see this file's ids, so a tab is told
    // whether it's the chosen one and says when it's tapped.
    component Tab: Rectangle {
        id: tabItem

        property string label
        property bool selected: false
        signal chosen

        height: 28
        radius: 7
        color: selected || tabHover.hovered ? Theme.surface2 : "transparent"

        Text {
            anchors.centerIn: parent
            text: tabItem.label
            color: tabItem.selected ? Theme.fg : Theme.fgDim
            font.family: Theme.font
            font.pixelSize: 12.5
            font.weight: Font.Medium
        }

        HoverHandler {
            id: tabHover
        }

        TapHandler {
            onTapped: tabItem.chosen()
        }
    }

    // A label on the left and a value on the right.
    component Line: Item {
        property string label
        property string value
        property color ink: Theme.fg

        implicitHeight: 24

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: lineValue.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            // Process names come from other programs: never markup.
            textFormat: Text.PlainText
            text: parent.label
            color: Theme.fg
            font.family: Theme.font
            font.pixelSize: 12.5
        }

        Text {
            id: lineValue

            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: parent.value
            color: parent.ink
            font.family: Theme.font
            font.pixelSize: 12.5
            font.features: ({ "tnum": 1 })
        }
    }

    component Heading: Text {
        leftPadding: 10
        topPadding: 8
        bottomPadding: 2
        color: Theme.fgDim
        font.family: Theme.font
        font.pixelSize: 11.5
        font.weight: Font.Medium
    }

    Rectangle {
        id: card

        anchors.fill: parent
        implicitHeight: list.implicitHeight + 12
        radius: 12
        color: Theme.surface
        border.color: Theme.dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.08)

        Column {
            id: list

            anchors.fill: parent
            anchors.margins: 6
            spacing: 2

            Row {
                id: readouts

                x: 10
                width: list.width - 20
                topPadding: 6
                bottomPadding: 8
                spacing: 8

                Readout {
                    width: (readouts.width - readouts.spacing * 2) / 3
                    label: "CPU"
                    value: Sysmon.formatPercent(SysmonData.cpu)
                    ink: root.toneColor(SysmonData.throttled ? "danger" : "normal")
                }

                Readout {
                    width: (readouts.width - readouts.spacing * 2) / 3
                    label: "Memory"
                    value: SysmonData.memory ? Sysmon.formatBytes(SysmonData.memory.used) : ""
                    ink: root.toneColor(root.memoryTone)
                }

                Readout {
                    width: (readouts.width - readouts.spacing * 2) / 3
                    label: "Temp"
                    value: Sysmon.formatTemp(SysmonData.temp)
                    ink: root.toneColor(root.tempTone)
                }
            }

            Row {
                id: tabs

                width: list.width
                spacing: 4

                Tab {
                    width: (tabs.width - tabs.spacing) / 2
                    label: "CPU"
                    selected: root.tab === "cpu"
                    onChosen: root.tab = "cpu"
                }

                Tab {
                    width: (tabs.width - tabs.spacing) / 2
                    label: "Memory"
                    selected: root.tab === "memory"
                    onChosen: root.tab = "memory"
                }
            }

            // CPU.
            Column {
                visible: root.tab === "cpu"
                width: list.width
                topPadding: 6
                spacing: 0

                Line {
                    width: list.width
                    visible: Number.isFinite(SysmonData.temp)
                    label: "Temperature"
                    value: Sysmon.formatTemp(SysmonData.temp)
                    ink: root.toneColor(root.tempTone)
                }

                Line {
                    width: list.width
                    visible: value !== ""
                    label: "Clock"
                    value: Sysmon.formatFreq(SysmonData.freq, SysmonData.probe.maxFreq)
                }

                // Only where the kernel counts throttling (Intel), and only
                // while the counter reads: an unreadable one can't say "No".
                Line {
                    width: list.width
                    visible: SysmonData.probe.throttle !== "" && SysmonData.throttleState !== null
                    label: "Thermal throttling"
                    value: SysmonData.throttled ? "Now" : "No"
                    ink: root.toneColor(SysmonData.throttled ? "danger" : "normal")
                }

                Heading {
                    width: list.width
                    text: "Top CPU"
                }

                Repeater {
                    model: SysmonData.top.cpu

                    Line {
                    width: list.width
                        required property var modelData

                        label: modelData.name
                        value: Sysmon.formatPercent(modelData.cpu)
                    }
                }

                Line {
                    width: list.width
                    visible: SysmonData.top.cpu.length === 0
                    label: "Measuring…"
                    value: ""
                    ink: Theme.fgDim
                }
            }

            // Memory.
            Column {
                visible: root.tab === "memory"
                width: list.width
                topPadding: 6
                spacing: 0

                Line {
                    width: list.width
                    label: "Memory"
                    value: SysmonData.memory ? Sysmon.formatUsage(SysmonData.memory.used, SysmonData.memory.total) : ""
                    ink: root.toneColor(root.memoryTone)
                }

                Line {
                    width: list.width
                    visible: (SysmonData.memory?.swapTotal ?? 0) > 0
                    label: "Swap"
                    value: SysmonData.memory ? Sysmon.formatUsage(SysmonData.memory.swapUsed, SysmonData.memory.swapTotal) : ""
                }

                Heading {
                    width: list.width
                    text: "Top memory"
                }

                Repeater {
                    model: SysmonData.top.memory

                    Line {
                    width: list.width
                        required property var modelData

                        label: modelData.name
                        value: Sysmon.formatBytes(modelData.memory)
                    }
                }

                Line {
                    width: list.width
                    visible: SysmonData.top.memory.length === 0
                    label: "Measuring…"
                    value: ""
                    ink: Theme.fgDim
                }
            }
        }
    }
}
