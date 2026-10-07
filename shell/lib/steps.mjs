// The − and + of a number on the settings panel's pages (SPEC.md §16),
// shared so each page's steps go to the next mark the same way.

// How many decimal places `step` has: 0.05 has two.
function places(step) {
    const text = String(step);
    const dot = text.indexOf(".");
    return dot < 0 ? 0 : text.length - dot - 1;
}

// `value` moved `steps` marks `step` apart, between `lo` and `hi`. Off a
// mark (a value typed into a file, or a scale Hyprland rounded), the first
// step lands on the nearest mark that way, so 0.73 goes to 0.75 or 0.7,
// never past one. A value past an end, which the files may allow, stays
// put on a press that would move it back across. The result is rounded to
// the step's places, so 0.55 + 0.05 is 0.6, not 0.6000000000000001.
export function stepped(value, steps, step, lo, hi) {
    if (steps === 0) {
        return value;
    }
    const at = value / step;
    const near = Math.round(at);
    // A hair off a mark is float noise (0.6 / 0.05 is 11.999999999999998).
    const from = Math.abs(at - near) < 1e-9 ? near : steps > 0 ? Math.floor(at) : Math.ceil(at);
    const next = Number(((from + steps) * step).toFixed(places(step)));
    const clamped = Math.max(lo, Math.min(hi, next));
    return (steps > 0 && clamped < value) || (steps < 0 && clamped > value) ? value : clamped;
}
