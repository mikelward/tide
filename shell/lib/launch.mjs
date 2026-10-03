// The bookkeeping for a command the shell runs (shell/Launcher.qml,
// SessionMenu.qml and ClockData.qml), as pure functions the QML feeds
// Process signals into.
//
// A run's signals arrive separately and in no fixed order: `started`, the
// exit code, the end of stderr, and `running` going false. Quickshell 0.3
// reports a command that can't start (no tide on PATH) only by
// `running` going false without `started`: no exit code and no end of
// stderr. So a run is done either then, or once both the exit code and the
// whole of stderr are in, and it reports exactly once.

export function initial() {
    return Object.freeze({ started: false, stopped: false, code: null, errors: null, done: false, report: null });
}

// What a finished run has to say: a warning for a failed start or a nonzero
// exit, or a log line for stderr on success (tide launch carries on
// past a missed focus grant or a slow shell, and says so; so may the app).
// Null when there's nothing to say, undefined while it isn't finished.
function outcome(run, command) {
    const shown = command.join(" ");
    if (run.stopped && !run.started) {
        return { level: "warn", message: `tide: couldn't start ${shown}` };
    }
    if (run.code === null || run.errors === null) {
        return undefined;
    }
    const errors = run.errors.trim();
    if (run.code !== 0) {
        return { level: "warn", message: `tide: ${shown} exited ${run.code}: ${errors}` };
    }
    if (errors !== "") {
        return { level: "log", message: `tide: ${shown}: ${errors}` };
    }
    return null;
}

// The run after `event`: {type: "started"}, {type: "stopped"},
// {type: "exited", code} or {type: "stderr", text}. `done` turns true once,
// on the event that finishes the run, which alone carries its `report`.
export function step(run, event, command) {
    if (run.done) {
        return Object.freeze(Object.assign({}, run, { report: null }));
    }
    const next = Object.assign({}, run, { report: null });
    switch (event.type) {
    case "started":
        next.started = true;
        break;
    case "stopped":
        next.stopped = true;
        break;
    case "exited":
        next.code = event.code;
        break;
    case "stderr":
        next.errors = event.text;
        break;
    default:
        throw new Error(`unknown process event: ${event.type}`);
    }
    const report = outcome(next, command);
    if (report !== undefined) {
        next.done = true;
        next.report = report;
    }
    return Object.freeze(next);
}

// One run, from its first signal to its last: `on(event)` steps it, logs
// its report through `log` ({warn, log}), calls `then(ok)` exactly once
// when it's done, whether it worked or not (`ok`: it exited 0, which is
// proof it started, whatever order the `started` signal arrives in),
// and returns whether it's done, so the QML can let the Process go.
// Signals after that change nothing.
export function track(command, then, log) {
    let run = initial();
    return {
        on(event) {
            if (run.done) {
                return true;
            }
            run = step(run, event, command);
            if (!run.done) {
                return false;
            }
            if (run.report?.level === "warn") {
                log.warn(run.report.message);
            } else if (run.report?.level === "log") {
                log.log(run.report.message);
            }
            then?.(run.code === 0);
            return true;
        },
    };
}
