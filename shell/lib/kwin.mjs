// The launcher's Workspaces and Windows tabs on KDE Plasma (SPEC.md §8.5),
// from KWin's own D-Bus, through `busctl --user --json=short`: its
// desktops and the current one (org.kde.KWin.VirtualDesktopManager), its
// windows (the krunner1 runner at /WindowsRunner, whose empty query lists
// them all) and each one's app and desktop (org.kde.KWin.getWindowInfo).
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

// Activates the window the runner matched as `match`.
export function activateCommand(match) {
    return ["busctl", "--user", "call", KWIN, "/WindowsRunner", "org.kde.krunner1", "Run", "ss", match, ""];
}

// Goes to the desktop with ID `id`.
export function goCommand(id) {
    return ["busctl", "--user", "set-property", KWIN, ...VDM, "current", "s", id];
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
// runner's match, which activateCommand takes. A window on every desktop
// (none listed) shows none; one gone since the list is left out, as is one
// that asks to be left out of switchers.
export function launcherWindows(windows, info, desktops) {
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
                urgent: false,
                focus: i,
            };
        });
}

// The Workspaces tab's workspaces, as Switcher.workspaceRows takes them:
// every desktop in KWin's order, the current one marked, with how many
// windows each has and the first one's app, a window on every desktop (none
// listed) counting on each. `desktop` is the desktop's ID, which goCommand
// takes, as two desktops may share a name.
export function launcherWorkspaces(desktops, current, windows, info) {
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
            urgent: false,
            count: here.length,
            app: here.length > 0 ? info[here[0].uuid].app : "",
        };
    });
}
