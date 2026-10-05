import QtQuick
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import "lib/bluetooth.mjs" as Bt
import "lib/network.mjs" as Net
import "lib/status.mjs" as Status

// The status icons before the clocks (SPEC.md §7.4). So far: keep awake;
// Bluetooth; network; volume and its %, which scrolls by 5%; battery, red
// below 15%; and the system monitor's CPU %, each with its popover; the
// notification center's bell; and the session menu.
// The tray is shell/Tray.qml, to their left. The other icons come later;
// TODO.md lists them.
Row {
    id: root

    spacing: 10

    // The bar's monitor, which the bell opens the notification center on.
    property string monitorName: ""

    // Whether a point in the bar's scene is on the bell.
    function onBell(scenePoint) {
        return bell.visible && bell.contains(bell.mapFromItem(null, scenePoint.x, scenePoint.y));
    }

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var battery: UPower.displayDevice

    // Volume and mute are only live on a bound node.
    PwObjectTracker {
        objects: [root.sink]
    }

    // Keep awake: always here, faint while off and in the accent color
    // while on, whether you asked or the mic is live. A click turns your
    // request on, until the next click turns it off.
    SymbolicIcon {
        id: keepAwake

        anchors.verticalCenter: parent.verticalCenter
        name: "display-brightness-symbolic"
        color: KeepAwakeData.on ? Theme.accent : Theme.fgFaint

        TapHandler {
            onTapped: KeepAwakeData.toggle()
        }
    }

    SymbolicIcon {
        id: bluetooth

        readonly property var view: Bt.bluetoothIcon(Bluetooth.defaultAdapter, Bluetooth.defaultAdapter?.devices.values ?? [])

        anchors.verticalCenter: parent.verticalCenter
        visible: view.visible
        name: view.icon || "bluetooth-disabled-symbolic"

        TapHandler {
            onTapped: bluetoothPopover.toggle()
        }

        BluetoothPopover {
            id: bluetoothPopover

            icon: bluetooth
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

        TapHandler {
            onTapped: networkPopover.toggle()
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
        spacing: 3

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: Status.volumeIcon({
                muted: root.sink?.audio?.muted ?? true,
                volume: root.sink?.audio?.volume,
            })
        }

        // Wide enough for "100%" so the icons after it don't shift.
        Text {
            id: volumeText

            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(implicitWidth, volumeWidth.width)
            horizontalAlignment: Text.AlignRight
            text: Status.volumeText(root.sink?.audio?.volume)
            color: (root.sink?.audio?.muted ?? true) ? Theme.fgDim : Theme.fg
            font.family: Theme.font
            font.pixelSize: 13
            font.weight: Font.Medium
            font.features: ({ "tnum": 1 })

            TextMetrics {
                id: volumeWidth

                font: volumeText.font
                text: "100%"
            }
        }

        property real wheel: 0

        TapHandler {
            onTapped: volumePopover.toggle()
        }

        VolumePopover {
            id: volumePopover

            icon: volume
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
        spacing: 3

        TapHandler {
            onTapped: batteryPopover.toggle()
        }

        BatteryPopover {
            id: batteryPopover

            icon: battery
        }

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: battery.view.icon || "battery-missing-symbolic"
            color: battery.ink
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
        spacing: 3

        TapHandler {
            onTapped: sysmonPopover.toggle()
        }

        SysmonPopover {
            id: sysmonPopover

            icon: sysmon
        }

        SymbolicIcon {
            anchors.verticalCenter: parent.verticalCenter
            file: "cpu-symbolic.svg"
            color: sysmon.ink
        }

        // Wide enough for "100%" so the icons after it don't shift.
        Text {
            id: cpuText

            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(implicitWidth, cpuWidth.width)
            horizontalAlignment: Text.AlignRight
            text: SysmonData.view.text
            color: sysmon.ink
            font.family: Theme.font
            font.pixelSize: 13
            font.weight: Font.Medium
            font.features: ({ "tnum": 1 })

            TextMetrics {
                id: cpuWidth

                font: cpuText.font
                text: "100%"
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

        TapHandler {
            onTapped: HistoryData.toggleAt(root.monitorName)
        }

        // Middle-click toggles Do not disturb (§7.4).
        TapHandler {
            acceptedButtons: Qt.MiddleButton
            onTapped: NotificationData.setDnd(!NotificationData.dnd)
        }
    }

    SymbolicIcon {
        id: session

        anchors.verticalCenter: parent.verticalCenter
        name: "system-shutdown-symbolic"

        TapHandler {
            onTapped: sessionMenu.toggle()
        }

        SessionMenu {
            id: sessionMenu

            icon: session
        }
    }
}
