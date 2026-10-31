// Hyprland dispatches from the bar, spelled for whichever config Hyprland
// runs. Under a Lua config (Hyprland.usingLua) a dispatch is a Lua call,
// hl.dsp.*, as the config's own bindings and conf's hyprctl uses write
// them; the old text form is ignored there. Under hyprlang it's the text
// form.

import { minimizedWorkspace } from "./minimized.mjs";

// Go to workspace `id`.
export function focusWorkspace(id, lua) {
    if (!Number.isInteger(id)) {
        throw new Error(`not a workspace ID: ${id}`);
    }
    return lua ? `hl.dsp.focus({ workspace = ${id} })` : `workspace ${id}`;
}

// A workspace's name, checked to be one a dispatch can carry: one line
// (workspacenames.mjs's checkName says what else a name must be).
function workspaceName(name) {
    if (typeof name !== "string" || name.trim() === "" || /[\n\r]/.test(name)) {
        throw new Error(`not a workspace name: ${JSON.stringify(name)}`);
    }
    return name;
}

// A Lua string literal holding `s`.
function luaString(s) {
    let out = '"';
    for (const ch of s) {
        const code = ch.charCodeAt(0);
        if (ch === '"' || ch === "\\") {
            out += "\\" + ch;
        } else if (code < 0x20 || code === 0x7f) {
            out += "\\" + String(code).padStart(3, "0");
        } else {
            out += ch;
        }
    }
    return out + '"';
}

// Go to the workspace named `name`, which Hyprland makes if no workspace
// has that name (SPEC.md §6.5): how the bar reaches every workspace, a
// numbered one included, since a negative ID would read as a step.
export function focusWorkspaceName(name, lua) {
    const n = workspaceName(name);
    return lua ? `hl.dsp.focus({ workspace = ${luaString("name:" + n)} })` : `workspace name:${n}`;
}

// Name workspace `id` `name`: the shell undoing a rename of home (§6.5).
export function renameWorkspace(id, name, lua) {
    if (!Number.isInteger(id)) {
        throw new Error(`not a workspace ID: ${id}`);
    }
    const n = workspaceName(name);
    return lua ? `hl.dsp.workspace.rename({ workspace = ${id}, name = ${luaString(n)} })` : `renameworkspace ${id} ${n}`;
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

// A window address as a dispatch names it, checked to be hex.
function windowAddress(address) {
    const hex = String(address ?? "").toLowerCase().replace(/^0x/, "");
    if (!/^[0-9a-f]+$/.test(hex)) {
        throw new Error(`not a window address: ${address}`);
    }
    return `address:0x${hex}`;
}

// Move the window at `address` to the workspace named `name`, made if it's
// new, and follow it there: the name prompt's Enter (SPEC.md §6.5).
export function moveWindowToWorkspace(address, name, lua) {
    const w = windowAddress(address);
    const n = workspaceName(name);
    return lua
        ? `hl.dsp.window.move({ workspace = ${luaString("name:" + n)}, follow = true, window = ${luaString(w)} })`
        : `movetoworkspace name:${n},${w}`;
}

// Ask the window at `address` to close, as Super+Backspace does: the name
// prompt's Esc for a new window on home.
export function closeWindow(address, lua) {
    const w = windowAddress(address);
    return lua ? `hl.dsp.window.close({ window = ${luaString(w)} })` : `closewindow ${w}`;
}

// Minimize the window at `address` from the workspace named `name`: a
// silent move to that workspace's minimize workspace, which nothing shows
// (SPEC.md §6.7). Focus goes to the window that was under it. Restoring it
// is moveWindowToWorkspace back to `name`.
export function minimizeWindow(address, name, lua) {
    const w = windowAddress(address);
    const target = minimizedWorkspace(workspaceName(name));
    return lua
        ? `hl.dsp.window.move({ workspace = ${luaString(target)}, follow = false, window = ${luaString(w)} })`
        : `movetoworkspacesilent ${target},${w}`;
}
