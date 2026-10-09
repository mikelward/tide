// Unplugging while idle (SPEC.md §10), as UnplugSuspend.qml carries it out.
// hypridle's suspend step runs `tide idle-suspend`, which on AC leaves a
// flag instead of suspending, and the same step runs `tide idle-suspend
// --cancel` on the first input after it (conf's hypridle.conf). On the switch
// to battery, the shell runs `tide idle-suspend --unplugged`, which
// suspends if the flag is still there.
//
// The state: { checking, again }, checking while that command runs, and
// again when a switch to battery came while it ran: the power can flap,
// battery to AC and back, within one check, and the check may have seen it
// on AC. Events:
//   {type: "power", onBattery}   UPower's switch, either way
//   {type: "done"}               the command ended
// The result's `run` is true to run the command now.

export const INITIAL = Object.freeze({ checking: false, again: false });

function result(state, run) {
    return { state: Object.freeze(state), run: run };
}

export function next(state, event) {
    switch (event.type) {
    case "power":
        if (state.checking) {
            // Checked again once this one ends, if the power ends up on
            // battery.
            return result(Object.assign({}, state, { again: event.onBattery }), false);
        }
        if (!event.onBattery) {
            return result(state, false);
        }
        return result(Object.assign({}, state, { checking: true }), true);
    case "done":
        if (state.again) {
            return result(Object.assign({}, state, { again: false }), true);
        }
        return result(Object.assign({}, state, { checking: false }), false);
    default:
        return result(state, false);
    }
}

export const COMMAND = Object.freeze(["tide", "idle-suspend", "--unplugged"]);
