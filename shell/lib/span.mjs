// A workspace spanning every monitor, as the shell reads it (SPEC.md §6.5,
// Monitors; hypr/tide/span.lua is the model). Each monitor's part of a
// workspace is a Hyprland workspace of its own: the main monitor's has the
// workspace's own name, each other's is NAME@OUT, OUT being the monitor's
// connector. A name can't hold `@` (workspacenames.mjs's UNSAFE), so the
// last `@` always starts the connector.

export const SEP = "@";

// The workspace a Hyprland workspace's name is a part of: NAME@OUT is
// NAME, and any other name is itself. A special workspace's name
// (`special:...`) is left as it is.
export function workspaceOf(name) {
    const s = String(name ?? "");
    if (s.startsWith("special:")) {
        return s;
    }
    const at = s.lastIndexOf(SEP);
    return at > 0 && at < s.length - 1 ? s.slice(0, at) : s;
}
