// The Workspaces page (SPEC.md §6.5, §16): the standing workspaces, home's
// apps and the name patterns, each a list in workspaces.json and
// workspaces.local.json, and each standing workspace's own settings
// (workspaceSettings), changed as the page changes them. `muted` is the
// Notifications page's (mute.mjs).

import { jsonError } from "./clocks.mjs";
import {
    loadWorkspaceSettings, parseWorkspaceSettings, sameName, workspaceSetting, workspaceSettingsOf,
} from "./workspacenames.mjs";

// The page's lists, in its order: which keep an order that matters (the
// first standing workspace is home; patterns are tried in turn), and what
// the field at the foot asks for.
export const LISTS = Object.freeze([
    { key: "standing", heading: "STANDING WORKSPACES", ordered: true, hint: "Add a workspace, such as docs" },
    { key: "inApps", heading: "HOME'S APPS", ordered: false, hint: "Add a program or web address, such as gmail" },
    { key: "namePatterns", heading: "NAME PATTERNS", ordered: true, hint: "Add a pattern, such as \\b([A-Z]+-[0-9]+)\\b" },
]);

// What each standing workspace's section says: its switch for askForName,
// and its pinned apps' field.
export const ASK_LABEL = "Open new windows on a new workspace";
export const PINNED_LABEL = "Pinned apps";
export const PINNED_HINT = "Pin a program or web address, such as gmail";

// A standing workspace's section heading: its name, and home's mark.
export function workspaceHeading(name, index) {
    return index === 0 ? `${name} · home` : name;
}

function listOf(key) {
    return LISTS.find(l => l.key === key);
}

// The local file's object, or {error}.
function localObject(localText) {
    if (localText === null || localText === undefined || localText.trim() === "") {
        return {};
    }
    try {
        return JSON.parse(localText);
    } catch (e) {
        return { error: `workspaces.local.json: ${jsonError(localText)}` };
    }
}

// workspaces.local.json's text with the settings of the workspace named
// `name` as `change` makes them of the ones in effect ({askForName,
// pinnedApps}, workspaceSetting's): {text, setting}, or {error}. As a list
// does, the first change copies the workspaceSettings in effect into the
// local file, since a local one replaces the shared one whole (§16.1): with
// neither file setting it, that's home asking for a name, so turning on
// another workspace's switch leaves home's on. An entry is found by its
// name ignoring case, and keeps the case it has.
export function editedWorkspace(sharedText, localText, name, change) {
    const loaded = loadWorkspaceSettings(sharedText, localText);
    if (loaded.errors.length > 0) {
        return { error: loaded.errors[0] };
    }
    const current = workspaceSetting(loaded.settings, name);
    const result = change({ askForName: current.askForName, pinnedApps: current.pinnedApps.slice() });
    if (result.error) {
        return { error: result.error };
    }
    const local = localObject(localText);
    if (local.error) {
        return local;
    }
    const all = Object.assign({}, workspaceSettingsOf(loaded.settings));
    const key = Object.keys(all).find(k => sameName(k, name)) ?? name;
    all[key] = { askForName: result.setting.askForName, pinnedApps: result.setting.pinnedApps };
    const text = JSON.stringify(Object.assign({}, local, { workspaceSettings: all }), null, 2) + "\n";
    const checked = parseWorkspaceSettings(text);
    if (checked.error) {
        return { error: checked.error };
    }
    return { text, setting: all[key] };
}

// A workspace's settings with askForName `on`.
export function withAskForName(setting, on) {
    return { setting: Object.assign({}, setting, { askForName: on === true }) };
}

// A workspace's settings with `raw` pinned, as withItem adds it.
export function withPinned(setting, raw) {
    const r = withItem(setting.pinnedApps, raw);
    return r.error ? r : { setting: Object.assign({}, setting, { pinnedApps: r.list }) };
}

// A workspace's settings without the pinned app `item` at `index`, as
// withoutItem takes it out.
export function withoutPinned(setting, index, item) {
    const r = withoutItem(setting.pinnedApps, index, item);
    return r.error ? r : { setting: Object.assign({}, setting, { pinnedApps: r.list }) };
}

// workspaces.local.json's text with list `key` as `change` makes it of the
// list in effect: {text, list}, or {error}. The first change to a list
// copies the shared one into the local file, since a local list replaces
// the shared one whole (§16.1). Either file not loading, or the new list
// not being one the files would take (an empty standing, a name twice, a
// pattern that doesn't compile), is an {error}, naming why.
export function editedList(sharedText, localText, key, change) {
    if (!listOf(key)) {
        return { error: `${key} isn't one of the page's lists (${LISTS.map(l => l.key).join(", ")})` };
    }
    const loaded = loadWorkspaceSettings(sharedText, localText);
    if (loaded.errors.length > 0) {
        return { error: loaded.errors[0] };
    }
    const result = change(loaded.settings[key].slice());
    if (result.error) {
        return { error: result.error };
    }
    let local = {};
    if (localText !== null && localText !== undefined && localText.trim() !== "") {
        try {
            local = JSON.parse(localText);
        } catch (e) {
            return { error: `workspaces.local.json: ${jsonError(localText)}` };
        }
    }
    const value = Object.assign({}, local, { [key]: result.list });
    const text = JSON.stringify(value, null, 2) + "\n";
    const checked = parseWorkspaceSettings(text);
    if (checked.error) {
        return { error: checked.error };
    }
    return { text, list: result.list };
}

// The list with `raw` added at the end, trimmed: {list} or {error}. One
// that's there already (as a name, ignoring case) is refused; whether it can
// be one at all is editedList's to say, as the files' check.
export function withItem(list, raw) {
    const item = typeof raw === "string" ? raw.trim() : "";
    if (item === "") {
        return { error: "type something to add" };
    }
    if (list.some(i => sameName(i, item))) {
        return { error: `${item} is listed already` };
    }
    return { list: list.concat([item]) };
}

// The entry a change is for: `index` (from 0) if it's still `item`, so a
// hand edit that has moved them since is refused; with no index, the first
// that is. -1 when none is.
function itemIndex(list, index, item) {
    if (index === undefined || index === null) {
        return list.indexOf(item);
    }
    return list[index] === item ? index : -1;
}

function missing(index, item) {
    return index === undefined || index === null ? { error: `${item} isn't listed` } : { error: `entry ${index + 1} isn't ${item}` };
}

export function movedItem(list, index, item, step) {
    const from = itemIndex(list, index, item);
    if (from < 0) {
        return missing(index, item);
    }
    const to = Math.max(0, Math.min(list.length - 1, from + step));
    const next = list.slice();
    next.splice(to, 0, next.splice(from, 1)[0]);
    return { list: next };
}

export function withoutItem(list, index, item) {
    const at = itemIndex(list, index, item);
    if (at < 0) {
        return missing(index, item);
    }
    return { list: list.filter((x, i) => i !== at) };
}

// What the page says beside an entry: the first standing workspace is
// home.
export function itemNote(key, index) {
    return key === "standing" && index === 0 ? "home" : "";
}
