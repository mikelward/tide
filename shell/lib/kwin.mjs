// The launcher's Workspaces and Windows tabs on KDE Plasma (SPEC.md §8.5),
// from KWin's own D-Bus, through `busctl --user --json=short`: its
// desktops and the current one (org.kde.KWin.VirtualDesktopManager), its
// windows (the krunner1 runner at /WindowsRunner, whose empty query lists
// them all) and each one's app and desktop (org.kde.KWin.getWindowInfo).
// KWin's D-Bus doesn't say which windows want attention, so tide on KDE
// (mikelward/tide-kde), a KWin script, keeps their UUIDs in the desktop's
// settings in plasmashell, which the Attention tab reads.
// Pure functions over busctl's JSON, so they test with no KWin; KWinData.qml
// runs the commands.

const BUSCTL = ["busctl", "--user", "--json=short"];
const KWIN = "org.kde.KWin";
const VDM = ["/VirtualDesktopManager", "org.kde.KWin.VirtualDesktopManager"];

// The desktops, then the current one's ID: two lines of JSON.
export const DESKTOPS_COMMAND = Object.freeze(BUSCTL.concat(["get-property", KWIN, ...VDM, "desktops", "current"]));

// Every window, as the runner matches the empty query.
export const WINDOWS_COMMAND = Object.freeze(BUSCTL.concat(["call", KWIN, "/WindowsRunner", "org.kde.krunner1", "Match", "s", ""]));

// Each window's details, one line of JSON apiece, for the window UUIDs
// passed after it: a shell loop, so all of them take one process.
export function infoCommand(uuids) {
    return ["sh", "-c", 'for id; do busctl --user --json=short call org.kde.KWin /KWin org.kde.KWin getWindowInfo s "$id" || echo null; done', "sh"].concat(uuids);
}

// The windows wanting attention, as tide on KDE keeps them: their UUIDs as
// JSON, in the desktop's settings, group "tide", key "attention".
const ATTENTION_SCRIPT = 'const d = desktops()[0]; if (d) { d.currentConfigGroup = ["tide"]; print(d.readConfig("attention", "[]")); }';
export const ATTENTION_COMMAND = Object.freeze(BUSCTL.concat(["call", "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell",
    "evaluateScript", "s", ATTENTION_SCRIPT]));

// Activates the window the runner matched as `match`.
export function activateCommand(match) {
    return ["busctl", "--user", "call", KWIN, "/WindowsRunner", "org.kde.krunner1", "Run", "ss", match, ""];
}

// Goes to the desktop with ID `id`.
export function goCommand(id) {
    return ["busctl", "--user", "set-property", KWIN, ...VDM, "current", "s", id];
}

// Makes a desktop named `name` after the last of the `count` there are.
// `--` ends busctl's options, so a name starting with a dash is a name.
export function createCommand(count, name) {
    return ["busctl", "--user", "--", "call", KWIN, ...VDM, "createDesktop", "us", String(count), name];
}

// The ID of the desktop named `name`, exactly, among parseDesktops's
// `desktops`, or null.
export function desktopNamed(desktops, name) {
    return desktops.find((d) => d.name === name)?.id ?? null;
}

// The KWin script that moves the window you're in to the desktop named
// `name`, making it after the last if there's none, then follows it there.
// KWin's D-Bus has no call that moves a window, so moveCommand loads this.
// A window that isn't an app's normal one, or none, stays where it is, and
// the journal says so (KWin's print).
export function moveScript(name) {
    return `(function () {
    const name = ${JSON.stringify(name)};
    const w = workspace.activeWindow;
    if (!w || !w.normalWindow || w.specialWindow) {
        print("tide: no window to move to the desktop named " + name);
        return;
    }
    const named = () => workspace.desktops.find((d) => d.name === name);
    if (!named()) {
        workspace.createDesktop(workspace.desktops.length, name);
    }
    const d = named();
    if (!d) {
        print("tide: KWin made no desktop named " + name + ", so the window stays");
        return;
    }
    w.desktops = [d];
    workspace.currentDesktop = d;
    workspace.activeWindow = w;
})();
`;
}

// Runs moveScript(name) in KWin: writes it to a file in the runtime
// directory, loads it through /Scripting, runs it and unloads it, then
// removes the file. KWin refuses to load a second script by the same
// name, so one left from a run that failed part-way is unloaded first.
const MOVE_RUNNER = `f=$(mktemp "\${XDG_RUNTIME_DIR:-/tmp}/tide-move.XXXXXX.js") || exit 1
trap 'rm -f "$f"' EXIT
printf '%s' "$1" >"$f" || exit 1
s="org.kde.KWin /Scripting org.kde.kwin.Scripting"
busctl --user call $s unloadScript s tide-move >/dev/null
id=$(busctl --user call $s loadScript ss "$f" tide-move) || exit 1
id=\${id#i }
case $id in ''|-*|*[!0-9]*) echo "KWin wouldn't load the script that moves the window: $id" >&2; exit 1 ;; esac
busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script run
ran=$?
busctl --user call $s unloadScript s tide-move >/dev/null
exit $ran`;

// What the log calls moveCommand(name), in place of the script it holds.
export function moveShown(name) {
    return ["KWin's script moving the window to", JSON.stringify(name)];
}

export function moveCommand(name) {
    return ["sh", "-c", MOVE_RUNNER, "tide-move", moveScript(name)];
}

// The JSON values in busctl's output, one per line, skipping blank lines.
// Throws on a line that isn't JSON, naming it.
export function jsonLines(text) {
    return String(text ?? "").split("\n").filter((l) => l.trim() !== "").map((l) => {
        try {
            return JSON.parse(l);
        } catch (e) {
            throw new Error(`busctl said something that isn't JSON: ${l.slice(0, 80)}`);
        }
    });
}

// The desktops in KWin's order, [{id, name}], and the current one's ID,
// from DESKTOPS_COMMAND's output.
export function parseDesktops(text) {
    const [list, current] = jsonLines(text);
    const desktops = (list?.data ?? [])
        .slice()
        .sort((a, b) => a[0] - b[0])
        .map(([, id, name]) => ({ id, name }));
    return { desktops, current: current?.data ?? null };
}

// The windows the runner matched, [{match, uuid, title}], once each, in its
// order: it lists a window again for each way it matched. A match is
// "<action>_<id>"; it matches desktops too, by their bare IDs, where a
// window's UUID is in braces.
export function parseWindows(text) {
    const [reply] = jsonLines(text);
    const seen = new Set();
    const out = [];
    for (const [match, title] of reply?.data?.[0] ?? []) {
        const uuid = match.slice(match.indexOf("_") + 1);
        if (seen.has(match) || !/^\{.*\}$/.test(uuid)) {
            continue;
        }
        seen.add(match);
        out.push({ match, uuid, title });
    }
    return out;
}

// The UUIDs of the windows wanting attention, from ATTENTION_COMMAND's
// output: none when plasmashell has nothing, as without tide on KDE.
// Throws on a list that isn't one, naming it.
export function parseAttention(text) {
    const [reply] = jsonLines(text);
    const saved = String(reply?.data?.[0] ?? "").trim();
    if (saved === "") {
        return [];
    }
    let list;
    try {
        list = JSON.parse(saved);
    } catch (e) {
        throw new Error(`the windows wanting attention aren't a list: ${saved.slice(0, 80)}`);
    }
    if (!Array.isArray(list)) {
        throw new Error(`the windows wanting attention aren't a list: ${saved.slice(0, 80)}`);
    }
    return list.filter((id) => typeof id === "string");
}

// Each window's {app, desktops}, by UUID, from infoCommand's output for
// `uuids`, in the same order. A window gone meanwhile reads as null and is
// left out.
export function parseInfo(text, uuids) {
    const out = {};
    jsonLines(text).forEach((reply, i) => {
        const info = reply?.data?.[0];
        // KWin answers a window it doesn't know with nothing in the map
        if (!info || !info.uuid || i >= uuids.length) {
            return;
        }
        const value = (k) => info[k]?.data;
        out[uuids[i]] = {
            app: value("desktopFile") || value("resourceClass") || "",
            desktops: value("desktops") ?? [],
            skip: value("skipSwitcher") === true,
        };
    });
    return out;
}

// The Windows tab's windows, as the launcher lists them (allWindows):
// {address, title, app, workspace, urgent, focus}. `address` is the
// runner's match, which activateCommand takes; `urgent`, whether its UUID
// is in `attention`. A window on every desktop (none listed) shows none;
// one gone since the list is left out, as is one that asks to be left out
// of switchers.
export function launcherWindows(windows, info, desktops, attention = []) {
    const names = {};
    for (const d of desktops) {
        names[d.id] = d.name;
    }
    return windows
        .filter((w) => info[w.uuid] && !info[w.uuid].skip)
        .map((w, i) => {
            const i2 = info[w.uuid];
            return {
                address: w.match,
                title: w.title,
                app: i2.app,
                workspace: i2.desktops.length === 1 ? (names[i2.desktops[0]] ?? "") : "",
                urgent: attention.includes(w.uuid),
                focus: i,
            };
        });
}

// The Workspaces tab's workspaces, as Switcher.workspaceRows takes them:
// every desktop in KWin's order, the current one marked, with how many
// windows each has and the first one's app, a window on every desktop (none
// listed) counting on each, and whether one of its own wants attention (a
// UUID in `attention`). `desktop` is the desktop's ID, which goCommand
// takes, as two desktops may share a name.
export function launcherWorkspaces(desktops, current, windows, info, attention = []) {
    return desktops.map((d) => {
        const here = windows.filter((w) => {
            const on = info[w.uuid]?.desktops;
            return on !== undefined && (on.length === 0 || on.includes(d.id));
        });
        return {
            id: d.id,
            desktop: d.id,
            name: d.name,
            home: false,
            state: d.id === current ? "current" : here.length > 0 ? "occupied" : "empty",
            urgent: here.some((w) => attention.includes(w.uuid) && info[w.uuid].desktops.length > 0),
            count: here.length,
            app: here.length > 0 ? info[here[0].uuid].app : "",
        };
    });
}
