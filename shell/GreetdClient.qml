import QtQuick
import Quickshell
import Quickshell.Io
import "lib/greetd.mjs" as Greetd

// The greeter's connection to greetd (SPEC.md §11), in place of
// Quickshell's Greetd: tide-greetd relays each request and its reply
// (cmd/tide-greetd), and shell/lib/greetd.mjs keeps every reply with the
// login it answers. Its interface follows Quickshell's, so greeter.qml reads
// the same. tide-greeter passes the helper's path in $TIDE_GREETER_GREETD.
Scope {
    id: root

    property var conversation: Greetd.INITIAL
    // Once tide-greetd has stopped, the next login starts it again.
    readonly property bool available: Greetd.available(root.conversation) || !helper.running
    // A login is under way at greetd, which cancelSession() would stop.
    readonly property bool active: Greetd.active(root.conversation)

    signal authMessage(string message, bool error, bool responseRequired, bool echoResponse)
    signal authFailure(string message)
    signal readyToLaunch()
    signal error(string error)

    function createSession(user) {
        if (!Greetd.available(root.conversation) && !helper.running) {
            root.conversation = Greetd.INITIAL;
            root.unsent = [];
            helper.running = true;
        }
        root.apply(Greetd.createSession(root.conversation, user));
    }
    function respond(text) {
        root.apply(Greetd.respond(root.conversation, text));
    }
    function cancelSession() {
        root.apply(Greetd.cancel(root.conversation));
    }
    // Quickshell exits once greetd has the session, as Quickshell's
    // Greetd.launch does by default.
    function launch(command, env) {
        root.apply(Greetd.launch(root.conversation, command, env));
    }

    // Requests wait here until tide-greetd has started: Quickshell drops
    // a write to a process that isn't running yet.
    property var unsent: []
    property bool started: false

    function apply(r) {
        root.conversation = r.state;
        if (r.requests.length > 0) {
            root.unsent = root.unsent.concat(r.requests);
            root.flush();
        }
        for (const event of r.events) {
            if (event.type === "authMessage") {
                root.authMessage(event.message, event.error, event.responseRequired, event.echo);
            } else if (event.type === "authFailure") {
                root.authFailure(event.message);
            } else if (event.type === "readyToLaunch") {
                root.readyToLaunch();
            } else if (event.type === "launched") {
                Qt.quit();
            } else {
                root.error(event.message);
            }
        }
    }

    function flush() {
        if (!root.started || root.unsent.length === 0) {
            return;
        }
        const lines = root.unsent.map(request => JSON.stringify(request) + "\n").join("");
        root.unsent = [];
        helper.write(lines);
    }

    Process {
        id: helper

        command: [Quickshell.env("TIDE_GREETER_GREETD") || "tide-greetd"]
        stdinEnabled: true
        running: true

        stdout: SplitParser {
            onRead: data => {
                let line = null;
                try {
                    line = JSON.parse(data);
                } catch (e) {
                    // Greetd.received reports a line it can't use as the end
                    // of the connection.
                    console.warn(`tide-greeter: tide-greetd sent a line that isn't JSON: ${e}`);
                }
                root.apply(Greetd.received(root.conversation, line));
            }
        }
        // Its faults also come on stdout, as a line the greeter shows; this
        // is for the journal.
        stderr: SplitParser {
            onRead: data => console.warn(data)
        }
        onStarted: {
            root.started = true;
            root.flush();
        }
        onExited: (exitCode, exitStatus) => {
            root.started = false;
            root.apply(Greetd.stopped(root.conversation, exitCode));
        }
        // A command that can't start stops without `started` or `exited`
        // (shell/lib/launch.mjs).
        onRunningChanged: {
            if (!running && !root.started && Greetd.available(root.conversation)) {
                root.apply(Greetd.stopped(root.conversation, null));
            }
        }
    }
}
