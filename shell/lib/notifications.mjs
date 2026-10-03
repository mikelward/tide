// Notification popups (SPEC.md §9), as pure functions the QML binds to.
//
// The QML passes Quickshell's NotificationUrgency values in, so this file
// names no Quickshell type.

// How long a popup stays, in ms, by urgency; a critical one stays until
// it's dismissed (0).
export function timeoutFor(urgency, URGENCY) {
    if (urgency === URGENCY.Critical) {
        return 0;
    }
    return urgency === URGENCY.Low ? 4000 : 6000;
}

// At most three popups show; the rest wait their turn, oldest first.
export const MAX_SHOWN = 3;

// How tall the stack of popups may be: all of it when it fits on the
// output below the bar and its margins, else that room, and the rest
// scrolls, so every popup's buttons stay reachable.
export function stackHeight(content, screenHeight, above, below) {
    return Math.max(0, Math.min(content, screenHeight - above - below));
}

// Reply drafts by notification id, as a new map with `id`'s set to `text`,
// or dropped when it's empty. They live outside the popups, which are
// rebuilt on whichever monitor takes focus.
export function withDraft(drafts, id, text) {
    const next = Object.assign({}, drafts);
    if (text) {
        next[id] = text;
    } else {
        delete next[id];
    }
    return next;
}

// The draft notification `id` keeps: its own, or none once an update has
// taken its reply field away, since nothing could send or empty it then.
export function replyDraft(drafts, id, hasInlineReply) {
    return hasInlineReply ? drafts[id] ?? "" : "";
}

// The popups on screen from the queue, oldest first, drawn newest on top.
export function shown(queue) {
    return queue.slice(0, MAX_SHOWN).reverse();
}

// A notification's x-canonical-private-synchronous key, if it has one:
// volume and brightness tools send one so each change replaces the last.
export function syncKey(hints) {
    const key = hints?.["x-canonical-private-synchronous"];
    return typeof key === "string" && key !== "" ? key : null;
}

// The queue after `notification` arrives. One from the same app with the
// same synchronous key takes the place of the one it replaces, whose
// popup goes; anything else joins the end. (A `replaces_id` update needs
// nothing here: Quickshell updates that notification in place.)
export function arrive(queue, notification) {
    const key = syncKey(notification.hints);
    const index = key === null ? -1 : queue.findIndex(n =>
        n !== notification && n.appName === notification.appName && syncKey(n.hints) === key);
    if (queue.includes(notification)) {
        return { queue, replaced: null };
    }
    if (index < 0) {
        return { queue: [...queue, notification], replaced: null };
    }
    const next = [...queue];
    const replaced = next[index];
    next[index] = notification;
    return { queue: next, replaced };
}

// The queue without a notification that's gone (dismissed, expired,
// closed by its app, or replaced).
export function leave(queue, notification) {
    return queue.filter(n => n !== notification);
}

// The app a click grants focus to (§9, §14.3): the desktop entry the
// notification names, else its app name. The focus guard matches either
// against window classes, case-insensitively and by the last part of a
// qualified ID. Null when there's neither.
export function grantId(notification) {
    for (const id of [notification.desktopEntry, notification.appName]) {
        const trimmed = (id ?? "").trim();
        if (trimmed !== "") {
            return trimmed;
        }
    }
    return null;
}

// Whether a notification's closing clears the bar marks it made (§14.4):
// a dismissal, which an invoked action is too, or its app closing it does;
// running out of time on screen doesn't, since nobody has looked at its
// window yet. `reasons` is Quickshell's NotificationCloseReason.
export function clearsMarks(reason, reasons) {
    return reason !== reasons.Expired;
}

// The default action, invoked by clicking the popup itself: the one an app
// names "default", which the spec reserves for that.
export function defaultAction(actions) {
    return actions.find(a => a.identifier === "default") ?? null;
}

// The actions shown as buttons: every one but the default.
export function buttons(actions) {
    return actions.filter(a => a.identifier !== "default" && a.text !== "");
}

const ALLOWED = new Set(["b", "i", "u"]);

// A body as Qt's StyledText, from the freedesktop body markup an app may
// send (b, i, u, a and img). Bold, italic and underline stay; links keep
// their text and lose their target, and images go, so a notification can't
// make the shell fetch anything. Everything else is escaped, and line
// breaks are kept.
export function bodyStyled(body) {
    body = String(body);
    const out = [];
    const tag = /<\s*(\/?)\s*([a-zA-Z]+)[^>]*>/g;
    let last = 0;
    // An exec loop: Qt's JavaScript engine has no matchAll.
    for (let m = tag.exec(body); m !== null; m = tag.exec(body)) {
        out.push(escape(String(body).slice(last, m.index)));
        last = m.index + m[0].length;
        const name = m[2].toLowerCase();
        if (ALLOWED.has(name)) {
            out.push(`<${m[1]}${name}>`);
        } else if (name === "br") {
            out.push("<br>");
        } else if (name !== "a" && name !== "img") {
            out.push(escape(m[0]));
        }
    }
    out.push(escape(String(body).slice(last)));
    return out.join("").replace(/\r?\n/g, "<br>");
}

// Entities the app already escaped stay escaped once, not twice.
function escape(text) {
    return text
        .replace(/&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}

// An app_icon is a themed icon name, or a path or file:// URL to an image
// (the spec allows both). Returns the URL for a path, else null for a name.
export function iconFile(appIcon) {
    if (appIcon.startsWith("file://")) {
        return appIcon;
    }
    return appIcon.startsWith("/") ? `file://${appIcon}` : null;
}

// A popup's countdown, kept in the one NotificationData rather than in each
// monitor's popup, so there's one per notification however many monitors
// draw it. Running, it has a deadline; held, it keeps the time it had left,
// so letting go resumes it rather than starting it over. Each hold has a
// source ("popup" while hovered or replied to, "click" while a click's
// focus grant is recorded, "unseen" while no monitor can show it), and it
// runs again only once every source has let go. A critical popup's (0 ms) never runs out.
export function countdown(ms, now) {
    return Object.freeze({ ms, deadline: ms > 0 ? now + ms : Infinity, left: ms, holders: Object.freeze([]) });
}

export function held(c) {
    return c.holders.length > 0;
}

export function hold(c, source, now) {
    if (c.holders.includes(source)) {
        return c;
    }
    const left = held(c) ? c.left : Math.max(0, c.deadline - now);
    return Object.freeze(Object.assign({}, c, { left, holders: Object.freeze([...c.holders, source]) }));
}

export function release(c, source, now) {
    if (!c.holders.includes(source)) {
        return c;
    }
    const holders = Object.freeze(c.holders.filter(h => h !== source));
    if (holders.length > 0) {
        return Object.freeze(Object.assign({}, c, { holders }));
    }
    return Object.freeze(Object.assign({}, c, { holders, deadline: c.ms > 0 ? now + c.left : Infinity }));
}

// A fresh countdown, as for an update in place, keeping whoever holds it.
export function restarted(c, ms, now) {
    let fresh = countdown(ms, now);
    for (const source of c.holders) {
        fresh = hold(fresh, source, now);
    }
    return fresh;
}

// Whether a running countdown has run out.
export function due(c, now) {
    return !held(c) && now >= c.deadline;
}

// When the next of `countdowns` runs out, or null when none will.
export function nextDeadline(countdowns) {
    const running = countdowns.filter(c => !held(c) && Number.isFinite(c.deadline));
    return running.length === 0 ? null : Math.min(...running.map(c => c.deadline));
}

// Whether a notification shows while Do not disturb is on (§9): only a
// critical one from a system sender gets through. The system senders are
// the shell and the tide tools, which send as "tide" (the
// battery warning among them), and polkit agents. Chrome marks every
// requireInteraction web notification critical, so a critical one from
// anyone else is held like the rest.
export function passesDnd(notification, URGENCY) {
    if (notification.urgency !== URGENCY.Critical) {
        return false;
    }
    return [notification.appName, notification.desktopEntry].some(name => {
        const id = (name ?? "").trim().toLowerCase();
        return id === "tide" || id.includes("polkit");
    });
}

// The notifications in the popup queue that Do not disturb holds: none
// while it's off, else every one that doesn't pass (passesDnd). The shell
// takes these down whenever anything could change the answer (an arrival,
// an update, turning it on), so one rule covers them all.
export function heldByDnd(queue, dnd, URGENCY) {
    return dnd ? queue.filter(n => !passesDnd(n, URGENCY)) : [];
}

// Persistence (§9). A popup that runs out of time, or that Do not disturb
// or a share holds, leaves the queue for `resting`: the notification stays
// live on the server, out of sight, so a click on its center entry can
// still run its actions. It's released when the center lets its entry go
// (unkept), and woken back into the queue by an update in place, which is
// news as a new notification would be.

// {queue, resting, replaced} after `notification` arrives (arrive). A
// synchronous key also matches a resting notification, which is still
// live: the new one takes its place in the history and marks, and it's
// released, rather than lingering beside it.
export function arriveResting(queue, resting, notification) {
    const result = arrive(queue, notification);
    const key = syncKey(notification.hints);
    if (result.replaced || key === null || queue.includes(notification)) {
        return { queue: result.queue, resting, replaced: result.replaced };
    }
    const replaced = resting.find(n =>
        n !== notification && n.appName === notification.appName && syncKey(n.hints) === key) ?? null;
    return { queue: result.queue, resting: replaced ? leave(resting, replaced) : resting, replaced };
}

// Whether `notification` is still live on the server: shown or waiting
// in the queue, or resting. A click's grant can outlast the popup, so its
// action runs if it's either.
export function isLive(queue, resting, notification) {
    return queue.includes(notification) || resting.includes(notification);
}

// {queue, resting} after `notification`'s popup goes but the notification
// stays.
export function rest(queue, resting, notification) {
    return {
        queue: leave(queue, notification),
        resting: resting.includes(notification) ? resting : [...resting, notification],
    };
}

// {queue, resting, replaced} after a resting notification is updated in
// place, so its popup shows again (arrive, which may replace another).
export function wake(queue, resting, notification) {
    const result = arrive(queue, notification);
    return { queue: result.queue, resting: leave(resting, notification), replaced: result.replaced };
}

// The resting notifications whose center entry has gone (cleared, past
// the history's cap, or never there for a transient one), to release.
// `keys` holds the entries' keys; `keyOf` turns an id into one.
export function unkept(resting, keys, keyOf) {
    const kept = new Set(keys);
    return resting.filter(n => !kept.has(keyOf(n.id)));
}
