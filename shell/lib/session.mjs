// The session menu (SPEC.md §7.4): lock, log out, suspend, restart and shut
// down, as pure functions the QML binds to.
//
// Everything goes through logind or uwsm, so the menu has one path to test:
// locking raises logind's Lock signal (SPEC.md §10), and logging out stops
// the uwsm session, units and all. Power actions check logind's inhibitors
// first and ask only when something blocks them (§8).

export const ACTIONS = Object.freeze([
    Object.freeze({ id: "lock", label: "Lock", icon: "system-lock-screen-symbolic" }),
    Object.freeze({ id: "logout", label: "Log out", icon: "system-log-out-symbolic" }),
    Object.freeze({ id: "suspend", label: "Suspend", icon: "weather-clear-night-symbolic" }),
    Object.freeze({ id: "reboot", label: "Restart", icon: "system-reboot-symbolic" }),
    Object.freeze({ id: "poweroff", label: "Shut down", icon: "system-shutdown-symbolic" }),
]);

const POWER = new Set(["suspend", "reboot", "poweroff"]);

// The command for an action. A power action checks inhibitors, so it fails
// when something blocks it, unless `force` says to go ahead anyway.
export function actionCommand(id, force = false) {
    if (id === "lock") {
        // Through logind, or without it when hypridle isn't there to answer
        // (SPEC.md §10).
        return ["tide", "lock"];
    }
    if (id === "logout") {
        return ["uwsm", "stop"];
    }
    if (POWER.has(id)) {
        return ["systemctl", `--check-inhibitors=${force ? "no" : "yes"}`, id];
    }
    throw new Error(`unknown session action: ${id}`);
}

// What blocked a power action, from systemctl's stderr when it fails: one
// line per inhibitor ("Firefox: Playing video") or other logged-in user. An
// empty list means it failed for some other reason.
export function blockers(stderr) {
    const found = [];
    for (const line of String(stderr).split("\n")) {
        const inhibitor = /Operation inhibited by "(.*?)".*reason is "(.*?)"/.exec(line);
        if (inhibitor) {
            found.push(`${inhibitor[1]}: ${inhibitor[2]}`);
            continue;
        }
        const user = /^User (\S+) is logged in on (\S+?)\.?$/.exec(line.trim());
        if (user) {
            found.push(`${user[1]} is logged in on ${user[2]}`);
        }
    }
    return found;
}

// The other logged-in users that blocked a power action, from systemctl's
// stderr, when they're all that blocked it: no inhibitor, which logind
// enforces whatever systemctl is told, and nothing else failed. Otherwise
// an empty list.
export function sessionsOnly(stderr) {
    const lines = String(stderr).split("\n");
    if (lines.some((line) => /Operation inhibited by /.test(line))) return [];
    return blockers(stderr);
}

// Whether an action can be blocked by inhibitors, and so may ask first.
export function isPower(id) {
    return POWER.has(id);
}
