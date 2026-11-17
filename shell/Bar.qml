import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "lib/barclick.mjs" as Click
import "lib/barlayout.mjs" as BarLayout
import "lib/barsettings.mjs" as BarSettings
import "lib/settings.mjs" as Settings

// One bar per monitor (SPEC.md §7.1): a plain rectangle flush with the top
// edge, or the bottom one (Theme.barAtBottom), and both sides, its
// exclusive zone keeping tiling off it. Its layer is named tide-bar, which `tide doctor` looks for to tell the space
// it reserves from another bar's.
PanelWindow {
    id: bar

    required property var modelData
    // This bar's HyprlandMonitor, or null on tidewm, which isn't asked.
    readonly property var monitor: Compositor.tidewm ? null : Hyprland.monitorFor(bar.screen)

    // The Bar page's layout (SPEC.md §7.1): each item's zone, order and
    // whether it shows (appearance.json's barLayout, lib/barlayout.mjs).
    // barIcons keeps clocks turned off when they were a status icon.
    readonly property var layout: BarLayout.layoutList(AppearanceData.settings.barLayout, AppearanceData.settings.barIcons)
    readonly property var shown: {
        const out = {};
        for (const e of bar.layout) {
            out[e.id] = e.shown;
        }
        return out;
    }
    // Where each shown item goes, and how wide the title may be. The
    // workspaces' width takes in the layout symbol after them.
    // The status icons are placed even when they're off, for the config
    // errors' warning they hold, which always shows (StatusIcons.qml).
    readonly property var place: BarLayout.placed(bar.layout.map(e => e.id === "icons" ? Object.assign({}, e, { shown: true }) : e), {
        logo: logo.implicitWidth,
        workspaces: workspaces.implicitWidth + 7 + layoutSymbol.implicitWidth,
        title: Math.min(windowTitle.implicitWidth, windowTitle.maxWidth),
        icons: statusIcons.implicitWidth,
        clocks: clocks.implicitWidth
    }, { width: bar.width, pills: pills.implicitWidth })

    // How far each click target reaches past its ends: the gaps between
    // them split, so none is dead, whatever their spacing. The first
    // reaches the bar's left edge and the last its right one. The title is
    // a target too, so its neighbors stop at it.
    readonly property var targets: [
        { id: "logo", item: logo },
        { id: "workspaces", item: workspaces },
        { id: "title", item: windowTitle },
        { id: "presenter", item: presenter, in: pills },
        { id: "sharing", item: sharing, in: pills },
        { id: "mic", item: mic, in: pills },
        { id: "icons", item: statusIcons },
        { id: "clocks", item: clocks }
    ].map(t => ({
        id: t.id,
        left: t.item.x + (t.in ? t.in.x : 0),
        right: t.item.x + (t.in ? t.in.x : 0) + t.item.width,
        shown: t.item.visible && t.item.width > 0
    })).sort((a, b) => a.left - b.left)
    readonly property var reaches: {
        const chain = Click.chainReaches(bar.targets, { start: 0, end: bar.width });
        const out = {};
        bar.targets.forEach((t, i) => out[t.id] = chain[i]);
        return out;
    }

    screen: modelData
    WlrLayershell.namespace: "tide-bar"
    // Only while a popover is open, so a click into one (the network
    // password) can take the keyboard; otherwise hovering the bar would.
    WlrLayershell.keyboardFocus: PopoverData.open !== null ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    // The edge changes live, from the Appearance page: the layer moves
    // and its exclusive zone with it.
    anchors {
        top: !Theme.barAtBottom
        bottom: Theme.barAtBottom
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight
    color: Theme.barBg

    // A right-click on the bar but off its items opens the Bar page
    // (SPEC.md §7.1). Under everything: an item's own right-click grabs
    // the press first (BarHit.qml), and the tray's MouseArea takes its own.
    Item {
        anchors.fill: parent
        z: -2

        TapHandler {
            acceptedButtons: Qt.RightButton
            gesturePolicy: TapHandler.WithinBounds
            onTapped: SettingsData.open(BarSettings.opened(BarSettings.page("bar"), Settings.PAGES))
        }
    }

    // tide's logo, two waves, first on the left by default (§7.1): a tap
    // opens the launcher on this monitor, or closes it.
    SymbolicIcon {
        id: logo

        visible: bar.shown.logo
        x: bar.place.x.logo ?? 0
        anchors.verticalCenter: parent.verticalCenter
        file: "tide-symbolic.svg"
        color: Theme.accent

        BarHit {
            settings: BarSettings.page("logo")
            reach: bar.reaches.logo

            TapHandler {
                onTapped: LauncherData.toggle(bar.screen)
            }
        }
    }

    Workspaces {
        id: workspaces

        visible: bar.shown.workspaces
        x: bar.place.x.workspaces ?? 0
        anchors.verticalCenter: parent.verticalCenter
        monitorName: bar.screen?.name ?? ""
        // The layout symbol after it isn't a target.
        reach: bar.reaches.workspaces
    }

    // The layout symbol, after the workspaces wherever they are.
    LayoutSymbol {
        id: layoutSymbol

        visible: bar.shown.workspaces
        anchors.left: workspaces.right
        anchors.leftMargin: 7
        anchors.verticalCenter: parent.verticalCenter
        monitor: bar.monitor
        screenName: bar.screen?.name ?? ""
    }

    // The window title, as wide as its zone leaves room for
    // (BarLayout.placed): centered by default, it stays centered.
    WindowTitle {
        id: windowTitle

        visible: bar.shown.title
        x: bar.place.x.title ?? 0
        anchors.verticalCenter: parent.verticalCenter
        width: bar.place.title
        monitorName: bar.screen?.name ?? ""
        reach: bar.reaches.title
    }

    // Presenter mode's pill, then the privacy pills, first in the right
    // zone (§7.1). They aren't in the layout: each shows only while it
    // has something to say.
    Row {
        id: pills

        x: bar.place.pills
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        PresenterPill {
            id: presenter

            reach: bar.reaches.presenter
            anchors.verticalCenter: parent.verticalCenter
        }

        SharingPill {
            id: sharing

            reach: bar.reaches.sharing
            anchors.verticalCenter: parent.verticalCenter
        }

        MicPill {
            id: mic

            reach: bar.reaches.mic
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // The tray and the status icons, in the Bar page's order (§7.4).
    StatusIcons {
        id: statusIcons

        iconsShown: bar.shown.icons
        x: bar.place.x.icons ?? 0
        reach: bar.reaches.icons
        // Its screen's name is its monitor's, on Hyprland and tidewm alike,
        // and the bell opens the center there (HistoryData.openOn).
        monitorName: bar.screen?.name ?? ""
        anchors.verticalCenter: parent.verticalCenter
    }

    // Local's clock and the zones in the bar (§7.3), wherever the Bar
    // page's Layout puts them: by default after the status icons. At the
    // right edge, with the clocks' own 5 px, the last clock's text sits
    // 11 px from it.
    Clocks {
        id: clocks

        visible: bar.shown.clocks
        x: bar.place.x.clocks ?? 0
        anchors.verticalCenter: parent.verticalCenter
        reach: bar.reaches.clocks
    }

    // Every bar is in the notification center's focus grab, so the bell
    // can close it rather than a press outside closing it and the bell's
    // tap reopening it, and a press on another monitor's bar reaches it.
    // Any press but the bell's closes it, as outside the center. Every bar
    // is in a popover's grab too, and a press closes the popover the same
    // way unless it's on the popover's own target (PopoverData.pressed). A PointHandler only watches, so the press
    // still reaches the control under it.
    Item {
        readonly property var barWindow: QsWindow.window

        anchors.fill: parent
        z: 1

        PointHandler {
            acceptedButtons: Qt.AllButtons
            onActiveChanged: {
                if (active && Click.closesOnPress(HistoryData.openOn !== "", statusIcons.onBell(point.scenePosition))) {
                    HistoryData.close();
                }
                if (active) {
                    PopoverData.pressed(parent.barWindow, point.scenePosition);
                }
            }
        }
    }

    Component.onCompleted: PopoverData.addBar(bar)
    Component.onDestruction: PopoverData.removeBar(bar)

    // Keep awake (SPEC.md §10): every bar holds one while it's on, so it
    // holds on whichever monitors are lit.
    IdleInhibitor {
        window: bar
        enabled: KeepAwakeData.on
    }

    // Only while the shell is the notification server (NotificationData).
    LazyLoader {
        active: NotificationData.enabled

        NotificationCenter {
            panel: bar
        }
    }
}
