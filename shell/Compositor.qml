pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import Quickshell.Io
import "lib/compositor.mjs" as Comp
import "lib/dispatch.mjs" as Dispatch
import "lib/tidewm.mjs" as Tw
import "lib/why.mjs" as Why
import "lib/workspaces.mjs" as Ws

// What the shell asks of the compositor the session runs (SPEC.md §5.3):
// Hyprland's, the default, through Quickshell's Hyprland module, or
// tidewm's, through its I3 module, which speaks sway's IPC as tidewm does.
// Each binding reads only the one in use, so the other isn't asked. It
// says which monitor has focus, for the popups, prompts and launcher that
// open there, which workspaces there are, for the bar, the switcher and
// the name prompt, and goes to and renames them, and which windows there
// are and which has focus, for the bar's icons and title and the
// switcher, and focuses, moves, closes, minimizes and maximizes one.
Singleton {
    id: root

    readonly property bool tidewm: Comp.isTidewm(Quickshell.env("XDG_CURRENT_DESKTOP"))
    // Whether tidewm's session runs tidesway, which rounds corners.
    readonly property bool tidesway: Comp.isTidesway(Quickshell.env("XDG_CURRENT_DESKTOP"))
    // The focused monitor's name, its Wayland output's, or "" before one
    // has focus. tidewm says when focus moves to another monitor in an
    // output event, which has the I3 module ask for the outputs again.
    readonly property string focusedMonitorName: (root.tidewm ? I3.focusedMonitor?.name : Hyprland.focusedMonitor?.name) ?? ""
    // The screen of the focused monitor, or null.
    readonly property var focusedScreen: Comp.screenNamed(Quickshell.screens, root.focusedMonitorName)

    // tidewm's workspaces as its GET_WORKSPACES gives them, or [] on
    // Hyprland.
    readonly property var tidewmListed: root.tidewm ? I3.workspaces.values.map(w => w.lastIpcObject) : []
    // tidewm's outputs as its GET_OUTPUTS gives them, or [] on Hyprland.
    readonly property var tidewmOutputs: root.tidewm ? I3.monitors.values.map(m => m.lastIpcObject) : []
    // Hyprland's workspaces' keys (Ws.workspaceKey) in the order they were
    // made, as `hyprctl workspaces -j` lists them (Ws.madeOrder), for the
    // order of named workspaces, which have no ID from Hyprland 0.57. It's
    // read as the shell starts and each time a workspace is made or goes.
    property var made: []
    // The workspaces, as workspaces.mjs's workspaceOrder takes them:
    // [{id, order, name}] from Hyprland, a part of a spanning one apiece,
    // `id` being its key (Ws.hyprlandWorkspaces), or from tidewm, where one
    // spans every monitor.
    readonly property var workspaces: root.tidewm
        ? Comp.tidewmWorkspaces(root.tidewmListed)
        : Ws.hyprlandWorkspaces(Hyprland.workspaces.values.map(w => ({ address: w.address, id: w.id, name: w.name })), root.made)
    // Each monitor, [{name, workspace}], with the ID of the workspace it
    // shows (Hyprland's key): on tidewm, the current one, which every
    // monitor shows.
    readonly property var monitors: root.tidewm
        ? Comp.tidewmMonitors(I3.monitors.values.map(m => m.name), Comp.tidewmCurrent(root.tidewmListed))
        : Hyprland.monitors.values.map(m => ({ name: m.name, workspace: m.activeWorkspace ? Ws.workspaceKey(m.activeWorkspace) : null }))

    // The current workspace's name on tidewm, which every monitor shows.
    readonly property string tidewmCurrentName: root.tidewm ? (root.tidewmListed.find(w => w?.focused === true)?.name ?? "") : ""

    // The windows the bar draws, [{address, workspace, workspaceName, app,
    // urgent, fullscreen}] (workspaces.mjs's barWorkspaces), apart from
    // `windows` so Hyprland's title changes don't redraw the bar.
    readonly property var barWindows: root.tidewm
        ? Tw.shellWindows(TidewmData.state, root.workspaces).map(w => ({
            address: w.address,
            workspace: w.workspace,
            workspaceName: w.workspaceName,
            app: w.app,
            urgent: w.urgent,
            fullscreen: w.fullscreen
        }))
        : Hyprland.toplevels.values.map(t => ({
            address: Ws.normalizeAddress(t.address),
            workspace: t.workspace ? Ws.workspaceKey(t.workspace) : null,
            workspaceName: t.workspace?.name ?? "",
            app: t.lastIpcObject?.class || t.wayland?.appId || "",
            urgent: t.urgent,
            fullscreen: t.lastIpcObject?.fullscreen ?? 0
        }))
    // Every window, [{address, title, app, workspace, workspaceName,
    // monitor, urgent, fullscreen, floating, focusHistoryID}], with its
    // title and its place in the focus history (Tw.shellWindows).
    readonly property var windows: root.tidewm
        ? Tw.shellWindows(TidewmData.state, root.workspaces)
        : Hyprland.toplevels.values.map(t => ({
            address: Ws.normalizeAddress(t.address),
            title: t.title ?? "",
            app: t.lastIpcObject?.class || t.wayland?.appId || "",
            workspace: t.workspace ? Ws.workspaceKey(t.workspace) : null,
            workspaceName: t.workspace?.name ?? "",
            monitor: t.monitor?.name ?? "",
            urgent: t.urgent,
            fullscreen: t.lastIpcObject?.fullscreen ?? 0,
            floating: t.lastIpcObject?.floating === true,
            focusHistoryID: t.lastIpcObject?.focusHistoryID ?? -1
        }))
    // The focused window on tidewm, one of `windows`, or null. Hyprland's
    // is FocusData's, which knows Hyprland's quirks.
    readonly property var tidewmActive: root.tidewm ? Tw.activeWindow(root.windows, root.tidewmCurrentName) : null

    // Says in the journal why the shell asked for a move (SPEC.md §5.4,
    // Reporting a bug): `why` names what asked, "the bar" or "the
    // switcher", for `tide report-bug`.
    function said(what, why) {
        console.log(Why.line(what, why || "the shell"));
    }

    // Focuses the window at `address`, showing its workspace.
    function focusWindow(address, why) {
        root.said(`focus ${address}`, why);
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.focusWindow(address, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.focusCommand(address), `focus window ${address}`);
    }

    // Moves the window at `address` to the workspace named `name`, and
    // focuses it there, as a minimized one is brought back (§6.7).
    function moveWindowTo(address, name, why) {
        root.said(`move ${address} to workspace ${name}, following it`, why);
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.moveWindowToWorkspace(address, name, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.moveAndFocusCommand(address, name), `move window ${address} to workspace ${JSON.stringify(name)}`);
    }

    // Moves the window at `address` to the workspace named `name` without
    // following it: a home app's window sent home, and Super+Shift+1…9.
    function sendWindowTo(address, name, why) {
        root.said(`move ${address} to workspace ${name}`, why);
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.sendWindowTo(address, name, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.sendCommand(address, name), `send window ${address} to workspace ${JSON.stringify(name)}`);
    }

    // Moves the window at `address` to tide's workspace named `name`, made
    // if it's new, and follows it there, focused: the name prompt's Enter
    // (§6.5). On Hyprland it goes through conf's move, which puts it in
    // the workspace's part on the window's own monitor
    // (Dispatch.moveWindowToNamed); a tidewm workspace spans every monitor
    // already, so it's moveWindowTo's.
    function moveWindowToNamed(address, name, why) {
        if (!root.tidewm) {
            root.said(`move ${address} to workspace ${name}, following it`, why);
            Hyprland.dispatch(Dispatch.moveWindowToNamed(address, name, Hyprland.usingLua));
            return;
        }
        root.moveWindowTo(address, name, why);
    }

    // Asks the window at `address` to close, as Super+Backspace does.
    function closeWindow(address) {
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.closeWindow(address, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.closeCommand(address), `close window ${address}`);
    }

    // Minimizes the window at `address` from the workspace named `name`
    // (§6.7): on Hyprland, to that workspace's minimize workspace
    // (Dispatch.minimizeWindow); on tidewm, by its own minimize, which
    // keeps the window on its workspace, hidden. Either way moveWindowTo
    // back to `name` restores it.
    function minimizeWindow(address, name, why) {
        root.said(`minimize ${address} from workspace ${name}`, why);
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.minimizeWindow(address, name, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.minimizeCommand(address), `minimize window ${address}`);
    }

    // Sends the window at `address` the shortcut `mods` + `key`, in
    // Hyprland's spelling, "CTRL SHIFT" and "V", whatever has the keyboard:
    // the picker's paste (§8.4).
    function sendShortcut(address, mods, key) {
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.sendShortcut(mods, key, address, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.shortcutCommand(address, mods, key), `send window ${address} ${mods} ${key}`);
    }

    // Toggles maximize on the window at `address`, which is the focused
    // one: Hyprland's dispatcher takes no address.
    function toggleMaximize(address) {
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.toggleMaximize(Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.maximizeCommand(address), `maximize window ${address}`);
    }

    function tidewmCommand(command, what) {
        if (command === null) {
            console.warn(`tide: tidewm can't be asked to ${what}: no container ID, or a name with a ", which tidewm's quotes can't hold`);
            return;
        }
        I3.dispatch(command);
    }

    // A workspace was made, went or was renamed: {type, id, name}, type
    // "created", "destroyed" or "renamed", as workspaces.mjs's
    // workspaceEvent reads Hyprland's.
    signal workspaceEvent(var event)

    // Goes to the workspace named `name`, which the compositor makes if
    // it's new: on Hyprland as Dispatch.focusWorkspaceName says.
    function goToWorkspace(name, why) {
        root.said(`go to workspace ${name}`, why);
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.focusWorkspaceName(name, Hyprland.usingLua));
            return;
        }
        const command = Comp.tidewmGoTo(name);
        if (command === null) {
            console.warn(`tide: tidewm can't be asked to go to workspace ${JSON.stringify(name)}: tidewm's quotes can't hold a "`);
            return;
        }
        I3.dispatch(command);
    }

    // Renames workspace `id`, named `from`, to `to`.
    function renameWorkspace(id, from, to) {
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.renameWorkspace(id, to, Hyprland.usingLua));
            return;
        }
        const command = Comp.tidewmRename(from, to);
        if (command === null) {
            console.warn(`tide: tidewm can't be asked to rename workspace ${JSON.stringify(from)} to ${JSON.stringify(to)}: tidewm's quotes can't hold a "`);
            return;
        }
        I3.dispatch(command);
    }

    Connections {
        target: root.tidewm ? null : Hyprland

        function onRawEvent(event) {
            const ws = Ws.workspaceEvent(event.name, event.data, root.workspaces.map(w => w.id).concat(root.made));
            if (ws === null) {
                return;
            }
            if (ws.ambiguous) {
                // Settled by the next list Hyprland gives (Ws.resolvedEvent).
                root.unsettled = root.unsettled.concat([ws]);
                root.readMade();
                return;
            }
            if (ws.type !== "renamed") {
                root.readMade();
            }
            root.workspaceEvent(ws);
        }
    }

    // Workspace events more than one known workspace fits, waiting for a
    // read of the list that starts after them (Ws.workspaceEvent).
    property var unsettled: []

    // Reads `made` again, and settles the unsettled events with the list. A
    // read that fails keeps the last `made`, which orders the workspaces
    // made since after the rest (Ws.hyprlandWorkspaces).
    function readMade() {
        if (root.tidewm) {
            return;
        }
        if (madeReader.running) {
            madeReader.again = true;
            return;
        }
        madeReader.settling = root.unsettled;
        root.unsettled = [];
        madeReader.started = false;
        madeReader.running = true;
    }

    // The events a read settles, the list it gave, or null for none.
    function settle(events, listed) {
        for (const e of events) {
            const ws = listed === null ? null : Ws.resolvedEvent(e, listed);
            if (ws === null) {
                console.warn(`tide: couldn't tell which workspace a ${e.type} event was for: more than one workspace's name begins the event's text, and Hyprland's list didn't settle it`);
                continue;
            }
            root.workspaceEvent(ws);
        }
    }

    Component.onCompleted: root.readMade()

    Process {
        id: madeReader

        // Another read was asked for while this one ran.
        property bool again: false
        // Quickshell reports a command that can't start (no hyprctl on
        // PATH) only by stopping without `started` (shell/lib/launch.mjs).
        property bool started: false
        // The unsettled events this read settles: by its list once its
        // output ends, or by none if it fails, whichever comes first.
        property var settling: []

        function settleWith(listed) {
            const events = madeReader.settling;
            madeReader.settling = [];
            root.settle(events, listed);
        }

        command: ["hyprctl", "workspaces", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let listed = null;
                try {
                    listed = JSON.parse(text);
                    root.made = Ws.madeOrder(listed);
                } catch (e) {
                    console.warn(`tide: couldn't run hyprctl workspaces: its list isn't JSON (${e.message}), so new named workspaces may be out of order on the bar`);
                }
                madeReader.settleWith(listed);
            }
        }
        onStarted: madeReader.started = true
        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: couldn't run hyprctl workspaces: it exited ${code}, so new named workspaces may be out of order on the bar`);
                madeReader.settleWith(null);
            }
            if (madeReader.again) {
                madeReader.again = false;
                root.readMade();
            }
        }
        onRunningChanged: {
            if (madeReader.running || madeReader.started) {
                return;
            }
            console.warn("tide: couldn't start hyprctl workspaces, so new named workspaces may be out of order on the bar");
            madeReader.settleWith(null);
            if (madeReader.again) {
                madeReader.again = false;
                root.readMade();
            }
        }
    }

    Connections {
        target: root.tidewm ? I3 : null

        function onRawEvent(event) {
            if (event.type !== "workspace") {
                return;
            }
            const ws = Comp.tidewmWorkspaceEvent(event.data);
            if (ws === null) {
                return;
            }
            // The I3 module looks a renamed workspace up by its new name,
            // which it doesn't have yet, so it keeps the old one until it
            // asks for the list again.
            if (ws.type === "renamed") {
                I3.refreshWorkspaces();
            }
            root.workspaceEvent(ws);
        }
    }
}
