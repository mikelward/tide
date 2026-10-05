import QtQuick
import Quickshell
import Quickshell.Io
import "lib/lock.mjs" as Lock

// Suspend, Restart and Shut down from the lock, and Restart and Shut down
// from the greeter (SPEC.md §10, §11), through logind as the session menu
// does (shell/lib/session.mjs), but never past an inhibitor: what blocks
// one is shown, not overridden.
// One run at a time (Lock.powerNext): the buttons stay busy until the
// run has its result and its process has stopped, so no signal of one
// run is taken for the next's.
Scope {
    id: root

    property var current: Lock.POWER_IDLE
    readonly property bool busy: Lock.powerBusy(current)
    readonly property string message: current.message

    function press(id) {
        root.powerEvent({ type: "press", id: id });
    }

    function powerEvent(event) {
        const r = Lock.powerNext(root.current, event);
        root.current = r.state;
        if (r.command !== null) {
            powerRunner.command = r.command;
            powerRunner.running = true;
        }
    }

    Process {
        id: powerRunner

        stderr: StdioCollector {
            onStreamFinished: root.powerEvent({ type: "stderr", text: text })
        }
        onStarted: root.powerEvent({ type: "started" })
        onRunningChanged: {
            if (!running) {
                root.powerEvent({ type: "stopped" });
            }
        }
        onExited: (code, status) => root.powerEvent({ type: "exited", code: code })
    }
}
