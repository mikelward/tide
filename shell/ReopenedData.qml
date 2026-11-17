pragma Singleton

import QtQuick
import Quickshell
import "lib/minimized.mjs" as Min
import "lib/reopened.mjs" as Reopened

// Reopened windows go back to their workspaces (SPEC.md §6.5), on Hyprland
// and on tidewm alike: the shell remembers each window that closes, and
// sends an app's windows back, unfollowed, when it opens them again with
// the same titles, as a browser restarting to update does
// (lib/reopened.mjs). What's remembered is the shell's alone, so a
// restarted shell starts with nothing remembered. tide on KDE does the same
// in its KWin script.
Singleton {
    id: root

    property var state: Reopened.NOTHING

    // Starts it, from shell.qml: the windows open now are the first seen.
    function load() {
        root.changed();
    }

    function changed() {
        const windows = Compositor.windows.map(w => ({
            address: w.address ?? "",
            app: w.app,
            title: w.title,
            workspace: Min.homeWorkspace(w.workspaceName),
            place: w.workspaceName
        }));
        const r = Reopened.windowsChanged(root.state, windows, Date.now());
        root.state = r.state;
        for (const m of r.moves) {
            console.log(`tide: sending window ${m.address} (${m.app}), reopened, back to ${m.workspace}`);
            Compositor.sendWindowTo(m.address, m.workspace);
        }
    }

    Connections {
        target: Compositor

        function onWindowsChanged() {
            root.changed();
        }
    }
}
