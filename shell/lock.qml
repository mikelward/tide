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
            onEvent: event => root.dispatch(event)
        }
    }

    // The kernel's hostname, read once; the face shows the short form.
    FileView {
        path: "/proc/sys/kernel/hostname"
        onLoaded: root.hostname = Lock.shortHostname(text(), root.user)
    }
}
