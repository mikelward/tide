pragma Singleton

import QtQuick
import Quickshell
import "lib/palette.mjs" as Palette

// The palette, light and dark, from theme/palette.json (through `make
// palette`), and the sizes from docs/mocks/common.css (SPEC.md §15). Light
// or dark is AppearanceData's, which owns the schedule; the palette changes
// in place.
Singleton {
    id: root

    readonly property bool dark: AppearanceData.dark

    readonly property int barHeight: 34
    readonly property int chipHeight: 26
    readonly property int chipRadius: 7

    // The mode's colors, which every color below reads, so a flip changes
    // them all in place.
    readonly property var palette: dark ? Palette.PALETTE.dark : Palette.PALETTE.light

    readonly property color barBg: palette.barBg
    readonly property color fg: palette.fg
    readonly property color fgDim: palette.fgDim
    readonly property color fgFaint: palette.fgFaint
    readonly property color surface: palette.surface
    readonly property color surface2: palette.surface2
    // The hairline around popovers, popups and the OSD, and between the
    // center's entries.
    readonly property color edge: palette.edge
    readonly property color accent: palette.accent
    readonly property color accentBg: palette.accentBg
    readonly property color accentFg: palette.accentFg
    readonly property color urgent: palette.urgent
    readonly property color urgentBg: palette.urgentBg
    readonly property color urgentRing: palette.urgentRing
    readonly property color danger: palette.danger
    // The Sharing pill's fill, with white on it.
    readonly property color dangerBg: palette.dangerBg
    readonly property color warn: palette.warn
    // The mic pill's fill (docs/mocks/common.css's .pill.mic).
    readonly property color warnBg: palette.warnBg
    // The clocks popover's day strip: night, day, and working hours.
    readonly property color stripNight: palette.stripNight
    readonly property color stripDay: palette.stripDay
    readonly property color stripNow: palette.stripNow

    readonly property string font: "Inter"
    readonly property string monoFont: "Ubuntu Mono"
}
