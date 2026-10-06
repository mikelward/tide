// The settings panel (SPEC.md §16), as pure functions the QML binds to.

// Its pages, in the sidebar's order. Each links out to the app that does
// the rest (`advanced`), which runs through `tide launch`, and says what
// the bar already does (`about`); a page with nothing of its own yet is
// only those.
export const PAGES = Object.freeze([
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
]);

// The page after moving `step` pages from `index`, stopping at either end.
export function movedPage(index, step) {
    return Math.max(0, Math.min(PAGES.length - 1, index + step));
}
