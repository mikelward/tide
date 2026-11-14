pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import Quickshell.Io
import "lib/configerrors.mjs" as Errors

// The compositor's config errors (SPEC.md §7.4); the bar's warning shows
// them, and one notification says they're there (lib/configerrors.mjs).
// - tidewm: GET_CONFIG's `errors`, asked of `tide-msg` each time the
//   listener connects, when a key reloads the config, on tidewm's reload
//   event (a `workspace` event, `reload`, from any reload), and after each
//   reload the shell asks for itself (reloaded()). Each time it asks
//   `tide-msg --outdated` too, whether the tidewm running is the one
//   installed: after a setup run that built a newer one, the warning says
//   to log out and back in, and nothing of tide's reloads the config.
// - Hyprland: `hyprctl configerrors`, asked as the shell starts and on
//   each `configreloaded` event. tide's Hyprland config hides Hyprland's
//   own banner in the tide session, so this is where they show.
Singleton {
    id: root

    readonly property bool listening: true
    readonly property string compositorName: Errors.compositorName(Compositor.tidewm)
    // The last load's errors, and what's been said of them (Errors.loaded).
    property var state: Errors.NOTHING
    // The errors, as tidewm worded them: none in Hyprland's session.
    readonly property var errors: state.errors
    // The tidewm running isn't the one installed: it was updated.
    readonly property bool outdated: state.outdated
    // Whether the bar's warning shows: errors, or an update.
    readonly property bool warns: Errors.warns(state)
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
    // (Super+Shift+R), which reloads tidewm's config with tide-msg, a reload
    // the listener doesn't hear.
    IpcHandler {
        target: "configerrors"

        function reloaded(): void {
            root.reloaded();
        }
    }

    function ask() {
        // One in flight answers for now too: what's installed rarely changes.
        if (Compositor.tidewm && !version.running) {
            version.running = true;
        }
        if (config.running) {
            root.again = true;
            return;
        }
        config.started = false;
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
        const outdated = root.state.outdated;
        const key = Errors.newsOf(root.state);
        Launcher.run(Errors.notifyCommand(errors, root.compositorName, outdated), ok => {
            if (!ok) {
                console.warn(`tide: couldn't say that ${Errors.summary(errors, root.compositorName, outdated)}; trying again in 30 s`);
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

    function read(text, ok) {
        const reply = Compositor.tidewm ? Errors.replyErrors(text) : Errors.hyprlandErrors(text, ok);
        if (reply.errors === undefined) {
            console.warn(`tide: couldn't read ${root.compositorName}'s config errors (${reply.why}); the bar shows none`);
            root.state = Errors.unreadable(root.state);
            return;
        }
        // A load with none forgets the errors told of, not an update.
        if (reply.errors.length === 0 && kept.told !== Errors.OUTDATED) {
            kept.told = "";
        }
        root.took(Errors.loaded(root.state, reply.errors));
    }

    I3IpcListener {
        // Subscribing sends a tick at once, so a tick with `first` is the
        // listener connected, again or for the first time. A binding says
        // a key's commands are about to run (Errors.asksForErrors).
        subscriptions: Compositor.tidewm ? ["tick", "binding", "workspace"] : []

        onIpcEvent: event => {
            if (Errors.asksForErrors(event.type, event.data)) {
                root.ask();
            }
        }
    }

    // Hyprland: each reload, from anywhere, and the errors as the shell
    // starts.
    Connections {
        target: Compositor.tidewm ? null : Hyprland

        function onRawEvent(event) {
            if (event.name === "configreloaded") {
                root.ask();
            }
        }
    }

    Component.onCompleted: {
        if (!Compositor.tidewm) {
            root.ask();
        }
    }

    Process {
        id: config

        // This run's output and exit status, read together once it has
        // ended: Quickshell finishes stdout before it says how the run
        // exited, so the output alone can't say whether it failed.
        property bool started: false
        property string out: ""
        property string errors: ""
        property int code: 0

        function reply(text, ok) {
            // With a reload since it was asked, what it says may be older
            // than the reload, and it's asked again below.
            if (!root.again) {
                root.read(text, ok);
            }
        }

        command: Compositor.tidewm ? ["tide-msg", "--type", "get_config"] : ["hyprctl", "configerrors"]
        stdout: StdioCollector {
            onStreamFinished: config.out = text
        }
        stderr: StdioCollector {
            onStreamFinished: config.errors = text
        }
        onStarted: {
            config.started = true;
            config.out = "";
            config.code = 0;
        }
        onExited: (code, status) => {
            config.code = code;
            if (code !== 0) {
                console.warn(`tide: ${config.command.join(" ")} exited ${code}: ${config.errors.trim()}`);
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
                // One that couldn't start has no reply to read, which
                // read() says, as it does for one that failed.
                config.reply(config.started ? config.out : "", config.started && config.code === 0);
                if (root.again) {
                    root.again = false;
                    root.ask();
                }
            });
        }
    }

    // Whether the tidewm running is the one installed, by its exit status
    // (Errors.outdatedOf). One that doesn't say, as a tide-msg from before
    // --outdated while a setup run is still installing, leaves what was
    // known. One that can't start says nothing here: `config` reports the
    // same tide-msg.
    Process {
        id: version

        property string errors: ""

        command: ["tide-msg", "--outdated"]
        stderr: StdioCollector {
            onStreamFinished: version.errors = text
        }
        onExited: (code, status) => {
            const outdated = Errors.outdatedOf(code);
            if (outdated === undefined) {
                // stderr may end after the exit.
                Qt.callLater(() => console.warn(`tide: tide-msg --outdated exited ${code}, so the bar doesn't say whether tidewm was updated: ${version.errors.trim()}`));
                root.took(Errors.unversioned(root.state));
                return;
            }
            // One that's over is forgotten, as fixed errors are.
            if (!outdated && kept.told === Errors.OUTDATED) {
                kept.told = "";
            }
            root.took(Errors.versioned(root.state, outdated));
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
