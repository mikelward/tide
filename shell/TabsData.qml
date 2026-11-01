pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/tabs.mjs" as Tabs
import "lib/polkit.mjs" as Polkit

// The browsers' tabs for the switcher's Windows tab (SPEC.md §8.3), on
// unless TIDE_TABS=0. It starts `tide-tabs serve`, the relay each browser's
// host connects to, and talks to it over its stdin and stdout as
// AgentData.qml does tide-agent. The tide connector or tileco, in the browser, sends the tabs;
// this keeps each browser's latest list and asks for a tab on Enter.
Singleton {
    id: root

    readonly property bool enabled: Quickshell.env("TIDE_TABS") !== "0"
    // {source: {browser, windows}}, from Tabs.applied.
    property var browsers: ({})
    property bool started: false
    readonly property bool running: helper.running && root.started
    property int attempt: 0

    function activate(item) {
        if (!root.running) {
            console.warn(`tide: tide-tabs isn't running, so tab "${item.name}" can't be brought up`);
            return;
        }
        helper.write(Tabs.activateLine(item) + "\n");
    }

    function stopped(code) {
        root.started = false;
        root.browsers = ({});
        if (!root.enabled) {
            return;
        }
        const wait = Polkit.retrySeconds(root.attempt);
        console.warn(`tide: tide-tabs stopped (${code === null ? "it couldn't start: is it installed?" : `exit ${code}`}), so the switcher lists no browser tabs; starting it again in ${wait} s`);
        restart.interval = wait * 1000;
        root.attempt += 1;
        restart.start();
    }

    Process {
        id: helper

        command: [Quickshell.env("TIDE_TABS_COMMAND") || "tide-tabs", "serve"]
        stdinEnabled: true
        running: root.enabled

        stdout: SplitParser {
            onRead: data => {
                const r = Tabs.parseLine(data);
                if (r.error) {
                    console.warn(`tide: ${r.error}`);
                    return;
                }
                if (r.message.type === "ready") {
                    root.attempt = 0;
                } else if (r.message.type === "fault") {
                    console.warn(`tide: tide-tabs: ${r.message.message}`);
                }
                root.browsers = Tabs.applied(root.browsers, r.message);
            }
        }
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
}
