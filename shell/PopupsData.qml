pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/launch.mjs" as Run
import "lib/popups.mjs" as Pop

// Whether any of the bar's popovers and menus is open, on any monitor:
// PopoverData's one open popover, which every popover reports
// (PopoverGrab.qml). The layout hears it (tide_layout.set_popups_open),
// so a click on one over a split edge reaches it rather than starting a
// drag (SPEC.md §6.6). It's told as the shell starts (shell.qml calls
// resync, since a lazy singleton would otherwise wait for the first
// popover), as one that exited with a popover open left it thinking one
// still is, and after a Hyprland config load, which starts the layout
// afresh.
Singleton {
    id: root

    readonly property bool anyOpen: PopoverData.open !== null

    onAnyOpenChanged: root.push()

    // Tells the layout again, whatever it last heard.
    function resync() {
        root.told = Pop.resynced(root.told);
        root.push();
    }

    // What the layout's heard, and the call out, if any (Pop.nextCall).
    property var told: Pop.NOT_TOLD

    function push() {
        const next = Pop.nextCall(root.told, root.anyOpen);
        if (next.send === null) {
            return;
        }
        root.told = next.state;
        const sending = next.send;
        const generation = next.state.generation;
        const run = layoutCall.createObject(root, { command: ["hyprctl", "eval", Pop.layoutCall(sending)] });
        run.finished.connect(() => {
            // A resync while it was out makes it count for nothing, so the
            // next push sends again. A failure isn't retried until it
            // changes; it's reported (layoutCall).
            root.told = Pop.answered(root.told, sending, generation);
            root.push();
        });
        run.running = true;
    }

    Component {
        id: layoutCall

        Process {
            id: run

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
                    // Without the tide layout, or one from before
                    // set_popups_open.
                    console.warn(`tide: couldn't tell the layout about the popovers: ${(reply + state.errors).trim()}`);
                } else if (state.report?.level === "log") {
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
            if (event.name === "configreloaded") {
                root.resync();
            }
        }
    }
}
