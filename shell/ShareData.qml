pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "lib/share.mjs" as Share

// Whether a screen share is live (SPEC.md §12): an xdph screencast stream
// with something consuming it, from PipeWire rather than Hyprland's
// screencast>> event, which fires for any screencopy. While a screen or
// area is shared, popups are held (§9), and the notification center counts
// them; a window share, known from the share picker's choice, holds none.
Singleton {
    id: root

    // A link group's state is only valid while it's bound, so the links out
    // of share nodes are.
    readonly property var links: Share.shareLinks(Pipewire.linkGroups.values)

    PwObjectTracker {
        objects: root.links
    }

    readonly property var shares: Share.liveShares(Pipewire.nodes.values, root.links, PwLinkState.Active)
    // Each share's kind, from the picker's choice paired with the stream
    // node that follows it (§12); a window share holds no popups.
    property var pairing: Share.PAIRING
    readonly property var shareNodes: Pipewire.nodes.values.filter(n => Share.isShareNode(n)).map(n => n.id)
    readonly property bool holdingPopups: Share.holdsPopups(root.shares, root.pairing)
    // Popups held during the current or last share, for the center's
    // banner. A new share starts the count again, and so does seeing the
    // banner after the share has ended.
    property int held: 0

    onHoldingPopupsChanged: {
        if (root.holdingPopups) {
            root.held = 0;
        }
    }

    onShareNodesChanged: root.apply(Share.nodesSeen(root.pairing, root.shareNodes, Date.now()))
    // Streams already there at startup have no choice to pair with.
    Component.onCompleted: root.apply(Share.nodesSeen(root.pairing, root.shareNodes, Date.now()))

    // The share picker's choice: "screen", "window" or "region".
    function chose(kind) {
        root.apply(Share.chose(root.pairing, kind, Date.now()));
    }

    // A pairing holds popups until PAIR_MS passes without a second node,
    // so this settles each one when it's due.
    function apply(next) {
        const now = Date.now();
        root.pairing = Share.settle(next, now);
        const wait = Share.settleIn(root.pairing, now);
        if (wait === null) {
            settler.stop();
        } else {
            settler.interval = wait;
            settler.restart();
        }
    }

    Timer {
        id: settler
        onTriggered: root.apply(root.pairing)
    }

    function counted(n) {
        root.held += n;
    }

    function seen() {
        if (!root.holdingPopups) {
            root.held = 0;
        }
    }
}
