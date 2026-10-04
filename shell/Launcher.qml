pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/launch.mjs" as Run

// Starts apps from the bar's menus the way keys and the launcher do,
// through `tide launch` (SPEC.md §5.4), and says so in the log when
// one fails rather than leaving a click that seemed to do nothing.
Singleton {
    id: root

    function launch(command) {
        run(["tide", "launch", "--"].concat(command), null);
    }

    // Grants app focus for what comes next (§14.3), then calls `then`,
    // whether or not the grant was recorded: a failed grant is logged,
    // and what the click asked for still happens.
    function grant(app, then) {
        run(["tide", "grant", app], then);
    }

    // Runs a command the launcher built (`tide launch …`, shell/lib/
    // launcher.mjs) from a desktop entry's working directory, if it names
    // one; `uwsm app` keeps it.
    function start(command, workingDirectory) {
        run(command, null, workingDirectory);
    }

    function run(command, then, workingDirectory) {
        const properties = { command: command, then: then };
        if (workingDirectory) {
            properties.workingDirectory = workingDirectory;
        }
        const process = runner.createObject(root, properties);
        process.running = true;
    }

    Component {
        id: runner

        Process {
            id: run

            // Called once the run is done, if set, whether it worked or not.
            property var then: null
            // Its signals, through shell/lib/launch.mjs's track, which logs
            // what it has to say and calls `then` exactly once.
            // Made once, not bound, so nothing can start it over mid-run.
            property var tracker: null

            Component.onCompleted: tracker = Run.track(command, then, {
                warn: m => console.warn(m),
                log: m => console.log(m)
            })

            function handle(event) {
                if (tracker.on(event)) {
                    destroy();
                }
            }

            stderr: StdioCollector {
                onStreamFinished: run.handle({ type: "stderr", text: text })
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (exitCode, status) => handle({ type: "exited", code: exitCode })
        }
    }
}
