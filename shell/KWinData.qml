pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/kwin.mjs" as KWin

// KWin's desktops and windows, for the launcher's Workspaces and Windows
// tabs on KDE Plasma (SPEC.md §8.5), from KWin's own D-Bus through busctl
// (lib/kwin.mjs). Read each time the launcher opens, as KWin says nothing
// the launcher could listen to: the desktops and the window list at once,
// then each window's app and desktop, in one more process.
Singleton {
    id: root

    // The Windows tab's windows and the Workspaces tab's workspaces, as the
    // launcher lists them; [] until the first read is in.
    property var windows: []
    property var workspaces: []

    // The read in flight: its desktops and windows as they come in.
    property int generation: 0
    property var desktops: null
    property var matched: null

    function refresh() {
        root.generation += 1;
        root.desktops = null;
        root.matched = null;
        desktopsReader.running = false;
        windowsReader.running = false;
        infoReader.running = false;
        desktopsReader.running = true;
        windowsReader.running = true;
    }

    // Brings up the window the runner matched as `match`.
    function activate(match) {
        Launcher.run(KWin.activateCommand(match));
    }

    // Goes to the desktop with ID `id`.
    function goTo(id) {
        Launcher.run(KWin.goCommand(id));
    }

    function parsed(what, read) {
        try {
            return read();
        } catch (e) {
            console.warn(`tide: couldn't read KWin's ${what}, so the launcher lists none: ${e}`);
            return null;
        }
    }

    function readInfo() {
        if (root.desktops === null || root.matched === null) {
            return;
        }
        infoReader.generation = root.generation;
        infoReader.uuids = root.matched.map(w => w.uuid);
        infoReader.command = KWin.infoCommand(infoReader.uuids);
        infoReader.running = true;
    }

    function finish(info) {
        root.windows = KWin.launcherWindows(root.matched, info, root.desktops.desktops);
        root.workspaces = KWin.launcherWorkspaces(root.desktops.desktops, root.desktops.current, root.matched, info);
        console.log(`tide: launcher: read ${root.windows.length} of KWin's windows and ${root.workspaces.length} desktops`);
    }

    Process {
        id: desktopsReader

        property int generation: 0

        command: KWin.DESKTOPS_COMMAND
        onRunningChanged: if (running) {
            generation = root.generation;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (desktopsReader.generation !== root.generation) {
                    return;
                }
                root.desktops = root.parsed("desktops", () => KWin.parseDesktops(text)) ?? { desktops: [], current: null };
                root.readInfo();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") {
                console.warn(`tide: busctl couldn't ask KWin for its desktops: ${text.trim()}`);
            }
        }
    }

    Process {
        id: windowsReader

        property int generation: 0

        command: KWin.WINDOWS_COMMAND
        onRunningChanged: if (running) {
            generation = root.generation;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (windowsReader.generation !== root.generation) {
                    return;
                }
                root.matched = root.parsed("windows", () => KWin.parseWindows(text)) ?? [];
                root.readInfo();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") {
                console.warn(`tide: busctl couldn't ask KWin for its windows: ${text.trim()}`);
            }
        }
    }

    Process {
        id: infoReader

        property int generation: 0
        property var uuids: []

        stdout: StdioCollector {
            onStreamFinished: {
                if (infoReader.generation !== root.generation) {
                    return;
                }
                root.finish(root.parsed("windows' details", () => KWin.parseInfo(text, infoReader.uuids)) ?? {});
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") {
                console.warn(`tide: busctl couldn't ask KWin about a window: ${text.trim()}`);
            }
        }
    }
}
