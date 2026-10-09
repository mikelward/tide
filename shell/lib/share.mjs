// Knowing that a screen share is live (SPEC.md §12), as pure functions the
// QML binds to. The QML passes Quickshell's PipeWire objects and its
// PwLinkState.Active in, so this file names no Quickshell type.

// xdph names each screencast's PipeWire node xdph-streaming-<id>.
export function isShareNode(node) {
    return typeof node?.name === "string" && node.name.startsWith("xdph-streaming");
}

// The link groups out of share nodes: the ones the shell binds (with a
// PwObjectTracker), since a link group's state is only valid while bound,
// and only these, rather than every audio link.
export function shareLinks(linkGroups) {
    return linkGroups.filter(g => isShareNode(g.source));
}

// The share nodes something is consuming: an xdph stream with an active
// link out of it. A stream nobody reads yet (the picker is still open, or
// Chrome hasn't started) isn't a share.
export function liveShares(nodes, linkGroups, ACTIVE) {
    const consumed = new Set(linkGroups
        .filter(g => g.state === ACTIVE && g.source)
        .map(g => g.source.id));
    return nodes.filter(n => isShareNode(n) && consumed.has(n.id));
}

// How long after the picker's choice its stream may appear and still be
// paired with it (§12).
export const PAIR_MS = 5000;

// What the shell knows of each share's kind: the picker's choices still
// waiting for a stream, each share node seen and when, the kind paired with
// a node and when (pending until PAIR_MS passes without a second node), and
// the kinds that have settled.
export const PAIRING = Object.freeze({ waiting: [], seen: [], pending: {}, kinds: {} });

function recent(list, now) {
    return list.filter(e => now - e.time >= 0 && now - e.time <= PAIR_MS);
}

// The picker's choice (its option's kind: "screen", "window" or
// "region"), waiting for its stream.
export function chose(state, kind, now) {
    return {
        waiting: recent(state.waiting, now).concat([{ kind: kind, time: now }]),
        seen: state.seen,
        pending: state.pending,
        kinds: state.kinds
    };
}

// The share nodes now present, by id. A new one takes the waiting choice's
// kind only when that's unambiguous: exactly one choice waiting, and no
// other share node new within PAIR_MS. Anything else is left unpaired,
// which counts as a screen share, and drops the waiting choices, since one
// of these nodes may have been theirs; and a second node new so soon after
// a pairing undoes it, since either could have been the choice's. So a
// pairing is pending until PAIR_MS passes (settle), and holds popups till
// then: an unrelated stream that came first can't show them meanwhile. A
// node that goes and an id that comes back are new again.
export function nodesSeen(state, ids, now) {
    const present = new Set(ids);
    const seen = state.seen.filter(e => present.has(e.id));
    const pending = {};
    const kinds = {};
    for (const e of seen) {
        if (state.pending[e.id] !== undefined) {
            pending[e.id] = state.pending[e.id];
        }
        if (state.kinds[e.id] !== undefined) {
            kinds[e.id] = state.kinds[e.id];
        }
    }
    let waiting = recent(state.waiting, now);
    const known = new Set(seen.map(e => e.id));
    const fresh = ids.filter((id, i) => !known.has(id) && ids.indexOf(id) === i);
    if (fresh.length === 0) {
        return { waiting: waiting, seen: seen, pending: pending, kinds: kinds };
    }
    const others = recent(seen, now);
    if (fresh.length === 1 && waiting.length === 1 && others.length === 0) {
        pending[fresh[0]] = { kind: waiting[0].kind, time: now };
        waiting = [];
    } else {
        waiting = [];
        for (const e of others) {
            delete pending[e.id];
            delete kinds[e.id];
        }
    }
    return {
        waiting: waiting,
        seen: seen.concat(fresh.map(id => ({ id: id, time: now }))),
        pending: pending,
        kinds: kinds
    };
}

// The pairings PAIR_MS old with no second node to undo them, settled. The
// same state back when none is, so a binding on it doesn't churn.
export function settle(state, now) {
    const due = Object.keys(state.pending).filter(id => now - state.pending[id].time > PAIR_MS);
    if (due.length === 0) {
        return state;
    }
    const pending = Object.assign({}, state.pending);
    const kinds = Object.assign({}, state.kinds);
    for (const id of due) {
        kinds[id] = pending[id].kind;
        delete pending[id];
    }
    return { waiting: state.waiting, seen: state.seen, pending: pending, kinds: kinds };
}

// How long until the next pending pairing can settle, in ms, or null when
// none is pending.
export function settleIn(state, now) {
    const times = Object.keys(state.pending).map(id => state.pending[id].time);
    if (times.length === 0) {
        return null;
    }
    return Math.max(1, Math.min(...times) + PAIR_MS + 1 - now);
}

// A share's kind: what a settled pairing gave its node, or "screen", the
// safe way to be wrong.
export function kindOf(state, id) {
    return state.kinds[id] ?? "screen";
}

// Whether popups are held for the shares that are live. A screen or region
// share holds them; a window share can't show them (§9). A share the shell
// couldn't pair counts as a screen share, so a popup waits rather than
// leaking into a stream.
export function holdsPopups(shares, state) {
    return shares.some(s => kindOf(state, s.id) !== "window");
}

// The bar's red Sharing pill (§7.4) shows while any share is live, and takes
// no room otherwise. Unlike holding popups, a window share counts.
export function sharingPill(shares) {
    return shares.length > 0;
}
