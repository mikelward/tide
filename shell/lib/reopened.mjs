// Reopened windows go back to their workspaces (tide SPEC.md §6.5): an app that
// closes all its windows and opens them again, as a browser does when it
// restarts to update, would otherwise open them all on the workspace
// you're on. Free of any compositor's API, so tide on KDE copies it
// verbatim (tide-kde's `make check-tide-reopened`).
//
// The caller hands over every window it knows each time they change, as
// [{address, app, title, workspace}]: `address` any string that names one
// window while it's open, `app` its class or app ID, `title` its title and
// `workspace` the name of the workspace it's on, or "" for none it could go
// back to (a special one). A minimized window's is the workspace it was
// minimized from. `place`, if given, says where it is now in more detail,
// minimized or not, so a window minimized meanwhile counts as moved; it
// defaults to `workspace`. A window with no app yet is left out until it
// has one.
//
// A window that closes is remembered for KEEP_MS: its app, title and
// workspace. A window that opens while its app has no other window open
// starts that app's reopening, which lasts REOPEN_MS. Each window of the
// app that opens meanwhile goes back to the workspace of the remembered
// window with its app and title, the one that closed first if more than
// one has them; one whose title doesn't match yet (an app that names its
// windows once they've loaded) goes back if its title matches within
// TITLE_MS, as long as it's still where it opened. Each remembered window
// is taken once.
// Nothing else moves: a window opened while another of its app is open,
// one moved meanwhile, and one with a title no closed window had.

// How long a closed window is remembered, in milliseconds: long enough for
// an update to install before the app opens again.
export const KEEP_MS = 10 * 60 * 1000;
// How long after an app's first window opens its others count as reopened.
export const REOPEN_MS = 30 * 1000;
// How long a reopened window's title has to come to match a closed one's:
// longer, and a page you open yourself could match.
export const TITLE_MS = 5 * 1000;
// The most closed windows remembered; the oldest go first.
export const MAX_CLOSED = 200;

// Before the first list: nothing seen, nothing remembered.
export const NOTHING = Object.freeze({ seen: null, closed: [], reopening: [], waiting: [] });

function listed(windows) {
    return Array.from(windows ?? []).filter(w => w && typeof w.address === "string" && w.address !== "" && typeof w.app === "string" && w.app !== "").map(w => ({
        address: w.address,
        app: w.app,
        title: typeof w.title === "string" ? w.title : "",
        workspace: typeof w.workspace === "string" ? w.workspace : "",
        place: typeof w.place === "string" ? w.place : (typeof w.workspace === "string" ? w.workspace : "")
    }));
}

function find(list, address) {
    for (const w of list) {
        if (w.address === address) {
            return w;
        }
    }
    return null;
}

function reopeningUntil(reopening, app, now) {
    for (const r of reopening) {
        if (r.app === app && now < r.until) {
            return r.until;
        }
    }
    return null;
}

// The index in `closed` of the window `w` reopens, or -1.
function match(closed, w) {
    if (w.title === "") {
        return -1;
    }
    for (let i = 0; i < closed.length; i++) {
        if (closed[i].app === w.app && closed[i].title === w.title) {
            return i;
        }
    }
    return -1;
}

// The windows are now `windows`, at `now` (ms): {state, moves}, `moves`
// being [{address, workspace, app, title}], each window to send back,
// unfollowed, to the workspace named `workspace`.
export function windowsChanged(state, windows, now) {
    const current = listed(windows);
    if (!state || state.seen === null) {
        return { state: { seen: current, closed: [], reopening: [], waiting: [] }, moves: [] };
    }
    let closed = state.closed.filter(c => now - c.at >= 0 && now - c.at < KEEP_MS);
    for (const w of state.seen) {
        if (find(current, w.address) === null && w.workspace !== "") {
            closed.push({ app: w.app, title: w.title, workspace: w.workspace, at: now });
        }
    }
    if (closed.length > MAX_CLOSED) {
        closed = closed.slice(closed.length - MAX_CLOSED);
    }
    const opened = current.filter(w => find(state.seen, w.address) === null);
    // An app with no window open has no reopening left: its next window
    // starts another.
    let reopening = state.reopening.filter(r => now < r.until && current.some(w => w.app === r.app));
    for (const w of opened) {
        const others = current.filter(o => o.app === w.app && find(opened, o.address) === null);
        const remembered = closed.some(c => c.app === w.app);
        if (others.length === 0 && remembered && reopeningUntil(reopening, w.app, now) === null) {
            reopening.push({ app: w.app, until: now + REOPEN_MS });
        }
    }
    const moves = [];
    const take = (w, i) => {
        const c = closed[i];
        closed = closed.filter((_, j) => j !== i);
        if (c.workspace !== w.workspace) {
            moves.push({ address: w.address, workspace: c.workspace, app: w.app, title: w.title });
        }
    };
    // Those waiting for their title, while still where they opened and
    // their app's reopening lasts.
    const waiting = [];
    for (const wait of state.waiting) {
        const w = find(current, wait.address);
        if (w === null || w.place !== wait.place || now >= wait.until) {
            continue;
        }
        const i = match(closed, w);
        if (i >= 0) {
            take(w, i);
        } else {
            waiting.push(wait);
        }
    }
    for (const w of opened) {
        if (reopeningUntil(reopening, w.app, now) === null) {
            continue;
        }
        const i = match(closed, w);
        if (i >= 0) {
            take(w, i);
        } else {
            waiting.push({ address: w.address, place: w.place, until: now + TITLE_MS });
        }
    }
    return { state: { seen: current, closed: closed, reopening: reopening, waiting: waiting }, moves: moves };
}
