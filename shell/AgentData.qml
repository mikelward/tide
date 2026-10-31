pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/agent.mjs" as Agent
import "lib/polkit.mjs" as Polkit

// The shell's side of tide-agent, NetworkManager's secret agent (SPEC.md
// §5.6), on unless TIDE_AGENT=0. It starts tide-agent and talks to it
// over its stdin and stdout, as the greeter does tide-greetd: tide-agent does the D-Bus side, and this
// decides where and when each request is asked (shell/lib/agent.mjs). The
// network popover asks for a Wi-Fi key it just tried in place;
// AgentPrompt.qml asks for the rest. A line either way can hold a
// password, so none is ever logged.
Singleton {
    id: root

    readonly property bool enabled: Quickshell.env("TIDE_AGENT") !== "0"

    // tide-agent's last status message ({state, pid, message}), null
    // until it sends one, and its BlueZ pairing agent's.
    property var status: null
    property var btStatus: null
    // Whether tide-lock.service runs, from tide-agent.
    property bool locked: false
    // Requests declined while locked, offered once the lock goes.
    property var missed: []
    // The connections the shell brought up lately (Agent.noteStarted).
    property var startedAt: ({})

    // Requests wait their turn; one is asked at a time.
    property var queue: []
    property var current: null
    // How it's asked: "" while the guard is asked, "popover", "prompt", or
    // "notified" while the notification offers it. `focused` is whether
    // the prompt takes the keyboard.
    property string showing: ""
    property bool focused: false
    // The popover a "popover" request is asked in (Agent.ownerFor).
    property var owner: null
    property var notifier: null

    // Restarts back off as the polkit agent's do (Polkit.retrySeconds),
    // and the first failure in a run of them is a notification.
    property int attempt: 0
    property bool warned: false
    property bool started: false

    function noteStarted(uuid) {
        root.startedAt = Agent.noteStarted(root.startedAt, uuid, Date.now());
    }

    function send(line) {
        if (!helper.running || !root.started) {
            console.warn("tide: tide-agent isn't running, so the answer to NetworkManager's request was lost");
            return;
        }
        helper.write(line);
    }

    function answer(type, id, values) {
        root.send(Agent.answerLine(type, id, values));
        if (root.current && root.current.id === id) {
            root.finish();
        }
    }

    function reply(id, values) {
        root.answer("reply", id, values);
    }
    function cancel(id) {
        root.answer("cancel", id);
    }
    function decline(id) {
        root.answer("decline", id);
    }

    function handle(m) {
        switch (m.type) {
        case "request":
            root.queue = root.queue.concat([m]);
            root.reevaluate();
            break;
        case "cancel":
            // NetworkManager gave up (CancelGetSecrets), or tide-agent's
            // time ran out: the one way a request ends that's not ours.
            root.queue = root.queue.filter(r => r.id !== m.id);
            if (root.current && root.current.id === m.id) {
                root.finish();
            }
            root.reevaluate();
            break;
        case "status":
            root.status = m;
            root.attempt = 0;
            root.warned = false;
            console.log(`tide: network agent: ${Agent.statusText(true, true, m)}`);
            break;
        case "bt-status":
            root.btStatus = m;
            console.log(`tide: Bluetooth pairing agent: ${m.state}${m.pid ? ` (pid ${m.pid})` : ""}${m.message ? `: ${m.message}` : ""}`);
            break;
        case "lock":
            root.locked = m.locked;
            root.reevaluate();
            if (!m.locked) {
                root.offerMissed();
            }
            break;
        case "missed":
            root.missed = Agent.addMissed(root.missed, m.connection);
            if (!root.locked) {
                root.offerMissed();
            }
            break;
        case "fault":
            console.warn(`tide: tide-agent: ${m.message}`);
            break;
        }
    }

    // Every outstanding request, the shown one and those waiting, is looked
    // at again after anything around it changes (Agent.fate): the lock
    // coming or going, the popover it's shown in letting go, tide-agent
    // stopping, a request arriving or ending. So each ends in one place:
    // shown, rerouted, declined and kept for after unlock, or dropped with
    // tide-agent. A reload starts a new shell, whose tide-agent is new too,
    // with nothing outstanding.
    function reevaluate() {
        const base = { helperRunning: helper.running && root.started, locked: root.locked };
        const waiting = [];
        for (const r of root.queue) {
            const f = Agent.fate(r, base);
            if (f === "decline") {
                root.declineMissed(r);
            } else if (f === "keep") {
                waiting.push(r);
            }
        }
        root.queue = waiting;
        const r = root.current;
        if (r) {
            const o = root.owner;
            const env = Object.assign({
                showing: root.showing,
                ownerHolds: Agent.holds(r, o ? { visible: o.visible, pendingName: o.pending ? o.pending.name : "" } : null)
            }, base);
            switch (Agent.fate(r, env)) {
            case "decline":
                root.declineMissed(r);
                root.finish();
                break;
            case "drop":
                root.finish();
                break;
            case "reroute":
                root.owner = null;
                root.showing = "";
                root.ask(r, Agent.route(r, [], root.startedAt, Date.now()), []);
                break;
            }
        }
        root.next();
    }

    // Declined while locked: nothing is asked under the lock (§5.6), and
    // the connection is offered again once it goes.
    function declineMissed(r) {
        root.send(Agent.answerLine("decline", r.id));
        if (Agent.missedOnDecline(r)) {
            root.missed = Agent.addMissed(root.missed, r.connection);
        }
    }

    function next() {
        if (root.current || root.queue.length === 0) {
            return;
        }
        const request = root.queue[0];
        root.queue = root.queue.slice(1);
        root.current = request;
        const popovers = NetworkData.open.map(p => ({ popover: p, visible: p.visible, pendingName: p.pending ? p.pending.name : "" }));
        const pending = popovers.map(p => p.pendingName).filter(n => n !== "");
        root.ask(request, Agent.route(request, pending, root.startedAt, Date.now()), popovers);
    }

    // A popover changed (hidden, moved on to another network): the popover
    // holding the current request may have let it go.
    function checkOwner() {
        root.reevaluate();
    }

    function ownerGone(popover) {
        if (root.owner === popover) {
            root.owner = null;
            root.reevaluate();
        }
    }

    function ask(request, how, popovers) {
        switch (how) {
        case "popover":
            root.owner = Agent.ownerFor(request, popovers);
            if (!root.owner) {
                root.ask(request, Agent.route(request, [], root.startedAt, Date.now()), []);
                return;
            }
            root.showing = "popover";
            break;
        case "prompt":
            root.show(true);
            break;
        case "display":
            root.show(false);
            break;
        case "guard":
            runner.createObject(root, {
                command: ["tide", "prompt-focus"],
                then: run => root.guardAnswered(request, run)
            });
            break;
        default:
            root.notify();
        }
    }

    function guardAnswered(request, run) {
        if (request !== root.current || root.showing !== "") {
            return;
        }
        const route = Polkit.route(run.code);
        if (route.warn) {
            console.warn(`tide: couldn't ask the focus guard whether the network prompt may take the keyboard (${(run.err ?? "").trim() || "tide prompt-focus didn't start"}); offering it through a notification`);
        }
        if (route.show === "prompt") {
            root.show(true);
        } else {
            root.notify();
        }
    }

    function notify() {
        const request = root.current;
        root.showing = "notified";
        root.notifier = runner.createObject(root, {
            command: Agent.notifyCommand(request),
            then: (run, process) => root.notificationAnswered(request, run, process)
        });
    }

    function notificationAnswered(request, run, process) {
        if (root.notifier === process) {
            root.notifier = null;
        }
        if (request !== root.current || root.showing !== "notified") {
            return;
        }
        const outcome = Agent.notifyOutcome(run.started, run.code, run.out);
        if (outcome === "open") {
            // The click was yours.
            root.show(true);
        } else if (outcome === "dismissed") {
            root.cancel(request.id);
        } else {
            console.warn(`tide: couldn't offer the network prompt through a notification (${(run.err ?? "").trim() || `notify-send exited ${run.code}`}); showing it without the keyboard, so a click opens it`);
            root.show(false);
        }
    }

    // A VPN's own dialog has nothing for the shell to draw: it's told to
    // run, with a focus grant first when it may take the keyboard.
    function show(focused) {
        const request = root.current;
        if (request.kind === "vpn-dialog") {
            root.showing = "running";
            if (!focused) {
                root.answer("go", request.id);
                return;
            }
            Launcher.run(Agent.GRANT_ANY, ok => {
                if (!ok) {
                    console.warn("tide: couldn't grant the VPN's sign-in window focus, so it opens marked instead");
                }
                if (root.current === request) {
                    root.answer("go", request.id);
                }
            });
            return;
        }
        root.focused = focused;
        root.showing = "prompt";
    }

    function finish() {
        if (root.notifier) {
            root.notifier.signal(2);
            root.notifier = null;
        }
        root.current = null;
        root.showing = "";
        root.focused = false;
        root.owner = null;
        Qt.callLater(root.next);
    }

    function offerMissed() {
        const list = root.missed;
        root.missed = [];
        for (const connection of list) {
            runner.createObject(root, {
                command: Agent.missedCommand(connection),
                then: run => {
                    const outcome = Agent.missedOutcome(run.started, run.code, run.out);
                    if (outcome === "connect") {
                        root.noteStarted(connection.uuid);
                        Launcher.run(Agent.connectCommand(connection.uuid));
                    } else if (outcome === "failed") {
                        console.warn(`tide: couldn't say that ${connection.id} needs a password (${(run.err ?? "").trim() || `notify-send exited ${run.code}`})`);
                    }
                }
            });
        }
    }

    // tide-agent stopped: whatever it was asking is gone with it, since
    // NetworkManager saw the agent go.
    function stopped(code) {
        root.started = false;
        root.status = null;
        root.btStatus = null;
        root.reevaluate();
        if (!root.enabled) {
            return;
        }
        const wait = Polkit.retrySeconds(root.attempt);
        console.warn(`tide: tide-agent stopped (${code === null ? "it couldn't start: is it installed?" : `exit ${code}`}), so NetworkManager can't ask the shell for passwords; starting it again in ${wait} s`);
        if (!root.warned) {
            root.warned = true;
            Launcher.run(["notify-send", "--app-name=tide", "--icon=network-error-symbolic", "Network passwords can't be asked for", "tide-agent stopped; `tide doctor` says why."]);
        }
        restart.interval = wait * 1000;
        root.attempt += 1;
        restart.start();
    }

    Process {
        id: helper

        command: [Quickshell.env("TIDE_AGENT_COMMAND") || "tide-agent"]
        stdinEnabled: true
        running: root.enabled

        stdout: SplitParser {
            onRead: data => {
                const r = Agent.parseLine(data);
                if (r.error) {
                    console.warn(`tide: ${r.error}`);
                    return;
                }
                root.handle(r.message);
            }
        }
        // tide-agent's own log, which never holds a secret.
        stderr: SplitParser {
            onRead: data => console.warn(data)
        }
        onStarted: root.started = true
        onExited: (code, status) => root.stopped(code)
        // A command that can't start stops without `started` or `exited`
        // (shell/lib/launch.mjs).
        onRunningChanged: {
            if (!running && !root.started && root.enabled && !restart.running) {
                root.stopped(null);
            }
        }
    }

    Timer {
        id: restart

        onTriggered: helper.running = true
    }

    // `qs -c tide ipc call agent status`, for `tide doctor`.
    IpcHandler {
        target: "agent"

        function status(): string {
            return Agent.statusText(root.enabled, helper.running, root.status);
        }
    }

    // One run of a command whose answer matters, as PolkitData's.
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
