pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/keys.mjs" as Keys
import "lib/launch.mjs" as Run

// The key bindings Hyprland has now, for the settings panel's Keys page
// (SPEC.md §16), from `hyprctl binds -j` (shell/lib/keys.mjs): listed as
// the shell starts, and again as the page shows, since a config reload
// can change them.
Singleton {
    id: root

    // The bindings as last listed, as [{keys, does, submap}].
    property var binds: []
    // Why the last listing has none, or "".
    property string error: ""

    function list() {
        lister.createObject(root).running = true;
    }

    // hyprctl binds -j, read once both its streams end, as InputData's
    // device list is.
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
                const r = Keys.listedBinds(state.report?.level === "warn", out);
                if (r.error !== "") {
                    console.warn(`tide: ${r.error}`);
                }
                root.binds = r.binds;
                root.error = r.error;
                destroy();
            }

            command: ["hyprctl", "binds", "-j"]
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
