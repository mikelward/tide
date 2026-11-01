pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/lock.mjs" as Lock

// The main keyboard's layout, for the bar's label (SPEC.md §7.4): the
// lock's own reader (LockKeymap), read at start and on each layout switch
// Hyprland reports. `next()` moves every keyboard to the layout after the
// main keyboard's, read afresh, as Super+Alt+Space does (§16).
Singleton {
    id: root

    readonly property string keymap: keymapReader.current.keymap
    readonly property int count: keymapReader.current.count
    readonly property var index: keymapReader.current.index
    readonly property string label: Lock.layoutLabel(root.keymap)

    // Hyprland can make another keyboard main with no event (a key on it,
    // an unplug), so the cached index may be another keyboard's. A click
    // reads the main keyboard afresh and switches once that answer is in,
    // as Super+Alt+Space's script does (§16).
    property bool switching: false

    function next() {
        root.switching = true;
        keymapReader.refresh();
    }

    function switchNow() {
        root.switching = false;
        const n = Lock.nextLayout({ index: root.index, count: root.count });
        if (n === null) {
            console.warn("tide: no next keyboard layout to switch to");
            return;
        }
        switcher.command = ["hyprctl", "switchxkblayout", "all", String(n)];
        switcher.running = true;
    }

    Connections {
        target: keymapReader

        // The read a click asked for has answered, and no other is due.
        function onCurrentChanged() {
            if (root.switching && Lock.layoutSettled(keymapReader.current)) {
                root.switchNow();
            }
        }
    }

    LockKeymap {
        id: keymapReader

        name: "tide"
    }

    Process {
        id: switcher

        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "" && text.trim() !== "ok") {
                    console.warn(`tide: hyprctl switchxkblayout said: ${text.trim()}`);
                }
            }
        }
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: hyprctl switchxkblayout exited ${code}`);
            }
        }
    }
}
