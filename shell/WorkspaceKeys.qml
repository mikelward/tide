import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/span.mjs" as Span
import "lib/workspacekeys.mjs" as Keys
import "lib/workspaces.mjs" as Ws

// The workspace keys of SPEC.md §6.6 that need the bar's order or the
// workspaces you used, which tidewm doesn't know: conf's tidewm config
// runs `qs -c tide ipc call workspaces …` for Super+1…9 and Super+0
// (`go N`, `send N`), Super+Home (`home`), Super+Tab (`homeOrBack`) and
// Super+End (`lastOther`). conf's hyprland.lua does them itself, but the
// calls work there too. Each answers what it did, or why it didn't.
Scope {
    id: root

    // The workspaces other than home, the one used last first
    // (Keys.used), from the shell's start.
    property var history: Keys.NO_HISTORY
    readonly property string current: Compositor.tidewm
        ? Compositor.tidewmCurrentName
        : (Hyprland.focusedMonitor?.activeWorkspace?.name ?? "")

    onCurrentChanged: root.note()
    Component.onCompleted: root.note()

    function note() {
        root.history = Keys.used(root.history, root.current, WorkspacesData.home);
    }

    function here() {
        return Span.workspaceOf(root.current);
    }

    function order() {
        return Ws.workspaceOrder(Compositor.workspaces, WorkspacesData.standing);
    }

    // What lastUsed needs to know which workspaces are still there.
    function place() {
        return {
            home: WorkspacesData.home,
            standing: WorkspacesData.standing,
            names: Compositor.workspaces.map(w => Span.workspaceOf(w.name))
        };
    }

    function goTo(name, why) {
        if (name === null) {
            return why;
        }
        Compositor.goToWorkspace(name);
        return `went to ${name}`;
    }

    // The focused window's address, or null, as FocusData has it: on
    // Hyprland that corrects Hyprland.activeToplevel, which still names
    // the last window after focus moves to an empty workspace, and is null
    // until the first focus change after the shell starts.
    function focused() {
        return FocusData.focused?.address ?? null;
    }

    IpcHandler {
        target: "workspaces"

        // Super+N: the Nth workspace on the bar, the last for 0.
        function go(n: int): string {
            return root.goTo(Keys.nth(root.order(), n), `no workspace ${n} on the bar`);
        }
        // Super+Shift+N: sends the focused window there, staying here.
        function send(n: int): string {
            const name = Keys.nth(root.order(), n);
            if (name === null) {
                return `no workspace ${n} on the bar`;
            }
            const address = root.focused();
            if (address === null) {
                return "no window focused";
            }
            Compositor.sendWindowTo(address, name);
            return `sent ${address} to ${name}`;
        }
        // Super+Home.
        function home(): string {
            return root.goTo(WorkspacesData.home, "");
        }
        // Super+Tab: home, or from home back to the last other one.
        function homeOrBack(): string {
            return root.goTo(Keys.homeOrBack(root.here(), root.history, root.place()), "no other workspace used");
        }
        // Super+End: the last workspace other than home and this one.
        function lastOther(): string {
            return root.goTo(Keys.lastOther(root.here(), root.history, root.place()), "no other workspace used");
        }
    }
}
