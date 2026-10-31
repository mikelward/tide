import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "lib/dispatch.mjs" as Dispatch
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
            const t = Hyprland.activeToplevel;
            const address = Ws.normalizeAddress(t?.address);
            const r = Min.minimizeFrom(t ? { address: address, workspace: t.workspace?.name ?? "" } : null);
            if (r.error !== undefined) {
                return r.error;
            }
            Hyprland.dispatch(Dispatch.minimizeWindow(address, r.name, Hyprland.usingLua));
            return "minimized";
        }
    }
}
