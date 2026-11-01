// Presenter mode (SPEC.md §10): Do not disturb and keep awake together,
// from Super+P, the launcher or the bar's pill.
//
// It doesn't overwrite the two toggles. It holds both on over them, as a
// live mic holds keep awake, so turning it off leaves each as it was
// before. The state is {presenting, dnd, keepAwake}: presenter mode, and
// your own Do not disturb and keep awake under it.

export const OFF = Object.freeze({ presenting: false, dnd: false, keepAwake: false });

function part(state, key) {
    return Boolean(state?.[key]);
}

function frozen(presenting, dnd, keepAwake) {
    return Object.freeze({ presenting, dnd, keepAwake });
}

// What's in effect: each toggle, or presenter mode over it, and keep awake
// while the mic is live too.
export function effective(state, micLive = false) {
    const presenting = part(state, "presenting");
    return Object.freeze({
        dnd: presenting || part(state, "dnd"),
        keepAwake: presenting || part(state, "keepAwake") || Boolean(micLive),
    });
}

// Super+P: presenter mode on or off, with your toggles as they were.
export function presenterToggled(state) {
    return frozen(!part(state, "presenting"), part(state, "dnd"), part(state, "keepAwake"));
}

// Do not disturb set from the bell, the center, the launcher or IPC.
// While presenting it already reads on, so turning it on changes nothing,
// and turning it off ends presenter mode: Do not disturb goes off, and keep
// awake stays on, as yours now.
export function dndSet(state, on) {
    if (!part(state, "presenting")) {
        return frozen(false, Boolean(on), part(state, "keepAwake"));
    }
    if (on) {
        return frozen(true, part(state, "dnd"), part(state, "keepAwake"));
    }
    return frozen(false, false, true);
}

// Keep awake toggled from the bar, the launcher or Super+S. While presenting
// it reads on, so a toggle turns it off and ends presenter mode, and Do not
// disturb stays on, as yours now. Without the shell as the notification
// server (`dndAvailable` false) there's no Do not disturb to keep, so it's
// left as it was.
export function keepAwakeToggled(state, dndAvailable = true) {
    if (!part(state, "presenting")) {
        return frozen(false, part(state, "dnd"), !part(state, "keepAwake"));
    }
    return frozen(false, dndAvailable ? true : part(state, "dnd"), false);
}

// The Presenting pill's hover text (SPEC.md §7.4), as tilemo's: what
// presenter mode is holding. Without the shell as the notification server
// there's no Do not disturb, so it's keep awake alone, as the OSD says.
export function pillTip(dndAvailable) {
    return dndAvailable ? "Presenting: Do not disturb and keep awake" : "Presenting: keep awake only";
}
