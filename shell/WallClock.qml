import QtQuick
import Quickshell
import "lib/wallclock.mjs" as Wall

// A SystemClock at minute precision that also catches up at once when the
// wall clock jumps: on a resume, or when the time is set (SPEC.md §7.3).
// SystemClock's own timer stops while the machine sleeps, so on its own
// it shows the time from before a suspend for up to a minute after it.
// A wake comes from logind (Sleep.qml); the check each second catches the
// rest, and a wake if logind can't be heard.
QtObject {
    id: root

    // The current minute, as SystemClock's `date`.
    readonly property var date: clock.date

    // After a jump, once `date` is the new time.
    signal jumped

    property SystemClock clock: SystemClock {
        id: clock

        precision: SystemClock.Minutes
    }

    function catchUp() {
        // Turning it off and on reads the time afresh and waits for the
        // next minute from now.
        clock.enabled = false;
        clock.enabled = true;
        root.jumped();
    }

    property Timer watch: Timer {
        property real last: Date.now()

        interval: Wall.CHECK_MS
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            const jump = Wall.jumped(last, now, interval);
            last = now;
            if (jump) {
                root.catchUp();
            }
        }
    }

    property Connections wake: Connections {
        target: Sleep

        function onWoke() {
            // So the check that follows doesn't catch up a second time.
            root.watch.last = Date.now();
            root.catchUp();
        }
    }
}
