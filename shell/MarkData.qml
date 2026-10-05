pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/launch.mjs" as Run
import "lib/workspaces.mjs" as Ws

// The bar's attention marks (SPEC.md §14.4), one set for every monitor's
// bar, kept as events arrive (shell/lib/workspaces.mjs):
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
//     kinds together, so Super+Tab goes to them newest first.
//   - While Super+Tab steps through the marks, focusing one clears nothing;
//     releasing Super clears the one it landed on (updateMarks' cycle).
Singleton {
    id: root

    property var marks: Ws.NO_MARKS

    // What a notification's mark is judged against: the windows, and the
    // workspaces on screen when it arrives.
    readonly property var windows: Hyprland.toplevels.values.map(t => ({
        address: Ws.normalizeAddress(t.address),
        workspace: t.workspace ? t.workspace.id : null,
        app: t.lastIpcObject?.class || t.wayland?.appId || "",
        // Lower is more recent (Notes.siteWindowClasses, Ws.focusRank).
        focus: Ws.focusRank(root.focusOrder, Ws.normalizeAddress(t.address), t.lastIpcObject?.focusHistoryID),
    }))

    // Windows focused since the shell started, newest first (Ws.withFocus).
    property var focusOrder: []
    readonly property var visible: Ws.visibleWorkspaces(Hyprland.monitors.values.map(m => ({
        workspace: m.activeWorkspace ? m.activeWorkspace.id : null,
        special: m.lastIpcObject?.specialWorkspace?.id ?? 0,
    })))

    // A notification arrived, or was updated in place: it marks its app's
    // windows that aren't on screen now (`app` an app or a list of them). Each update adds to what it marked.
    // `replaces` is the ID of one it took the place of, whose marks it
    // takes over, or undefined.
    function notified(id, app, replaces) {
        if (app) {
            root.marks = Ws.updateMarks(root.marks, {
                type: "notified",
                id: id,
                replaces: replaces,
                app: app,
                windows: root.windows,
                visible: root.visible
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
    readonly property string noted: JSON.stringify(Ws.attentionOrder(root.marks))

    onNotedChanged: root.push()

    // Tells the guard every marked window in order, one call at a
    // time, so an older list can't land after a newer one.
    function push() {
        if (root.pushing || root.pushed === root.noted) {
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
        target: Hyprland

        function onRawEvent(event) {
            let mark = Ws.markEvent(event.name, event.data);
            if (mark?.type === "focused") {
                root.focusOrder = Ws.withFocus(root.focusOrder, mark.address);
            } else if (mark?.type === "closed") {
                root.focusOrder = Ws.withoutWindow(root.focusOrder, mark.address);
            }
            if (mark?.type === "urgent") {
                mark = Ws.activatedEvent(mark.address, root.windows);
            }
            if (mark !== null) {
                root.marks = Ws.updateMarks(root.marks, mark);
            }
            if (mark?.type === "guardReset") {
                root.resync();
            }
        }
    }
}
