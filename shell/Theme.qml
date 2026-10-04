pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/appearance.mjs" as Appearance
import "lib/palette.mjs" as Palette

// The palette, light and dark, from theme/palette.json (through `make
// palette`), and the sizes from docs/mocks/common.css (SPEC.md §15). Until
// the shell owns the light/dark schedule, it follows the desktop's color
// scheme, which conf's theme daemon flips; the palette changes in place.
Singleton {
    id: root

    // Dark until the color scheme is read, as the shell was before this.
    property bool dark: true

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
    // The clocks popover's day strip: night, day, and working hours.
    readonly property color stripNight: palette.stripNight
    readonly property color stripDay: palette.stripDay
    readonly property color stripNow: palette.stripNow

    readonly property string font: "Inter"
    readonly property string monoFont: "Ubuntu Mono"

    // Whether the monitor has reported a change, which is newer than
    // anything the startup read can say.
    property bool changed: false

    function heard(line, fromMonitor) {
        const next = Appearance.heardScheme({ dark: root.dark, changed: root.changed }, line, fromMonitor);
        root.dark = next.dark;
        root.changed = next.changed;
    }

    // The monitor starts first, and heardScheme keeps the startup read from
    // undoing a change it reports. gsettings monitor has no "ready" signal,
    // though, so a flip in the instant before it subscribes is missed until
    // the next one; TODO.md has the decision.
    Process {
        command: ["gsettings", "monitor", "org.gnome.desktop.interface", "color-scheme"]
        running: true
        stdout: SplitParser {
            onRead: data => root.heard(data, true)
        }
        onExited: (code, status) => {
            console.warn(`tide: gsettings monitor exited ${code}; the bar no longer follows light and dark`);
        }
    }

    Process {
        command: ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.heard(text, false)
        }
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: gsettings get color-scheme exited ${code}; the bar stays ${root.dark ? "dark" : "light"}`);
            }
        }
    }
}
