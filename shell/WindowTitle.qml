import QtQuick
import Quickshell
import "lib/title.mjs" as Title
import "lib/barsettings.mjs" as BarSettings

// The window title in the middle of this monitor's bar (SPEC.md §7.1):
// the focused window's when it's on this monitor, else nothing, from
// shell/lib/title.mjs.
Text {
    id: root

    // This bar's monitor's name.
    required property string monitorName

    // About Title.MAX_TITLE characters wide, as waybar's max-length had
    // it. Past that, and past the room Bar.qml gives it, the text elides,
    // which Qt does only between whole characters.
    readonly property real maxWidth: metrics.averageCharacterWidth * Title.MAX_TITLE

    FontMetrics {
        id: metrics

        font: root.font
    }

    // The focused window, or null with none (FocusData.qml).
    readonly property var active: FocusData.focused

    // The window the title stands for, {address, title}, or null.
    readonly property var window: Title.barWindow({
        monitor: root.monitorName !== "" ? root.monitorName : null,
        active: root.active ? {
            monitor: root.active.monitor,
            address: root.active.address,
            title: root.active.title
        } : null
    })

    text: root.window?.title ?? ""

    // Double-clicking it toggles maximize on that window, like a title
    // bar (SPEC.md §7.1). It's always the focused window, so the dispatch
    // needs no address.
    // Hovered, only while there's a title to double-click.
    BarHit {
        settings: BarSettings.page("title")
        visible: root.window !== null

        TapHandler {
            onDoubleTapped: {
                if (root.window) {
                    Compositor.toggleMaximize(root.window.address);
                }
            }
        }
    }
    // Hovering it shows the title in full below it, or above it on a
    // bottom bar (SPEC.md §7.1), as the minimized tray shows an icon's
    // title (MinimizedTray.qml). A HoverHandler takes no clicks, so the
    // double-click still reaches the TapHandler.
    HoverHandler {
        id: hover
    }

    readonly property string hoverText: Title.hoverTitle(root.window, hover.hovered)

    TextMetrics {
        id: fullWidth

        font: full.font
        text: root.hoverText
    }

    PopupWindow {
        visible: root.hoverText !== ""
        anchor.item: root
        anchor.edges: Theme.hangEdge
        anchor.gravity: Theme.hangEdge
        anchor.margins.top: Theme.hang(8).top
        anchor.margins.bottom: Theme.hang(8).bottom
        color: "transparent"
        implicitWidth: full.width + 18
        implicitHeight: full.implicitHeight + 10

        Rectangle {
            anchors.fill: parent
            radius: 7
            color: Theme.surface2
            border.color: Theme.edge

            Text {
                id: full

                anchors.centerIn: parent
                // Its natural width, up to Title.HOVER_LINE average
                // characters, past which it wraps.
                width: Math.min(Math.ceil(fullWidth.advanceWidth) + 1, metrics.averageCharacterWidth * Title.HOVER_LINE)
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: root.hoverText
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 12
            }
        }
    }

    // Titles come from apps: never markup.
    textFormat: Text.PlainText
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignHCenter
    color: Theme.fg
    font.family: Theme.font
    font.pixelSize: 13
}
