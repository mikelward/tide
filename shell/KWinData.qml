pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/kwin.mjs" as KWin

// KWin's desktops and windows, for the launcher's Workspaces, Windows and
// Attention tabs on KDE Plasma (SPEC.md §8.5), from KWin's own D-Bus
// through busctl (lib/kwin.mjs), and which windows want attention, from
// what tide on KDE keeps in plasmashell. Read each time the launcher opens,
// as KWin says nothing the launcher could listen to: the desktops, the
// window list and the windows wanting attention at once, then each
// window's app and desktop, in one more process.
Singleton {
    id: root

    // The Windows tab's windows and the Workspaces tab's workspaces, as the
    // launcher lists them; [] until the first read is in.
    property var windows: []
    property var workspaces: []
    // KWin's desktops, [{id, name}], in its order, as last read: the name
    // prompt's workspaces (KWinPromptData).
    property var desktopList: []

    // The read in flight: its desktops and windows as they come in.
    property int generation: 0
    property var desktops: null
    property var matched: null
    property var attention: null

    function refresh() {
        root.generation += 1;
        root.desktops = null;
        root.matched = null;
        root.attention = null;
        desktopsReader.running = false;
        windowsReader.running = false;
        attentionReader.running = false;
        infoReader.running = false;
        desktopsReader.running = true;
        windowsReader.running = true;
        attentionReader.running = true;
    }

    // Brings up the window the runner matched as `match`.
    function activate(match) {
        Launcher.run(KWin.activateCommand(match));
    }

    // Goes to the desktop with ID `id`.
    function goTo(id) {
        Launcher.run(KWin.goCommand(id));
    }

    // Goes to the desktop named `name`, making it after the last if
    // there's none, as Super+Return's prompt does on Hyprland (SPEC.md
    // §8.5). KWin doesn't say which desktop it made, so the desktops are
    // read again to find it.
    function goToNamed(name) {
        const id = KWin.desktopNamed(root.desktopList, name);
        if (id !== null) {
            root.goTo(id);
            return;
        }
        Launcher.run(KWin.createCommand(root.desktopList.length, name), ok => {
            if (ok) {
                namedReader.name = name;
                namedReader.running = true;
            }
        });
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
        if (root.desktops === null || root.matched === null || root.attention === null) {
            return;
        }
        infoReader.generation = root.generation;
        infoReader.uuids = root.matched.map(w => w.uuid);
        infoReader.command = KWin.infoCommand(infoReader.uuids);
        infoReader.running = true;
    }

    function finish(info) {
        root.windows = KWin.launcherWindows(root.matched, info, root.desktops.desktops, root.attention);
        root.workspaces = KWin.launcherWorkspaces(root.desktops.desktops, root.desktops.current, root.matched, info, root.attention);
        const wanting = root.windows.filter(w => w.urgent).length;
        console.log(`tide: launcher: read ${root.windows.length} of KWin's windows, ${wanting} wanting attention, and ${root.workspaces.length} desktops`);
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
                root.desktopList = root.desktops.desktops;
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
        id: attentionReader

        property int generation: 0

        command: KWin.ATTENTION_COMMAND
        onRunningChanged: if (running) {
            generation = root.generation;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                if (attentionReader.generation !== root.generation) {
                    return;
                }
                // Without plasmashell, or tide on KDE, none: the other tabs fill in all the same
                root.attention = text.trim() === "" ? [] : root.parsed("windows wanting attention", () => KWin.parseAttention(text)) ?? [];
                root.readInfo();
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") {
                console.warn(`tide: busctl couldn't ask plasmashell which windows want attention: ${text.trim()}`);
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

    // The desktops again, once goToNamed made one, to go to it.
    Process {
        id: namedReader

        property string name: ""

        command: KWin.DESKTOPS_COMMAND
        stdout: StdioCollector {
            onStreamFinished: {
                const read = root.parsed("desktops", () => KWin.parseDesktops(text));
                if (read === null) {
                    return;
                }
                root.desktopList = read.desktops;
                const id = KWin.desktopNamed(read.desktops, namedReader.name);
                if (id === null) {
                    console.warn(`tide: KWin made no desktop named ${JSON.stringify(namedReader.name)}, so there's none to go to`);
                    return;
                }
                root.goTo(id);
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") {
                console.warn(`tide: busctl couldn't ask KWin for its desktops: ${text.trim()}`);
            }
        }
    }
}
