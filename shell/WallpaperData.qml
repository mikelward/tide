pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/appearance.mjs" as Appearance

// The wallpaper the shell draws (SPEC.md §15): the first of
// Appearance.wallpaperCandidates that can be read, for light or dark as it
// is now, looked for again whenever either changes. A color set for the
// mode is the only candidate, drawn as it is, with no lookup. With none,
// the shell draws no wallpaper.
//
// The lock draws the same one, a picture blurred, from the record this
// keeps in the session's runtime directory: so the two agree without the
// lock working out light or dark, or the settings, itself.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property var candidates: AppearanceData.loaded ? Appearance.wallpaperCandidates(AppearanceData.settings, AppearanceData.dark, root.home, Quickshell.env("TIDE_WALLPAPER") || "") : []
    // The file to draw, or "" for none or a color.
    property string path: ""
    // The color to fill with, as #rrggbb, or "" for none or a file.
    property string color: ""
    // How the mode's picture is placed (Appearance.POSITIONS).
    readonly property string position: Appearance.wallpaperPosition(AppearanceData.settings, AppearanceData.dark)
    // What show() last drew, a file, a color or "", once it has.
    property string shown: ""
    property bool showing: false
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
    // The lock frames the picture as the shell does.
    onPositionChanged: {
        if (root.showing) {
            root.writeRecord();
        }
    }
    // And its face is light or dark as the shell is (SPEC.md §10), even
    // when both modes draw the same picture.
    Connections {
        target: AppearanceData

        function onDarkChanged() {
            if (root.showing) {
                root.writeRecord();
            }
        }
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
        if (Appearance.wallpaperColor(root.drawable[0]) !== "") {
            root.show(root.drawable[0]);
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

    // Draws `wallpaper`, a file or a color, or none, and records it for the
    // lock: each time, not only on a change, so a shell restarted with none
    // still clears the last shell's.
    function show(wallpaper) {
        root.color = Appearance.wallpaperColor(wallpaper);
        root.path = root.color === "" ? wallpaper : "";
        root.shown = wallpaper;
        root.showing = true;
        root.writeRecord();
    }

    // Records what's drawn, its position, and light or dark, for the lock. One that can't
    // be recorded is logged; the lock shows the last one recorded, or none.
    function writeRecord() {
        if (root.runtimeDir === "") {
            return;
        }
        const text = Appearance.wallpaperRecord(root.shown, root.position, AppearanceData.dark);
        if (record.readNow() === text) {
            return;
        }
        const error = record.writeNow(text);
        if (error !== "") {
            console.warn(`tide: ${error}; the lock may show another wallpaper`);
        }
    }

    // The greeter's copy of this user's look (SPEC.md §11): each mode's
    // wallpaper and the settings that decide light or dark, in the folder
    // `setup` makes for the user under /var/lib/tide/look, which the
    // greeter, as greetd's own user, can read where it can't read the home.
    // Copied again whenever the settings or the candidates change. With no
    // folder there, it's said once and the greeter keeps its own look.
    readonly property string lookDir: Appearance.lookDir(Quickshell.env("TIDE_LOOK_DIR") || "", Quickshell.env("USER") || "")
    readonly property var lightCandidates: AppearanceData.loaded ? Appearance.wallpaperCandidates(AppearanceData.settings, false, root.home, Quickshell.env("TIDE_WALLPAPER") || "") : []
    readonly property var darkCandidates: AppearanceData.loaded ? Appearance.wallpaperCandidates(AppearanceData.settings, true, root.home, Quickshell.env("TIDE_WALLPAPER") || "") : []
    readonly property string lookKey: AppearanceData.loaded ? JSON.stringify([AppearanceData.settings, root.lightCandidates, root.darkCandidates]) : ""
    property bool lookMissingSaid: false
    // One copy at a time (Appearance.tellNext, as the theme's commands
    // are): a change while one runs is copied again once it's done, so an
    // older copy can't finish last over a newer one.
    property var looking: Appearance.TELL_IDLE

    onLookKeyChanged: Qt.callLater(root.lookStep, "change")

    function lookStep(event) {
        const r = Appearance.tellNext(root.looking, event);
        root.looking = r.state;
        if (r.start) {
            root.exportLook();
        }
    }

    function exportLook() {
        if (root.lookKey === "" || root.lookDir === "") {
            root.lookStep("done");
            return;
        }
        looker.createObject(root, {
            settings: AppearanceData.settings,
            light: root.lightCandidates,
            dark: root.darkCandidates,
            command: Appearance.lookCommand(root.lookDir, root.lightCandidates, root.darkCandidates)
        }).running = true;
    }

    function lookCopied(run, code, text, errors) {
        // Settings that changed meanwhile are copied now, and written then.
        if (root.looking.again) {
            root.lookStep("done");
            return;
        }
        root.lookWrite(run, code, text, errors);
    }

    function lookWrite(run, code, text, errors) {
        if (code === 2) {
            if (!root.lookMissingSaid) {
                root.lookMissingSaid = true;
                console.log(`tide: no ${root.lookDir} to keep your look in, so the greeter shows its own; setup makes it`);
            }
            root.lookStep("done");
            return;
        }
        if (code !== 0) {
            console.warn(`tide: couldn't copy your wallpaper to ${root.lookDir}, so the greeter may show another: ${errors.trim()}`);
        }
        // Written by a command, not a FileView, so it's readable by the
        // greeter whatever the umask; the next copy waits for it.
        lookWriter.createObject(root, {
            command: Appearance.lookWriteCommand(root.lookDir, Appearance.lookJson(run.settings, run.light, run.dark, Appearance.lookCopied(text)))
        }).running = true;
    }

    Component {
        id: lookWriter

        Process {
            id: writeRun

            stderr: StdioCollector {
                id: writeErr
            }
            onExited: (code, status) => {
                if (code !== 0) {
                    console.warn(`tide: couldn't write ${root.lookDir}/look.json, so the greeter may show another look: ${writeErr.text.trim()}`);
                }
                root.lookStep("done");
                destroy();
            }
        }
    }

    Component {
        id: looker

        Process {
            id: lookRun

            property var settings: ({})
            property var light: []
            property var dark: []

            stdout: StdioCollector {
                id: lookOut
            }
            stderr: StdioCollector {
                id: lookErr
            }
            onExited: (code, status) => {
                root.lookCopied(lookRun, code, lookOut.text, lookErr.text);
                destroy();
            }
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
