pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import "lib/compositor.mjs" as Comp
import "lib/dispatch.mjs" as Dispatch
import "lib/tidewm.mjs" as Tw
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
    // The workspaces, as workspaces.mjs's workspaceOrder takes them:
    // [{id, name}] from Hyprland, a part of a spanning one apiece, or
    // [{id, order, name}] from tidewm, where one spans every monitor.
    readonly property var workspaces: root.tidewm
        ? Comp.tidewmWorkspaces(root.tidewmListed)
        : Hyprland.workspaces.values.map(w => ({ id: w.id, name: w.name }))
    // Each monitor, [{name, workspace}], with the ID of the workspace it
    // shows: on tidewm, the current one, which every monitor shows.
    readonly property var monitors: root.tidewm
        ? Comp.tidewmMonitors(I3.monitors.values.map(m => m.name), Comp.tidewmCurrent(root.tidewmListed))
        : Hyprland.monitors.values.map(m => ({ name: m.name, workspace: m.activeWorkspace ? m.activeWorkspace.id : null }))

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
            workspace: t.workspace ? t.workspace.id : null,
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
            workspace: t.workspace ? t.workspace.id : null,
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

    // Focuses the window at `address`, showing its workspace.
    function focusWindow(address) {
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.focusWindow(address, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.focusCommand(address), `focus window ${address}`);
    }

    // Moves the window at `address` to the workspace named `name`, and
    // focuses it there, as a minimized one is brought back (§6.7).
    function moveWindowTo(address, name) {
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.moveWindowToWorkspace(address, name, Hyprland.usingLua));
            return;
        }
        root.tidewmCommand(Tw.moveAndFocusCommand(address, name), `move window ${address} to workspace ${JSON.stringify(name)}`);
    }

    // Moves the window at `address` to the workspace named `name` without
    // following it: a home app's window sent home, and Super+Shift+1…9.
    function sendWindowTo(address, name) {
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
    function moveWindowToNamed(address, name) {
        if (!root.tidewm) {
            Hyprland.dispatch(Dispatch.moveWindowToNamed(address, name, Hyprland.usingLua));
            return;
        }
        root.moveWindowTo(address, name);
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
    function minimizeWindow(address, name) {
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
    function goToWorkspace(name) {
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
            const ws = Ws.workspaceEvent(event.name, event.data);
            if (ws !== null) {
                root.workspaceEvent(ws);
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
