import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import "lib/barclick.mjs" as Click
import "lib/bluetooth.mjs" as Bt
import "lib/keepawake.mjs" as KeepAwake
import "lib/network.mjs" as Net
import "lib/status.mjs" as Status

// The status icons before the clocks (SPEC.md §7.4), each with hover text
// (BarTip) in tilemo's words where tilemo has the same icon. So far: keep awake;
// Bluetooth, then one for each connected audio device; network; volume and its %, which scrolls by 5%; battery, red
// below 15%; and the system monitor's CPU %, each with its popover; the
// notification center's bell; and the session menu.
// The tray is shell/Tray.qml, to their left. The other icons come later;
// TODO.md lists them.
Row {
    id: root

    spacing: 10

    // The bar's monitor, which the bell opens the notification center on.
    property string monitorName: ""
    // How far the click targets at the group's ends reach past it (Bar.qml).
    property var reach: ({ left: Click.PAD, right: Click.PAD })

    // Whether a point in the bar's scene is on the bell's click target.
    function onBell(scenePoint) {
        const area = bellHit.area;
        return bell.visible && area.contains(area.mapFromItem(null, scenePoint.x, scenePoint.y));
    }

    // How far an icon's click target reaches past it: half the spacing to
    // a neighbor, and the group's reach at its ends.
    function reachOf(item) {
        return Click.groupReach({
            x: item.x,
            width: item.width,
            groupWidth: root.width,
            spacing: root.spacing,
            left: root.reach.left,
            right: root.reach.right
        });
    }

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var battery: UPower.displayDevice

    // Volume and mute are only live on a bound node.
    PwObjectTracker {
        objects: [root.sink]
    }

    // Keep awake: a cup of coffee, always here, faint while off and in the
    // accent color while on, whether you asked, the mic is live or you're
    // presenting. A click turns your request on, until the next click turns
    // it off, and the OSD says what it did; hovering says what it's doing.
    SymbolicIcon {
        id: keepAwake

        anchors.verticalCenter: parent.verticalCenter
        name: KeepAwake.ICON
        color: KeepAwakeData.on ? Theme.accent : Theme.fgFaint

        BarHit {
            id: keepAwakeHit

            reach: root.reachOf(keepAwake)

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

        anchors.verticalCenter: parent.verticalCenter
        visible: view.visible
        name: view.icon || "bluetooth-active-symbolic"
        color: view.on ? Theme.fg : Theme.fgFaint

        BarHit {
            id: bluetoothHit

            reach: root.reachOf(bluetooth)

            TapHandler {
                onTapped: bluetoothPopover.toggle(parent)
            }
        }

        BarTip {
            item: bluetooth
            shown: bluetoothHit.hovered
            text: Bt.bluetoothTip(bluetooth.adapter)
        }

        BluetoothPopover {
            id: bluetoothPopover

            icon: bluetooth
        }
    }

    // An icon beside it for each connected audio device, headphones,
    // headset or speakers, with its name and battery on hover. A click opens
    // the Bluetooth popover.
    Repeater {
        model: Bt.audioIcons(bluetooth.adapter, bluetooth.devices)

        SymbolicIcon {
            id: audioDevice

            required property var modelData

            anchors.verticalCenter: parent.verticalCenter
            name: modelData.icon

            BarHit {
                id: audioHit

                reach: root.reachOf(audioDevice)

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

    SymbolicIcon {
        id: network

        // Quickshell.Networking's devices as network.mjs reads them.
        readonly property var devices: Networking.devices.values.map(d => ({
            type: d.type,
            connected: d.connected,
            networks: d.networks?.values ?? [],
        }))
        readonly property var view: Net.networkIcon({
            devices: devices,
            wifiEnabled: Networking.wifiEnabled,
            connectivity: Networking.connectivity,
        })

        anchors.verticalCenter: parent.verticalCenter
        visible: view.visible
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
            id: networkHit

            reach: root.reachOf(network)

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

        anchors.verticalCenter: parent.verticalCenter
        visible: root.sink !== null
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
                id: volumeHit

                span: volume
                reach: root.reachOf(volume)

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
            text: Status.volumeTip({ muted: root.sink?.audio?.muted ?? true })
        }
    }

    Row {
        id: battery

        readonly property var view: Status.batteryView({
            present: root.battery?.isPresent ?? false,
            percentage: root.battery?.percentage,
            state: root.battery?.state,
        })
        readonly property color ink: view.low ? Theme.danger : Theme.fg

        anchors.verticalCenter: parent.verticalCenter
        visible: view.visible
        spacing: 2

        BatteryPopover {
            id: batteryPopover

            icon: battery
        }

        BarTip {
            item: battery
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
            name: battery.view.icon || "battery-missing-symbolic"
            color: battery.ink

            // In here, not the Row itself, which would cull a target that
            // takes no room (BarHit.qml).
            BarHit {
                id: batteryHit

                span: battery
                reach: root.reachOf(battery)

                TapHandler {
                    onTapped: batteryPopover.toggle(parent)
                }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: battery.view.text
            color: battery.ink
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

        anchors.verticalCenter: parent.verticalCenter
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
                id: sysmonHit

                span: sysmon
                reach: root.reachOf(sysmon)

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

        anchors.verticalCenter: parent.verticalCenter
        visible: NotificationData.enabled
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
            id: bellHit

            reach: root.reachOf(bell)

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
            text: Status.bellTip({ dnd: NotificationData.dnd, unread: HistoryData.unread })
        }
    }

    SymbolicIcon {
        id: session

        anchors.verticalCenter: parent.verticalCenter
        name: "system-shutdown-symbolic"

        BarHit {
            id: sessionHit

            reach: root.reachOf(session)

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
}
