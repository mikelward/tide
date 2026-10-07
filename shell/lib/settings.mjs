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
        about: "Each step counts from your last input. On AC power the machine never suspends; the displays just stay off.",
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
        about: "For every mouse. A setting made here applies to all of them; one set for a single mouse in hyprland.local.lua still wins.",
        advanced: null,
    },
    {
        id: "touchpad",
        label: "Touchpad",
        icon: "input-touchpad-symbolic",
        about: "For every touchpad, apart from the mice. One set for a single touchpad in hyprland.local.lua still wins.",
        advanced: null,
    },
]);

// The page after moving `step` pages from `index`, stopping at either end.
export function movedPage(index, step) {
    return Math.max(0, Math.min(PAGES.length - 1, index + step));
}
