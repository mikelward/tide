pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/launch.mjs" as Run
import "lib/report.mjs" as Report
import "lib/startup.mjs" as Startup

// Start at login (SPEC.md §16): the commands in startup.json and
// startup.local.json (§16.1), run once a session through `tide launch
// --background --unless-running`, so nothing they open takes focus and
// nothing running is started twice. It records the graphical session it
// ran them in, by graphical-session.target's invocation ID, in
// $XDG_RUNTIME_DIR, so a shell restarted later runs nothing, and the next
// login, even with the runtime directory kept, runs them again. A list that
// can't load yet runs once it does. A bad file is a notification naming it,
// once, and so is each command that fails.
Singleton {
    id: root

    // The list in effect, as the shell runs it.
    property var commands: []
    // The list the page shows: the files' as last read or changed.
    property var listed: []
    // Whether this shell has settled running the list: run it, or found
    // the record says this graphical session already has.
    property bool ran: false
    // Whether the session's ID is being read.
    property bool asking: false
    // The commands being started, in order (Startup.startQueue).
    property var queue: null
    property var reports: Report.NOTHING
    property var fileErrors: []
    // The commands that failed, each "COMMAND: why", reported once.
    property var runFailures: []
    // Why the page's last change couldn't be saved, or "".
    property string saveFailure: ""

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""

    function add(command) {
        return root.edit(commands => Startup.withCommand(commands, command));
    }

    function move(index, command, step) {
        return root.edit(commands => Startup.movedCommand(commands, index, command, step));
    }

    function remove(index, command) {
        return root.edit(commands => Startup.withoutCommand(commands, index, command));
    }

    // Changes the list as `change` says, in startup.local.json: the panel
    // writes only the .local files (§16.1). The files as they are now, so a
    // hand edit made a moment ago is built on, and one that doesn't parse
    // is left as it is. Returns why it didn't, or "".
    function edit(change) {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        if (broken.length > 0) {
            return `${broken[0]}; not changing Start at login`;
        }
        const result = Startup.editedStartup(sharedText, localText, change);
        if (result.error) {
            return `${result.error}; not changing Start at login`;
        }
        const error = local.writeNow(result.text);
        root.saveFailure = error === "" ? "" : `${error}; Start at login not saved`;
        root.load();
        return root.saveFailure;
    }

    function report() {
        const errors = root.fileErrors.concat(root.saveFailure !== "" ? [root.saveFailure] : [], root.runFailures);
        const v = Report.verdict(root.reports, errors);
        root.reports = v.state;
        root.send(v.send);
    }

    function send(errors) {
        for (const error of errors) {
            const summary = root.runFailures.includes(error) ? "A command at login failed" : "Start at login not applied";
            Launcher.run(Report.notifyCommand(summary, error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    // Reads both files, and runs the list if this session hasn't yet. Run
    // at the start, whenever a file changes on disk, and after the page's
    // changes.
    function load() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Startup.loadStartup(sharedText, localText);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        const editable = Startup.editableStartup(sharedText, localText);
        if (!editable.error) {
            root.listed = editable.commands;
        }
        // An unreadable file, or one that doesn't parse, says nothing of
        // which list is meant, so nothing runs until it's fixed.
        if (broken.length > 0 || result.commands === null) {
            root.report();
            return;
        }
        root.commands = result.commands;
        root.report();
        root.runOnce();
    }

    // Runs the list, unless the record says this graphical session already
    // has. The session's ID is read first, once per shell: a list that
    // can't load yet asks again when it does.
    function runOnce() {
        if (root.ran || root.asking) {
            return;
        }
        root.asking = true;
        session.createObject(root).running = true;
    }

    function sessionRead(output, errors) {
        root.asking = false;
        const id = Startup.sessionId(output);
        if (id === "") {
            console.warn(`tide: ${Startup.SESSION_COMMAND.join(" ")} gave no ID: ${(output + errors).trim() || "nothing"}`);
        }
        let recordedText = null;
        if (root.runtimeDir !== "") {
            recordedText = recorded.readNow();
            if (recorded.broken !== "") {
                console.warn(`tide: ${recorded.broken}; taking it for no record of Start at login`);
            }
        } else {
            console.warn("tide: no XDG_RUNTIME_DIR, so Start at login's commands run again if the shell restarts");
        }
        const due = Startup.startupDue(recordedText, id);
        if (due.warn !== "") {
            console.warn(`tide: ${due.warn}`);
        }
        root.ran = true;
        if (!due.run) {
            return;
        }
        if (root.runtimeDir !== "") {
            const error = recorded.writeNow(due.record);
            if (error !== "") {
                console.warn(`tide: ${error}; Start at login's commands run again if the shell restarts`);
            }
        }
        root.queued(Startup.startQueue(root.commands));
    }

    // Starts what the queue says to: each command once the one before it
    // has started (Startup.STARTED) or ended, so they start in order.
    function queued(r) {
        root.queue = r.state;
        if (r.start !== null) {
            starter.createObject(root, { name: r.start.command, index: r.start.index, command: Startup.launchCommand(r.start.command) }).running = true;
        }
    }

    function failed(name, ok, errors) {
        const failure = Startup.runFailure(name, ok, errors);
        if (failure !== "") {
            root.runFailures = root.runFailures.concat([failure]);
            root.report();
        }
    }

    // One command, as Launcher runs one (shell/lib/launch.mjs), which also
    // says when it has started.
    Component {
        id: starter

        Process {
            id: start

            property string name
            property int index
            property var tracker: null

            function handle(event) {
                if (tracker.on(event)) {
                    root.queued(Startup.queueEnded(root.queue, start.index));
                    destroy();
                }
            }

            Component.onCompleted: tracker = Run.track(command, (ok, errors) => root.failed(start.name, ok, errors), {
                warn: m => console.warn(m),
                log: m => console.log(m)
            })
            stdout: SplitParser {
                onRead: line => root.queued(Startup.queuePrinted(root.queue, start.index, line))
            }
            stderr: StdioCollector {
                onStreamFinished: start.handle({ type: "stderr", text: text })
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

    // Reads the graphical session's ID, which tells this login from the
    // last (Startup.SESSION_COMMAND).
    Component {
        id: session

        Process {
            id: run

            property string output: ""
            property bool outputRead: false
            property string errors: ""
            property bool errorsRead: false
            property bool started: false
            property bool done: false

            // Once both streams are in, or it couldn't start, which reads
            // neither (shell/lib/launch.mjs).
            function finish() {
                if (done || !(outputRead && errorsRead) && (running || started)) {
                    return;
                }
                done = true;
                root.sessionRead(output, errors);
                destroy();
            }

            command: Startup.SESSION_COMMAND
            stdout: StdioCollector {
                onStreamFinished: {
                    run.output = text;
                    run.outputRead = true;
                    run.finish();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    run.errors = text;
                    run.errorsRead = true;
                    run.finish();
                }
            }
            onStarted: started = true
            onRunningChanged: {
                if (!running) {
                    finish();
                }
            }
        }
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/startup.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/startup.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // This session's record that the list has run.
    SettingsFile {
        id: recorded

        path: root.runtimeDir === "" ? "" : `${root.runtimeDir}/${Startup.RECORD}`
    }

    Timer {
        id: resend

        interval: 30 * 1000
        onTriggered: {
            const r = Report.retry(root.reports);
            root.reports = r.state;
            root.send(r.send);
        }
    }
}
