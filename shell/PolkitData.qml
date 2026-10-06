pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/polkit.mjs" as Polkit

// The shell's polkit agent (SPEC.md §5.2, §14.1), opt-in with
// TIDE_POLKIT=1 until it has run in a live session. With it set,
// tide-shell starts no agent of its own, and the shell's asks for every
// password a privileged action needs. PolkitPrompt.qml draws the prompt.
//
// A request takes the keyboard only when it follows your key press: the
// focus guard says whether you pressed one in the last 2 s (`tide
// prompt-focus`). Otherwise a notification offers Authenticate, and the
// prompt opens from it, so a password field never appears under typing
// meant for something else. Quickshell 0.3.1 doesn't say which process
// asked, so the rest of §14.1's rule, that the requester descends from the
// focused window's process, waits on it (TODO.md).
Singleton {
    id: root

    readonly property bool enabled: Quickshell.env("TIDE_POLKIT") === "1"

    readonly property var agent: agentLoader.item
    readonly property bool registered: root.agent?.isRegistered ?? false
    // The request being handled; polkitd queues the rest.
    readonly property var flow: root.agent?.flow ?? null

    // How the request shows: "" while the guard is asked, "notified" while
    // the notification offers it, "prompt" once the prompt is up. `focused`
    // is whether the prompt takes the keyboard: it doesn't when it's up
    // only because the notification couldn't be shown, and then a click
    // gives it the keyboard.
    property string showing: ""
    property bool focused: false
    // The request the above is for, so a late answer about one that has
    // ended changes nothing.
    property var routed: null
    // The notification offering it, while it's up.
    property var notifier: null

    // polkitd lets one agent register per session, and Quickshell 0.3.1
    // only logs a refusal, so a registration that hasn't happened when its
    // wait is up counts as refused: the agent is made again, so it takes
    // over once the other agent goes, waiting longer each time
    // (Polkit.retrySeconds), as tide-shell does for an agent of its own.
    // The wait is seconds, where registering takes milliseconds: making it
    // again while Quickshell is still registering the old one would hand
    // its answer to an agent that's gone.
    property int attempt: 0
    property bool remaking: false

    // The agent itself is polkit-agent.qml, the only file that imports
    // Quickshell's polkit module. LazyLoader compiles a source as soon as
    // it's set, so it's set only when enabled: with the agent off, a
    // Quickshell built without polkit still loads the shell.
    LazyLoader {
        id: agentLoader

        source: root.enabled ? "polkit-agent.qml" : ""
        active: root.enabled && !root.remaking
    }

    onRegisteredChanged: {
        if (root.registered) {
            root.attempt = 0;
            console.log("tide: the polkit agent registered with polkitd");
        }
    }

    Timer {
        id: registration

        interval: Polkit.retrySeconds(root.attempt) * 1000
        running: root.enabled && !root.remaking && !root.registered
        onTriggered: {
            if (!root.agent) {
                console.warn("tide: the shell couldn't make its polkit agent (is Quickshell built with polkit? see the error above), so apps can't ask for a password");
                return;
            }
            console.warn(`tide: the polkit agent didn't register with polkitd within ${interval / 1000} s; another agent may hold this session (\`tide doctor\` names it), so it tries again, waiting ${Polkit.retrySeconds(root.attempt + 1)} s`);
            root.attempt += 1;
            root.remaking = true;
        }
    }

    // A new request: ask the guard whether its prompt may take the
    // keyboard. The user running the shell is asked for first, when polkit
    // lists them; choosing restarts the request's PAM conversation, so it's
    // done before anything shows.
    function start() {
        const flow = root.flow;
        root.finish();
        if (!flow) {
            return;
        }
        root.routed = flow;
        const i = Polkit.preferredIdentity(flow.identities, Quickshell.env("USER"));
        if (i >= 0 && flow.selectedIdentity !== flow.identities[i]) {
            flow.selectedIdentity = flow.identities[i];
        }
        runner.createObject(root, {
            command: ["tide", "prompt-focus"],
            then: run => root.guardAnswered(flow, run)
        });
    }

    function guardAnswered(flow, run) {
        if (flow !== root.routed || root.showing !== "") {
            return;
        }
        const route = Polkit.route(run.code);
        if (route.warn) {
            console.warn(`tide: couldn't ask the focus guard whether the polkit prompt may take the keyboard (${(run.err ?? "").trim() || "tide prompt-focus didn't start"}); offering it through a notification`);
        }
        if (route.show === "prompt") {
            root.show(true);
            return;
        }
        root.showing = "notified";
        root.notifier = runner.createObject(root, {
            command: Polkit.notifyCommand(flow.message),
            then: (run, process) => root.notificationAnswered(flow, run, process)
        });
    }

    // An answer about a notification the shell closed itself (the request
    // ended, or `ipc call polkit open` opened it) is no answer.
    function notificationAnswered(flow, run, process) {
        if (root.notifier === process) {
            root.notifier = null;
        }
        if (flow !== root.routed || root.showing !== "notified") {
            return;
        }
        const outcome = Polkit.notifyOutcome(run.started, run.code, run.out);
        if (outcome === "open") {
            root.show(true);
        } else if (outcome === "dismissed") {
            // You closed it: the app hears no rather than waiting on a
            // prompt nobody will open.
            flow.cancelAuthenticationRequest();
        } else {
            console.warn(`tide: couldn't offer the polkit prompt through a notification (${(run.err ?? "").trim() || `notify-send exited ${run.code}`}); showing it without the keyboard, so a click opens it`);
            root.show(false);
        }
    }

    function show(focused) {
        root.focused = focused;
        root.showing = "prompt";
    }

    // The request ended (authenticated, canceled by you or by polkitd) or
    // the next one replaced it: the prompt goes, and so does the
    // notification. notify-send closes it on SIGINT.
    function finish() {
        if (root.notifier) {
            root.notifier.signal(2);
            root.notifier = null;
        }
        root.routed = null;
        root.showing = "";
        root.focused = false;
    }

    // A request that ends drops the flow (the next one, or null), and the
    // next one starts with authenticationRequestStarted.
    onFlowChanged: {
        if (root.flow !== root.routed) {
            root.finish();
        }
    }

    // `qs -c tide ipc call polkit open` opens a request that's waiting on
    // its notification, as Authenticate would: for a key binding.
    // `... polkit status` is how `tide doctor` tells a working agent from
    // one the shell couldn't make (a Quickshell built without polkit) or
    // one polkitd hasn't taken.
    IpcHandler {
        target: "polkit"

        function status(): string {
            if (!root.enabled) {
                return "off";
            }
            if (root.registered) {
                return "registered";
            }
            return root.agent || root.remaking ? "unregistered" : "missing";
        }

        function open(): void {
            if (root.routed && root.showing === "notified") {
                if (root.notifier) {
                    root.notifier.signal(2);
                    root.notifier = null;
                }
                root.show(true);
            }
        }
    }

    // One run of a command whose answer matters, made for each request so
    // a late answer about an old one can't be taken for the new one's. It
    // calls `then` with the finished run (Polkit.runStep) and itself, once,
    // and goes.
    Component {
        id: runner

        Process {
            id: run

            property var then: null
            property var state: Polkit.runStart()

            Component.onCompleted: running = true

            function on(event) {
                state = Polkit.runStep(state, event);
                if (state.finished) {
                    then(state, run);
                    destroy();
                }
            }

            stdout: StdioCollector {
                onStreamFinished: run.on({ type: "stdout", text: text })
            }
            stderr: StdioCollector {
                onStreamFinished: run.on({ type: "stderr", text: text })
            }
            onStarted: on({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    on({ type: "stopped" });
                }
            }
            onExited: (code, status) => on({ type: "exited", code: code })
        }
    }
}
