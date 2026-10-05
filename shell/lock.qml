import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import "lib/lock.mjs" as Lock

// tide-lock (SPEC.md §10): the session lock, a Quickshell process of its own,
// run by tide-lock.service as `qs -p .../tide/lock.qml` with the file watcher
// off. It locks every output at start and exits once PAM (service
// "tide-lock") accepts the password; exiting any other way leaves the
// session locked, which is what ext-session-lock is for.
ShellRoot {
    id: root

    // The password face's state (shell/lib/lock.mjs).
    property var face: Lock.INITIAL
    readonly property string user: Quickshell.env("USER") || ""
    readonly property date lockedAt: new Date()
    property string hostname: ""

    // The zone clocks come from the bar's ClockData, which this process
    // runs its own copy of; the bar is the one that reports a bad clocks
    // file. Set before its files load, which is asynchronous.
    Component.onCompleted: ClockData.quiet = true

    // Every key and PAM event goes through here, so the field changes on
    // the frame the key is pressed and nothing waits on PAM to draw.
    function dispatch(event) {
        const r = Lock.next(root.face, event);
        root.face = r.state;
        for (const action of r.actions) {
            if (action.type === "start") {
                // Later, not now: a held Enter starts a new conversation
                // from inside the last one's completed signal.
                Qt.callLater(root.startPam);
            } else if (action.type === "respond") {
                pam.respond(action.text);
            }
        }
        if (root.face.unlocked && lock.locked) {
            lock.locked = false;
        }
    }

    // Suspend, Restart and Shut down from the lock (SPEC.md §10), through
    // logind as the session menu does (shell/lib/session.mjs), but never
    // past an inhibitor: what blocks one is shown, not overridden.
    // One run at a time (Lock.powerNext): the buttons stay busy until the
    // run has its result and its process has stopped, so no signal of one
    // run is taken for the next's.
    property var power: Lock.POWER_IDLE

    function powerEvent(event) {
        const r = Lock.powerNext(root.power, event);
        root.power = r.state;
        if (r.command !== null) {
            powerRunner.command = r.command;
            powerRunner.running = true;
        }
    }

    Process {
        id: powerRunner

        stderr: StdioCollector {
            onStreamFinished: root.powerEvent({ type: "stderr", text: text })
        }
        onStarted: root.powerEvent({ type: "started" })
        onRunningChanged: {
            if (!running) {
                root.powerEvent({ type: "stopped" });
            }
        }
        onExited: (code, status) => root.powerEvent({ type: "exited", code: code })
    }

    function startPam() {
        if (!pam.start()) {
            root.dispatch({ type: "failed", detail: "PAM didn't start" });
        }
    }

    PamContext {
        id: pam

        // Its own service, not "login" (SPEC.md §10); `make install-session`
        // installs it in /etc/pam.d.
        config: "tide-lock"

        onPamMessage: root.dispatch({
            type: "pam",
            text: pam.message,
            isError: pam.messageIsError,
            responseRequired: pam.responseRequired,
        })
        onCompleted: result => root.dispatch({
            type: "done",
            result: result === PamResult.Success ? "success"
                : result === PamResult.MaxTries ? "maxtries"
                : result === PamResult.Failed ? "failed" : "error",
        })
        // A `completed(Error)` follows, which reports it.
        onError: error => console.warn(`tide-lock: PAM failed: ${PamError.toString(error)}`)
    }

    WlSessionLock {
        id: lock

        locked: true

        // Unlocked: the compositor has dropped the lock, so the process's
        // job is done. A clean exit, so systemd doesn't restart it.
        onLockedChanged: {
            if (!locked) {
                Qt.quit();
            }
        }

        LockSurface {
            lockState: root.face
            hostname: root.hostname
            user: root.user
            lockedAt: root.lockedAt
            powerMessage: root.power.message
            powerBusy: Lock.powerBusy(root.power)
            onEvent: event => root.dispatch(event)
            onPower: id => root.powerEvent({ type: "press", id: id })
        }
    }

    // An idle lock opens in the screensaver face (SPEC.md §10). Every lock
    // arrives through logind, so `tide idle-lock`, which hypridle's idle
    // step runs, leaves this flag first: the time it locked. A flag only
    // counts for a few seconds (Lock.idleFlagFresh), so one left by a lock
    // that never happened can't change a later Super+L. Read once, then
    // removed.
    readonly property string idleFlag: `${Quickshell.env("XDG_RUNTIME_DIR")}/tide-lock-idle`

    FileView {
        path: Quickshell.env("XDG_RUNTIME_DIR") ? root.idleFlag : ""
        onLoaded: {
            if (Lock.idleFlagFresh(text(), Date.now())) {
                root.dispatch({ type: "screensaver" });
            }
            removeFlag.running = true;
        }
        // No flag is the usual case: a lock from Super+L, suspend or the lid.
    }

    Process {
        id: removeFlag

        command: ["rm", "-f", "--", root.idleFlag]
        onExited: code => {
            if (code !== 0) {
                console.warn(`tide-lock: couldn't remove ${root.idleFlag} (rm exited ${code})`);
            }
        }
    }

    // The kernel's hostname, read once; the face shows the short form.
    FileView {
        path: "/proc/sys/kernel/hostname"
        onLoaded: root.hostname = Lock.shortHostname(text(), root.user)
    }
}
