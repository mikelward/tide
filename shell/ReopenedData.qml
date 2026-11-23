pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/minimized.mjs" as Min
import "lib/reopened.mjs" as Reopened

// Reopened windows go back to their workspaces (SPEC.md §6.5), on Hyprland
// and on tidewm alike: the shell remembers each window that closes, and
// sends an app's windows back, unfollowed, when it opens them again with
// the same titles, as a browser restarting to update does
// (lib/reopened.mjs). What it remembers, and the windows open, are saved
// to $XDG_STATE_HOME/tide/windows.json as they change, so after a logout,
// or a restarted shell, a browser's restored session goes back too. tide
// on KDE does the same in its KWin script.
Singleton {
    id: root

    property var state: Reopened.NOTHING
    // Whether the file may be written: not before it's read, nor when it
    // couldn't be, so a file this shell can't read isn't replaced.
    property bool saving: false

    readonly property string dir: (Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`) + "/tide"

    // Starts it, from shell.qml: the windows saved before the logout, if
    // any, count as closed now, and the windows open now as opened.
    function load() {
        // Blocks until onLoaded or onLoadFailed has run.
        file.text();
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
            Compositor.sendWindowTo(m.address, m.workspace, `${m.app} reopened it, so it goes back where it was`);
        }
        // A burst of changes, as a browser's titles make, is one write.
        if (root.saving && !writer.running) {
            writer.start();
        }
    }

    Timer {
        id: writer

        interval: 2000
        onTriggered: file.setText(JSON.stringify(Reopened.snapshot(root.state, Date.now())))
    }

    FileView {
        id: file

        path: `${root.dir}/windows.json`
        printErrors: false
        preload: false
        blockLoading: true
        atomicWrites: true
        onLoaded: {
            let saved = null;
            try {
                saved = JSON.parse(text());
            } catch (e) {
                // Replaced at the next write, as nothing in it can be used.
                console.warn(`tide: ${path}: ${e}; windows from before won't go back to their workspaces`);
            }
            root.state = Reopened.restored(saved, Date.now());
            root.saving = true;
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) {
                console.warn(`tide: ${path}: ${FileViewError.toString(error)}; windows won't be saved for the next login`);
                return;
            }
            // No file yet: the first change writes one.
            root.saving = true;
        }
        onSaveFailed: error => console.warn(`tide: ${path}: ${FileViewError.toString(error)}; windows not saved for the next login`)
    }

    Connections {
        target: Compositor

        function onWindowsChanged() {
            root.changed();
        }
    }
}
