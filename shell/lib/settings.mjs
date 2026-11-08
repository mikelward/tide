// The settings panel (SPEC.md §16), as pure functions the QML binds to.

import { matches, searchedRows } from "./settingssearch.mjs";

// The sidebar's groups, in its order, each under a heading that can't be
// chosen.
export const GROUPS = Object.freeze([
    { id: "hardware", label: "Hardware" },
    { id: "windows", label: "Windows" },
    { id: "general", label: "General" },
]);

// Its pages, in the sidebar's order, each in its `group`, and a group's
// pages together. Each has the words that find it in the launcher
// (`keywords`, beside its label), and says what to know first (`about`, or
// ""), and links out to the app that does the rest (`advanced`, run
// through `tide launch`), unless nothing does (null); a page with nothing
// of its own yet is only those.
export const PAGES = Object.freeze([
    {
        id: "displays",
        group: "hardware",
        label: "Displays",
        icon: "video-display-symbolic",
        keywords: ["monitors", "scale", "resolution"],
        about: "Scale and position for each monitor.",
        advanced: { label: "Arrange displays", command: ["nwg-displays"] },
    },
    {
        id: "sound",
        group: "hardware",
        label: "Sound",
        icon: "audio-speakers-symbolic",
        keywords: ["audio", "volume", "speakers", "headphones", "microphone"],
        about: "",
        advanced: { label: "Advanced sound settings", command: ["pavucontrol"] },
    },
    {
        id: "network",
        group: "hardware",
        label: "Network",
        icon: "network-wireless-symbolic",
        keywords: ["wi-fi", "wifi", "ethernet", "vpn"],
        about: "Wi-Fi and VPNs are in the bar's network menu. Setting up a connection is in NetworkManager's editor.",
        advanced: { label: "Network connections", command: ["nm-connection-editor"] },
    },
    {
        id: "bluetooth",
        group: "hardware",
        label: "Bluetooth",
        icon: "bluetooth-active-symbolic",
        keywords: ["pairing", "headset"],
        about: "Connecting a paired device is in the bar's Bluetooth menu. Pairing a new one is in Blueman.",
        advanced: { label: "Bluetooth devices", command: ["blueman-manager"] },
    },
    {
        id: "mouse",
        group: "hardware",
        label: "Mouse",
        icon: "input-mouse-symbolic",
        keywords: ["pointer", "left-handed", "right-handed", "speed"],
        about: "All mice, or one at a time with ‹ and ›.",
        advanced: null,
    },
    {
        id: "touchpad",
        group: "hardware",
        label: "Touchpad",
        icon: "input-touchpad-symbolic",
        keywords: ["trackpad", "pointing stick", "tap to click", "left-handed", "right-handed"],
        about: "All touchpads, or one at a time with ‹ and ›.",
        advanced: null,
    },
    {
        id: "keyboard",
        group: "hardware",
        label: "Keyboard",
        icon: "input-keyboard-symbolic",
        keywords: ["layout", "xkb", "repeat", "dvorak"],
        about: "Layout, such as us, or us,de for two. Variant, such as dvorak.",
        advanced: null,
    },
    {
        id: "power",
        group: "hardware",
        label: "Power",
        icon: "battery-good-symbolic",
        keywords: ["battery", "power profile", "lid", "laptop"],
        about: "With an external monitor connected, closing the lid only turns off the laptop screen.",
        advanced: null,
    },
    {
        id: "layouts",
        group: "windows",
        label: "Layouts",
        icon: "view-dual-symbolic",
        keywords: ["tiling", "master", "monocle", "ultrawide"],
        about: "New workspaces start with these layouts. Changes here reset widths set with the keys.",
        advanced: null,
    },
    {
        id: "workspaces",
        group: "windows",
        label: "Workspaces",
        icon: "view-grid-symbolic",
        keywords: ["home workspace", "standing workspaces", "name patterns"],
        about: "Workspaces listed here are always on the bar. The first is home. Pinned apps ignore close keys like Ctrl+W.",
        advanced: null,
    },
    {
        id: "floating",
        group: "windows",
        label: "Floating",
        icon: "window-restore-symbolic",
        keywords: ["float", "window rules", "dialogs", "tiling"],
        about: "These apps open floating. Add a title to float only some of their windows.",
        advanced: null,
    },
    {
        id: "appearance",
        group: "general",
        label: "Appearance",
        icon: "night-light-symbolic",
        keywords: ["wallpaper", "background", "sunset", "sunrise"],
        about: "Light or dark, for the bar and apps. Switching by hand lasts until the next scheduled change.",
        advanced: null,
    },
    {
        id: "notifications",
        group: "general",
        label: "Notifications",
        icon: "preferences-system-notifications-symbolic",
        keywords: ["dnd", "quiet hours", "schedule", "muted apps"],
        about: "Do not disturb hides popups. They still go to the notification center. A schedule that ends before it starts runs overnight.",
        advanced: null,
    },
    {
        id: "clipboard",
        group: "general",
        label: "Clipboard",
        icon: "edit-paste-symbolic",
        keywords: ["copy history", "paste history"],
        about: "Keeps what you copy for Super+V. Skips passwords from password managers.",
        advanced: null,
    },
    {
        id: "clocks",
        group: "general",
        label: "Clocks",
        icon: "preferences-system-time-symbolic",
        keywords: ["time zone", "timezone", "world clock", "24 hour"],
        about: "Extra clocks, left to right. Bar shows one in the bar; the clock popover lists them all. Local time is always last. A label can be any text, such as PT or LAX, or abbr for the zone's short name.",
        advanced: null,
    },
    {
        id: "idle",
        group: "general",
        label: "Idle",
        icon: "weather-clear-night-symbolic",
        keywords: ["timeout", "blank", "dim"],
        about: "",
        advanced: null,
    },
    {
        id: "startup",
        group: "general",
        label: "Start at login",
        icon: "system-run-symbolic",
        keywords: ["startup", "autostart", "login items"],
        about: "These start when you log in, in this order. One already running is skipped. Changes apply at your next login.",
        advanced: null,
    },
]);

// Parts of a page that open on their own, as pages do: from the launcher
// by their label and `keywords`, and by `id` over IPC, which opens `page`
// scrolled to them. Keys was a page of its own, so its id still opens the
// shortcuts.
export const SECTIONS = Object.freeze([
    {
        id: "keys",
        page: "keyboard",
        label: "Keyboard shortcuts",
        icon: "preferences-desktop-keyboard-shortcuts-symbolic",
        keywords: ["shortcuts", "bindings", "hotkeys"],
        about: "",
    },
]);

// The index of the page `id` names, or -1.
export function pageIndex(id) {
    return PAGES.findIndex(p => p.id === id);
}

// Where `id` opens the panel, a page's or a section's: {index, section},
// with section the section's id or "", or null for neither.
export function opened(id) {
    const index = pageIndex(id);
    if (index >= 0) {
        return { index, section: "" };
    }
    const section = SECTIONS.find(s => s.id === id);
    return section ? { index: pageIndex(section.page), section: section.id } : null;
}

// What `id` names as a section, or null.
export function section(id) {
    return SECTIONS.find(s => s.id === id) ?? null;
}

// The sidebar, top to bottom: each group's heading ({heading: label}),
// then its pages ({page: index into PAGES}).
export function sidebarRows() {
    const rows = [];
    for (const group of GROUPS) {
        rows.push({ heading: group.label, page: -1 });
        PAGES.forEach((p, index) => {
            if (p.group === group.id) {
                rows.push({ heading: "", page: index });
            }
        });
    }
    return rows;
}

// The page after moving `step` pages from `index` through `kept`, the
// pages the sidebar shows (every page by default), stopping at either end.
// From a page not in `kept`, the first kept; with none kept, `index`.
export function movedPage(index, step, kept = PAGES.map((_, i) => i)) {
    if (kept.length === 0) {
        return index;
    }
    const at = kept.indexOf(index);
    if (at < 0) {
        return kept[0];
    }
    return kept[Math.max(0, Math.min(kept.length - 1, at + step))];
}

// What finds the page at `index` in the sidebar's search (SPEC.md §16):
// its label and keywords, and those of its sections, so "shortcuts" finds
// Keyboard.
export function pageTerms(index) {
    const page = PAGES[index];
    const terms = [page.label, ...(page.keywords ?? [])];
    for (const s of SECTIONS) {
        if (s.page === page.id) {
            terms.push(s.label, ...(s.keywords ?? []));
        }
    }
    return terms;
}

// The sidebar's rows that `query` keeps: sidebarRows() less the pages it
// doesn't find and the headings left with none.
export function searchedSidebar(query) {
    return searchedRows(sidebarRows(), query, r => r.heading !== "", r => pageTerms(r.page));
}

// The pages among `rows` (sidebar rows), in order.
export function keptPages(rows) {
    return rows.filter(r => r.heading === "").map(r => r.page);
}

// The section of the page at `index` that `query` found it by, when the
// page's own label and keywords don't find it, so the panel scrolls
// there; else "". The query's words may be the page's and the section's
// together, as "repeat shortcuts" is Keyboard's and its shortcuts'.
export function searchedSection(index, query) {
    const page = PAGES[index];
    const own = [page.label, ...(page.keywords ?? [])];
    if (matches(query, own)) {
        return "";
    }
    const found = SECTIONS.find(s => s.page === page.id && matches(query, [...own, s.label, ...(s.keywords ?? [])]));
    return found ? found.id : "";
}
