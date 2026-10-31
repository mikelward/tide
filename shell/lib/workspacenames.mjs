// Named workspaces (SPEC.md §6.5): what a name may be, how one typed
// matches the ones there are, and the Workspaces settings
// (workspaces.json and workspaces.local.json, §16), as pure functions the
// QML binds to.

import { jsonError } from "./clocks.mjs";

// The longest a name may be, in characters.
export const MAX_NAME = 32;

// The standing workspaces when no file names any: the first is the home
// workspace (§6.5).
export const DEFAULT_STANDING = Object.freeze(["in", "re", "oc", "me"]);

// What each setting is when no file sets it.
export const DEFAULT_SETTINGS = Object.freeze({
    standing: DEFAULT_STANDING,
    inApps: Object.freeze([]),
    namePatterns: Object.freeze([]),
});

// A name as typed, made one: trimmed, and refused if it's empty, runs over
// more than one line or is longer than MAX_NAME. {name} or {error}.
export function checkName(text) {
    const name = String(text ?? "").trim();
    if (name === "") {
        return { error: "a workspace needs a name" };
    }
    if (/[\n\r]/.test(name)) {
        return { error: "a workspace's name is one line" };
    }
    if ([...name].length > MAX_NAME) {
        return { error: `a workspace's name is at most ${MAX_NAME} characters` };
    }
    return { name };
}

// Whether two names are the same workspace's: case doesn't count.
export function sameName(a, b) {
    return String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();
}

// The name in `names` that `typed` matches, ignoring case, or null: a name
// typed at the prompt uses the workspace already there, in the case it was
// made with.
export function matchName(names, typed) {
    return names.find((n) => sameName(n, typed)) ?? null;
}

// The home workspace's name: the first standing one.
export function homeName(settings) {
    return (settings.standing ?? DEFAULT_STANDING)[0];
}

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function listError(key, value) {
    if (!Array.isArray(value)) {
        return `${key} must be a list`;
    }
    const bad = value.findIndex((v) => typeof v !== "string" || v.trim() === "");
    return bad >= 0 ? `${key} must list text, not ${JSON.stringify(value[bad])} at ${bad + 1}` : null;
}

// Why one file's settings can't be taken, or null.
function settingsError(value) {
    if (!isObject(value)) {
        return "expected an object of settings";
    }
    for (const key of Object.keys(value)) {
        if (!Object.prototype.hasOwnProperty.call(DEFAULT_SETTINGS, key)) {
            return `${key} isn't a setting (standing, inApps or namePatterns)`;
        }
        const err = listError(key, value[key]);
        if (err) {
            return err;
        }
    }
    if (value.standing !== undefined) {
        if (value.standing.length === 0) {
            return "standing must name at least one workspace, the first being home";
        }
        const seen = [];
        for (const raw of value.standing) {
            const checked = checkName(raw);
            if (checked.error) {
                return `standing: ${JSON.stringify(raw)}: ${checked.error}`;
            }
            if (checked.name !== raw) {
                return `standing: ${JSON.stringify(raw)} has space around it`;
            }
            if (matchName(seen, raw) !== null) {
                return `standing names ${JSON.stringify(raw)} twice`;
            }
            seen.push(raw);
        }
    }
    return null;
}

// One file's settings: {settings} or {error}.
export function parseWorkspaceSettings(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    const err = settingsError(value);
    return err ? { error: err } : { settings: value };
}

// The settings in effect from workspaces.json and workspaces.local.json,
// each the file's text or null when it doesn't exist. Every setting is a
// list, so the local file's replaces the shared one's whole (§16.1). A
// file that's wrong keeps `lastGood`, and `errors` names each file that is:
// {settings, errors}.
export function loadWorkspaceSettings(sharedText, localText, lastGood = DEFAULT_SETTINGS) {
    const errors = [];
    const settings = Object.assign({}, DEFAULT_SETTINGS);
    for (const [name, text] of [["workspaces.json", sharedText], ["workspaces.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseWorkspaceSettings(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        Object.assign(settings, parsed.settings);
    }
    return errors.length > 0 ? { settings: lastGood, errors } : { settings, errors };
}

// `s` as a regular expression that matches only it.
function quoted(s) {
    return s.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}

// The window classes an "in" app's entry matches, as RE2 patterns for a
// Hyprland window rule (which matches the whole class, ignoring nothing).
// Each is matched as a class the way the focus guard matches one
// (focus.lua's same_id): without case, and a bare name as the last part of
// a qualified one, so `thunderbird` takes `org.mozilla.Thunderbird`. One
// that looks like a host is a site too, which takes that site's Chrome and
// Chromium `--app` windows and its subdomains', as a notification's site
// does (notifications.mjs's siteWindowClasses):
// `chrome-mail.google.com__-Default`.
export function inAppPatterns(inApps) {
    const out = [];
    for (const raw of inApps) {
        const app = raw.trim().toLowerCase().replace(/\.desktop$/, "");
        if (app === "") {
            continue;
        }
        out.push(app.includes(".") ? `(?i)${quoted(app)}` : `(?i)(.*\\.)?${quoted(app)}`);
        if (/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(app)) {
            out.push(`(?i)(chrome|chromium)-([^_]*\\.)?${quoted(app)}_.*-[^-]+`);
        }
    }
    return out;
}

// A Lua string literal holding `s`.
export function luaString(s) {
    let out = '"';
    for (const ch of String(s)) {
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

// ~/.config/hypr/tide-workspaces.lua, which conf's hyprland.lua reads as
// data: the home workspace it makes at login and keeps, and the classes
// its window rules send there.
export function workspacesLua(settings) {
    const list = (items) => items.length === 0 ? "{}" : `{\n${items.map((i) => `        ${luaString(i)},\n`).join("")}    }`;
    return "-- Written by tide's shell from workspaces.json and workspaces.local.json\n"
        + "-- (tide SPEC.md §6.5, §16); edit those, not this.\n"
        + "return {\n"
        + `    home = ${luaString(homeName(settings))},\n`
        + `    in_apps = ${list(inAppPatterns(settings.inApps ?? []))},\n`
        + "}\n";
}
