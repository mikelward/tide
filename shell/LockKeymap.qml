import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/lock.mjs" as Lock

// The main keyboard's layout, for the badge by the lock's field
// (Lock.layoutNext): read from hyprctl at start, again on each layout
// switch Hyprland reports, and again on refresh(), which the lock calls
// when a password fails, since that is when the badge matters and the main
// keyboard may have changed with no event (an unplug). Unknown, the badge
// is hidden rather than guessed.
Scope {
    id: root

    // Names the process in its warnings.
    property string name: "tide-lock"
    readonly property string badge: Lock.layoutBadge(current.keymap)

    property var current: Lock.LAYOUT_INITIAL

    function refresh() {
        root.layoutEvent({ type: "refresh" });
    }

    function layoutEvent(event) {
        const r = Lock.layoutNext(root.current, event);
        root.current = r.state;
        if (r.query) {
            devices.lookUp();
        }
    }

    Process {
        id: devices

        // Quickshell reports a command that can't start (no hyprctl on
        // PATH) only by stopping without `started` (shell/lib/launch.mjs).
        property bool started: false
        property bool answered: false

        function lookUp() {
            started = false;
            answered = false;
            running = true;
        }

        command: ["hyprctl", "devices", "-j"]
        Component.onCompleted: root.refresh()

        stdout: StdioCollector {
            onStreamFinished: {
                const keymap = Lock.mainKeymap(text);
                if (keymap === null) {
                    console.warn(`${root.name}: hyprctl devices gave no keyboard; the layout badge stays hidden`);
                }
                devices.answered = true;
                root.layoutEvent({ type: "answer", keymap: keymap });
            }
        }
        onStarted: started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`${root.name}: hyprctl devices exited ${code}`);
            }
        }
        onRunningChanged: {
            if (running) {
                return;
            }
            if (!started) {
                console.warn(`${root.name}: couldn't start hyprctl; the layout badge stays hidden`);
            }
            // No output to answer with: the read is over all the same.
            if (!answered) {
                root.layoutEvent({ type: "answer", keymap: null });
            }
        }
    }

    Connections {
        target: Hyprland

        // The event names a keyboard, but only hyprctl says which is main,
        // so it's only a cue to read again.
        function onRawEvent(event) {
            if (event.name === "activelayout") {
                root.refresh();
            }
        }
    }
}
