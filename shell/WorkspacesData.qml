pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/dispatch.mjs" as Dispatch
import "lib/launch.mjs" as Run
import "lib/report.mjs" as Report
import "lib/workspacenames.mjs" as Names
import "lib/workspaces.mjs" as Ws
import "lib/writes.mjs" as Writes

// The Workspaces settings (SPEC.md §6.5, §16), from workspaces.json and
// workspaces.local.json (§16.1): the standing workspaces, the first of them
// home, and the apps that live on home. What conf's Hyprland config needs
// of them, home's name and the classes its window rules send there, is
// written to ~/.config/hypr/tide-workspaces.lua, which hyprland.lua reads
// as it loads, and `hyprctl eval conf_workspaces.reload()` has it read
// again, as the shell starts too. A bad file is a notification naming it,
// once, and the last good settings stay; one that can't be written or
// applied is tried again until it is (shell/lib/writes.mjs).
//
// It also keeps home's name: a rename from elsewhere (`hyprctl`) is
// undone as it's heard.
Singleton {
    id: root

    // The settings in effect, defaults until the files are read.
    property var settings: Names.DEFAULT_SETTINGS
    readonly property var standing: root.settings.standing
    readonly property string home: Names.homeName(root.settings)
    // Home's workspace ID while it exists, else null (Ws.homeIdAfter).
    // It's kept from the list Hyprland gives too, since a shell started
    // after home was made never hears it made; a rename leaves it, so the
    // rename can be undone.
    property var homeId: null
    readonly property var listedHome: Hyprland.workspaces.values.find(w => w.name === root.home)?.id ?? null

    onListedHomeChanged: {
        if (root.listedHome !== null) {
            root.homeId = root.listedHome;
        }
    }

    property var reports: Report.NOTHING
    property var fileErrors: []
    property var target: Writes.TARGET

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    readonly property string dir: `${root.configHome}/tide`

    function stepped(r) {
        root.target = r.state;
        if (r.action?.write !== undefined) {
            const error = written.writeNow(r.action.write);
            root.stepped(Writes.targetWritten(root.target, error === "" ? "" : `${error}; home and its apps' rules stay as they were`));
            return;
        }
        if (r.action?.apply) {
            applier.createObject(root).running = true;
        }
        root.report();
    }

    function report() {
        const failures = [root.target.failure].filter(f => f !== "");
        const errors = root.fileErrors.concat(failures);
        const v = Report.verdict(root.reports, errors);
        root.reports = v.state;
        root.send(v.send);
        if (failures.length > 0 && !retry.running) {
            retry.start();
        }
    }

    function send(errors) {
        for (const error of errors) {
            Launcher.run(Report.notifyCommand("Workspace settings not applied", error), ok => {
                root.reports = Report.sent(root.reports, error, ok);
                if (!ok) {
                    resend.restart();
                }
            });
        }
    }

    // Reads both settings files and the file hyprland.lua reads, and
    // writes and applies the settings when they've changed.
    function load() {
        const sharedText = shared.readNow();
        const localText = local.readNow();
        const broken = [shared.broken, local.broken].filter(b => b !== "");
        const result = Names.loadWorkspaceSettings(sharedText, localText, root.settings);
        for (const error of result.errors) {
            console.warn(`tide: ${error}`);
        }
        root.fileErrors = broken.concat(result.errors);
        if (root.fileErrors.length > 0) {
            root.report();
            return;
        }
        if (Names.homeName(result.settings) !== root.home) {
            // Another home: the old one's ID no longer says where it is.
            root.homeId = null;
        }
        root.settings = result.settings;
        if (root.listedHome !== null) {
            root.homeId = root.listedHome;
        }
        const writtenText = written.readNow();
        if (written.broken !== "") {
            root.stepped(Writes.targetUnreadable(root.target, `${written.broken}; home and its apps' rules stay as they were`));
            return;
        }
        // Hyprland outlives the shell, and a shell that died with an apply
        // still to retry left it with the old home and rules, so the first
        // read applies what's wanted, as InputData does: reloading the same
        // rules again changes nothing.
        root.target = Writes.readTarget(root.target, writtenText, null).state;
        root.stepped(Writes.wantTarget(root.target, Names.workspacesLua(root.settings)));
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            const ws = Ws.workspaceEvent(event.name, event.data);
            if (ws === null) {
                return;
            }
            if (Ws.homeRenamed(root.homeId, ws, root.home)) {
                console.log(`tide: workspace ${root.home} was renamed ${ws.name}; naming it ${root.home} again`);
                Hyprland.dispatch(Dispatch.renameWorkspace(ws.id, root.home, Hyprland.usingLua));
            }
            root.homeId = Ws.homeIdAfter(root.homeId, ws, root.home);
        }
    }

    SettingsFile {
        id: shared

        path: `${root.dir}/workspaces.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    SettingsFile {
        id: local

        path: `${root.dir}/workspaces.local.json`
        watchChanges: true
        onFileChanged: root.load()
    }

    // What hyprland.lua reads. Written only when it would say something
    // else.
    SettingsFile {
        id: written

        path: `${root.configHome}/hypr/tide-workspaces.lua`
    }

    // Has hyprland.lua take what was written: `hyprctl eval` answers "ok",
    // or why not, on stdout.
    Component {
        id: applier

        Process {
            id: run

            property var state: Run.initial()
            property string reply: ""
            property bool replyRead: false
            property string errors: ""
            property bool errorsRead: false

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
                let error = "";
                if (!state.started) {
                    console.warn(state.report.message);
                    error = state.report.message.replace(/^tide: /, "");
                } else if (state.code !== 0 || reply.trim() !== "ok") {
                    // A conf from before named workspaces has no
                    // conf_workspaces.
                    error = `couldn't apply the workspace settings: ${(reply + state.errors).trim()}`;
                    console.warn(`tide: ${error}`);
                } else if (state.report?.level === "log") {
                    console.log(state.report.message);
                }
                root.stepped(Writes.targetApplied(root.target, error));
                destroy();
            }

            command: ["hyprctl", "eval", "conf_workspaces.reload()"]
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

    Timer {
        id: retry

        interval: 30 * 1000
        onTriggered: root.load()
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
