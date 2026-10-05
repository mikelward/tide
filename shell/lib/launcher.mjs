// The launcher's results (SPEC.md §8): the apps from desktop entries and
// their desktop actions, matched with fuzzy.mjs, and the command that runs
// one through `tide launch` (§5.4).

import { score as used } from "./frecency.mjs";
import { match } from "./fuzzy.mjs";
import { ACTIONS as SESSION, actionCommand } from "./session.mjs";

// A match outside the name (generic name, keywords, the command) still
// finds an app, but below one that matches its name as well.
const OTHER_FIELD = 24;

function basename(path) {
    return String(path ?? "").split("/").pop();
}

// One row per app a desktop entry shows, and one per desktop action it
// offers ("New Incognito Window"), as plain objects. Entries marked
// NoDisplay, or with nothing to run, are left out. `entries` are
// Quickshell DesktopEntry objects or anything with their properties.
export function launcherItems(entries) {
    const items = [];
    for (const e of entries) {
        if (!e || e.noDisplay || !e.command || e.command.length === 0) {
            continue;
        }
        const app = {
            kind: "app",
            id: e.id,
            name: e.name || e.id,
            sub: e.genericName || e.comment || "",
            icon: e.icon || "",
            keywords: [...(e.keywords ?? [])],
            exec: basename(e.command[0]),
            command: [...e.command],
            terminal: Boolean(e.runInTerminal),
            workingDirectory: e.workingDirectory || "",
            appId: e.startupClass || "",
            entryId: e.id,
        };
        items.push(app);
        for (const a of e.actions ?? []) {
            if (!a || !a.command || a.command.length === 0) {
                continue;
            }
            items.push(Object.assign({}, app, {
                kind: "action",
                id: `${e.id}:${a.id}`,
                name: a.name || a.id,
                sub: app.name,
                icon: a.icon || app.icon,
                keywords: [],
                exec: basename(a.command[0]),
                command: [...a.command],
            }));
        }
    }
    return items;
}

// The built-in quick actions (§8), as rows like the apps', with symbolic
// icons the launcher colors like the bar's: `hint` is the
// key that does the same, so the launcher teaches the bindings. Do not
// disturb and keep awake say whether they're on (`state.dnd`,
// `state.keepAwake`, and `state.micHolds` when only a live mic holds keep
// awake, which a click can't turn off). Do not disturb is there only
// while the shell is the notification server (`state.notifications`), as
// the bell is: under swaync it would hold nothing. Theme and Settings come
// later (TODO.md).
export function quickActions(state = {}) {
    const quick = (id, name, sub, icon, keywords, hint = "") => ({
        kind: "quick",
        id,
        name,
        sub,
        icon,
        keywords,
        exec: "",
        hint,
    });
    const onOff = on => (on ? "On" : "Off");
    const session = {};
    for (const a of SESSION) {
        session[a.id] = a;
    }
    // Listed in this order, which also breaks ties between them: window
    // first, so "scr" and Enter is a window screenshot (§8).
    return [
        quick("screenshot-window", "Screenshot window", "The window you were in", "camera-photo-symbolic", ["capture", "print"], "Alt+Print"),
        quick("screenshot-screen", "Screenshot screen", "The monitor you were on", "camera-photo-symbolic", ["capture", "print"], "Print"),
        quick("screenshot-region", "Screenshot region", "Drag to select", "camera-photo-symbolic", ["capture", "print", "area"], "Shift+Print"),
        quick("lock", session.lock.label, "Session", session.lock.icon, ["screen"], "Super+L"),
        quick("logout", session.logout.label, "Session", session.logout.icon, ["exit", "sign out", "quit"]),
        quick("suspend", session.suspend.label, "Session", session.suspend.icon, ["sleep"]),
        quick("reboot", session.reboot.label, "Session", session.reboot.icon, ["reboot"]),
        quick("poweroff", session.poweroff.label, "Session", session.poweroff.icon, ["power off", "halt"]),
        state.notifications ? quick("dnd", "Do not disturb", onOff(state.dnd), "notifications-disabled-symbolic", ["dnd", "notifications", "quiet"]) : null,
        quick("keep-awake", "Keep awake", state.micHolds ? "On while the mic is live" : onOff(state.keepAwake), "display-brightness-symbolic", ["caffeine", "idle", "inhibit"]),
        quick("reload", "Reload shell", "tide", "view-refresh-symbolic", ["restart", "quickshell"]),
    ].filter(q => q).map((q, rank) => Object.assign({}, q, { rank }));
}

// "Screenshot window" for the window at `address` (Hyprland's, recorded
// as the launcher opened). `hyprctl clients -j` is read when the screenshot
// runs, not before, and gives the window's stableId, which the script
// captures with `grim -T` (its own contents, even under a popup) via
// `--window-id`. A Hyprland that reports no stableId gets the window's
// rectangle (`--geometry`), taken where the window is now. A window that has
// closed, or a lookup that fails, falls back to the focused window
// (`--window`), saying why on stderr, which Launcher logs. jq is already one
// of tide's dependencies (README).
export const WINDOW_SCREENSHOT = [
    'a=$1',
    "w=$(hyprctl clients -j | jq -r --arg a \"$a\" '.[] | select((.address | ascii_downcase | ltrimstr(\"0x\") | sub(\"^0+\"; \"\")) == $a) | if .stableId then \"--window-id\\t\\(.stableId | tostring)\" else \"--geometry\\t\\(.at[0]),\\(.at[1]) \\(.size[0])x\\(.size[1])\" end' | head -n 1)",
    'if test -n "$w"; then exec screenshot "${w%%\t*}" "${w#*\t}"; fi',
    'echo "the window the launcher opened over is gone or unreadable; taking the focused window" >&2',
    "exec screenshot --window",
].join("\n");

export function windowScreenshot(address) {
    return address ? ["sh", "-c", WINDOW_SCREENSHOT, "sh", address] : ["screenshot", "--window"];
}

// What running a quick action takes: a command to run (`run`), with a
// pause first for the launcher to leave the screen (`afterClose`, so a
// screenshot doesn't catch it), or something the shell does itself
// (`shell`: "dnd", "keep-awake", "reload"). "Screenshot window" takes the
// window recorded as the launcher opened (`context.window`, its normalized
// Hyprland address; windowScreenshot), and "Screenshot screen" the monitor
// it opened on (`context.output`, Hyprland's name for it), so a focus change
// while it closes can't swap either; with none, the script finds the focused
// one itself.
export function quickCommand(id, context = {}) {
    switch (id) {
    case "screenshot-window":
        return { run: windowScreenshot(context.window), afterClose: true };
    case "screenshot-screen":
        return { run: context.output ? ["screenshot", "--output", context.output] : ["screenshot"], afterClose: true };
    case "screenshot-region":
        return { run: ["screenshot", "--region"], afterClose: true };
    case "lock":
    case "logout":
    case "suspend":
    case "reboot":
    case "poweroff":
        // A power action checks inhibitors (session.mjs), and one that's
        // blocked asks before going ahead (confirmRows); `power` says to
        // keep the launcher open until it knows.
        return { run: actionCommand(id, false), afterClose: false, power: ["suspend", "reboot", "poweroff"].includes(id) };
    case "dnd":
    case "keep-awake":
    case "reload":
        return { shell: id };
    default:
        throw new Error(`unknown quick action: ${id}`);
    }
}

// The rows for confirming a power action that something blocks (§8: ask
// only then): go ahead anyway, or cancel. The launcher stays open with
// these in place of the results, under a list of what's in the way, as
// the session menu does.
export function confirmRows(id) {
    const action = SESSION.find(a => a.id === id);
    const row = (choice, name, icon) => ({
        item: { kind: "confirm", id: choice, name, sub: "", icon, keywords: [], exec: "", hint: "" },
        positions: [],
    });
    return [
        row("anyway", `${action?.label ?? id} anyway`, "dialog-warning-symbolic"),
        row("cancel", "Cancel", "window-close-symbolic"),
    ];
}

// The heading over that list.
export function blockedHeading(id) {
    return `${SESSION.find(a => a.id === id)?.label ?? id} is blocked by:`;
}

// A row's identity across rebuilds: its kind and id together, since a
// desktop entry may share an id with a quick action ("keep-awake").
export function rowKey(row) {
    return row ? `${row.item.kind}:${row.item.id}` : null;
}

// The selection once the rows change. A new query preselects its top hit;
// otherwise (a toggle's state changed under an open launcher) it stays on
// the row it was on (`previousKey`, from rowKey), wherever that moved, so
// Enter runs what was selected.
export function reselect(previousKey, rows, queryChanged) {
    if (rows.length === 0) {
        return -1;
    }
    if (queryChanged || previousKey === null) {
        return 0;
    }
    const at = rows.findIndex(r => rowKey(r) === previousKey);
    return at >= 0 ? at : 0;
}

// How `item` matches `query`: its score and the matched positions in its
// name (code points, empty when only another field matched), or null.
export function scoreItem(item, query) {
    const byName = match(query, item.name);
    let best = byName ? { score: byName.score, positions: byName.positions } : null;
    const others = [item.sub, item.exec, ...item.keywords];
    for (const text of others) {
        const m = text ? match(query, text) : null;
        if (m && (!best || m.score - OTHER_FIELD > best.score)) {
            best = { score: m.score - OTHER_FIELD, positions: [] };
        }
    }
    return best;
}

function byName(a, b) {
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" }) || a.id.localeCompare(b.id);
}

// On an equal score, a quick action first: §8 promises `scr` and Enter
// is a window screenshot, even with an app named Screenshot installed.
// Then an app, before its own desktop actions.
const KIND_ORDER = { quick: 0, app: 1, action: 2 };

// Between two equal fuzzy scores, the closer match first: one in the
// name before one in another field, then a prefix of the name, then one
// unbroken run, then one that starts earlier, then the shorter name.
// fuzzy.mjs scores most of this already; this settles what it leaves equal.
function byShape(a, b) {
    return (
        Number(b.inName) - Number(a.inName) ||
        Number(b.prefix) - Number(a.prefix) ||
        Number(b.run) - Number(a.run) ||
        a.start - b.start ||
        [...a.item.name].length - [...b.item.name].length
    );
}

function shape(item, positions) {
    const inName = positions.length > 0;
    const run = inName && positions.every((p, i) => p === positions[0] + i);
    return {
        inName,
        prefix: run && positions[0] === 0,
        run,
        start: inName ? positions[0] : Infinity,
    };
}

// The rows for `query`, best first, each `{item, positions, section}`.
// `frecency` is the state from frecency.mjs, keyed by rowKey's "kind:id",
// read at `now`. Rows come in sections (§8), which Tab steps through:
//   - An empty query lists the apps you've used ("Recent", most used
//     first), then the other apps ("Apps", by name), without their desktop
//     actions, then the quick actions ("Actions") in their own order.
//   - A query puts its top hit first ("Best match"), then the other quick
//     actions ("Actions"), then the apps and their desktop actions
//     ("Apps"), each in rank order. Rank is by match score; equal scores go
//     by kind (quick actions in their own order), then by the shape of the
//     match (byShape), and only then most used first. Use only ever breaks
//     a tie, so `scr` and Enter stays a window screenshot however often you
//     take another kind.
export function search(items, query, frecency = {}, now = 0) {
    const usage = item => used(frecency[`${item.kind}:${item.id}`], now);
    if (query.trim() === "") {
        const apps = items.filter(i => i.kind === "app").map(item => ({ item, used: usage(item) }));
        apps.sort((a, b) => b.used - a.used || byName(a.item, b.item));
        const quick = items.filter(i => i.kind === "quick");
        return apps
            .map(a => ({ item: a.item, positions: [], section: a.used > 0 ? "Recent" : "Apps" }))
            .concat(quick.map(item => ({ item, positions: [], section: "Actions" })));
    }
    const rows = [];
    for (const item of items) {
        const m = scoreItem(item, query);
        if (m) {
            rows.push(Object.assign({ item, score: m.score, used: usage(item), positions: m.positions }, shape(item, m.positions)));
        }
    }
    rows.sort(
        (a, b) =>
            b.score - a.score ||
            KIND_ORDER[a.item.kind] - KIND_ORDER[b.item.kind] ||
            (a.item.rank ?? 0) - (b.item.rank ?? 0) ||
            byShape(a, b) ||
            b.used - a.used ||
            byName(a.item, b.item)
    );
    const row = section => ({ item, positions }) => ({ item, positions, section });
    const rest = rows.slice(1);
    return rows
        .slice(0, 1)
        .map(row("Best match"))
        .concat(rest.filter(r => r.item.kind === "quick").map(row("Actions")))
        .concat(rest.filter(r => r.item.kind !== "quick").map(row("Apps")));
}

// Whether the row at `index` starts a section, so gets its heading.
export function startsSection(rows, index) {
    const section = rows[index]?.section ?? "";
    return section !== "" && (index === 0 || rows[index - 1].section !== section);
}

// The selection after Tab (`step` 1) or Shift+Tab (-1) from `index`: the
// first row of the next or previous section, wrapping around. Shift+Tab
// inside a section goes to its own start first. A list with no sections
// keeps the selection.
export function nextSection(rows, index, step) {
    const starts = rows.map((_, i) => i).filter(i => startsSection(rows, i));
    if (starts.length === 0) {
        return index;
    }
    if (step > 0) {
        return starts.find(i => i > index) ?? starts[0];
    }
    const before = starts.filter(i => i < index);
    return before.length > 0 ? before[before.length - 1] : starts[starts.length - 1];
}

// Programs that start something else, so a window never has their name:
// shells, sandboxes and launchers an Exec line runs an app through.
// tide-grant keeps the same list (opaque in cmd/tide-grant/desktop.go).
const WRAPPERS = new Set([
    "env", "sh", "bash", "dash", "zsh", "exec", "nohup", "setsid", "sudo", "pkexec", "systemd-run",
    "flatpak", "snap", "gtk-launch", "gapplication", "dbus-launch", "xdg-open", "gio", "uwsm", "uwsm-app",
    "app2unit", "python", "python3", "perl", "java", "wine", "toolbox", "distrobox",
]);

// The window classes `item`'s window may have, for its focus grant
// (SPEC.md §14.3): its StartupWMClass when the entry names one, its
// desktop ID, which a Wayland app's app_id usually is, and the program it
// runs, unless that's a wrapper. One grant takes any of them, so an app
// whose class is none of these is left unfocused and marked, the safe way
// to be wrong. A terminal app's window is the terminal's, whatever class
// the entry names, so it grants the first window of any app (`*`).
export function grantIds(item) {
    if (item.terminal) {
        return ["*"];
    }
    const ids = [];
    const seen = new Set();
    for (const id of [item.appId, item.entryId, WRAPPERS.has(item.exec) ? "" : item.exec]) {
        const key = String(id ?? "").toLowerCase();
        if (key !== "" && !seen.has(key)) {
            seen.add(key);
            ids.push(id);
        }
    }
    return ids.length > 0 ? ids : ["*"];
}

// The `tide launch` command that runs `item`, granting focus to the
// classes grantIds lists; `newWorkspace` (Ctrl+Enter) asks for its first
// window on an empty workspace.
export function launchCommand(item, { newWorkspace = false } = {}) {
    const command = ["tide", "launch"];
    if (newWorkspace) {
        command.push("--new-workspace");
    }
    for (const id of grantIds(item)) {
        command.push("--app", id);
    }
    command.push("--");
    if (item.terminal) {
        command.push("xdg-terminal-exec");
    }
    return command.concat(item.command);
}

function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// Whether Ctrl+Enter's "on a new empty workspace" applies to `item`: an
// app or a desktop action opens a window it can go to. A quick action
// opens none, so Ctrl+Enter runs it as Enter does.
export function opensWindow(item) {
    return item?.kind === "app" || item?.kind === "action";
}

// `name` as styled text with the matched letters underlined in `color`,
// everything else escaped: names come from desktop entries, never markup.
export function highlighted(name, positions, color) {
    const at = new Set(positions);
    return [...name].map((c, i) => (at.has(i) ? `<u><font color="${color}">${escapeHtml(c)}</font></u>` : escapeHtml(c))).join("");
}

// The selection after moving `step` rows from `index` among `count`,
// clamped to the list rather than wrapping.
export function moved(index, step, count) {
    if (count === 0) {
        return -1;
    }
    return Math.max(0, Math.min(count - 1, index + step));
}
