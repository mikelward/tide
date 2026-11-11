import QtQuick
import Quickshell
import Quickshell.Io
import "lib/appearance.mjs" as Appearance

// A user's look, as their shell keeps it for the greeter and the splash
// (SPEC.md §11, §15): their light and dark schedule and wallpapers, in the
// folder `setup` makes for them (Appearance.lookDir), since their home is
// theirs alone. None there, or one that can't be read, is null: the face's
// own dark gradient. Light or dark is worked out again each minute.
Item {
    id: root

    // Whose look, and the name to log trouble under.
    property string user: ""
    property string name: "tide"

    readonly property string dir: Appearance.lookDir(Quickshell.env("TIDE_LOOK_DIR") || "", root.user)
    property var look: null
    property real now: Date.now()
    // {dark, path, color, position} (Appearance.lookAt), or null.
    readonly property var shown: root.look === null ? null : Appearance.lookAt(root.look, root.now, root.dir)

    FileView {
        path: root.dir === "" ? "" : `${root.dir}/look.json`
        printErrors: false
        onLoaded: {
            const r = Appearance.parseLook(text());
            if (r.error) {
                console.warn(`${root.name}: ${path}: ${r.error}; showing the default look`);
            }
            root.look = r.look ?? null;
            root.now = Date.now();
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) {
                console.warn(`${root.name}: ${path}: ${FileViewError.toString(error)}; showing the default look`);
            }
            root.look = null;
        }
    }

    Timer {
        interval: 60 * 1000
        repeat: true
        running: root.look !== null
        onTriggered: root.now = Date.now()
    }
}
