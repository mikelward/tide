pragma Singleton

import QtQuick
import Quickshell
import "lib/keepawake.mjs" as KeepAwake

// Keep awake (SPEC.md §10), shared by every monitor's bar: while it's on,
// each bar holds an idle inhibitor, so hypridle doesn't dim, lock, blank or
// suspend. It turns itself off after KeepAwake.HOLD_MS. It survives a
// config reload, but a new shell starts with it off.
Singleton {
    id: root

    readonly property bool on: held.until > 0

    function toggle() {
        const next = KeepAwake.toggled({ on: root.on, until: held.until }, Date.now());
        held.until = next.until;
    }

    PersistentProperties {
        id: held

        reloadableId: "tide-keep-awake"

        // When it turns off (ms since the epoch); 0 while it's off.
        property real until: 0
    }

    // Checks the wall clock against `until` every 30 s, so it turns off
    // within 30 s of its time. A timer set for the whole two hours would
    // count only time awake: after a suspend that outlasted the deadline,
    // it would hold on for whatever was left before it. Starting on, it
    // also catches a deadline that passed before a config reload.
    Timer {
        running: root.on
        repeat: true
        triggeredOnStart: true
        interval: 30 * 1000
        onTriggered: {
            if (!KeepAwake.isOn({ on: true, until: held.until }, Date.now())) {
                held.until = 0;
            }
        }
    }
}
