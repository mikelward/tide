import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import Quickshell.Io
import "lib/compositor.mjs" as Comp
import "lib/lock.mjs" as Lock

// The main keyboard's layout, named under the login and lock field
// (Lock.layoutNext): read from hyprctl at start, again on each layout
// switch Hyprland reports, and again on refresh(), which the lock and the
// greeter call when a password fails, since that is when the layout matters
// and the main keyboard may have changed with no event (an unplug).
// Unknown, the name is hidden rather than guessed. The bar's layout label
// (KeyboardData) reads it too, with the main keyboard's layout count and
// which is active. On tidewm (§5.3) it's tidewm's GET_INPUTS, read again on
// each of its input events.
Scope {
    id: root

    // Names the process in its warnings.
    property string name: "tide-lock"
    readonly property string layoutName: Lock.layoutName(current.keymap)
    readonly property bool tidewm: Comp.isTidewm(Quickshell.env("XDG_CURRENT_DESKTOP"))
    // The tide-msg to ask tidewm with: the greeter names the one setup
    // checked, beside tide-greeter, rather than whichever is first on PATH.
    property string msg: "tide-msg"
    readonly property string reader: root.tidewm ? root.msg : "hyprctl"

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

        command: root.tidewm ? [root.msg, "--type", "get_inputs"] : ["hyprctl", "devices", "-j"]
        Component.onCompleted: root.refresh()

        stdout: StdioCollector {
            onStreamFinished: {
                const keyboard = root.tidewm ? Lock.tidewmKeyboard(text) : Lock.mainKeyboard(text);
                if (keyboard === null) {
                    console.warn(`${root.name}: ${devices.command.join(" ")} gave no keyboard; the layout's name stays hidden`);
                }
                devices.answered = true;
                root.layoutEvent(Object.assign({ type: "answer", keymap: null }, keyboard));
            }
        }
        onStarted: started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`${root.name}: ${devices.command.join(" ")} exited ${code}`);
            }
        }
        onRunningChanged: {
            if (running) {
                return;
            }
            if (!started) {
                console.warn(`${root.name}: couldn't start ${root.reader}; the layout's name stays hidden`);
            }
            // No output to answer with: the read is over all the same.
            if (!answered) {
                root.layoutEvent({ type: "answer", keymap: null });
            }
        }
    }

    // tidewm's input events: a layout switched, a keymap changed, or a
    // keyboard came or went.
    I3IpcListener {
        subscriptions: root.tidewm ? ["input"] : []

        onIpcEvent: event => {
            if (event.type === "input") {
                root.refresh();
            }
        }
    }

    Connections {
        target: Hyprland
        enabled: !root.tidewm

        // The event names a keyboard, but only hyprctl says which is main,
        // so it's only a cue to read again.
        function onRawEvent(event) {
            if (event.name === "activelayout") {
                root.refresh();
            }
        }
    }
}
