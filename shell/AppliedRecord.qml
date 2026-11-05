import QtQuick
import Quickshell
import "lib/writes.mjs" as Writes

// This session's record of what a program last read of a settings file the
// shell writes (shell/lib/writes.mjs's firstApplied): for a program that
// outlives the shell, and that an apply costs something, as hypridle's
// restart (IdleData) or tidewm's reload (InputData, AppearanceData). Kept in
// $XDG_RUNTIME_DIR, so a new login, and so a new program, starts without
// one. Without it, a shell that died with an apply still to retry would
// leave its successor taking the file for what the program has.
Scope {
    id: root

    // The record's file name in $XDG_RUNTIME_DIR.
    required property string name
    // What the shell does when it can't tell, for the log: "restarting
    // hypridle to be sure it has its timings", say.
    required property string unsure
    // What a record that can't be written costs, for the log.
    required property string again

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""

    // What the program has as the shell first reads its file, `text`, for
    // Writes.readTarget: what this session's record says, else the file,
    // which the program read as it started, recorded now. A record that
    // can't be read or written says nothing (null), so the shell applies to
    // be sure; so does a file that couldn't be read until now (`failure`,
    // the target's), which the program couldn't either.
    function firstApplied(text, failure) {
        if (failure !== "") {
            return null;
        }
        if (root.runtimeDir === "") {
            return text;
        }
        const recordedText = recorded.readNow();
        if (recorded.broken !== "") {
            console.warn(`tide: ${recorded.broken}; ${root.unsure}`);
            return null;
        }
        const first = Writes.firstApplied(text, recordedText);
        return Writes.afterRecord(first, first.record === null || root.record(first.record));
    }

    // Records what the program has now, returning whether it could. One
    // that can't be written is logged: it only costs another apply if this
    // shell dies with one still to retry.
    function record(text) {
        if (root.runtimeDir === "") {
            return true;
        }
        const error = recorded.writeNow(text);
        if (error !== "") {
            console.warn(`tide: ${error}; ${root.again}`);
            return false;
        }
        return true;
    }

    SettingsFile {
        id: recorded

        path: root.runtimeDir === "" ? "" : `${root.runtimeDir}/${root.name}`
    }
}
