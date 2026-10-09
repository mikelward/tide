import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "lib/unplug.mjs" as Unplug

// Unplugging while idle (SPEC.md §10), from shell/lib/unplug.mjs. hypridle's
// suspend step runs `tide idle-suspend`, which on AC leaves a flag instead
// of suspending, and the first input after the step clears it (`tide
// idle-suspend --cancel`, from conf's hypridle.conf). When UPower reports
// the switch to battery, this runs `tide idle-suspend --unplugged`, which
// suspends if the flag is still there: no one has been back since.
Scope {
    id: root

    property var unplug: Unplug.INITIAL

    function apply(r) {
        root.unplug = r.state;
        if (r.run) {
            unplugged.started = false;
            unplugged.running = true;
        }
    }

    Connections {
        target: UPower

        function onOnBatteryChanged() {
            root.apply(Unplug.next(root.unplug, { type: "power", onBattery: UPower.onBattery }));
        }
    }

    Process {
        id: unplugged

        // Quickshell reports a command that can't start only by stopping
        // without `started` (shell/lib/launch.mjs).
        property bool started: false

        command: Unplug.COMMAND
        // Why it didn't suspend, when something stopped it, for the
        // journal: Quickshell drops what a command prints unless it's read.
        stderr: SplitParser {
            onRead: data => console.warn(data)
        }
        onStarted: started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: tide idle-suspend --unplugged exited ${code}`);
            }
        }
        // Each check ends here, whether or not it started.
        onRunningChanged: {
            if (running) {
                return;
            }
            if (!started) {
                console.warn("tide: couldn't start tide idle-suspend, so unplugging won't suspend");
            }
            root.apply(Unplug.next(root.unplug, { type: "done" }));
        }
    }
}
