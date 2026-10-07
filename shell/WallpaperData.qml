pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/appearance.mjs" as Appearance

// The wallpaper the shell draws (SPEC.md §15): the first of
// Appearance.wallpaperCandidates that can be read, for light or dark as it
// is now, looked for again whenever either changes. With none, the shell
// draws no wallpaper.
//
// The lock draws the same one, blurred, from the record this keeps in the
// session's runtime directory: so the two agree without the lock working
// out light or dark, or the settings, itself.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property var candidates: AppearanceData.loaded ? Appearance.wallpaperCandidates(AppearanceData.settings, AppearanceData.dark, root.home, Quickshell.env("TIDE_WALLPAPER") || "") : []
    // The file to draw, or "" for none.
    property string path: ""
    // What the shell found it couldn't draw (Wallpaper.qml), a corrupt
    // image say, passed over for the next until the candidates change.
    property var undrawable: []
    readonly property var drawable: Appearance.drawableCandidates(root.candidates, root.undrawable)
    // Each lookup's number, so one that finishes after a newer one started
    // is dropped.
    property int generation: 0
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""

    onCandidatesChanged: {
        root.undrawable = [];
        root.find();
    }

    // Passes over `path`, the one drawn, for the next candidate: Image
    // couldn't load it. Each monitor's window says so; once is enough.
    function cantDraw(path) {
        if (path === "" || path !== root.path || root.undrawable.includes(path)) {
            return;
        }
        root.undrawable = root.undrawable.concat([path]);
        root.find();
    }

    function find() {
        root.generation++;
        if (root.drawable.length === 0) {
            root.show("");
            return;
        }
        finder.createObject(root, {
            generation: root.generation,
            command: Appearance.findCommand(root.drawable)
        }).running = true;
    }

    function found(lookup, code, text) {
        if (lookup.generation !== root.generation) {
            return; // superseded
        }
        if (code === 0 && text !== "") {
            root.show(text);
            return;
        }
        // Nothing to draw is a setup without a wallpaper, not an error.
        console.log(`tide: no wallpaper: none of ${root.drawable.join(", ")} can be read`);
        root.show("");
    }

    // Draws `path`, or none, and records it for the lock: each time, not
    // only on a change, so a shell restarted with none still clears the
    // last shell's. One that can't be recorded is logged; the lock shows
    // the last one recorded, or none.
    function show(path) {
        root.path = path;
        if (root.runtimeDir === "") {
            return;
        }
        const text = Appearance.wallpaperRecord(path);
        if (record.readNow() === text) {
            return;
        }
        const error = record.writeNow(text);
        if (error !== "") {
            console.warn(`tide: ${error}; the lock may show another wallpaper`);
        }
    }

    // The lock's record (lock.qml).
    SettingsFile {
        id: record

        path: root.runtimeDir === "" ? "" : `${root.runtimeDir}/tide-wallpaper`
    }

    Component {
        id: finder

        Process {
            id: run

            property int generation: 0

            stdout: StdioCollector {
                id: out
            }
            onExited: (code, status) => {
                root.found(run, code, out.text);
                destroy();
            }
        }
    }
}
