// Keep awake (SPEC.md §10): a bar toggle that holds an idle inhibitor, so
// the screen doesn't dim, lock, blank or suspend for idleness. It turns
// itself off after a while, so it can't be left on by accident for days.

export const HOLD_MS = 2 * 60 * 60 * 1000;

export const OFF = Object.freeze({ on: false, until: 0 });

// The state after a click on the toggle at `now`: on for HOLD_MS, or off.
export function toggled(state, now) {
    return isOn(state, now) ? OFF : Object.freeze({ on: true, until: now + HOLD_MS });
}

// Whether keep awake holds at `now`; past its time, it doesn't.
export function isOn(state, now) {
    return Boolean(state?.on) && Number.isFinite(state.until) && now < state.until;
}

// How long until it turns itself off, in ms; 0 when it's off.
export function remaining(state, now) {
    return isOn(state, now) ? state.until - now : 0;
}
