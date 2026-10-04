pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/frecency.mjs" as Frecency

// What the launcher has run, and how recently (SPEC.md §8), kept in
// $XDG_STATE_HOME/tide/launcher.json so the order survives a restart.
Singleton {
    id: root

    // shell/lib/frecency.mjs's state, keyed by "kind:id".
    property var frecency: Frecency.initial()
    // "unread" until the file has been read, then "saved", or "memory"
    // when it couldn't be, as in HistoryData. The read blocks, and comes
    // before any change; the file is at most 200 short entries.
    property string store: "unread"

    readonly property string dir: (Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`) + "/tide"

    function load() {
        if (root.store === "unread") {
            // Blocks until onLoaded or onLoadFailed has run.
            file.text();
        }
    }

    Component.onCompleted: root.load()

    // The row `key` (launcher.mjs's rowKey) was run now.
    function record(key) {
        root.load();
        root.frecency = Frecency.record(root.frecency, key, Date.now());
        if (root.store === "saved") {
            Qt.callLater(root.flush);
        }
    }

    function flush() {
        file.setText(Frecency.serialize(root.frecency));
    }

    FileView {
        id: file

        path: `${root.dir}/launcher.json`
        printErrors: false
        // Read only when root.load() asks, and then before returning.
        preload: false
        blockLoading: true
        atomicWrites: true
        blockWrites: true
        onLoaded: {
            const result = Frecency.parse(text());
            for (const error of result.errors) {
                console.warn(`tide: ${path}: ${error}`);
            }
            root.frecency = result.state;
            root.store = "saved";
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) {
                // Writing would replace what we couldn't read, so this
                // shell keeps the launcher's history in memory only.
                console.warn(`tide: ${path}: ${FileViewError.toString(error)}; launcher history won't be saved`);
                root.store = "memory";
                return;
            }
            // No file yet: the first launch writes one.
            root.store = "saved";
        }
        onSaveFailed: error => console.warn(`tide: ${path}: ${FileViewError.toString(error)}; launcher history not saved`)
    }
}
