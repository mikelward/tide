// The launcher's frecency (SPEC.md §8): how often and how recently each row
// was run, kept in $XDG_STATE_HOME/tide/launcher.json, so the empty query
// lists what you use and, among equal matches, a query puts it first.
//
// Each row keeps a count and the time it was last run. Its score is the
// count weighted by how long ago that was, as Firefox's frecency does in
// buckets, so something used daily last month gives way to what you use
// now, without a decay that needs rewriting the file as time passes.

export const MAX_ENTRIES = 200;

const DAY = 24 * 60 * 60 * 1000;
const BUCKETS = [
    [4 * DAY, 100],
    [14 * DAY, 70],
    [31 * DAY, 50],
    [90 * DAY, 30],
];
const OLD = 10;

export function initial() {
    return Object.freeze({});
}

// An entry's score at `now`: 0 for none.
export function score(entry, now) {
    if (!entry) {
        return 0;
    }
    const age = Math.max(0, now - entry.last);
    const bucket = BUCKETS.find(([limit]) => age < limit);
    return entry.count * (bucket ? bucket[1] : OLD);
}

// The state after running the row `key` at `now`. Past MAX_ENTRIES, the
// lowest-scoring entries go, so the file stays small.
export function record(state, key, now) {
    const old = state[key];
    const next = { ...state, [key]: Object.freeze({ count: (old?.count ?? 0) + 1, last: now }) };
    const keys = Object.keys(next);
    if (keys.length > MAX_ENTRIES) {
        keys.sort((a, b) => score(next[b], now) - score(next[a], now) || next[b].last - next[a].last);
        for (const k of keys.slice(MAX_ENTRIES)) {
            delete next[k];
        }
    }
    return Object.freeze(next);
}

export function serialize(state) {
    return JSON.stringify({ version: 1, entries: state }, null, 1) + "\n";
}

// {state, errors}: the entries that read cleanly, and one message per
// thing that didn't, so a damaged file loses what's damaged, not the rest.
export function parse(text) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return { state: initial(), errors: [`not JSON (${e.message}); starting over`] };
    }
    const entries = data?.entries;
    if (typeof entries !== "object" || entries === null || Array.isArray(entries)) {
        return { state: initial(), errors: ["no entries; starting over"] };
    }
    const state = {};
    const errors = [];
    for (const [key, entry] of Object.entries(entries)) {
        if (Number.isInteger(entry?.count) && entry.count > 0 && Number.isFinite(entry?.last)) {
            state[key] = Object.freeze({ count: entry.count, last: entry.last });
        } else {
            errors.push(`entry ${JSON.stringify(key)} isn't a count and a time; dropped`);
        }
    }
    return { state: Object.freeze(state), errors };
}
