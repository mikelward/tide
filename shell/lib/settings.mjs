// The settings panel (SPEC.md §16), as pure functions the QML binds to.

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
        about: "Each monitor's scale and where it goes beside the others, kept with the monitor whichever port it's in. Hyprland may round a scale to one that divides the screen evenly. One set for a monitor in hyprland.local.lua still wins.",
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
        about: "For every mouse, or one chosen by name with ‹ and ›, whose own settings apply over every mouse's. One set for a single mouse in hyprland.local.lua still wins.",
        advanced: null,
    },
    {
        id: "touchpad",
        group: "hardware",
        label: "Touchpad",
        icon: "input-touchpad-symbolic",
        keywords: ["trackpad", "pointing stick", "tap to click", "left-handed", "right-handed"],
        about: "For every touchpad, apart from the mice, or one chosen by name with ‹ and ›, whose own settings apply over every touchpad's. One set for a single touchpad in hyprland.local.lua still wins.",
        advanced: null,
    },
    {
        id: "keyboard",
        group: "hardware",
        label: "Keyboard",
        icon: "input-keyboard-symbolic",
        keywords: ["layout", "xkb", "repeat", "dvorak"],
        about: "For every keyboard. A layout is XKB's name for it, such as us, or us,de for two; a variant is one such as dvorak, or none. One set in hyprland.local.lua still wins.",
        advanced: null,
    },
    {
        id: "power",
        group: "hardware",
        label: "Power",
        icon: "battery-good-symbolic",
        keywords: ["battery", "power profile", "lid", "laptop"],
        about: "The battery, and the power profile, which power-profiles-daemon sets for the whole machine. Closing the lid with no other monitor suspends, locks or does nothing; with one, the laptop's screen just turns off, as it always has.",
        advanced: null,
    },
    {
        id: "layouts",
        group: "windows",
        label: "Layouts",
        icon: "view-dual-symbolic",
        keywords: ["tiling", "master", "monocle", "ultrawide"],
        about: "How a new workspace starts, by its monitor's shape, and each layout's master width and count. A change applies to every workspace, which keeps its layout but loses a width or count changed with the keys.",
        advanced: null,
    },
    {
        id: "workspaces",
        group: "windows",
        label: "Workspaces",
        icon: "view-grid-symbolic",
        keywords: ["home workspace", "standing workspaces", "name patterns"],
        about: "Standing workspaces are always on the bar, in this order; the first is home, made at login, where only home's apps go. Home's apps start there at login: a program, such as gmail, or a web address, opened as a Chrome app window. A window class or a site goes there without starting. A name pattern is a regular expression tried against a new window's title, in order: its first capture group names the window's workspace.",
        advanced: null,
    },
    {
        id: "appearance",
        group: "general",
        label: "Appearance",
        icon: "night-light-symbolic",
        keywords: ["wallpaper", "background", "sunset", "sunrise"],
        about: "Light or dark for the shell and apps. By the clock goes light and dark at the times below; sunrise and sunset needs this machine's latitude and longitude, north and east positive. A switch made now lasts until the next change.",
        advanced: null,
    },
    {
        id: "notifications",
        group: "general",
        label: "Notifications",
        icon: "preferences-system-notifications-symbolic",
        keywords: ["dnd", "quiet hours", "schedule", "muted apps"],
        about: "Do not disturb holds popups; they still go to the notification center. On a schedule, it turns on as the time comes, and off as it ends unless you changed it meanwhile; a window ending earlier than it starts runs into the next day. A muted app or site never pops up and never asks for attention: an app ID, such as org.gnome.Nautilus, or site:chat.google.com.",
        advanced: null,
    },
    {
        id: "clipboard",
        group: "general",
        label: "Clipboard",
        icon: "edit-paste-symbolic",
        keywords: ["copy history", "paste history"],
        about: "What you copy is kept for the picker on Super+C, the newest first, apart from passwords a password manager marks. Off, new copies aren't kept; what's kept stays until it's cleared. A smaller number trims the history at the next copy.",
        advanced: null,
    },
    {
        id: "clocks",
        group: "general",
        label: "Clocks",
        icon: "preferences-system-time-symbolic",
        keywords: ["time zone", "timezone", "world clock", "24 hour"],
        about: "The bar's clocks, left to right, before the local one, which is always last; a clock in the local zone is hidden. A label is any text, none for just the time, or abbr for the zone's abbreviation, such as PDT. The list is this machine's own once changed.",
        advanced: null,
    },
    {
        id: "idle",
        group: "general",
        label: "Idle",
        icon: "weather-clear-night-symbolic",
        keywords: ["timeout", "blank", "dim"],
        about: "Each step counts from your last input. On AC power the machine suspends only with Suspend on AC on; otherwise the displays just stay off.",
        advanced: null,
    },
    {
        id: "startup",
        group: "general",
        label: "Start at login",
        icon: "system-run-symbolic",
        keywords: ["startup", "autostart", "login items"],
        about: "Commands started once as you log in, one after another in this order, without taking focus: each is a program and its arguments, such as google-calendar, and one already running isn't started again. A home app's window goes to home. A change takes effect at the next login. The list is this machine's own once changed.",
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
        about: "The key bindings Hyprland has now, from conf's hyprland.lua and hyprland.local.lua, in their order. What one does is its description in hl.bind.",
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

// The page after moving `step` pages from `index`, stopping at either end.
export function movedPage(index, step) {
    return Math.max(0, Math.min(PAGES.length - 1, index + step));
}
