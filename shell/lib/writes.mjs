// Writing a settings file another program reads, and having it read it
// (SPEC.md §16.1), as pure state the QML drives. A write or an apply that
// fails stays pending: the caller reports it and tries again, rather than
// taking it as done.
//
// Each function returns the new state, and those that move it on also
// what to do now, if anything.

// The file another program reads, and the command that has it read it
// again (an apply).
//   wanted: what the file should say (null until the settings are in).
//   onDisk: what it says, as last read or written (null: no file).
//   applied: what the program last read.
//   known: whether the file has been read yet. Until it has, nothing is
//     written over it.
//   step: "", "writing" or "applying".
//   writing: the text being written.
//   failure: why the last write or apply failed, or "".
export const TARGET = Object.freeze({ wanted: null, onDisk: null, applied: null, known: false, step: "", writing: null, failure: "" });

// The next write or apply, if one is due and none is in flight: a write
// when the file says something else, then an apply when the program
// hasn't read what it says. With nothing left to do, nothing has failed.
function nextStep(state) {
    if (!state.known || state.step !== "" || state.wanted === null) {
        return { state, action: null };
    }
    if (state.wanted !== state.onDisk) {
        return { state: Object.assign({}, state, { step: "writing", writing: state.wanted }), action: { write: state.wanted } };
    }
    if (state.wanted !== state.applied) {
        return { state: Object.assign({}, state, { step: "applying" }), action: { apply: true } };
    }
    return { state: state.failure === "" ? state : Object.assign({}, state, { failure: "" }), action: null };
}

// The file was read. The first time, what it says is what the program
// has, since it read it as it started: a shell start that wants the same
// leaves the program alone. Unless it couldn't be read before this (the
// only failure there can be until it is): then the program couldn't
// either, and has none of it. Or unless `reapply`, for a program that
// outlives the shell and costs nothing to apply again: then the shell
// applies it as it starts, in case the one before it died with an apply
// still to retry.
export function readTarget(state, text, reapply = false) {
    const first = state.known ? {} : { applied: state.failure === "" && !reapply ? text : null, known: true };
    return { state: Object.assign({}, state, { onDisk: text }, first) };
}

// The file couldn't be read (permissions, say). Nothing is written over
// it until it's read; the caller reads it again on its retry.
export function targetUnreadable(state, error) {
    return { state: Object.assign({}, state, { failure: error }), action: null };
}

// The settings say the file should be `text`.
export function wantTarget(state, text) {
    return nextStep(Object.assign({}, state, { wanted: text }));
}

// The write is done (`error` "") or failed. A failed one leaves the file
// as it was, and waits for the caller's retry or a change.
export function targetWritten(state, error) {
    if (error) {
        return { state: Object.assign({}, state, { step: "", writing: null, failure: error }), action: null };
    }
    return nextStep(Object.assign({}, state, { step: "", onDisk: state.writing, writing: null }));
}

// The apply is done (`error` "") or failed, as targetWritten.
export function targetApplied(state, error) {
    if (error) {
        return { state: Object.assign({}, state, { step: "", failure: error }), action: null };
    }
    return nextStep(Object.assign({}, state, { step: "", applied: state.onDisk }));
}
