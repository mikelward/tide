import QtQuick
import Quickshell
import Quickshell.Io
import "lib/lock.mjs" as Lock

// Whether there's a keyboard to type with, for the password field's focus
// on the login and lock faces (Lock.keyboardsNext): `tide keyboards` at
// start, and again on each input device udev adds or removes, which
// `udevadm monitor` reports. A monitor's KVM switching its USB keyboard
// to this machine or away is one. While it can't be told, there counts as
// one, so the field shows its focus as it did before.
Scope {
    id: root

    // Names the process in its warnings.
    property string name: "tide-lock"
    readonly property bool present: Lock.hasKeyboard(current)
    // How many, null while unknown: the lock and the greeter read the
    // layout again when it changes, so a keyboard that went takes its
    // layout's badge with it.
    readonly property var count: current.count

    property var current: Lock.KEYBOARDS_INITIAL

    function refresh() {
        root.keyboardsEvent({ type: "refresh" });
    }

    function keyboardsEvent(event) {
        const r = Lock.keyboardsNext(root.current, event);
        root.current = r.state;
        if (r.query) {
            names.lookUp();
        }
    }

    Process {
        id: names

        // Quickshell reports a command that can't start (no tide on PATH)
        // only by stopping without `started` (shell/lib/launch.mjs).
        property bool started: false
        property int lastCode: -1

        function lookUp() {
            started = false;
            lastCode = -1;
            running = true;
        }

        command: ["tide", "keyboards"]
        Component.onCompleted: root.refresh()

        stdout: StdioCollector {
            id: namesOut
        }
        stderr: StdioCollector {
            id: namesErr
        }
        onStarted: started = true
        onExited: (code, status) => {
            names.lastCode = code;
            if (code !== 0) {
                console.warn(`${root.name}: keyboards: tide keyboards exited ${code}: ${namesErr.text.trim()}; the password field shows its focus whether or not there's a keyboard`);
            }
        }
        onRunningChanged: {
            if (running) {
                return;
            }
            if (!started) {
                console.warn(`${root.name}: keyboards: couldn't start tide keyboards; the password field shows its focus whether or not there's a keyboard`);
            }
            root.keyboardsEvent({ type: "answer", names: started && lastCode === 0 ? namesOut.text : null });
        }
    }

    // Each line is a cue to count again: an event, or, once it's
    // listening, its header, which line buffering lets through at once, so
    // a change between the first count and then isn't missed.
    Process {
        id: watch

        property bool started: false

        command: ["stdbuf", "-oL", "udevadm", "monitor", "--udev", "--subsystem-match=input"]
        running: true

        stdout: SplitParser {
            onRead: root.refresh()
        }
        onStarted: started = true
        onExited: (code, status) => {
            console.warn(`${root.name}: keyboards: udevadm monitor exited ${code}; the password field shows its focus whether or not there's a keyboard`);
        }
        onRunningChanged: {
            if (running) {
                return;
            }
            if (!started) {
                console.warn(`${root.name}: keyboards: couldn't start udevadm monitor; the password field shows its focus whether or not there's a keyboard`);
            }
            root.keyboardsEvent({ type: "lost" });
        }
    }
}
