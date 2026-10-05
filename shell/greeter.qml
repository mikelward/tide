// Qt picks an icon theme only for a desktop it knows, and the greeter runs
// in none: without this, no theme icon loads, so symbolic icons are blank.
// Quickshell reads pragmas only above the first import (SPEC.md §15).
//@ pragma IconTheme Adwaita
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd
import Quickshell.Wayland
import "lib/greeter.mjs" as Greeter
import "lib/lock.mjs" as Lock

// The tide greeter (SPEC.md §11): the lock's face (LockFace.qml) in its
// login mode, on every monitor, logging in through greetd. greetd runs
// `tide-greeter`, which runs Hyprland with greeter/hyprland.lua, which runs
// this as `qs -p .../greeter.qml`. Once greetd has the session to start,
// Quickshell exits, Hyprland exits after it, and greetd starts the session.
//
// The password goes through the lock's state machine (shell/lib/lock.mjs),
// with greetd in PAM's place: Enter opens a greetd session for the chosen
// user, greetd's prompts take the field, and its verdict ends the attempt.
ShellRoot {
    id: root

    property var face: Lock.INITIAL

    // The choices: the people who can log in (getent passwd, within
    // login.defs' range), the sessions (LISTING_SCRIPT) and what was
    // chosen last time. Each is picked once all four are read, unless
    // someone picked first.
    property string passwd: ""
    property string loginDefs: ""
    readonly property var users: Greeter.parseUsers(root.passwd, Greeter.uidRange(root.loginDefs))
    property var sessions: []
    property var remembered: ({ user: "", session: "" })
    property int pending: 4
    property bool userChosen: false
    property bool sessionChosen: false
    property string user: ""
    property string session: ""
    readonly property var chosen: root.sessions.find(s => s.id === root.session) ?? null
    readonly property string userLabel: root.users.find(u => u.name === root.user)?.label ?? root.user

    property string hostnameText: ""
    readonly property string hostname: Lock.shortHostname(root.hostnameText, root.user)

    // Where the last login is remembered: the greeter user's state
    // directory, which greetd's greeter session has as its home.
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`) + "/tide-greeter"

    // An Enter pressed before they're all read waits for them.
    property bool startWhenRead: false

    function read() {
        root.pending -= 1;
        // Picked once: a file read again later changes nothing.
        if (root.pending !== 0) {
            return;
        }
        if (!root.userChosen) {
            root.user = Greeter.pickUser(root.users, root.remembered.user);
        }
        if (!root.sessionChosen) {
            root.session = Greeter.pickSession(root.sessions, root.remembered.session);
        }
        if (root.startWhenRead) {
            root.startWhenRead = false;
            root.start();
        }
    }

    // Every key and greetd event goes through here, so the field changes on
    // the frame the key is pressed and nothing waits on greetd to draw.
    function dispatch(event) {
        if (!Greeter.takes(root.face, event)) {
            return;
        }
        if (event.type === "done" && event.result !== "success") {
            keymap.refresh();
        }
        const r = Lock.next(root.face, event);
        root.face = r.state;
        for (const action of r.actions) {
            if (action.type === "start") {
                // Later, not now: start can report a failure through
                // dispatch, which mustn't run inside this one.
                Qt.callLater(root.start);
            } else if (action.type === "respond") {
                Greetd.respond(action.text);
            }
        }
    }

    function start() {
        if (root.pending > 0) {
            root.startWhenRead = true;
        } else if (!Greetd.available) {
            root.dispatch({ type: "failed", detail: "greetd isn't running" });
        } else if (root.user === "") {
            root.dispatch({ type: "failed", detail: "no user to log in as" });
        } else {
            Greetd.createSession(root.user);
        }
    }

    // The password was taken: remember the choice, then hand greetd the
    // session. The write blocks, since Quickshell exits once greetd has it.
    function launch() {
        const session = root.chosen;
        if (session === null) {
            Greetd.cancelSession();
            root.face = Greeter.greetdError(root.face, "no session to start", "");
            return;
        }
        remember.setText(Greeter.serializeRemembered(root.user, session.id));
        Greetd.launch([session.command], session.env);
    }

    // Another user: whatever greetd was doing for the last one stops, and
    // the field starts over. Not while a login is under way
    // (Greeter.canPickUser), which the face shows by disabling the picker.
    function pickUser(name) {
        if (!Greeter.canPickUser(root.face)) {
            return;
        }
        root.userChosen = true;
        if (name === root.user) {
            return;
        }
        if (Greetd.state !== GreetdState.Inactive) {
            Greetd.cancelSession();
        }
        root.user = name;
        root.face = Lock.INITIAL;
    }

    function pickSession(id) {
        root.sessionChosen = true;
        root.session = id;
    }

    Connections {
        target: Greetd

        // Quickshell sets echoResponse on any message but a secret prompt,
        // so it counts only for a prompt.
        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (Greeter.inConversation(root.face)) {
                root.dispatch({
                    type: "pam",
                    text: message,
                    isError: error,
                    responseRequired: responseRequired,
                    echo: responseRequired && echoResponse,
                });
            }
        }
        function onAuthFailure(message) {
            if (Greeter.inConversation(root.face)) {
                root.dispatch(Greeter.authFailureEvent(message));
            }
        }
        function onReadyToLaunch() {
            if (!Greeter.inConversation(root.face)) {
                // A login for a user since replaced: drop it.
                Greetd.cancelSession();
                return;
            }
            root.dispatch({ type: "done", result: "success" });
            root.launch();
        }
        function onError(error) {
            console.warn(`tide-greeter: greetd: ${error}`);
            root.face = Greeter.greetdError(root.face, error, root.chosen?.name ?? "");
        }
    }

    // Restart and Shut down (LockPower.qml).
    LockPower {
        id: powerActions
    }

    // The keyboard's layout, for the badge by the field (LockKeymap.qml).
    LockKeymap {
        id: keymap
        name: "tide-greeter"
    }

    // A read's output counts once its stream ends, which a started command
    // always reaches. Quickshell reports a command that can't start only by
    // stopping without `started` (shell/lib/launch.mjs), and that read is
    // over too, with nothing.
    Process {
        property bool started: false

        command: ["getent", "passwd"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: {
                root.passwd = text;
                root.read();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "") {
                    console.warn(`tide-greeter: getent passwd: ${text.trim()}`);
                }
            }
        }
        onStarted: started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide-greeter: getent passwd exited ${code}`);
            }
        }
        onRunningChanged: {
            if (!running && !started) {
                console.warn("tide-greeter: couldn't start getent; no users to pick");
                root.read();
            }
        }
    }

    // UID_MIN and UID_MAX; without the file, login.defs' own defaults.
    FileView {
        path: "/etc/login.defs"
        printErrors: false
        onLoaded: {
            root.loginDefs = text();
            root.read();
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) {
                console.warn(`tide-greeter: ${path}: ${FileViewError.toString(error)}; the users are UIDs 1000 to 60000`);
            }
            root.read();
        }
    }

    Process {
        property bool started: false

        command: ["sh", "-c", Greeter.LISTING_SCRIPT]
        running: true

        stdout: StdioCollector {
            onStreamFinished: {
                root.sessions = Greeter.sessionList(Greeter.parseListing(text));
                root.read();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "") {
                    console.warn(`tide-greeter: reading the sessions: ${text.trim()}`);
                }
            }
        }
        onStarted: started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide-greeter: reading the sessions exited ${code}`);
            }
        }
        onRunningChanged: {
            if (!running && !started) {
                console.warn("tide-greeter: couldn't start sh to read the sessions; only the shell is offered");
                root.sessions = Greeter.sessionList([]);
                root.read();
            }
        }
    }

    FileView {
        id: remember

        path: `${root.stateDir}/last.json`
        printErrors: false
        atomicWrites: true
        blockWrites: true
        onLoaded: {
            root.remembered = Greeter.parseRemembered(text());
            root.read();
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) {
                console.warn(`tide-greeter: ${path}: ${FileViewError.toString(error)}; nothing is preselected`);
            }
            root.read();
        }
        onSaveFailed: error => console.warn(`tide-greeter: ${path}: ${FileViewError.toString(error)}; this login won't be preselected next time`)
    }

    // The kernel's hostname, read once; the face shows the short form.
    FileView {
        path: "/proc/sys/kernel/hostname"
        onLoaded: root.hostnameText = text()
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData

            screen: modelData
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "tide-greeter"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            color: "#000000"

            LockFace {
                anchors.fill: parent
                mode: "login"
                lockState: root.face
                hostname: root.hostname
                user: root.userLabel
                status: Greeter.statusText(root.face, root.chosen?.name ?? "", Lock.statusText(root.face))
                powerMessage: powerActions.message
                powerBusy: powerActions.busy
                layout: keymap.badge
                users: root.users
                userName: root.user
                userPickable: Greeter.canPickUser(root.face)
                sessions: root.sessions
                sessionId: root.session
                onEvent: event => root.dispatch(event)
                onPower: id => powerActions.press(id)
                onPickUser: name => root.pickUser(name)
                onPickSession: id => root.pickSession(id)
            }
        }
    }
}
