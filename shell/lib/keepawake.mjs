// Keep awake (SPEC.md §10): a bar toggle that holds an idle inhibitor, so
// the screen doesn't dim, lock, blank or suspend for idleness. A click keeps
// it on until the next click; it never times out.
//
// The state is {on, until}. `until` is from the versions that turned it off
// after two hours: a config reload into this version carries their state
// over (PersistentProperties, same id), and `migrated` turns it into this
// version's once, at load.

export const OFF = Object.freeze({ on: false, until: 0 });

// The state carried over from a reload, at `now`: an old deadline still to
// come is on, with no end now; one that has passed is off, as the old
// version would have turned it. Either way the deadline is gone.
export function migrated(state, now) {
    const pending = Number.isFinite(state?.until) && state.until > now;
    return Object.freeze({ on: Boolean(state?.on) || pending, until: 0 });
}

// The state after a click: on, with no end, or off.
export function toggled(state) {
    return state?.on ? OFF : Object.freeze({ on: true, until: 0 });
}
