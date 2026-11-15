import QtQuick
import Quickshell
import Quickshell.Io
import "lib/kdeborders.mjs" as Borders

// The Borders settings on KDE Plasma (SPEC.md §8.5), from
// shell/lib/kdeborders.mjs: tide's window decoration there (tide on KDE's,
// org.tide.decoration) reads them from kwinrc, so as Plasma's session
// starts, and each time appearance.json or appearance.local.json changes,
// this writes them there and has KWin read its settings again. Only while
// KWin's decoration is tide's; otherwise it writes nothing.
Scope {
    id: root

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${Quickshell.env("HOME")}/.config`
    // One run at a time, and a change during one runs once it ends, so the
    // last run always has the files as they are (Borders.next).
    property var applying: Borders.IDLE
    // Whether both files can be read now. One that can't is taken for
    // neither missing nor empty: the decoration keeps what it has.
    readonly property bool readable: shared.broken === "" && local.broken === ""

    function textOf(file) {
        // A missing file is the defaults' cue, not an error.
        return file.loaded ? file.text() : null;
    }

    function changed() {
        // Both files' first loads are in before anything is written, so the
        // shared settings aren't written before the local ones replace them.
        if (!shared.settled || !local.settled) {
            return;
        }
        root.step("change");
    }

    // A run starts only on files that can be read, whether it's a change's
    // own or one held during the run before it.
    function step(type) {
        const r = Borders.next(root.applying, { type: type, readable: root.readable });
        root.applying = r.state;
        if (r.start) {
            root.apply();
        }
    }

    function apply() {
        const found = Borders.borders([["appearance.json", root.textOf(shared)], ["appearance.local.json", root.textOf(local)]]);
        for (const error of found.errors) {
            console.warn(`tide: ${error}; tide's decoration on Plasma gets tide's default`);
        }
        // Launcher logs what the command says it did, or why it failed;
        // either way the next change gets its turn.
        Launcher.run(Borders.applyCommand(found.settings), () => root.step("done"), null, Borders.SHOWN);
    }

    FileView {
        id: shared

        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Whether its first load has finished, either way.
        property bool settled: false

        path: `${root.configHome}/tide/appearance.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            broken = "";
            settled = true;
            root.changed();
        }
        onLoadFailed: error => {
            settled = true;
            broken = error === FileViewError.FileNotFound ? "" : `${path}: ${FileViewError.toString(error)}`;
            if (broken !== "") {
                console.warn(`tide: ${broken}; tide's decoration on Plasma keeps its settings`);
            }
            root.changed();
        }
    }

    FileView {
        id: local

        // Why it can't be read, or "" when it can (or doesn't exist).
        property string broken: ""
        // Whether its first load has finished, either way.
        property bool settled: false

        path: `${root.configHome}/tide/appearance.local.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            broken = "";
            settled = true;
            root.changed();
        }
        onLoadFailed: error => {
            settled = true;
            broken = error === FileViewError.FileNotFound ? "" : `${path}: ${FileViewError.toString(error)}`;
            if (broken !== "") {
                console.warn(`tide: ${broken}; tide's decoration on Plasma keeps its settings`);
            }
            root.changed();
        }
    }
}
