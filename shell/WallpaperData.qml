pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/appearance.mjs" as Appearance

// The wallpaper the shell draws (SPEC.md §15): the first of
// Appearance.wallpaperCandidates that can be read, for light or dark as it
// is now, looked for again whenever either changes. With none, the shell
// draws no wallpaper.
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
            root.path = "";
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
            root.path = text;
            return;
        }
        // Nothing to draw is a setup without a wallpaper, not an error.
        console.log(`tide: no wallpaper: none of ${root.drawable.join(", ")} can be read`);
        root.path = "";
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
