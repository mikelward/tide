pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import "lib/network.mjs" as Net
import "lib/vpn.mjs" as Vpn

// What the network icons and popovers share. There's one popover per
// monitor, but Wi-Fi scanning is one switch per device, so it's held here,
// on while any popover is open. So are the VPNs (SPEC.md §7.4), which come
// from nmcli since Quickshell.Networking 0.3 doesn't list them: one read
// for every monitor's icon and popover.
Singleton {
    id: root

    // The network popovers that are open, across monitors (Net.trackOpen).
    property var open: []

    // The VPN connections, from shell/lib/vpn.mjs's parseConnections.
    property var vpns: []
    readonly property string lock: Vpn.lock(root.vpns)
    // The last toggle that didn't work, {uuid, action}, so its row says so;
    // null when none.
    property var vpnFailed: null

    onOpenChanged: {
        // An opened popover shows what's current, whatever the monitor
        // below missed.
        if (root.open.length > 0) {
            root.readVpns();
        }
    }

    function readVpns() {
        if (!list.running) {
            list.running = true;
        } else {
            // A change during a read: read again once it's done.
            list.again = true;
        }
    }

    function toggleVpn(vpn) {
        const action = Vpn.toggleAction(vpn);
        root.vpnFailed = null;
        Launcher.run(Vpn.toggleCommand(vpn), ok => {
            if (!ok) {
                // nmcli's own message is in the log (Launcher).
                root.vpnFailed = {
                    uuid: vpn.uuid,
                    action: action
                };
            }
            root.readVpns();
        });
    }

    Instantiator {
        model: Networking.devices.values.filter(d => d.type === DeviceType.Wifi)

        delegate: Binding {
            required property var modelData

            target: modelData
            property: "scannerEnabled"
            value: Net.shouldScan(root.open)
        }
    }

    Process {
        id: list

        // Whether something changed while this read was running.
        property bool again: false
        // Quickshell 0.3 gives a run that never started (nmcli not on
        // PATH) no exit code, so that's told from this.
        property bool started: false

        command: Vpn.LIST_COMMAND
        onStarted: started = true
        onRunningChanged: {
            if (running) {
                started = false;
                return;
            }
            if (!started) {
                console.warn("tide: couldn't run env for nmcli connection show; no VPNs are shown");
            } else if (again) {
                // Here rather than on exit, which can come while it still
                // counts as running, when starting it again would do nothing.
                again = false;
                running = true;
            }
        }
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const result = Vpn.parseConnections(text);
                for (const e of result.errors) {
                    console.warn(`tide: ${e}`);
                }
                root.vpns = result.vpns;
                root.vpnFailed = Vpn.settledFailure(root.vpnFailed, result.vpns);
            }
        }
        onExited: (code, status) => {
            if (code === 127) {
                // env's "not found", since the list runs through env.
                console.warn("tide: no nmcli on PATH; is NetworkManager installed? No VPNs are shown");
            } else if (code !== 0) {
                // NetworkManager not running, say: whatever it printed has
                // been taken as the list, which may then be empty.
                console.warn(`tide: nmcli connection show exited ${code}; the VPNs shown may be wrong until it next succeeds`);
            }
        }
    }

    // nmcli monitor prints a line for each change NetworkManager reports;
    // any of them could be a VPN coming up or going down, so each starts a
    // read, coalesced.
    Process {
        id: monitor

        property bool started: false

        command: ["nmcli", "monitor"]
        running: true
        onStarted: started = true
        onRunningChanged: {
            if (running) {
                started = false;
            } else if (!started) {
                // Not restarted: nmcli is missing, and the list says so.
                console.warn("tide: couldn't run nmcli monitor");
            }
        }
        stdout: SplitParser {
            onRead: settle.restart()
        }
        onExited: (code, status) => {
            console.warn(`tide: nmcli monitor exited ${code}; the VPN lock updates only every minute until it restarts`);
            restart.start();
        }
    }

    Timer {
        id: settle

        interval: 300
        onTriggered: root.readVpns()
    }

    Timer {
        id: restart

        interval: 10 * 1000
        onTriggered: monitor.running = true
    }

    // A backstop for a change nmcli monitor doesn't print.
    Timer {
        interval: 60 * 1000
        running: true
        repeat: true
        onTriggered: root.readVpns()
    }
}
