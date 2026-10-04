// The network icon's VPN lock and the popover's VPNs (SPEC.md §7.4).
// Quickshell.Networking 0.3 doesn't list VPN connections, so these come
// from NetworkManager's own nmcli, read as plain text here:
//
//   LC_ALL=C nmcli -t -f NAME,UUID,TYPE,ACTIVE,STATE connection show

// The connection types that count as a VPN.
const VPN_TYPES = new Set(["vpn", "wireguard"]);

// In the C locale, since nmcli translates "yes" and "activated", and its
// manual asks scripts that read its output to set LC_ALL=C.
export const LIST_COMMAND = ["env", "LC_ALL=C", "nmcli", "-t", "-f", "NAME,UUID,TYPE,ACTIVE,STATE", "connection", "show"];

// One line of nmcli's terse output, split into its fields. Terse output
// escapes ":" and "\" inside a field with "\", so a VPN named "a:b" is
// "a\:b".
export function splitTerse(line) {
    const fields = [""];
    for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === "\\" && i + 1 < line.length) {
            fields[fields.length - 1] += line[++i];
        } else if (c === ":") {
            fields.push("");
        } else {
            fields[fields.length - 1] += c;
        }
    }
    return fields;
}

// The VPN connections in LIST_COMMAND's output: {vpns, errors}. A vpn is
// {name, uuid, active, state}, state being nmcli's ("activated",
// "activating", "deactivating") or "" when it's down. A line that doesn't
// have the five fields is an error, so a change in nmcli's output shows in
// the log rather than as VPNs that quietly vanished.
export function parseConnections(text) {
    const vpns = [];
    const errors = [];
    for (const line of String(text).split("\n")) {
        if (line.trim() === "") {
            continue;
        }
        const f = splitTerse(line);
        if (f.length !== 5 || f[1] === "") {
            errors.push(`nmcli: can't read connection line ${JSON.stringify(line)}`);
            continue;
        }
        const [name, uuid, type, active, state] = f;
        if (VPN_TYPES.has(type)) {
            vpns.push({ name, uuid, active: active === "yes", state: active === "yes" ? state : "" });
        }
    }
    return { vpns, errors };
}

// The lock on the network icon: "on" while any VPN is up, "connecting"
// while one is coming up and none is, else "".
export function lock(vpns) {
    if (vpns.some((v) => v.state === "activated")) {
        return "on";
    }
    return vpns.some((v) => v.state === "activating") ? "connecting" : "";
}

// The popover's VPNs: the ones up or changing first, then by name.
export function vpnList(vpns) {
    const rank = (v) => (v.active ? 0 : 1);
    return [...vpns].sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name));
}

// A VPN's line in the popover. `failed` is the last toggle that didn't
// work, {uuid, action} with action "up" or "down", or null. It shows while
// the VPN is still where that toggle failed to move it from, so a VPN that
// stayed up after a failed "down" says so rather than "Connected".
export function vpnStatus(vpn, failed) {
    if (failed?.uuid === vpn.uuid) {
        if (failed.action === "up" && !vpn.active) {
            return "Couldn't connect";
        }
        if (failed.action === "down" && vpn.active) {
            return "Couldn't disconnect";
        }
    }
    switch (vpn.state) {
    case "activated":
        return "Connected";
    case "activating":
        return "Connecting…";
    case "deactivating":
        return "Disconnecting…";
    default:
        return "";
    }
}

// The failure to keep after a read of `vpns`: null once its VPN has
// reached the state the failed toggle aimed for (up, or down), or has gone,
// so an old failure can't come back the next time it moves the other way.
export function settledFailure(failed, vpns) {
    if (!failed) {
        return null;
    }
    const vpn = vpns.find((v) => v.uuid === failed.uuid);
    if (!vpn || vpn.active === (failed.action === "up")) {
        return null;
    }
    return failed;
}

// What a click on a VPN's row does: "down" if it's up or coming up, else
// "up".
export function toggleAction(vpn) {
    return vpn.active ? "down" : "up";
}

// The command for that, by uuid, since names needn't be unique.
export function toggleCommand(vpn) {
    return ["nmcli", "connection", toggleAction(vpn), "uuid", vpn.uuid];
}
