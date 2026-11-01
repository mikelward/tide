// Browser tabs in the switcher's Windows tab (SPEC.md §8.3), as pure
// functions TabsData.qml and the switcher bind to. `tide-tabs serve`, the
// shell's child, sends one line per browser each time its tabs change;
// tileco, the extension, is what reads them.

import { minimizedFrom } from "./minimized.mjs";

// A line from `tide-tabs serve`: {message} or {error}.
export function parseLine(line) {
    let m;
    try {
        m = JSON.parse(line);
    } catch (e) {
        return { error: `tide-tabs sent a line that isn't JSON: ${e.message}` };
    }
    if (!m || typeof m !== "object" || typeof m.type !== "string") {
        return { error: "tide-tabs sent a line without a type" };
    }
    return { message: m };
}

// The browsers after `m`: {source: {browser, windows}}. A browser's tabs
// come whole each time, so each message replaces what it had; "gone" drops
// it.
export function applied(browsers, m) {
    if (m.type === "tabs" && typeof m.source === "string") {
        const out = Object.assign({}, browsers);
        out[m.source] = {
            browser: String(m.browser ?? ""),
            windows: (Array.isArray(m.windows) ? m.windows : []).map((w) => ({
                id: w.id,
                title: String(w.title ?? ""),
                tabs: (Array.isArray(w.tabs) ? w.tabs : []).map((t) => ({
                    id: t.id,
                    title: String(t.title ?? ""),
                    url: String(t.url ?? ""),
                    active: t.active === true,
                })),
            })),
        };
        return out;
    }
    // The relay stopping takes every browser with it.
    if (m.type === "fault") {
        return {};
    }
    if (m.type === "gone" && m.source in browsers) {
        const out = Object.assign({}, browsers);
        delete out[m.source];
        return out;
    }
    return browsers;
}

// Whether a toplevel's title is a window of `browser` whose active tab is
// `title`. Chrome and Brave title a window "TAB - Google Chrome" or
// "TAB - Brave", with a profile's name beside it in some versions, so the
// browser's own name has to be one of the parts after the tab's: another
// app's "TAB - kitty" isn't the browser's. `app` is the toplevel's class,
// which a title that's just the tab's must also show to be a browser's.
export function titleMatches(windowTitle, tabTitle, browser, app = "") {
    const w = String(windowTitle ?? "");
    const t = String(tabTitle ?? "");
    const b = String(browser ?? "");
    if (t === "") {
        return false;
    }
    if (w === t) {
        return BROWSER_CLASS.test(String(app ?? ""));
    }
    if (b === "" || !w.startsWith(`${t} - `)) {
        return false;
    }
    return w.slice(t.length + 3).split(" - ").includes(b);
}

// The classes Chromium browsers give their windows.
const BROWSER_CLASS = /chrom|brave|vivaldi|opera|edge/i;

// Each browser window's toplevel: [{source, windowId, address}], the first
// toplevel (in `windows`' order) whose title matches, each toplevel taken
// once, so two windows showing the same title both go under the first
// (SPEC.md §8.3).
export function placed(browsers, windows) {
    const taken = new Set();
    const out = [];
    for (const source of Object.keys(browsers).sort()) {
        for (const bw of browsers[source].windows) {
            const fits = (x) => titleMatches(x.title, bw.title, browsers[source].browser, x.app);
            const w = windows.find((x) => fits(x) && !taken.has(x.address)) ?? windows.find(fits);
            if (w) {
                taken.add(w.address);
            }
            out.push({ source, windowId: bw.id, address: w ? w.address : null });
        }
    }
    return out;
}

// The tab rows to list under each toplevel: {address: [row]}, and those
// whose window wasn't found, under "". A row is the launcher's shape, kind
// "tab", with what Enter needs: the browser (`source`), the tab and window
// IDs, and the toplevel to focus. Its icon is its window's app.
export function tabRows(browsers, windows) {
    const where = {};
    for (const p of placed(browsers, windows)) {
        where[`${p.source}/${p.windowId}`] = p.address;
    }
    const app = {};
    for (const w of windows) {
        app[w.address] = w;
    }
    const out = {};
    for (const source of Object.keys(browsers).sort()) {
        const b = browsers[source];
        for (const bw of b.windows) {
            const address = where[`${source}/${bw.id}`] ?? null;
            const w = address === null ? null : app[address];
            for (const t of bw.tabs) {
                const key = address ?? "";
                (out[key] = out[key] ?? []).push({
                    item: {
                        kind: "tab",
                        id: `${source}/${t.id}`,
                        name: t.title || t.url || "Untitled",
                        sub: ["tab", b.browser, t.active ? "showing" : "", hostOf(t.url)].filter((s) => s).join(" · "),
                        icon: w ? w.app : "",
                        source,
                        tabId: t.id,
                        windowId: bw.id,
                        address,
                        // A minimized browser goes back where it came from
                        // (SPEC.md §6.7), as its window's row does.
                        restoreTo: w ? minimizedFrom(w.workspace) : null,
                        url: t.url,
                    },
                    positions: [],
                    section: "",
                });
            }
        }
    }
    return out;
}

function hostOf(url) {
    const m = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(String(url ?? ""));
    return m ? m[1] : "";
}

// What the Windows tab says about tabs, or "" when they're listed:
// `running` is whether `tide-tabs serve` runs, `browsers` who's connected.
export function tabsNote(running, browsers) {
    if (!running) {
        return "Browser tabs aren't listed: tide-tabs isn't running";
    }
    if (Object.keys(browsers).length === 0) {
        return "Browser tabs aren't listed: no browser has tileco connected";
    }
    return "";
}

// The line asking a browser to bring a tab up.
export function activateLine(item) {
    return JSON.stringify({ type: "activate", source: item.source, tabId: item.tabId, windowId: item.windowId });
}
