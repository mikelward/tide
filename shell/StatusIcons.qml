import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import "lib/barclick.mjs" as Click
import "lib/bluetooth.mjs" as Bt
import "lib/configerrors.mjs" as Errors
import "lib/keepawake.mjs" as KeepAwake
import "lib/network.mjs" as Net
import "lib/status.mjs" as Status
import "lib/barsettings.mjs" as BarSettings
import "lib/baricons.mjs" as BarIcons

// The status icons (SPEC.md §7.4), each with hover text (BarTip) in tide
// for macOS's words where tide for macOS has the same icon: tidewm's config
// errors, while it has any, always first; then, in the Bar page's order
// (appearance.json's barIcons, lib/baricons.mjs), the tray (Tray.qml); the
// keyboard layout, once there are two; keep awake; Bluetooth, then one for
// each connected audio device; network; volume and its %, which scrolls by
// 5%; battery, red at 20% and below; and the system monitor's CPU %, each
// with its popover; the notification center's bell; the session menu; and
// the clocks (Clocks.qml). Each one the page turns off is hidden. Each
// icon's x is baricons.mjs's, which counts the clocks' own room.
Item {
    id: root

    // The bar's monitor, which the bell opens the notification center on.
    property string monitorName: ""
    // How far the click targets at the group's ends reach past it (Bar.qml).
    property var reach: ({ left: Click.PAD, right: Click.PAD })

    // The Bar page's list, made whole, and the ids in the order they go.
    readonly property var icons: BarIcons.iconList(AppearanceData.settings.barIcons)
    readonly property var order: ["config"].concat(root.icons.map(e => e.id))

    // Whether the Bar page shows the icon `id`.
    function on(id) {
        return root.icons.some(e => e.id === id && e.shown);
    }

    function size(item) {
        return { width: item.width, shown: item.visible };
    }

    // Each item's width and whether it shows.
    readonly property var sizes: ({
        config: root.size(config),
        tray: root.size(tray),
        keyboard: root.size(layout),
        keepawake: root.size(keepAwake),
        bluetooth: root.size(bluetooth),
        headphones: root.size(headphones),
        network: root.size(network),
        volume: root.size(volume),
        battery: root.size(batteryIcon),
        sysmon: root.size(sysmon),
        notifications: root.size(bell),
        session: root.size(session),
        clocks: root.size(clocks)
    })

    // Each icon's x, and the group's width. It leaves out the reach past
    // the ends, which Bar.qml works out from this width: with it, the
    // width would wait on itself.
    readonly property var geometry: BarIcons.arranged(root.order, root.sizes)
    // Each icon's click reach, the group's ends reaching as Bar.qml says.
    readonly property var placed: BarIcons.arranged(root.order, root.sizes, root.reach)

    implicitWidth: root.geometry.width
    implicitHeight: Theme.barHeight

    // Whether a point in the bar's scene is on the bell's click target.
    function onBell(scenePoint) {
        const area = bellHit.area;
        return bell.visible && area.contains(area.mapFromItem(null, scenePoint.x, scenePoint.y));
    }

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var battery: UPower.displayDevice

    // Volume and mute are only live on a bound node.
    PwObjectTracker {
        objects: [root.sink]
    }

    // tidewm's config errors: a warning triangle, only while its config
    // has errors, which hovering counts and a click lists (lib/configerrors.mjs).
    SymbolicIcon {
        id: config

        x: root.geometry.x.config
        anchors.verticalCenter: parent.verticalCenter
        visible: ConfigErrorsData.errors.length > 0
        name: Errors.ICON
        color: Theme.warn

        ConfigErrorsPopover {
            id: configPopover

            icon: config
        }

        BarHit {
            settings: BarSettings.page("config")
            id: configHit

            reach: root.placed.reach.config

            TapHandler {
                onTapped: configPopover.toggle(parent)
            }
        }

        BarTip {
            item: config
            shown: configHit.hovered
            text: Errors.summary(ConfigErrorsData.errors)
        }
    }

    // Third-party tray icons (Tray.qml).
    Tray {
        id: tray

        x: root.geometry.x.tray
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("tray")
        reach: root.placed.reach.tray
    }

    // The keyboard layout, as tide for macOS's input source: up to three letters,
    // only once there are two layouts. A click goes to the next, as
    // Super+Alt+Space does; hovering names it in full.
    Text {
        id: layout

        x: root.geometry.x.keyboard
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("keyboard") && KeyboardData.count > 1 && KeyboardData.label !== ""
        text: KeyboardData.label
        color: Theme.fg
        font.family: Theme.font
        font.pixelSize: 12
        font.weight: Font.DemiBold

        BarHit {
            settings: BarSettings.page("keyboard")
            id: layoutHit

            reach: root.placed.reach.keyboard

            TapHandler {
                onTapped: KeyboardData.next()
            }
        }

        BarTip {
            item: layout
            shown: layoutHit.hovered
            text: KeyboardData.keymap
        }
    }

    // Keep awake: a cup of coffee, always here, faint while off and in the
    // accent color while on, whether you asked, the mic is live or you're
    // presenting. A click turns your request on, until the next click turns
    // it off, and the OSD says what it did; hovering says what it's doing.
    SymbolicIcon {
        id: keepAwake

        x: root.geometry.x.keepawake
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("keepawake")
        name: KeepAwake.ICON
        color: KeepAwakeData.on ? Theme.accent : Theme.fgFaint

        BarHit {
            settings: BarSettings.page("keepawake")
            id: keepAwakeHit

            reach: root.placed.reach.keepawake

            TapHandler {
                onTapped: KeepAwakeData.toggle()
            }
        }

        BarTip {
            item: keepAwake
            shown: keepAwakeHit.hovered
            text: KeepAwake.sign(KeepAwakeData.state)
        }
    }

    // Bluetooth: one glyph, faint while off, as keep awake is, and in the
    // text color while on.
    SymbolicIcon {
        id: bluetooth

        readonly property var adapter: Bluetooth.defaultAdapter
        readonly property var devices: adapter?.devices.values ?? []
        readonly property var view: Bt.bluetoothIcon(adapter)

        x: root.geometry.x.bluetooth
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("bluetooth") && view.visible
        name: view.icon || "bluetooth-active-symbolic"
        color: view.on ? Theme.fg : Theme.fgFaint

        BarHit {
            settings: BarSettings.page("bluetooth")
            id: bluetoothHit

            reach: root.placed.reach.bluetooth

            TapHandler {
                onTapped: bluetoothPopover.toggle(parent)
            }
        }

        BarTip {
            item: bluetooth
            shown: bluetoothHit.hovered
            text: Bt.bluetoothTip(bluetooth.adapter, bluetooth.devices)
        }

        BluetoothPopover {
            id: bluetoothPopover

            icon: bluetooth
        }
    }

    // An icon beside it for each connected audio device, headphones,
    // headset or speakers, with its name and battery on hover. A click opens
    // the Bluetooth popover. A Row of its own, so the Bar page moves them as
    // one.
    Row {
        id: headphones

        x: root.geometry.x.headphones
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("headphones")
        spacing: BarIcons.GAP

        Repeater {
            model: Bt.audioIcons(bluetooth.adapter, bluetooth.devices)

            SymbolicIcon {
                id: audioDevice

                required property var modelData

                anchors.verticalCenter: parent.verticalCenter
                name: modelData.icon

                BarHit {
                    settings: BarSettings.page("bluetooth")
                    id: audioHit

                    reach: Click.groupReach({
                        x: audioDevice.x,
                        width: audioDevice.width,
                        groupWidth: headphones.width,
                        spacing: headphones.spacing,
                        left: root.placed.reach.headphones.left,
                        right: root.placed.reach.headphones.right
                    })

                    TapHandler {
                        onTapped: bluetoothPopover.toggle(parent)
                    }
                }

                BarTip {
                    item: audioDevice
                    shown: audioHit.hovered
                    text: audioDevice.modelData.tooltip
                }
            }
        }
    }

    SymbolicIcon {
        id: network

        // Quickshell.Networking's devices as network.mjs reads them, each
        // with the device itself for the popover to act on.
        readonly property var devices: Networking.devices.values.map(d => ({
            type: d.type,
            name: d.name,
            connected: d.connected,
            state: d.state,
            networks: d.networks?.values ?? [],
            hasLink: d.hasLink ?? false,
            linkSpeed: d.linkSpeed ?? 0,
            network: d.network ?? null,
            device: d,
        }))
        readonly property var view: Net.networkIcon({
            devices: devices,
            wifiEnabled: Networking.wifiEnabled,
            connectivity: Networking.connectivity,
        })

        x: root.geometry.x.network
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("network") && view.visible
        name: view.icon || "network-offline-symbolic"

        // A VPN's lock (SPEC.md §7.4), on a disc of the bar's color so it
        // reads over the icon; faint while the VPN is still connecting.
        Rectangle {
            visible: NetworkData.lock !== ""
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: -2
            anchors.bottomMargin: -2
            width: 10
            height: 10
            radius: 5
            color: Theme.barBg

            SymbolicIcon {
                anchors.centerIn: parent
                width: 8
                height: 8
                name: "changes-prevent-symbolic"
                opacity: NetworkData.lock === "on" ? 1 : 0.5
            }
        }

        BarHit {
            settings: BarSettings.page("network")
            id: networkHit

            reach: root.placed.reach.network

            TapHandler {
                onTapped: networkPopover.toggle(parent)
            }
        }

        BarTip {
            item: network
            shown: networkHit.hovered
            text: Net.networkTip({
                devices: network.devices,
                wifiEnabled: Networking.wifiEnabled,
                connectivity: Networking.connectivity,
                vpn: NetworkData.lock,
            })
        }

        NetworkPopover {
            id: networkPopover

            icon: network
            devices: network.devices
        }
    }

    // The volume's icon (muted, or a level by thirds), then its %, dimmed
    // while muted.
    Row {
        id: volume

        x: root.geometry.x.volume
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("volume") && root.sink !== null
        spacing: 2

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: Status.volumeIcon({
                muted: root.sink?.audio?.muted ?? true,
                volume: root.sink?.audio?.volume,
            })

            // In here, not the Row itself, which would cull a target that
            // takes no room (BarHit.qml). Scrolling over it changes the
            // volume too.
            BarHit {
                settings: BarSettings.page("volume")
                id: volumeHit

                span: volume
                reach: root.placed.reach.volume

                TapHandler {
                    onTapped: volumePopover.toggle(parent)
                }

                WheelHandler {
                    onWheel: event => {
                        const audio = root.sink?.audio;
                        if (!audio) {
                            return;
                        }
                        volume.wheel += event.angleDelta.y;
                        const notches = Math.trunc(volume.wheel / 120);
                        if (notches === 0) {
                            return;
                        }
                        volume.wheel -= notches * 120;
                        audio.volume = Status.scrolledVolume(audio.volume, notches);
                    }
                }
            }
        }

        // Held as wide as Status.PERCENT_ROOM, left-aligned so the spare
        // room falls before the next icon, not between this one and its %.
        Text {
            id: volumeText

            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(implicitWidth, volumeWidth.width)
            text: Status.volumeText(root.sink?.audio?.volume)
            color: (root.sink?.audio?.muted ?? true) ? Theme.fgDim : Theme.fg
            font.family: Theme.font
            font.pixelSize: 13
            font.weight: Font.Medium
            font.features: ({ "tnum": 1 })

            TextMetrics {
                id: volumeWidth

                font: volumeText.font
                text: Status.PERCENT_ROOM
            }
        }

        property real wheel: 0

        VolumePopover {
            id: volumePopover

            icon: volume
        }

        BarTip {
            item: volume
            shown: volumeHit.hovered
            text: Status.volumeTip({
                muted: root.sink?.audio?.muted ?? true,
                volume: root.sink?.audio?.volume,
                output: root.sink?.nickname || root.sink?.description || root.sink?.name || "",
            })
        }
    }

    Row {
        id: batteryIcon

        readonly property var view: Status.batteryView({
            present: root.battery?.isPresent ?? false,
            percentage: root.battery?.percentage,
            state: root.battery?.state,
        })
        readonly property color ink: view.low ? Theme.danger : Theme.fg

        x: root.geometry.x.battery
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("battery") && view.visible
        spacing: 2

        BatteryPopover {
            id: batteryPopover

            icon: batteryIcon
        }

        BarTip {
            item: batteryIcon
            shown: batteryHit.hovered
            text: Status.batteryTip({
                present: root.battery?.isPresent ?? false,
                percentage: root.battery?.percentage,
                state: root.battery?.state,
                toFull: root.battery?.timeToFull ?? 0,
                toEmpty: root.battery?.timeToEmpty ?? 0,
            })
        }

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: batteryIcon.view.icon || "battery-missing-symbolic"
            color: batteryIcon.ink

            // In here, not the Row itself, which would cull a target that
            // takes no room (BarHit.qml).
            BarHit {
                settings: BarSettings.page("battery")
                id: batteryHit

                span: batteryIcon
                reach: root.placed.reach.battery

                TapHandler {
                    onTapped: batteryPopover.toggle(parent)
                }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: batteryIcon.view.text
            color: batteryIcon.ink
            font.family: Theme.font
            font.pixelSize: 13
            font.weight: Font.Medium
            font.features: ({ "tnum": 1 })
        }
    }

    // The system monitor: CPU %, amber when hot or memory is nearly full,
    // red while throttling or critically hot. A click opens its popover.
    Row {
        id: sysmon

        readonly property color ink: SysmonData.view.tone === "danger" ? Theme.danger
            : SysmonData.view.tone === "warn" ? Theme.warn : Theme.fg

        x: root.geometry.x.sysmon
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("sysmon")
        spacing: 2

        SysmonPopover {
            id: sysmonPopover

            icon: sysmon
        }

        BarTip {
            item: sysmon
            shown: sysmonHit.hovered
            text: SysmonData.view.tip ?? ""
        }

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            file: "cpu-symbolic.svg"
            color: sysmon.ink

            // In here, not the Row itself, which would cull a target that
            // takes no room (BarHit.qml).
            BarHit {
                settings: BarSettings.page("sysmon")
                id: sysmonHit

                span: sysmon
                reach: root.placed.reach.sysmon

                TapHandler {
                    onTapped: sysmonPopover.toggle(parent)
                }
            }
        }

        // Held as wide as the volume's %, and aligned the same way.
        Text {
            id: cpuText

            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(implicitWidth, cpuWidth.width)
            text: SysmonData.view.text
            color: sysmon.ink
            font.family: Theme.font
            font.pixelSize: 13
            font.weight: Font.Medium
            font.features: ({ "tnum": 1 })

            TextMetrics {
                id: cpuWidth

                font: cpuText.font
                text: Status.PERCENT_ROOM
            }
        }
    }

    // Only while the shell is the notification server; a dot while
    // something has arrived since the center was last open. A click opens
    // the center, a middle-click toggles Do not disturb.
    SymbolicIcon {
        id: bell

        x: root.geometry.x.notifications
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("notifications") && NotificationData.enabled
        // A bell with a slash while Do not disturb is on.
        name: NotificationData.dnd ? "notifications-disabled-symbolic" : "preferences-system-notifications-symbolic"

        Rectangle {
            visible: HistoryData.unread
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: -2
            anchors.topMargin: -1
            width: 6
            height: 6
            radius: 3
            color: Theme.accent
        }

        BarHit {
            settings: BarSettings.page("notifications")
            id: bellHit

            reach: root.placed.reach.notifications

            TapHandler {
                onTapped: HistoryData.toggleAt(root.monitorName)
            }

            // Middle-click toggles Do not disturb (§7.4).
            TapHandler {
                acceptedButtons: Qt.MiddleButton
                onTapped: NotificationData.setDnd(!NotificationData.dnd)
            }
        }

        BarTip {
            item: bell
            shown: bellHit.hovered
            text: Status.bellTip({ dnd: NotificationData.dnd, unread: HistoryData.unreadCount })
        }
    }

    SymbolicIcon {
        id: session

        x: root.geometry.x.session
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("session")
        name: "system-shutdown-symbolic"

        BarHit {
            settings: BarSettings.page("session")
            id: sessionHit

            reach: root.placed.reach.session

            TapHandler {
                onTapped: sessionMenu.toggle(parent)
            }
        }

        BarTip {
            item: session
            shown: sessionHit.hovered
            text: "Lock, log out or power off"
        }

        SessionMenu {
            id: sessionMenu

            icon: session
        }
    }

    // Local's clock, and the zones in the bar (SPEC.md §7.3).
    Clocks {
        id: clocks

        x: root.geometry.x.clocks
        anchors.verticalCenter: parent.verticalCenter
        visible: root.on("clocks")
        reach: root.placed.reach.clocks
    }
}
