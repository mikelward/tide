pragma Singleton

import QtQuick
import Quickshell
import Quickshell.I3
import Quickshell.Io
import "lib/configerrors.mjs" as Errors

// tidewm's config errors (SPEC.md §7.4): GET_CONFIG's `errors`, asked of
// `tide-msg` each time the listener connects, when a key reloads the
// config, and after each reload the shell asks for itself (reloaded());
// the bar's warning shows them, and one notification says they're there
// (lib/configerrors.mjs). `tide reload` says when it has reloaded (the
// `configerrors` IPC target); a reload from anywhere else, as `tide-msg
// reload` in a terminal, isn't heard: tidewm has no event for it. In
// Hyprland's session it listens to nothing and asks nothing.
Singleton {
    id: root

    readonly property bool listening: Compositor.tidewm
    // The last load's errors, and what's been said of them (Errors.loaded).
    property var state: Errors.NOTHING
    // The errors, as tidewm worded them: none in Hyprland's session.
    readonly property var errors: state.errors
    readonly property string home: Quickshell.env("HOME") ?? ""
    // Asked again while asking: the config was reloaded meanwhile.
    property bool again: false

    // Names the singleton, so it's made as the shell starts (shell.qml).
    function load() {
    }

    // The shell had tidewm reload its config, whether or not it worked: a
    // reload that fails is one with errors.
    function reloaded() {
        if (root.listening) {
            root.ask();
        }
    }

    // `qs -c tide ipc call configerrors reloaded`, from `tide reload`
    // (Super+Ctrl+R), which reloads tidewm's config with tide-msg, a reload
    // the listener doesn't hear.
    IpcHandler {
        target: "configerrors"

        function reloaded(): void {
            root.reloaded();
        }
    }

    function ask() {
        if (config.running) {
            root.again = true;
            return;
        }
        config.replied = false;
        config.running = true;
    }

    // The set told of survives a shell reload, so a reload isn't news.
    PersistentProperties {
        id: kept

        reloadableId: "tide-config-errors"

        property string told: ""

        onLoaded: {
            if (kept.told !== "" && root.state.told === "") {
                root.state = Errors.sent(root.state, kept.told, true);
            }
        }
    }

    function took(next) {
        root.state = next.state;
        if (next.notify) {
            root.notify();
        }
        if (Errors.pending(root.state)) {
            resend.start();
        }
    }

    function notify() {
        const errors = root.state.errors;
        const key = Errors.keyOf(errors);
        Launcher.run(Errors.notifyCommand(errors), ok => {
            if (!ok) {
                console.warn("tide: couldn't say that tidewm's config has errors; trying again in 30 s");
            }
            root.state = Errors.sent(root.state, key, ok);
            if (ok) {
                kept.told = key;
            }
            if (Errors.pending(root.state)) {
                resend.start();
            }
        });
    }

    function read(text) {
        const reply = Errors.replyErrors(text);
        if (reply.errors === undefined) {
            console.warn(`tide: couldn't read tidewm's config errors (${reply.why}); the bar shows none`);
            root.state = Errors.unreadable(root.state);
            return;
        }
        if (reply.errors.length === 0) {
            kept.told = "";
        }
        root.took(Errors.loaded(root.state, reply.errors));
    }

    I3IpcListener {
        // Subscribing sends a tick at once, so a tick with `first` is the
        // listener connected, again or for the first time. A binding says
        // a key's commands are about to run (Errors.asksForErrors).
        subscriptions: root.listening ? ["tick", "binding"] : []

        onIpcEvent: event => {
            if (Errors.asksForErrors(event.type, event.data)) {
                root.ask();
            }
        }
    }

    Process {
        id: config

        // Whether this run's reply has been read.
        property bool replied: false
        property string errors: ""

        function reply(text) {
            config.replied = true;
            // With a reload since it was asked, what it says may be older
            // than the reload, and it's asked again below.
            if (!root.again) {
                root.read(text);
            }
        }

        command: ["tide-msg", "--type", "get_config"]
        stdout: StdioCollector {
            onStreamFinished: config.reply(text)
        }
        stderr: StdioCollector {
            onStreamFinished: config.errors = text
        }
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: tide-msg --type get_config exited ${code}: ${config.errors.trim()}`);
            }
        }
        onRunningChanged: {
            if (running) {
                return;
            }
            Qt.callLater(() => {
                if (config.running) {
                    return;
                }
                // A tide-msg that couldn't start leaves no reply to read,
                // which read() says.
                if (!config.replied) {
                    config.reply("");
                }
                if (root.again) {
                    root.again = false;
                    root.ask();
                }
            });
        }
    }

    // The notification counts as sent only once notify-send delivers it;
    // one that fails (at login, before the notification server is up) is
    // sent again, for as long as the errors last.
    Timer {
        id: resend

        interval: 30 * 1000
        onTriggered: root.took(Errors.retry(root.state))
    }
}
