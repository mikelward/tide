// The bar's network icon and popover (SPEC.md §7.4), as pure functions the
// QML binds to. Devices and networks are Quickshell.Networking's
// (NetworkManager), passed in as plain objects: a device is {type,
// connected, networks}, with `networks` an array.

// Quickshell's DeviceType, ConnectionState and NetworkConnectivity.
export const WIFI = 1;
export const WIRED = 2;
const CONNECTING = 1;
const DISCONNECTING = 3;
const PORTAL = 2;
const LIMITED = 3;

// The Wi-Fi strength icon for a signal from 0 to 1, as GNOME buckets it.
export function signalIcon(strength) {
    const s = Number.isFinite(strength) ? strength : 0;
    const level = s > 0.8 ? "excellent" : s > 0.55 ? "good" : s > 0.3 ? "ok" : s > 0.05 ? "weak" : "none";
    return `network-wireless-signal-${level}-symbolic`;
}

// The connected Wi-Fi network, if any.
export function connectedWifi(devices) {
    for (const d of devices) {
        if (d.type === WIFI) {
            const n = d.networks.find((x) => x.connected);
            if (n) {
                return n;
            }
        }
    }
    return null;
}

// The bar icon: wired when a cable is connected, else the Wi-Fi strength,
// else Wi-Fi off or offline. A connection that can't reach the internet
// (a captive portal, or limited) shows its "no route" form. Hidden where
// NetworkManager reports no devices at all.
export function networkIcon({ devices, wifiEnabled, connectivity }) {
    if (devices.length === 0) {
        return { visible: false, icon: "" };
    }
    const noRoute = connectivity === PORTAL || connectivity === LIMITED;
    if (devices.some((d) => d.type === WIRED && d.connected)) {
        return { visible: true, icon: noRoute ? "network-wired-no-route-symbolic" : "network-wired-symbolic" };
    }
    const wifi = connectedWifi(devices);
    if (wifi) {
        return { visible: true, icon: noRoute ? "network-wireless-no-route-symbolic" : signalIcon(wifi.signalStrength) };
    }
    const hasWifi = devices.some((d) => d.type === WIFI);
    return { visible: true, icon: hasWifi && !wifiEnabled ? "network-wireless-disabled-symbolic" : "network-offline-symbolic" };
}

// A Wi-Fi network's line in the popover.
export function wifiStatus(network) {
    if (network.state === CONNECTING) {
        return "Connecting…";
    }
    if (network.state === DISCONNECTING) {
        return "Disconnecting…";
    }
    if (network.connected) {
        return "Connected";
    }
    return network.known ? "Saved" : "";
}

// The Wi-Fi networks the popover lists: connected first, then saved ones,
// then by signal, strongest first. Networks with no name (hidden SSIDs)
// are left out, since there's nothing to click on.
export function wifiList(devices) {
    const rank = (n) => (n.connected ? 0 : n.known ? 1 : 2);
    return devices.filter((d) => d.type === WIFI)
        .reduce((all, d) => all.concat(d.networks), [])
        .filter((n) => n.name)
        .sort((a, b) => rank(a) - rank(b) || (b.signalStrength ?? 0) - (a.signalStrength ?? 0)
            || a.name.localeCompare(b.name));
}

// Which network popovers are open, across monitors: `open` with `popover`
// added when it shows and removed when it hides or goes away. A set
// rather than a count, so a repeated or missed transition can't leave
// scanning stuck on or off.
export function trackOpen(open, popover, visible) {
    const rest = open.filter((p) => p !== popover);
    return visible ? [...rest, popover] : rest;
}

// Wi-Fi scanning runs while any network popover is open.
export function shouldScan(open) {
    return open.length > 0;
}

// A popover's connection prompt: `pending`, the network it last asked to
// connect and so the only one whose failure it answers, and `asking`, the
// network waiting for a password. Events: {type: "connect", network},
// {type: "failed", network, noSecrets}, {type: "submit"} (Enter on the
// password), {type: "cancel"} (Escape, or the popover closing), and
// {type: "wifi", enabled}, from whatever switched it.
export const NO_PROMPT = Object.freeze({ pending: null, asking: null });

export function prompt(state, event) {
    switch (event.type) {
    case "connect":
        return Object.freeze({ pending: event.network, asking: null });
    case "failed":
        // A late failure for a network this popover has moved on from.
        if (event.network !== state.pending) {
            return state;
        }
        return Object.freeze({ pending: null, asking: event.noSecrets ? event.network : null });
    case "submit":
        return state.asking ? Object.freeze({ pending: state.asking, asking: null }) : state;
    case "cancel":
        return NO_PROMPT;
    case "wifi":
        // Off by any means (this popover, a key, another client) cancels:
        // no password typed for a radio that's off.
        return event.enabled ? state : NO_PROMPT;
    default:
        throw new Error(`unknown prompt event: ${event.type}`);
    }
}
