import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/minimized.mjs" as Min
import "lib/workspaces.mjs" as Ws

// Super+Z (SPEC.md §6.7): conf's key runs `qs -c tide ipc call windows
// minimize`, and this minimizes the focused window from its workspace. A
// window it can't minimize (none focused, one on a special workspace, one
// minimized already) stays, and the call's answer says why.
Scope {
    IpcHandler {
        target: "windows"

        function minimize(): string {
            let active = null;
            if (Compositor.tidewm) {
                const w = Compositor.tidewmActive;
                active = w ? { address: w.address, workspace: w.workspaceName } : null;
            } else {
                const t = Hyprland.activeToplevel;
                active = t ? { address: Ws.normalizeAddress(t.address), workspace: t.workspace?.name ?? "" } : null;
            }
            const r = Min.minimizeFrom(active);
            if (r.error !== undefined) {
                return r.error;
            }
            Compositor.minimizeWindow(active.address, r.name);
            return "minimized";
        }
    }
}
