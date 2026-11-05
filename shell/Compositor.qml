pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.I3
import "lib/compositor.mjs" as Comp
import "lib/dispatch.mjs" as Dispatch
import "lib/workspaces.mjs" as Ws

// What the shell asks of the compositor the session runs (SPEC.md §5.3):
// Hyprland's, the default, through Quickshell's Hyprland module, or
// tidewm's, through its I3 module, which speaks sway's IPC as tidewm does.
// Each binding reads only the one in use, so the other isn't asked. It
// says which monitor has focus, for the popups, prompts and launcher that
// open there, and which workspaces there are, for the bar, the switcher
// and the name prompt, and goes to and renames them.
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
            console.warn(`tide: tidewm can't be asked to go to workspace ${JSON.stringify(name)}: it reads a ; as the end of the command`);
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
            console.warn(`tide: tidewm can't be asked to rename workspace ${JSON.stringify(from)} to ${JSON.stringify(to)}: it would read the names wrongly`);
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
