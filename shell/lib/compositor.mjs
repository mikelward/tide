// Which compositor the session runs (SPEC.md §5.3), for Compositor.qml.
// Hyprland's session is the default; tidewm's names tidewm first in
// XDG_CURRENT_DESKTOP (session/tide-tidewm.desktop's DesktopNames), which
// is what bin/tide's in_tidewm reads too.

// Whether `desktop`, XDG_CURRENT_DESKTOP's value, is tidewm's session:
// tidewm is one of its colon-separated names, as the desktop entry spec
// reads them.
export function isTidewm(desktop) {
    return String(desktop ?? "").split(":").indexOf("tidewm") >= 0;
}

// The screen in `screens` named `name`, or null. A monitor's name is its
// Wayland output's, on Hyprland and tidewm alike, and so is a screen's.
export function screenNamed(screens, name) {
    if (!name) {
        return null;
    }
    for (const s of Array.from(screens ?? [])) {
        if (s && s.name === name) {
            return s;
        }
    }
    return null;
}

// tidewm's workspaces (its docs/ipc.md): one per name, spanning every
// monitor, one of them current everywhere. These turn its GET_WORKSPACES
// objects, as Quickshell's I3 module keeps them (lastIpcObject), and its
// workspace events into what the shell takes from Hyprland, and make
// tidewm's commands.

// The workspaces as workspaces.mjs's workspaceOrder takes them:
// [{id, order, name}]. `id` is tidewm's, which lasts through a rename.
// `order` places it as Hyprland's IDs place its own: a numbered one at
// its number, and a named one below zero in the order it was made
// (tidewm's IDs rise), so the newest comes last among them.
export function tidewmWorkspaces(objects) {
    const out = [];
    for (const w of Array.from(objects ?? [])) {
        if (!w || !Number.isInteger(w.id) || typeof w.name !== "string" || w.name === "") {
            continue;
        }
        out.push({ id: w.id, order: Number.isInteger(w.num) && w.num > 0 ? w.num : -w.id, name: w.name });
    }
    return out;
}

// The current workspace's ID, or null before tidewm has said.
export function tidewmCurrent(objects) {
    for (const w of Array.from(objects ?? [])) {
        if (w && w.focused === true && Number.isInteger(w.id)) {
            return w.id;
        }
    }
    return null;
}

// Each monitor, by name, with the workspace it shows: on tidewm, the
// current one on every monitor. [{name, workspace}], as Hyprland's give.
export function tidewmMonitors(names, current) {
    return Array.from(names ?? []).filter(n => typeof n === "string" && n !== "")
        .map(name => ({ name, workspace: current }));
}

// A workspace event, its JSON as tidewm sends it, as workspaces.mjs's
// workspaceEvent gives Hyprland's: {type, id, name}, type "created",
// "destroyed" or "renamed", and name the workspace's name now. null for
// any other change, or for what doesn't parse.
export function tidewmWorkspaceEvent(data) {
    let event = data;
    if (typeof data === "string") {
        try {
            event = JSON.parse(data);
        } catch (e) {
            return null;
        }
    }
    const types = { init: "created", empty: "destroyed", rename: "renamed" };
    const type = types[event?.change];
    const ws = event?.current;
    if (type === undefined || !ws || !Number.isInteger(ws.id) || typeof ws.name !== "string") {
        return null;
    }
    return { type, id: ws.id, name: ws.name };
}

// A name as tidewm's commands take it, or null for one they can't: tidewm
// reads the rest of a command as the name, as written, but a `;` ends the
// command. A name the shell allows has no quotes to go wrong (SPEC.md
// §6.5), and is trimmed, as tidewm trims a command.
export function tidewmName(name) {
    const n = String(name ?? "");
    return n === "" || n.indexOf(";") >= 0 || n.trim() !== n ? null : n;
}

// Going to the workspace named `name`, which tidewm makes if it's new.
// `number` makes the rest the name, so one named back_and_forth is
// that workspace, not the last one.
export function tidewmGoTo(name) {
    const n = tidewmName(name);
    return n === null ? null : `workspace number ${n}`;
}

// Renaming workspace `from` to `to`. tidewm splits the two at the first
// " to ", so neither may have one, and `from` can't start with "to ",
// which would rename the current workspace instead.
export function tidewmRename(from, to) {
    const f = tidewmName(from);
    const t = tidewmName(to);
    if (f === null || t === null || f.indexOf(" to ") >= 0 || /^to(\s|$)/i.test(f)) {
        return null;
    }
    return `rename workspace ${f} to ${t}`;
}
