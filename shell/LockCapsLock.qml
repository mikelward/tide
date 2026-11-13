import QtQuick
import Quickshell
import Quickshell.Io
import "lib/lock.mjs" as Lock

// Whether Caps Lock is on, for "Caps Lock is on" under the login and lock
// field (SPEC.md §10): `tide caps-lock` reads the keyboards' Caps Lock
// lights, which Hyprland and tidewm both set. Read at start, and again on
// refresh(), which the lock and the greeter call when a keyboard comes or
// goes and each time Caps Lock is pressed. While it can't be told, it
// counts as off.
Scope {
    id: root

    // Names the process in its warnings.
    property string name: "tide-lock"
    readonly property bool on: current.on === true

    property var current: Lock.CAPS_LOCK_INITIAL

    function refresh() {
        root.capsEvent({ type: "refresh" });
    }

    function capsEvent(event) {
        const r = Lock.capsLockNext(root.current, event);
        root.current = r.state;
        if (r.query) {
            read.lookUp();
        }
    }

    Process {
        id: read

        // Quickshell reports a command that can't start (no tide on PATH)
        // only by stopping without `started` (shell/lib/launch.mjs).
        property bool started: false
        property int lastCode: -1

        function lookUp() {
            started = false;
            lastCode = -1;
            running = true;
        }

        command: ["tide", "caps-lock"]
        Component.onCompleted: root.refresh()

        stdout: StdioCollector {
            id: readOut
        }
        stderr: StdioCollector {
            id: readErr
        }
        onStarted: started = true
        onExited: (code, status) => {
            read.lastCode = code;
            if (code !== 0) {
                console.warn(`${root.name}: caps lock: tide caps-lock exited ${code}: ${readErr.text.trim()}; "Caps Lock is on" stays hidden`);
            }
        }
        onRunningChanged: {
            if (running) {
                return;
            }
            if (!started) {
                console.warn(`${root.name}: caps lock: couldn't start tide caps-lock; "Caps Lock is on" stays hidden`);
            }
            root.capsEvent({ type: "answer", text: started && lastCode === 0 ? readOut.text : null });
        }
    }
}
