pragma Singleton

import QtQuick
import Quickshell
import "lib/keepawake.mjs" as KeepAwake

// Keep awake (SPEC.md §10), shared by every monitor's bar: while it's on,
// each bar holds an idle inhibitor, so hypridle doesn't dim, lock, blank or
// suspend. It's on while you asked for it, which lasts until you click it
// off, survives a config reload, and starts off in a new shell; and while
// the mic is live (MicData), so an audio-only call with nothing moving on
// screen doesn't blank.
Singleton {
    id: root

    // You turned it on.
    readonly property bool asked: held.on
    readonly property bool on: root.asked || MicData.live

    // Turns your request on or off. While the mic is live it stays on
    // either way; the click still decides what's left once the call ends.
    function toggle() {
        const next = KeepAwake.toggled({
            on: held.on,
            until: held.until
        });
        held.on = next.on;
        held.until = next.until;
    }

    PersistentProperties {
        id: held

        // The same id as before, so a reload into this version keeps keep
        // awake on if it was.
        reloadableId: "tide-keep-awake"

        property bool on: false
        // Set only by the versions that turned it off after two hours;
        // cleared by the migration below.
        property real until: 0

        // Whether it was on before the reload, from either version's state
        // (KeepAwake.migrated), read once now that the old values are in.
        onLoaded: {
            const next = KeepAwake.migrated({
                on: held.on,
                until: held.until
            }, Date.now());
            held.on = next.on;
            held.until = next.until;
        }
    }
}
