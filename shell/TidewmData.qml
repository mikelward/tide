pragma Singleton

import QtQuick
import Quickshell
import Quickshell.I3
import Quickshell.Io
import "lib/tidewm.mjs" as Tw

// tidewm's windows, for Compositor.qml in tidewm's session (SPEC.md §5.3):
// its GET_TREE, asked of `tide-msg` each time the listener connects and
// when a workspace is renamed, kept up to date by its window events
// (lib/tidewm.mjs). Quickshell's I3 module
// keeps workspaces and monitors, but no windows. In Hyprland's session it
// listens to nothing and asks nothing.
Singleton {
    id: root

    readonly property bool listening: Compositor.tidewm
    // The windows and their focus order (Tw.windowEvent).
    property var state: Tw.NO_WINDOWS
    // While the tree is being asked for, the window events heard
    // meanwhile, replayed on it when it comes, since it may be older than
    // they are; null otherwise.
    property var heard: null

    function askForTree() {
        if (tree.running) {
            root.treeAgain = true;
            return;
        }
        root.heard = [];
        tree.running = true;
    }

    // Asked again while asking: the listener connected again meanwhile.
    property bool treeAgain: false

    function treeRead(text) {
        // The focus history isn't in the tree, so the order so far is kept
        // for the windows still there (Tw.refreshed).
        let next = Tw.refreshed(root.state, text);
        if (next === null) {
            console.warn(`tide: couldn't read tidewm's window tree (${text.trim().slice(0, 200)}); its windows stay as they were`);
            next = root.state;
        }
        for (const event of root.heard ?? []) {
            next = Tw.windowEvent(next, event);
        }
        root.heard = null;
        root.state = next;
    }

    I3IpcListener {
        // Subscribing sends a tick at once, so a tick with `first` is the
        // listener connected, again or for the first time. A workspace
        // renamed changes its windows' workspace name with no window event
        // (Tw.asksForTree).
        subscriptions: root.listening ? ["window", "workspace", "tick"] : []

        onIpcEvent: event => {
            if (Tw.asksForTree(event.type, event.data)) {
                root.askForTree();
                return;
            }
            if (event.type !== "window") {
                return;
            }
            if (root.heard !== null) {
                root.heard = root.heard.concat([event.data]);
            } else {
                root.state = Tw.windowEvent(root.state, event.data);
            }
        }
    }

    Process {
        id: tree

        property string errors: ""

        command: ["tide-msg", "--type", "get_tree"]
        stdout: StdioCollector {
            onStreamFinished: root.treeRead(text)
        }
        stderr: StdioCollector {
            onStreamFinished: tree.errors = text
        }
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: tide-msg --type get_tree exited ${code}: ${tree.errors.trim()}`);
            }
        }
        onRunningChanged: {
            if (running) {
                return;
            }
            // A tide-msg that couldn't start, or said nothing, leaves no
            // tree to read, so the events heard meanwhile go on the
            // windows as they were rather than wait for one.
            Qt.callLater(() => {
                if (!tree.running && root.heard !== null) {
                    root.treeRead("");
                }
                if (root.treeAgain && !tree.running) {
                    root.treeAgain = false;
                    root.askForTree();
                }
            });
        }
    }
}
