// The settings panel (SPEC.md §16), as pure functions the QML binds to.

// Its pages, in the sidebar's order. Each says what to know first
// (`about`, or ""), and links out to the app that does the rest
// (`advanced`, run through `tide launch`), unless nothing does (null); a
// page with nothing of its own yet is only those.
export const PAGES = Object.freeze([
    {
        id: "idle",
        label: "Idle",
        icon: "weather-clear-night-symbolic",
        about: "Each step counts from your last input. On AC power the machine suspends only with Suspend on AC on; otherwise the displays just stay off.",
        advanced: null,
    },
    {
        id: "sound",
        label: "Sound",
        icon: "audio-speakers-symbolic",
        about: "",
        advanced: { label: "Advanced sound settings", command: ["pavucontrol"] },
    },
    {
        id: "network",
        label: "Network",
        icon: "network-wireless-symbolic",
        about: "Wi-Fi and VPNs are in the bar's network menu. Setting up a connection is in NetworkManager's editor.",
        advanced: { label: "Network connections", command: ["nm-connection-editor"] },
    },
    {
        id: "bluetooth",
        label: "Bluetooth",
        icon: "bluetooth-active-symbolic",
        about: "Connecting a paired device is in the bar's Bluetooth menu. Pairing a new one is in Blueman.",
        advanced: { label: "Bluetooth devices", command: ["blueman-manager"] },
    },
    {
        id: "mouse",
        label: "Mouse",
        icon: "input-mouse-symbolic",
        about: "For every mouse, or one chosen by name with ‹ and ›, whose own settings apply over every mouse's. One set for a single mouse in hyprland.local.lua still wins.",
        advanced: null,
    },
    {
        id: "touchpad",
        label: "Touchpad",
        icon: "input-touchpad-symbolic",
        about: "For every touchpad, apart from the mice, or one chosen by name with ‹ and ›, whose own settings apply over every touchpad's. One set for a single touchpad in hyprland.local.lua still wins.",
        advanced: null,
    },
    {
        id: "keyboard",
        label: "Keyboard",
        icon: "input-keyboard-symbolic",
        about: "For every keyboard. A layout is XKB's name for it, such as us, or us,de for two; a variant is one such as dvorak, or none. One set in hyprland.local.lua still wins.",
        advanced: null,
    },
    {
        id: "clocks",
        label: "Clocks",
        icon: "preferences-system-time-symbolic",
        about: "The bar's clocks, left to right, before the local one, which is always last; a clock in the local zone is hidden. A label is any text, none for just the time, or abbr for the zone's abbreviation, such as PDT. The list is this machine's own once changed.",
        advanced: null,
    },
    {
        id: "keys",
        label: "Keys",
        icon: "preferences-desktop-keyboard-shortcuts-symbolic",
        about: "The key bindings Hyprland has now, from conf's hyprland.lua and hyprland.local.lua, in their order. What one does is its description in hl.bind.",
        advanced: null,
    },
    {
        id: "layouts",
        label: "Layouts",
        icon: "view-dual-symbolic",
        about: "How a new workspace starts, by its monitor's shape, and each layout's master width and count. A change applies to every workspace, which keeps its layout but loses a width or count changed with the keys.",
        advanced: null,
    },
    {
        id: "appearance",
        label: "Appearance",
        icon: "night-light-symbolic",
        about: "Light or dark for the shell and apps. By the clock goes light and dark at the times below; sunrise and sunset needs this machine's latitude and longitude, north and east positive. A switch made now lasts until the next change.",
        advanced: null,
    },
]);

// The page after moving `step` pages from `index`, stopping at either end.
export function movedPage(index, step) {
    return Math.max(0, Math.min(PAGES.length - 1, index + step));
}
