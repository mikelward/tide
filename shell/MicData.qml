pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "lib/mic.mjs" as Mic

// Whether the microphone is live (SPEC.md §7.4, §10): an app capturing from
// it, from PipeWire's links, so it covers every app and every mic. Keep
// awake holds while it is.
Singleton {
    id: root

    // A link group's state is only valid while it's bound, and a node's
    // properties too, so the links from a mic into an input stream are,
    // and so are those streams, whose properties tell a meter apart.
    readonly property var links: Mic.captureLinks(Pipewire.linkGroups.values, {
        source: PwNodeType.AudioSource,
        inStream: PwNodeType.AudioInStream
    })

    PwObjectTracker {
        objects: root.links.concat(Mic.captureStreams(root.links))
    }

    // The apps' streams a mic is feeding now that are recording.
    readonly property var captures: Mic.liveCaptures(root.links, PwLinkState.Active)
    readonly property bool live: root.captures.length > 0
}
