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

// logind says when the machine wakes (PrepareForSleep false, after the
// sleep, with the wall clock already moved on), so the clocks and the
// light/dark schedule catch up then rather than at the next check. Read
// from gdbus, which comes with gsettings, so it needs nothing new.
export const SLEEP_MONITOR = ["gdbus", "monitor", "--system",
    "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"];

// Whether a line of SLEEP_MONITOR's output says the machine just woke:
// `/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)`.
// The signal before sleep (true) and every other line aren't.
export function woke(line) {
    return /\.Manager\.PrepareForSleep \(false,?\)/.test(line);
}
