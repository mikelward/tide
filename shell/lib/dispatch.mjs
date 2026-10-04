// Hyprland dispatches from the bar, spelled for whichever config Hyprland
// runs. Under a Lua config (Hyprland.usingLua) a dispatch is a Lua call,
// hl.dsp.*, as the config's own bindings and conf's hyprctl uses write
// them; the old text form is ignored there. Under hyprlang it's the text
// form.

// Go to workspace `id`.
export function focusWorkspace(id, lua) {
    if (!Number.isInteger(id)) {
        throw new Error(`not a workspace ID: ${id}`);
    }
    return lua ? `hl.dsp.focus({ workspace = ${id} })` : `workspace ${id}`;
}

// Go to the first empty workspace on the focused monitor, for the
// launcher's Ctrl+Enter (SPEC.md §8). `emptym` is Hyprland's own selector
// for it, in both the Lua and the text form.
export function focusEmptyWorkspace(lua) {
    return lua ? 'hl.dsp.focus({ workspace = "emptym" })' : "workspace emptym";
}

// Focus the window at `address` (hex, with or without 0x).
export function focusWindow(address, lua) {
    const hex = String(address ?? "").toLowerCase().replace(/^0x/, "");
    if (!/^[0-9a-f]+$/.test(hex)) {
        throw new Error(`not a window address: ${address}`);
    }
    return lua ? `hl.dsp.focus({ window = "address:0x${hex}" })` : `focuswindow address:0x${hex}`;
}

// Toggle maximize on the focused window (SPEC.md §6.3: Hyprland's
// fullscreen state 1), as conf's Super+Up and Super+middle-click do.
export function toggleMaximize(lua) {
    return lua ? 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })' : "fullscreen 1";
}
