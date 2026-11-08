pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import "lib/layouts.mjs" as Layouts
import "lib/tidewm.mjs" as Tw

// Each workspace's layout mode as hypr/tide/layout.lua announces it
// (SPEC.md §6.1). A workspace not heard from yet isn't in `modes`; the bar
// shows the layout's default for it. On tidewm, each monitor's layout as
// its layout event says it (Tw.heardLayout), in `tidewmHeard`.
Singleton {
    id: root

    // Workspace ID to mode.
    property var modes: ({})

    // Output name to {workspace, layout}, on tidewm.
    property var tidewmHeard: ({})

    I3IpcListener {
        subscriptions: Compositor.tidewm ? ["layout"] : []

        onIpcEvent: event => {
            if (event.type === "layout") {
                root.tidewmHeard = Tw.heardLayout(root.tidewmHeard, event.data);
            }
        }
    }

    Connections {
        target: Compositor.tidewm ? null : Hyprland

        function onRawEvent(event) {
            if (event.name === "configreloaded") {
                // Assumes a reload runs layout.lua afresh, starting every
                // workspace again in its default mode; TODO.md has the
                // live check.
                root.modes = {};
                return;
            }
            if (event.name !== "custom") {
                return;
            }
            const heard = Layouts.parseAnnouncement(event.data);
            if (heard) {
                root.modes = Object.assign({}, root.modes, { [heard.workspace]: heard.mode });
            }
        }
    }
}
