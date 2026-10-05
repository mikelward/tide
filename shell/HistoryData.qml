pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/history.mjs" as History
import "lib/notifications.mjs" as Notes

// The notification center's history (SPEC.md §9), kept in
// $XDG_STATE_HOME/tide/notifications.json so it survives a shell
// restart, and which monitor the center is open on, if any.
Singleton {
    id: root

    // {entries, unread} (shell/lib/history.mjs): entries newest first, and
    // the keys of those that arrived since the center was last open.
    property var history: ({
            entries: [],
            unread: []
        })
    readonly property var entries: root.history.entries
    // The monitor the center is open on, or "" while it's closed.
    property string openOn: ""
    // "unread" until the file has been read, then "saved", or "memory" when
    // it couldn't be. The read blocks, and comes before any change, so there
    // is never a change to a history that hasn't loaded: nothing to queue
    // while it loads, or to lose if the config reloads meanwhile. The file
    // is at most 200 short entries.
    property string store: "unread"

    readonly property bool unread: History.unread(root.history)
    readonly property string dir: (Quickshell.env("XDG_STATE_HOME") || `${Quickshell.env("HOME")}/.local/state`) + "/tide"
    // Notification ids start again with each shell process, so keys carry
    // its start. A config reload keeps the server and its ids, and carries
    // live notifications over, so the start is kept across reloads too, and
    // a carried-over notification keeps its key.
    PersistentProperties {
        id: process

        reloadableId: "tide-history"

        property real startedAt: Date.now()
    }

    function keyOf(id) {
        return `${process.startedAt}-${id}`;
    }

    function load() {
        if (root.store === "unread" && file.path !== "") {
            // Blocks until onLoaded or onLoadFailed has run.
            file.text();
        }
    }

    Component.onCompleted: root.load()

    function change(c) {
        root.load();
        root.history = History.apply(root.history, c);
        root.save();
    }

    // A notification arrived, or was updated in place; `replacedId` is the
    // id of one it took the place of. One carried over a config reload is
    // recorded only if the history hasn't got it (shell/lib/history.mjs).
    function record(notification, replacedId, carried) {
        root.change({
            op: "record",
            carried: carried === true,
            item: {
                key: root.keyOf(notification.id),
                app: notification.appName,
                icon: notification.appIcon,
                entry: notification.desktopEntry,
                origin: Notes.originText(notification),
                summary: notification.summary,
                body: notification.body,
                critical: notification.urgency === NotificationData.urgency.Critical,
                transient: notification.transient,
                replaces: replacedId === undefined ? undefined : root.keyOf(replacedId),
            },
            time: Date.now(),
        });
    }

    function clearAll() {
        root.change({
            op: "clearAll"
        });
    }

    function clearApp(app) {
        root.change({
            op: "clearApp",
            app: app
        });
    }

    function openAt(monitor) {
        root.openOn = monitor;
        root.change({
            op: "seen"
        });
    }

    function close() {
        if (root.openOn !== "") {
            root.openOn = "";
            // What arrived while it was open has been seen too.
            root.change({
                op: "seen"
            });
        }
    }

    function toggleAt(monitor) {
        if (root.openOn === monitor) {
            root.close();
        } else {
            root.openAt(monitor);
        }
    }

    // A burst of notifications, or of one's property updates, is one write:
    // Qt.callLater runs it once, when the current batch of events is done.
    // It blocks for that small write rather than running later, so a shell
    // that restarts right after a change doesn't lose it.
    function save() {
        if (root.store === "saved") {
            Qt.callLater(root.flush);
        }
    }

    function flush() {
        file.setText(History.serialize(root.history));
    }

    FileView {
        id: file

        // The bell's dot binds to this singleton whether or not the shell
        // is the notification server, so the file is opened only when it is.
        path: NotificationData.enabled ? `${root.dir}/notifications.json` : ""
        printErrors: false
        // Read only when root.load() asks, and then before returning.
        preload: false
        blockLoading: true
        atomicWrites: true
        blockWrites: true
        onLoaded: {
            const result = History.parse(text());
            for (const error of result.errors) {
                console.warn(`tide: ${path}: ${error}`);
            }
            root.history = {
                entries: result.entries,
                unread: result.unread
            };
            root.store = "saved";
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) {
                // Writing would replace a history we couldn't read, so this
                // shell keeps its history in memory only.
                console.warn(`tide: ${path}: ${FileViewError.toString(error)}; notification history won't be saved`);
                root.store = "memory";
                return;
            }
            // No file yet: the first change writes one.
            root.store = "saved";
        }
        onSaveFailed: error => console.warn(`tide: ${path}: ${FileViewError.toString(error)}; notification history not saved`)
    }

    // `qs -c tide ipc call notifications toggle`, from Super+Shift+N,
    // opens it on the focused monitor. Only while the shell is the
    // notification server, so the call fails and the binding can fall back
    // to swaync's panel otherwise.
    IpcHandler {
        target: "notifications"
        enabled: NotificationData.enabled

        // Do not disturb, for a key or the launcher: `dnd` toggles it,
        // `setDnd true|false` sets it.
        function dnd(): void {
            NotificationData.setDnd(!NotificationData.dnd);
        }

        function setDnd(on: bool): void {
            NotificationData.setDnd(on);
        }

        function toggle(): void {
            const monitor = Hyprland.focusedMonitor?.name ?? "";
            if (monitor === "") {
                root.close();
            } else {
                root.toggleAt(monitor);
            }
        }
    }
}
