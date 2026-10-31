// Keep awake (SPEC.md §10): a bar toggle that holds an idle inhibitor, so
// the screen doesn't dim, lock, blank or suspend for idleness. A click keeps
// it on until the next click; it never times out. A click itself is
// presenter.mjs's keepAwakeToggled, since presenter mode holds it too.
//
// The state is {on, until}. `until` is from the versions that turned it off
// after two hours: a config reload into this version carries their state
// over (PersistentProperties, same id), and `migrated` turns it into this
// version's once, at load.

export const OFF = Object.freeze({ on: false, until: 0 });

// Its icon everywhere it's shown: the bar, the OSD and the switcher. A
// cup of coffee, as on tilemo, and not the sun, which is brightness's.
// One of tide's own (shell/icons), since icon themes have none.
export const ICON = "keep-awake-symbolic.svg";

// What it's doing, in the words the OSD, the bar icon's hover text and
// the switcher all use, as tilemo's do: whether it's keeping the screen
// awake, and if you didn't ask, what is.
export function sign({ on, asked, presenting }) {
    if (!on) {
        return "Not keeping awake";
    }
    if (asked) {
        return "Keeping awake";
    }
    return presenting ? "Keeping awake while presenting" : "Keeping awake while the mic is live";
}

// The state carried over from a reload, at `now`: an old deadline still to
// come is on, with no end now; one that has passed is off, as the old
// version would have turned it. Either way the deadline is gone.
export function migrated(state, now) {
    const pending = Number.isFinite(state?.until) && state.until > now;
    return Object.freeze({ on: Boolean(state?.on) || pending, until: 0 });
}
