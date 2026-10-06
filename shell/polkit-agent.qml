import QtQuick
import Quickshell.Services.Polkit

// The shell's polkit agent, which PolkitData loads only with TIDE_POLKIT=1.
// This is the one file that imports Quickshell.Services.Polkit, and its
// lowercase name keeps Quickshell from making it a type, so nothing
// compiles it until it's loaded: a Quickshell built without polkit
// (-DSERVICE_POLKIT=OFF) still runs the shell while the agent is off.
PolkitAgent {
    onAuthenticationRequestStarted: PolkitData.start()
    // A remake makes the new agent only once the old one is gone.
    // LazyLoader deletes it later, and Quickshell 0.3.1 gives its listener
    // to one agent at a time: a new one made while the old is alive gets
    // none, and never registers.
    Component.onDestruction: {
        if (PolkitData.remaking) {
            Qt.callLater(() => PolkitData.remaking = false);
        }
    }
}
