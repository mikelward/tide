// The spike's Quickshell side: what Quickshell's Hyprland module sees.
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

ShellRoot {
    IpcHandler {
        target: "probe"

        function focused(): string {
            const w = Hyprland.focusedWorkspace;
            return w ? `${w.address}|${w.name}` : "";
        }
        function workspaces(): string {
            return JSON.stringify(Hyprland.workspaces.values.map(w => ({ address: w.address, id: w.id, name: w.name })));
        }
    }
}
