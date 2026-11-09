pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/wallclock.mjs" as Wall

// Says when the machine wakes from sleep, as logind does (SPEC.md §7.3),
// for WallClock. One listener for every clock. A listener that stops is
// started again; meanwhile WallClock's own check still catches a wake
// within a few seconds.
Singleton {
    id: root

    // After a wake, once the wall clock has moved on.
    signal woke

    Process {
        id: monitor

        command: Wall.SLEEP_MONITOR
        running: true
        stdout: SplitParser {
            onRead: data => {
                if (Wall.woke(data)) {
                    console.log("tide: woke from sleep");
                    root.woke();
                }
            }
        }
        stderr: SplitParser {
            onRead: data => console.warn(`tide: gdbus monitor: ${data}`)
        }
        onRunningChanged: {
            if (!running) {
                console.warn("tide: gdbus stopped listening for a wake from sleep; trying again in 30 s");
                restart.start();
            }
        }
    }

    Timer {
        id: restart

        interval: 30 * 1000
        onTriggered: monitor.running = true
    }
}
