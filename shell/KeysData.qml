pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/keys.mjs" as Keys
import "lib/launch.mjs" as Run

// The key bindings Hyprland has now, for the settings panel's keyboard
// shortcuts (SPEC.md §16), from `hyprctl binds -j` (shell/lib/keys.mjs),
// or on tidewm (§5.3) its config file's, from `tide-msg --type
// get_bindings`: listed as the shell starts, and again as the Keyboard
// page shows them, since a config reload can change them.
Singleton {
    id: root

    // The bindings as last listed, as [{keys, does, submap}].
    property var binds: []
    // Why the last listing has none, or "".
    property string error: ""

    function list() {
        lister.createObject(root).running = true;
    }

    // hyprctl binds -j, or tidewm's, read once both its streams end, as
    // InputData's device list is.
    Component {
        id: lister

        Process {
            id: listing

            property var state: Run.initial()
            property string out: ""
            property bool outRead: false
            property string errors: ""
            property bool errorsRead: false

            function streamed() {
                if (outRead && errorsRead) {
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
                if (state.report?.level === "warn") {
                    console.warn(state.report.message);
                } else if (state.report?.level === "log") {
                    console.log(state.report.message);
                }
                const failed = state.report?.level === "warn";
                const r = Compositor.tidewm ? Keys.listedTidewmBinds(failed, out) : Keys.listedBinds(failed, out);
                if (r.error !== "") {
                    console.warn(`tide: ${r.error}`);
                }
                root.binds = r.binds;
                root.error = r.error;
                destroy();
            }

            command: Compositor.tidewm ? ["tide-msg", "--type", "get_bindings"] : ["hyprctl", "binds", "-j"]
            stdout: StdioCollector {
                onStreamFinished: {
                    listing.out = text;
                    listing.outRead = true;
                    listing.streamed();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    listing.errors = text;
                    listing.errorsRead = true;
                    listing.streamed();
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
}
