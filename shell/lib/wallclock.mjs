// The wall clock's jumps (SPEC.md §7.3): Quickshell's SystemClock waits
// for the next minute on a timer that stops while the machine sleeps, so
// after a resume it can show the time from before for up to a minute.
// WallClock.qml checks the wall clock every CHECK_MS, and when it has moved
// further than that since the last check (a resume, or the time being set)
// it redraws at once.

export const CHECK_MS = 1000;

// How far a check may run late before it counts as a jump: a busy shell
// can stall a check, and a redraw it didn't need costs nothing.
export const SLACK_MS = 2000;

// Whether the wall clock jumped between a check at `last` and one at `now`,
// both in milliseconds since the epoch, `interval` apart on the timer.
export function jumped(last, now, interval = CHECK_MS) {
    return Math.abs(now - last - interval) > SLACK_MS;
}
