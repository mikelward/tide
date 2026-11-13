pragma Singleton

import QtQuick
import Quickshell
import "lib/report.mjs" as Report
import "lib/tidewm.mjs" as Tw
import "lib/workspacenames.mjs" as Names

// Pinned windows in tidewm's session (SPEC.md §6.5): tidewm keeps open each
// window pinned where it is, with its own keep_open, told as the windows,
// their workspaces and the Workspaces settings change (Tw.keepOpenCommand).
// Its kill then leaves the window open, from Super+Backspace or the app's
// own close keys, which conf's tidewm config binds --kept-open, and its
// close_refused event is the notification saying where it's pinned. A
// move to another workspace ends it in tidewm, and this says it again if
// the window's pinned there too. In Hyprland's session,
// hypr/tide/pinned.lua does it all, and this does nothing.
Singleton {
    id: root

    // The workspace the window ({app, workspaceName}) is pinned on, or
    // null. A minimized window is pinned on the workspace it came from.
    function pinnedOn(w) {
        return Names.pinnedOn(w.app, w.workspaceName, WorkspacesData.settings, WorkspacesData.resolved);
    }

    // What tidewm needs telling, as one tide-msg call, or "".
    readonly property string wanted: Compositor.tidewm
        ? Tw.keepOpenCommand(Compositor.windows, w => root.pinnedOn(w) !== null) : ""
    // The last call, out or done, which isn't made again until what's
    // wanted changes: done, its keep_open events are on their way, and
    // failed, a tidewm too old for keep_open fails each time the same way.
    // Nothing wanted forgets it, so the same call later is made again.
    property string sent: ""
    property bool sending: false

    onWantedChanged: {
        if (root.wanted === "") {
            root.sent = "";
        }
        root.push();
    }

    // Starts it, from shell.qml: windows open before the shell started may
    // be pinned already.
    function load() {
        root.push();
    }

    // One call at a time, so an older one can't land after a newer one;
    // each change's keep_open event brings what's wanted next.
    function push() {
        if (root.sending || root.wanted === "" || root.wanted === root.sent) {
            return;
        }
        const sending = root.wanted;
        root.sending = true;
        root.sent = sending;
        Launcher.run(["tide-msg", sending], ok => {
            if (!ok) {
                console.warn(`tide: couldn't have tidewm keep pinned windows open (${sending}), so they close as any other`);
            }
            root.sending = false;
            root.push();
        });
    }

    Connections {
        target: Compositor.tidewm ? TidewmData : null

        function onCloseRefused(address) {
            const w = Compositor.windows.find(x => x.address === address);
            // tidewm keeps open only what this said is pinned, so a window
            // it says it left open is pinned on its workspace, though the
            // settings may have changed since.
            const workspace = w ? (root.pinnedOn(w) ?? w.workspaceName) : "";
            const notice = Names.pinnedNotice(workspace);
            console.log(`tide: tidewm kept window ${address} open: it's pinned on ${workspace}`);
            Launcher.run(Report.notifyCommand(notice.summary, notice.body), ok => {
                if (!ok) {
                    console.warn(`tide: couldn't say window ${address} is pinned on ${workspace}`);
                }
            });
        }
    }
}
