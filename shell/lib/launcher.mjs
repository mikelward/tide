// The launcher's results (SPEC.md §8): the apps from desktop entries and
// their desktop actions, matched with fuzzy.mjs, and the command that runs
// one through `tide launch` (§5.4).

import { score as used } from "./frecency.mjs";
import { match } from "./fuzzy.mjs";
import { ACTIONS as SESSION, actionCommand } from "./session.mjs";
import { PAGES, SECTIONS } from "./settings.mjs";
import { ICON as KEEP_AWAKE_ICON } from "./keepawake.mjs";

// A match outside the name (generic name, keywords, the command) still
// finds an app, but below one that matches its name as well.
const OTHER_FIELD = 24;

function basename(path) {
    return String(path ?? "").split("/").pop();
}

// What tide's session sets XDG_CURRENT_DESKTOP to (SPEC.md §5), for a
// shell started without it: the shell runs only in tide.
export const DESKTOP = "tide:Hyprland";

// The desktop names OnlyShowIn and NotShowIn are matched against, in
// order, from XDG_CURRENT_DESKTOP's value.
export function desktopNames(value) {
    const names = String(value || "").split(":").filter(n => n !== "");
    return names.length > 0 ? names : DESKTOP.split(":");
}

// Quickshell 0.3's DesktopEntry has no OnlyShowIn or NotShowIn, so
// LauncherData runs this with `sh -c` as the shell starts, and again when
// the entries change. For each .desktop file in the directories Quickshell
// scans, in its order, it prints "@<path under applications/>", then
// those two keys from the [Desktop Entry] group, each with "|" in front.
// It exits 1 if a directory or file couldn't be read, having said why.
export const SHOW_IN_SCRIPT = [
    "status=0",
    "IFS=:",
    'for dir in "${XDG_DATA_HOME:-$HOME/.local/share}" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do',
    '    apps=${dir%/}/applications',
    '    test -d "$apps" || continue',
    "    find -L \"$apps\" -name '*.desktop' -type f -exec awk -v root=\"$apps\" '",
    '        FNR == 1 { group = ""; print "@" substr(FILENAME, length(root) + 2) }',
    '        /^[ \\t]*\\[/ { group = $0; sub(/^[ \\t]+/, "", group); sub(/[ \\t\\r]+$/, "", group); next }',
    '        group == "[Desktop Entry]" && /^[ \\t]*(OnlyShowIn|NotShowIn)[ \\t]*=/ { print "|" $0 }',
    "    ' {} + || status=1",
    "done",
    "exit $status",
].join("\n");

function showInList(value) {
    return value.split(";").map(s => s.trim()).filter(s => s !== "");
}

// SHOW_IN_SCRIPT's output, keyed by desktop file ID as Quickshell gives
// it (the path with "/" as "-", less ".desktop"): {only, not}, `only` null
// when the entry has no OnlyShowIn. The first file with an ID counts, as
// in Quickshell's scan, and the first of a repeated key.
export function parseShowIn(output) {
    const showIn = {};
    let current = null;
    for (const raw of String(output || "").split("\n")) {
        if (raw.startsWith("@")) {
            const id = raw.slice(1).replace(/\.desktop$/, "").split("/").join("-");
            current = Object.prototype.hasOwnProperty.call(showIn, id) ? null : { only: null, not: null };
            if (current !== null) {
                showIn[id] = current;
            }
            continue;
        }
        if (!raw.startsWith("|") || current === null) {
            continue;
        }
        const line = raw.slice(1);
        const eq = line.indexOf("=");
        const key = line.slice(0, eq).trim();
        const value = showInList(line.slice(eq + 1));
        if (key === "OnlyShowIn" && current.only === null) {
            current.only = value;
        } else if (key === "NotShowIn" && current.not === null) {
            current.not = value;
        }
    }
    for (const id in showIn) {
        showIn[id] = Object.freeze({ only: showIn[id].only, not: showIn[id].not ?? [] });
    }
    return showIn;
}

// Whether an entry with these keys (parseShowIn's) shows on a desktop
// with these names (desktopNames'), by the Desktop Entry spec: the first
// name either list holds decides; with none, an entry with an OnlyShowIn
// is hidden and any other shown.
export function shownIn(keys, names) {
    if (!keys) {
        return true;
    }
    for (const name of names) {
        if (keys.only !== null && keys.only.indexOf(name) >= 0) {
            return true;
        }
        if (keys.not.indexOf(name) >= 0) {
            return false;
        }
    }
    return keys.only === null;
}

// Other desktops' settings apps, which don't work in tide; its own
// Settings covers them (§16). Most say OnlyShowIn, but KDE's System
// Settings has a second entry for other desktops (NotShowIn=KDE), so a
// Settings entry that runs one of these is left out too. Panels run the
// same program with an argument (`gnome-control-center sound`).
export const SETTINGS_APPS = Object.freeze([
    "systemsettings", "systemsettings5", "kcmshell6", "kcmshell5",
    "gnome-control-center", "xfce4-settings-manager", "mate-control-center",
    "cinnamon-settings", "lxqt-config", "budgie-control-center", "cosmic-settings",
]);

// The program a command runs, past `env` and its assignments.
function program(command) {
    let i = 0;
    if (basename(command[0]) === "env") {
        i = 1;
        while (i < command.length && String(command[i]).indexOf("=") > 0) {
            i += 1;
        }
    }
    return basename(command[i]);
}

export function otherDesktopSettings(entry) {
    return [...(entry.categories ?? [])].indexOf("Settings") >= 0
        && SETTINGS_APPS.indexOf(program(entry.command)) >= 0;
}

// One row per app a desktop entry shows, and one per desktop action it
// offers ("New Incognito Window"), as plain objects. Entries marked
// NoDisplay, or with nothing to run, are left out, and so are those for
// other desktops: their OnlyShowIn and NotShowIn (`desktop.showIn`, from
// parseShowIn) against `desktop.names` (desktopNames'), and their settings
// apps (otherDesktopSettings). `entries` are Quickshell DesktopEntry
// objects or anything with their properties.
export function launcherItems(entries, desktop = {}) {
    const names = desktop.names ?? desktopNames("");
    const showIn = desktop.showIn ?? {};
    const items = [];
    for (const e of entries) {
        if (!e || e.noDisplay || !e.command || e.command.length === 0) {
            continue;
        }
        const keys = Object.prototype.hasOwnProperty.call(showIn, e.id) ? showIn[e.id] : null;
        if (!shownIn(keys, names) || otherDesktopSettings(e)) {
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
// disturb, keep awake and presenter mode say whether they're on
// (`state.dnd`, `state.keepAwake`, `state.presenting`, and `state.micHolds`
// when only a live mic holds keep awake, which a click can't turn off). Do not disturb is there only
// while the shell is the notification server (`state.notifications`), as
// the bell is: under swaync it would hold nothing. Dark style says whether
// it's on and until when (`state.dark`, `state.darkUntil` as "HH:MM", or ""
// when it doesn't change on its own); running it flips it until then
// (SPEC.md §15). Settings opens the settings panel (§16), and each of its
// pages has a row of its own ("Mouse settings"), which opens the panel on
// that page, as each section that opens on its own does ("Keyboard
// shortcuts"). Those are found by a query only (`queryOnly`), so the empty
// query's Actions don't list a dozen of them.
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
        quick("settings", "Settings", "Sound, network, mouse, keyboard and more", "preferences-system-symbolic", ["preferences", "control panel"]),
        ...PAGES.map(p => Object.assign(quick(`settings-${p.id}`, `${p.label} settings`, "Settings", p.icon, p.keywords), { queryOnly: true })),
        ...SECTIONS.map(s => Object.assign(quick(`settings-${s.id}`, s.label, "Settings", s.icon, s.keywords), { queryOnly: true })),
        state.notifications ? quick("dnd", "Do not disturb", onOff(state.dnd), "notifications-disabled-symbolic", ["dnd", "notifications", "quiet"]) : null,
        quick("dark-style", "Dark style", onOff(state.dark) + (state.darkUntil ? ` until ${state.darkUntil}` : ""), "night-light-symbolic", ["theme", "light", "night", "appearance", "mode"]),
        quick("keep-awake", "Keep awake", state.micHolds ? "On while the mic is live" : onOff(state.keepAwake), KEEP_AWAKE_ICON, ["caffeine", "coffee", "idle", "inhibit"], "Super+S"),
        quick("presenter", "Presenter mode", onOff(state.presenting), "x-office-presentation-symbolic", ["presentation", "slides", "projector", "meeting"], "Super+P"),
        quick("clear-clipboard", "Clear clipboard history", "Forget everything Super+C lists", "edit-clear-all-symbolic", ["clipboard", "wipe", "history", "cliphist", "forget"]),
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
// (`shell`: "settings", with the `page` to open on or "" for the first,
// "dnd", "dark-style", "keep-awake", "presenter",
// "reload"). "Screenshot window" takes the
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
    case "clear-clipboard":
        // Says why in a notification if it fails (SPEC.md §8.4).
        return { run: ["tide", "clipboard", "wipe", "--notify"], afterClose: false };
    case "dnd":
    case "dark-style":
    case "keep-awake":
    case "presenter":
    case "reload":
        return { shell: id };
    case "settings":
        return { shell: "settings", page: "" };
    default:
        // A page's row opens the panel on that page.
        if (id.startsWith("settings-") && [...PAGES, ...SECTIONS].some(p => `settings-${p.id}` === id)) {
            return { shell: "settings", page: id.slice("settings-".length) };
        }
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
        const quick = items.filter(i => i.kind === "quick" && !i.queryOnly);
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
// classes grantIds lists. Ctrl+Enter gives the name prompt what follows
// `tide launch`, which it runs with `--workspace NAME` (SPEC.md §6.5).
export function launchCommand(item) {
    const command = ["tide", "launch"];
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

// Whether Ctrl+Enter's "on a new workspace" applies to `item`: an app or a
// desktop action opens a window it can go to. A quick action opens none,
// so Ctrl+Enter runs it as Enter does.
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
