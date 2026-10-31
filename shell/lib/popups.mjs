// Telling the layout whether any of the shell's popovers and menus is open,
// for its edge drag (SPEC.md §6.6). Each is an xdg_popup of the bar, which
// Hyprland's Lua can't see, so the shell tells the layout whether one is
// (PopoverData.open), and while one is, a press on a split edge reaches the
// popover.

// The `hyprctl eval` code that tells the layout.
export function layoutCall(anyOpen) {
    return `tide_layout.set_popups_open(${anyOpen ? "true" : "false"})`;
}

// Telling the layout, one call at a time so an older answer can't land
// after a newer one. `pushed` is what it last heard (null: it needs
// telling), and `generation` counts resyncs, so a call that was in flight
// when the layout was started afresh doesn't count as heard.
export const NOT_TOLD = Object.freeze({ pushed: null, pushing: false, generation: 0 });

// The call to make now, if any: `send` is the value to send, or null.
export function nextCall(state, anyOpen) {
    if (state.pushing || state.pushed === anyOpen) {
        return { state, send: null };
    }
    return { state: Object.assign({}, state, { pushing: true }), send: anyOpen };
}

// The layout may have forgotten what it heard (the shell started, or a
// config load ran layout.lua afresh).
export function resynced(state) {
    return Object.assign({}, state, { pushed: null, generation: state.generation + 1 });
}

// A call that sent `sent` during `generation` finished. A failure counts
// as heard too, so it isn't retried until the value changes: without the
// tide layout every call fails the same way.
export function answered(state, sent, generation) {
    const current = generation === state.generation;
    return Object.assign({}, state, { pushing: false, pushed: current ? sent : null });
}
