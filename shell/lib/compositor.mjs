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

// Whether it's tidesway's session (SPEC.md §5.3), which is tidewm's too:
// tidesway is one of the names as well. tidesway reads tidewm's config and
// speaks its IPC, and has what tidewm lacks, rounded corners among them.
export function isTidesway(desktop) {
    return String(desktop ?? "").split(":").indexOf("tidesway") >= 0;
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
// reads the rest of a command as the name, as written, or a name in
// double quotes, as sway does, which one with a `;` needs, since a `;`
// outside them ends the command. Only such a name is quoted. tidewm's
// quotes take no escapes, so a name can't hold a `"`, which a name the
// shell allows never does (SPEC.md §6.5); and it's trimmed, as tidewm
// trims a command.
export function tidewmName(name) {
    const n = String(name ?? "");
    if (n === "" || n.indexOf('"') >= 0 || n.trim() !== n) {
        return null;
    }
    return n.indexOf(";") >= 0 ? `"${n}"` : n;
}

// Going to the workspace named `name`, which tidewm makes if it's new.
// `number` makes the rest the name, so one named back_and_forth is
// that workspace, not the last one.
export function tidewmGoTo(name) {
    const n = tidewmName(name);
    return n === null ? null : `workspace number ${n}`;
}

// Renaming workspace `from` to `to`. tidewm splits an unquoted `from`
// from `to` at the first " to ", so a `from` with one goes in quotes, as
// does one that starts with "to ", which would rename the current
// workspace instead; `to` may have one.
export function tidewmRename(from, to) {
    const f = tidewmName(from);
    const t = tidewmName(to);
    if (f === null || t === null) {
        return null;
    }
    const old = f.startsWith('"') || (f.indexOf(" to ") < 0 && !/^to(\s|$)/i.test(f)) ? f : `"${f}"`;
    return `rename workspace ${old} to ${t}`;
}

// What keeps home, named `home`, on tidewm, which reads no
// tide-workspaces.lua: `persist workspace`, which makes it if it's new.
// null for a home tidewm's commands can't name.
export function tidewmKeepHome(home) {
    const h = tidewmName(home);
    return h === null ? null : `persist workspace ${h}`;
}

// Letting old homes go, `pending` (names), once tidewm has said which
// workspaces there are (`names`, empty until then), so each goes once it's
// empty, as Hyprland's turned-off rule lets it: {command, pending}.
// `command` unpersists those still there, or is null; `pending` is what's
// left to let go, all of it until the list is known and none after, since
// one not in the list is gone already, which tidewm would refuse. Home
// itself, as it is now, stays.
export function tidewmRelease(pending, home, names) {
    const listed = Array.from(names ?? []);
    const old = Array.from(pending ?? []).filter(n => n !== home);
    if (listed.length === 0) {
        return { command: null, pending: old };
    }
    const there = old.filter((n, i) => old.indexOf(n) === i && listed.indexOf(n) >= 0 && tidewmName(n) !== null);
    return {
        command: there.length > 0 ? there.map(n => `unpersist workspace ${tidewmName(n)}`).join("; ") : null,
        pending: [],
    };
}

// The home tide-tidewm kept as tidewm started: the one named in `text`,
// the tide-workspaces.lua the shell last wrote, read as tide-tidewm reads
// it (`    home = "NAME",`), or `in` with no such line, as before the shell
// has run. The shell lets it go if home is now another (tidewmRelease).
export function startedHome(text) {
    const m = /^    home = "(.*)",$/m.exec(String(text ?? ""));
    return m ? m[1] : "in";
}
