pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/frecency.mjs" as Frecency
import "lib/launch.mjs" as Run
import "lib/launcher.mjs" as Search

// What the launcher has run, and how recently (SPEC.md §8), kept in
// $XDG_STATE_HOME/tide/launcher.json so the order survives a restart; and
// which desktop entries are for other desktops; and the wave logo's taps.
Singleton {
    id: root

    // The bar's wave logo opens or closes the launcher (SPEC.md §7.1) on
    // `onScreen`, its bar's screen; LauncherWindow answers.
    signal toggleRequested(var onScreen)

    function toggle(onScreen) {
        root.toggleRequested(onScreen);
    }

    // What launcher.mjs's launcherItems takes as `desktop`: this session's
    // desktop names, and each entry's OnlyShowIn and NotShowIn, read with
    // SHOW_IN_SCRIPT as the shell starts and whenever Quickshell's entries
    // change. Until the first read is in, only the settings apps are left
    // out.
    readonly property var desktopNames: Search.desktopNames(Quickshell.env("XDG_CURRENT_DESKTOP"))
    property var showIn: ({})
    readonly property var desktop: ({ names: root.desktopNames, showIn: root.showIn })
    // Each read's number, so an older one that ends last changes nothing.
    property int reads: 0

    function readShowIn() {
        root.reads += 1;
        reader.createObject(root, { generation: root.reads }).running = true;
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged() {
            root.readShowIn();
        }
    }

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

    Component.onCompleted: {
        root.load();
        root.readShowIn();
    }

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

    // SHOW_IN_SCRIPT, read once both its streams end, as KeysData's
    // listing is. A file it couldn't read is warned about and counts as
    // having neither key.
    Component {
        id: reader

        Process {
            id: reading

            property int generation: 0
            property var state: Run.initial()
            property string out: ""
            property bool outRead: false
            property string errors: ""
            property bool errorsRead: false

            function streamed() {
                if (outRead && errorsRead) {
                    handle({ type: "stderr", text: errors });
                }
            }

            function handle(event) {
                if (state.done) {
                    return;
                }
                state = Run.step(state, event, ["sh", "-c", "(the launcher's OnlyShowIn and NotShowIn reader)"]);
                if (!state.done) {
                    return;
                }
                if (state.report) {
                    console.warn(state.report.message);
                }
                if (generation === root.reads && state.started) {
                    root.showIn = Search.parseShowIn(out);
                    console.log(`tide: launcher: read OnlyShowIn and NotShowIn for ${Object.keys(root.showIn).length} desktop entries`);
                }
                destroy();
            }

            command: ["sh", "-c", Search.SHOW_IN_SCRIPT]
            stdout: StdioCollector {
                onStreamFinished: {
                    reading.out = text;
                    reading.outRead = true;
                    reading.streamed();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    reading.errors = text;
                    reading.errorsRead = true;
                    reading.streamed();
                }
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (code, status) => handle({ type: "exited", code: code })
        }
    }
}
