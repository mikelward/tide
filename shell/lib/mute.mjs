// Muted apps and sites (SPEC.md §9, Muted apps), as pure functions the QML
// binds to: which windows and notifications the `muted` list matches, and
// the entry a one-tap mute adds or removes. Entries are app IDs, matched as
// home's apps are (workspacenames.mjs's isHomeApp), or `site:HOST`, matched
// as a notification's site is (SPEC.md §14.4).

import { checkMuteEntry, isHomeApp } from "./workspacenames.mjs";
import { grantId, isChrome, isSystemSender, siteFrom } from "./notifications.mjs";

const SITE = "site:";

// The host a `site:HOST` entry names, lowercase, or null for an app ID.
function siteOfEntry(entry) {
    const s = String(entry ?? "");
    return s.toLowerCase().startsWith(SITE) ? s.slice(SITE.length).toLowerCase() : null;
}

// Whether `host` is `site` or one of its subdomains.
function underSite(host, site) {
    return host === site || host.endsWith("." + site);
}

// The site a Chrome or Chromium `--app` window's class names
// (`chrome-chat.google.com__-Default`), or null for any other class.
export function appWindowSite(cls) {
    const m = /^(chrome|chromium)-([^_]+)_.*-[^-]+$/i.exec(String(cls ?? ""));
    return m ? m[2].toLowerCase() : null;
}

// Whether a window of class `cls` is muted: an app ID matching its class,
// or a site its `--app` class names.
export function windowMuted(cls, muted) {
    const c = String(cls ?? "");
    if (c === "") {
        return false;
    }
    const site = appWindowSite(c);
    return (muted ?? []).some((e) => {
        const host = siteOfEntry(e);
        return host !== null ? site !== null && underSite(site, host) : isHomeApp(c, [e]);
    });
}

// What a notification is muted by: {id, site, system}, id being its
// desktop entry or app name (notifications.mjs's grantId), site the one
// Chrome or Chromium named in its origin hint, else null, and system
// whether it's a system sender, which nothing mutes. Another app naming a site
// there isn't taken at its word (§14.4). History entries carry the same
// three fields under other names, so a group's header asks the same way.
export function noteOf(desktopEntry, appName, originText) {
    const id = grantId({ desktopEntry, appName });
    return { id, site: isChrome(id) ? siteFrom(originText) : null, system: isSystemSender({ desktopEntry, appName }) };
}

// Whether a notification (noteOf) is muted: by its site, or by its app. A
// system sender's never is, whatever the list says.
export function noteMuted(note, muted) {
    if (note.system) {
        return false;
    }
    return (muted ?? []).some((e) => {
        const host = siteOfEntry(e);
        if (host !== null) {
            return note.site !== null && note.site !== undefined && underSite(note.site, host);
        }
        return note.id !== null && note.id !== undefined && isHomeApp(note.id, [e]);
    });
}

// The entry muting a window's row adds: its site for an `--app` window,
// else its class.
export function windowEntry(cls) {
    const site = appWindowSite(cls);
    return site !== null ? SITE + site : String(cls ?? "");
}

// The entry muting a notification (noteOf) adds: its site when it names
// one, else its app.
export function noteEntry(note) {
    return note.site ? SITE + note.site : String(note.id ?? "");
}

// The list after a one-tap toggle: if `isMuted(list)` already, every entry
// that mutes it goes (so a broad entry is removed too, rather than leaving
// the row muted); otherwise `entry` is added. {list, muted}, muted being
// whether it's muted after.
export function toggledMuted(list, isMuted, entry) {
    const current = list ?? [];
    if (isMuted(current)) {
        return { list: current.filter((e) => !isMuted([e])), muted: false };
    }
    // Only an entry the list would take back on loading it.
    const checked = checkMuteEntry(entry);
    if (checked.error) {
        return { list: current, muted: false };
    }
    return { list: [...current, checked.entry], muted: true };
}

// What a notification center group (history.mjs's groups) is muted by:
// its newest entry's app and site (noteOf), so a browser's group mutes the
// site it last heard from rather than the whole browser.
export function groupNote(group) {
    const newest = group?.items?.[0] ?? {};
    return noteOf(newest.entry, newest.app, newest.origin);
}
