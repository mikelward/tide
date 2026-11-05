pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/launch.mjs" as Run
import "lib/tidewm.mjs" as Tw
import "lib/workspaces.mjs" as Ws

// The bar's attention marks (SPEC.md §14.4), one set for every monitor's
// bar. Events are recorded as they arrive, and which marks stand is worked
// out from them, the windows and the muted list whenever any changes
// (shell/lib/workspaces.mjs's updateMarks and standingMarks):
//   - The focus guard's: a window it kept from focus marks its workspace
//     until the window is focused or closes. Whenever the guard's state may
//     have been rebuilt, the shell drops these and asks it to announce what
//     still waits: when the shell starts (it may have restarted with
//     windows waiting) and after a Hyprland config reload (which runs
//     focus.lua afresh).
//   - Notifications': NotificationData reports each one that arrives or is
//     updated, and each that closes, while the shell is the notification
//     server.
//   - The focus guard hears every marked window in the order they were
//     marked (tide_focus.set_order), since only the shell sees both
//     kinds together, and the switcher's Attention tab lists them newest
//     first.
// On tidewm (SPEC.md §5.3) the events are tidewm's window events
// (TidewmData.qml, Tw.markEvents), the guard's marks being the windows it
// marks urgent, and its guard is its own: nothing is replayed or pushed.
Singleton {
    id: root

    property var marks: Ws.NO_MARKS

    // What a notification's mark is judged against: the windows, and the
    // workspaces on screen when it arrives.
    readonly property var windows: Compositor.windows.map(w => ({
        address: w.address,
        workspace: w.workspace,
        app: w.app,
        // Lower is more recent (Notes.siteWindowClasses, Ws.focusRank).
        focus: Ws.focusRank(root.focusOrder, w.address, w.focusHistoryID),
    }))

    // Muted apps' windows are never marked (SPEC.md §9, Muted apps): their
    // marks clear as they're muted, and Ws.updateMarks records no new one,
    // the guard's or a notification's. Hyprland's own urgent flag on a
    // muted app's window is left out too (Ws.markedWindows).
    readonly property var muted: WorkspacesData.muted

    // Each change is recorded, so a mark made before an entry was added
    // never stands again, even once it's removed: a muted window's, and a
    // muted site's notification's on plain browser windows.
    onMutedChanged: {
        root.marks = Ws.updateMarks(root.marks, { type: "muted", muted: root.muted, windows: root.windows });
    }

    // Windows focused since the shell started, newest first (Ws.withFocus).
    property var focusOrder: []
    // tidewm has no special workspaces, and shows its current one on every
    // monitor.
    readonly property var visible: Ws.visibleWorkspaces(Compositor.tidewm
        ? Compositor.monitors.map(m => ({ workspace: m.workspace, special: 0 }))
        : Hyprland.monitors.values.map(m => ({
            workspace: m.activeWorkspace ? m.activeWorkspace.id : null,
            special: m.lastIpcObject?.specialWorkspace?.id ?? 0,
        })))

    // A notification arrived, or was updated in place: it marks its app's
    // windows that aren't on screen now (`app` an app or a list of them). Each update adds to what it marked.
    // `replaces` is the ID of one it took the place of, whose marks it
    // takes over, or undefined. `sender` is what it's muted by (Mute.noteOf),
    // kept with its marks so muting it later clears them.
    function notified(id, app, replaces, sender) {
        if (app) {
            root.marks = Ws.updateMarks(root.marks, {
                type: "notified",
                id: id,
                replaces: replaces,
                sender: sender,
                app: app,
                windows: root.windows,
                visible: root.visible,
                muted: root.muted
            });
        }
    }

    // A notification closed; whether that clears its marks depends on why
    // (Notes.clearsMarks).
    function dismissed(id) {
        root.marks = Ws.updateMarks(root.marks, { type: "dismissed", id: id });
    }

    // Asks the guard to announce every waiting window again. Each ask is
    // its own process with its own bookkeeping, so one overlapping another
    // (a reload while the startup replay still runs) can't finish the
    // other's; two replays only announce the same windows twice.
    function resync() {
        if (Compositor.tidewm) {
            return;
        }
        // tide_focus.announce_waiting() (hypr/tide/focus.lua)
        // re-sends tide-attention for each waiting window, which the
        // Connections below turn into marks like any other.
        guardCall.createObject(root, {
            command: ["hyprctl", "eval", "tide_focus.announce_waiting()"],
            what: "replay the focus guard's waiting windows"
        }).running = true;
        // A reloaded guard starts with no notification marks, and a call
        // still running may have reached the guard before the reload.
        root.guardGeneration += 1;
        root.pushed = null;
        root.push();
    }

    Component.onCompleted: resync()

    // The marked windows, in order, the guard last heard, as JSON, or
    // null when it needs telling again.
    property var pushed: null
    property bool pushing: false
    property int guardGeneration: 0
    readonly property string noted: JSON.stringify(Ws.attentionOrder(root.marks, root.windows, root.muted))

    onNotedChanged: root.push()

    // Tells the guard every marked window in order, one call at a
    // time, so an older list can't land after a newer one.
    function push() {
        if (Compositor.tidewm || root.pushing || root.pushed === root.noted) {
            return;
        }
        root.pushing = true;
        const sending = root.noted;
        const generation = root.guardGeneration;
        const list = JSON.parse(sending).map(a => `"0x${a}"`).join(",");
        const run = guardCall.createObject(root, {
            command: ["hyprctl", "eval", `tide_focus.set_order({${list}})`],
            what: "tell the focus guard which windows are marked"
        });
        run.finished.connect(() => {
            // A failure isn't retried until the list changes: outside a
            // tide session the guard isn't loaded, and every change
            // would fail the same way. It's reported (guardCall).
            if (generation === root.guardGeneration) {
                root.pushed = sending;
            }
            root.pushing = false;
            root.push();
        });
        run.running = true;
    }

    // One `hyprctl eval` of the focus guard, reported if it fails.
    Component {
        id: guardCall

        Process {
            id: run

            // What it does, for the warning when it fails.
            property string what: ""
            property var state: Run.initial()
            // Its reply is on stdout, which ends apart from stderr: the run
            // counts stderr as in only once both are.
            property string reply: ""
            property bool replyRead: false
            property string errors: ""
            property bool errorsRead: false

            signal finished

            function streamed() {
                if (replyRead && errorsRead) {
                    handle({ type: "stderr", text: errors });
                }
            }

            function handle(event) {
                if (state.done) {
                    return;
                }
                state = Run.step(state, event, command);
                if (!state.done) {
                    return;
                }
                if (!state.started) {
                    console.warn(state.report.message);
                } else if (state.code !== 0 || reply.trim() !== "ok") {
                    // Outside a tide session the guard isn't loaded.
                    console.warn(`tide: couldn't ${what}: ${(reply + state.errors).trim()}`);
                } else if (state.report?.level === "log") {
                    // It worked, but said something on the way.
                    console.log(state.report.message);
                }
                finished();
                destroy();
            }

            stdout: StdioCollector {
                onStreamFinished: {
                    run.reply = text;
                    run.replyRead = true;
                    run.streamed();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    run.errors = text;
                    run.errorsRead = true;
                    run.streamed();
                }
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (code, status) => handle({ type: "exited", code: code })
        }
    }

    Connections {
        target: Compositor.tidewm ? null : Hyprland

        function onRawEvent(event) {
            root.heard(Ws.markEvent(event.name, event.data));
        }
    }

    Connections {
        target: Compositor.tidewm ? TidewmData : null

        function onWindowHeard(data) {
            for (const mark of Tw.markEvents(data)) {
                root.heard(mark);
            }
        }
    }

    // A mark event heard from either compositor (Ws.markEvent, Tw.markEvents),
    // or null, filled in with what updateMarks needs to judge it.
    function heard(event) {
        let mark = event;
        if (mark?.type === "focused") {
            root.focusOrder = Ws.withFocus(root.focusOrder, mark.address);
        } else if (mark?.type === "closed") {
            root.focusOrder = Ws.withoutWindow(root.focusOrder, mark.address);
        }
        if (mark?.type === "urgent") {
            mark = Ws.activatedEvent(mark.address, root.windows);
        }
        if (mark?.type === "guarded") {
            mark = Object.assign({}, mark, {
                app: root.windows.find(w => w.address === mark.address)?.app ?? "",
                muted: root.muted
            });
        } else if (mark?.type === "focused") {
            // Whether muting had cleared a notification's mark on it
            // (Ws.updateMarks's "focused").
            mark = Object.assign({}, mark, { app: root.windows.find(w => w.address === mark.address)?.app });
        }
        if (mark !== null) {
            root.marks = Ws.updateMarks(root.marks, mark);
        }
        if (mark?.type === "guardReset") {
            root.resync();
        }
    }
}
