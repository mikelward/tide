pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import "lib/history.mjs" as History
import "lib/notifications.mjs" as Notes

// The notification server (SPEC.md §9), its popup queue, and each popup's
// countdown. The countdowns live here rather than in the popups, so there's
// one per notification whichever monitor draws it.
Singleton {
    id: root

    // The notifications with a popup, shown or waiting, oldest first.
    property var queue: []
    // The notifications whose popup has gone (timed out, or held for Do not
    // disturb or a share) but which stay live for the center (Notes.rest),
    // oldest first. A config reload carries them over as live ones, so
    // their ids are kept to tell them from popups: added as one rests and
    // dropped as one leaves, rather than copied from `resting`, which starts
    // empty after a reload while the carried ones are still arriving.
    property var resting: []

    PersistentProperties {
        id: restingState

        reloadableId: "tide-resting"

        property var ids: []
    }

    function setResting(next) {
        const gone = new Set(root.resting.filter(n => !next.includes(n)).map(n => n.id));
        const added = next.filter(n => !root.resting.includes(n)).map(n => n.id);
        restingState.ids = [...restingState.ids.filter(id => !gone.has(id) && !added.includes(id)), ...added];
        root.resting = next;
    }

    // A popup that goes rests rather than closing, and a resting one whose
    // center entry has already gone (a transient one has none) is released.
    function rest(notification) {
        const next = Notes.rest(root.queue, root.resting, notification);
        root.queue = next.queue;
        root.setResting(next.resting);
        root.release();
    }

    // Releases each resting notification the center has let go of
    // (Notes.unkept). Expiring, rather than dismissing, keeps its bar marks,
    // as its popup running out of time did. Closing takes it out of
    // `resting` (onNotification).
    function release() {
        for (const n of Notes.unkept(root.resting, HistoryData.entries.map(e => e.key), HistoryData.keyOf)) {
            n.expire();
        }
    }

    Connections {
        target: HistoryData

        function onEntriesChanged() {
            root.release();
        }
    }
    // Countdowns of the shown ones (shell/lib/notifications.mjs), by id.
    property var countdowns: ({})
    // Reply text being typed, by id, so it survives its popup moving to
    // another monitor as focus does.
    property var drafts: ({})

    // Do not disturb (§9), set from the center, the bell or IPC. While it's
    // on, a notification gets no popup unless it's a system sender's
    // critical one (Notes.passesDnd); it still goes to the history and
    // marks its app's windows. It's kept across config reloads.
    readonly property bool dnd: dndState.on
    // Popups are held for Do not disturb, or while a screen is shared
    // (ShareData). The same rule decides what gets through either way.
    readonly property bool quiet: root.dnd || ShareData.holdingPopups

    onQuietChanged: root.holdForDnd()

    PersistentProperties {
        id: dndState

        reloadableId: "tide-dnd"

        property bool on: false
    }

    function setDnd(on) {
        dndState.on = on;
    }

    // Takes down every popup, shown or waiting, that Do not disturb or a
    // screen share holds as things stand (Notes.heldByDnd). It runs whenever
    // the answer could change: either starting, an arrival, an update. It
    // rests, as a popup timing out does, keeping its history entry, its
    // marks and its actions.
    function holdForDnd() {
        const held = Notes.heldByDnd(root.queue, root.quiet, root.urgency);
        if (ShareData.holdingPopups) {
            ShareData.counted(held.length);
        }
        for (const n of held) {
            root.rest(n);
        }
    }

    readonly property var urgency: ({
            Low: NotificationUrgency.Low,
            Normal: NotificationUrgency.Normal,
            Critical: NotificationUrgency.Critical
        })
    readonly property var closeReason: ({
            Expired: NotificationCloseReason.Expired,
            Dismissed: NotificationCloseReason.Dismissed,
            CloseRequested: NotificationCloseReason.CloseRequested
        })

    // While M2's tide-shell runs swaync, the shell mustn't take
    // org.freedesktop.Notifications from it: Quickshell claims the name
    // whenever it's free, as it is for a moment each time the theme daemon
    // restarts swaync. So the server is opt-in until M4 retires swaync
    // (TODO.md).
    readonly property bool enabled: Quickshell.env("TIDE_NOTIFICATIONS") === "1"

    // A popup's time starts when it shows, not when it's queued; one that
    // has gone loses its countdown.
    onQueueChanged: root.track()

    // Popups show only on the focused monitor (NotificationPopups), so
    // while there's none (at startup, or as monitors change) nothing is on
    // screen, and every countdown is held as "unseen" rather than running
    // out on a popup nobody saw.
    readonly property bool onScreen: Hyprland.focusedMonitor !== null

    onOnScreenChanged: root.track()

    function track() {
        const now = Date.now();
        const next = {};
        for (const n of Notes.shown(root.queue)) {
            const c = root.countdowns[n.id] ?? Notes.countdown(Notes.timeoutFor(n.urgency, root.urgency), now);
            next[n.id] = root.onScreen ? Notes.release(c, "unseen", now) : Notes.hold(c, "unseen", now);
        }
        root.countdowns = next;
        root.schedule();
    }

    // Held by `source` ("popup" while hovered, "draft" while a reply is
    // unsent, "click" while a click's grant is recorded, "unseen" while no monitor can show
    // it); once every source lets go, it resumes.
    function hold(notification, source, held) {
        const c = root.countdowns[notification.id];
        if (!c) {
            return;
        }
        const now = Date.now();
        root.countdowns = Object.assign({}, root.countdowns, {
            [notification.id]: held ? Notes.hold(c, source, now) : Notes.release(c, source, now)
        });
        root.schedule();
    }

    // An update in place (replaces_id) gets its full time again, keeping
    // any hold.
    function restart(notification) {
        const c = root.countdowns[notification.id];
        if (!c) {
            return;
        }
        root.countdowns = Object.assign({}, root.countdowns, {
            [notification.id]: Notes.restarted(c, Notes.timeoutFor(notification.urgency, root.urgency), Date.now())
        });
        root.schedule();
    }

    // Runs an action after granting focus to the app that sent it, so the
    // window the app activates comes up (§9, §14.3). The click holds its
    // time only while the grant is recorded: a resident notification stays
    // after its action, and its time runs again. Here rather than in the
    // popup, which may be gone by the time the grant is.
    function run(notification, action) {
        // Clicking it is attending to it, so its marks go now (§14.4),
        // whether or not a resident notification stays after its action.
        MarkData.dismissed(notification.id);
        const app = Notes.grantId(notification);
        if (!app) {
            action.invoke();
            return;
        }
        root.hold(notification, "click", true);
        Launcher.grant(app, () => {
            // It may have gone meanwhile: closed by its app, or replaced. A
            // resting one is still live (a click on its center entry).
            if (Notes.isLive(root.queue, root.resting, notification)) {
                root.hold(notification, "click", false);
                action.invoke();
            }
        });
    }

    // A click on an entry in the center (§9): while the notification is
    // still live, shown or resting, what a click on its popup does (its
    // default action, or a dismissal when it has none); otherwise its app's
    // most recent window, through the focus guard (`tide focus`), since a
    // notification that has gone took its actions with it.
    function openEntry(entry) {
        const mine = n => HistoryData.keyOf(n.id) === entry.key;
        const live = root.queue.find(mine) ?? root.resting.find(mine) ?? null;
        const target = History.clickTarget(entry, live, Notes.defaultAction);
        if (target?.action) {
            root.run(live, target.action);
        } else if (target?.dismiss) {
            live.dismiss();
        } else if (target?.app) {
            Launcher.run(["tide", "focus", target.app], null);
        } else {
            console.warn("tide: notification center: the entry names no app, so the click brings nothing up");
        }
    }

    // A reply being typed holds the countdown as "draft" until it's sent
    // or emptied, whichever monitor shows the popup and wherever the
    // pointer or keyboard focus has gone.
    function setDraft(notification, text) {
        if ((root.drafts[notification.id] ?? "") !== text) {
            root.drafts = Notes.withDraft(root.drafts, notification.id, text);
            root.hold(notification, "draft", text !== "");
        }
    }

    function schedule() {
        const next = Notes.nextDeadline(Object.values(root.countdowns));
        if (next === null) {
            tick.stop();
            return;
        }
        tick.interval = Math.max(1, next - Date.now());
        tick.restart();
    }

    Timer {
        id: tick

        onTriggered: {
            const now = Date.now();
            // Its popup goes, and the notification rests (Notes.rest).
            for (const n of Notes.shown(root.queue)) {
                const c = root.countdowns[n.id];
                if (c && Notes.due(c, now)) {
                    root.rest(n);
                }
            }
            root.schedule();
        }
    }

    LazyLoader {
        active: root.enabled

        NotificationServer {
            // What §9 advertises. Chrome sends native notifications only
            // with body and actions, and actions are off by default.
            // Persistence is real: a popup that times out leaves the
            // notification resting, still live, until the center lets its
            // entry go, so an app that leaves keeping its notifications to
            // the server finds them there.
            bodySupported: true
            bodyMarkupSupported: true
            actionsSupported: true
            imageSupported: true
            persistenceSupported: true
            inlineReplySupported: true

            onNotification: notification => {
                notification.tracked = true;
                const id = notification.id;
                // One that was resting before a config reload goes on
                // resting, rather than popping up again.
                const wasResting = notification.lastGeneration && restingState.ids.includes(id);
                const result = wasResting ? {
                    queue: root.queue,
                    resting: [...root.resting, notification],
                    replaced: null
                } : Notes.arriveResting(root.queue, root.resting, notification);
                root.queue = result.queue;
                root.setResting(result.resting);
                // It marks its app's windows that are off screen (§14.4),
                // taking over the marks of any it replaced.
                MarkData.notified(id, Notes.grantId(notification), result.replaced?.id);
                // The center's history keeps it, past its popup (§9). One
                // carried over a config reload is usually there already.
                HistoryData.record(notification, result.replaced?.id, notification.lastGeneration);
                // However it goes (dismissed, expired, invoked, closed by
                // its app, or replaced), its popup goes with it. Its marks
                // go too, unless it only ran out of time.
                notification.closed.connect(reason => {
                    root.queue = Notes.leave(root.queue, notification);
                    root.setResting(Notes.leave(root.resting, notification));
                    root.drafts = Notes.withDraft(root.drafts, id, "");
                    if (Notes.clearsMarks(reason, root.closeReason)) {
                        MarkData.dismissed(id);
                    }
                });
                // Quickshell has no signal for a replaces_id update as such,
                // only one per property that changed, so any of them counts.
                // (A resend identical to the last changes nothing it can see.)
                // An update is news, so it marks again.
                for (const changed of [notification.appNameChanged, notification.appIconChanged, notification.summaryChanged, notification.bodyChanged, notification.urgencyChanged, notification.actionsChanged, notification.imageChanged, notification.hintsChanged, notification.desktopEntryChanged, notification.expireTimeoutChanged]) {
                    changed.connect(() => {
                        // A resting one shows again, as news.
                        if (root.resting.includes(notification)) {
                            const woken = Notes.wake(root.queue, root.resting, notification);
                            root.queue = woken.queue;
                            root.setResting(woken.resting);
                            woken.replaced?.expire();
                        }
                        root.restart(notification);
                        MarkData.notified(id, Notes.grantId(notification));
                        HistoryData.record(notification);
                        root.holdForDnd();
                    });
                }
                // An update that takes the reply field away drops its draft,
                // and with it the draft's hold.
                notification.hasInlineReplyChanged.connect(() => root.setDraft(notification, Notes.replyDraft(root.drafts, notification.id, notification.hasInlineReply)));
                result.replaced?.expire();
                root.holdForDnd();
            }
        }
    }
}
