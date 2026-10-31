// The shell's side of tide-agent, NetworkManager's secret agent (SPEC.md
// §5.6), as pure functions that shell/AgentData.qml, AgentPrompt.qml and
// NetworkPopover.qml call. tide-agent does the D-Bus side and sends one
// JSON object per line; these decide where and when each request is
// asked. A line can hold a saved password, so nothing here puts one in an
// error or a log message.

// tide-agent's messages, parsed: {message} or {error}. The error never
// quotes the line.
const MESSAGE_TYPES = ["request", "cancel", "status", "bt-status", "lock", "missed", "fault"];

export function parseLine(text) {
    let m = null;
    try {
        m = JSON.parse(text);
    } catch (e) {
        return { error: "tide-agent sent a line that isn't JSON" };
    }
    if (m === null || typeof m !== "object" || MESSAGE_TYPES.indexOf(m.type) < 0) {
        return { error: "tide-agent sent a message the shell doesn't know" };
    }
    if ((m.type === "request" || m.type === "cancel") && typeof m.id !== "string") {
        return { error: `tide-agent sent a ${m.type} with no id` };
    }
    return { message: m };
}

// The shell's answers, as lines for tide-agent's stdin: "reply" with
// values, "go" (run a VPN's own dialog), "cancel" (you said no) and
// "decline" (the shell won't ask).
export function answerLine(type, id, values) {
    const a = { type: type, id: id };
    if (type === "reply") {
        a.values = values || {};
    }
    return JSON.stringify(a) + "\n";
}

// How long after the shell brings a connection up (a VPN row) a request
// for it still counts as yours: long enough for a slow VPN to ask.
export const STARTED_MS = 10 * 1000;

// startedAt is {uuid: ms}, the connections the shell brought up, which
// `noteStarted` adds to and prunes.
export function noteStarted(startedAt, uuid, now) {
    const next = {};
    for (const k in startedAt) {
        if (now - startedAt[k] < STARTED_MS) {
            next[k] = startedAt[k];
        }
    }
    next[uuid] = now;
    return next;
}

// Where a request is asked (§5.6, §14.1):
//   "popover": a Wi-Fi key for the network an open popover just tried, in
//     that popover's row, which already has the keyboard;
//   "prompt": the shell's prompt, with the keyboard, for a connection the
//     shell brought up in the last 10 s;
//   "guard": NetworkManager says you asked (nmcli connection up), so the
//     focus guard decides between the prompt and a notification;
//   "notify": a notification, for anything NetworkManager asks on its own,
//     and every Bluetooth pairing, which a device starts (blueman's own
//     agent answers the ones blueman-manager starts);
//   "display": a code to type on a Bluetooth device, shown without the
//     keyboard, since there's nothing to type here.
// `pending` is the names of the networks the open popovers tried.
export function route(request, pending, startedAt, now) {
    if (request.kind === "bt-display") {
        return "display";
    }
    if (request.kind === "wifi" && request.ssid && (pending || []).indexOf(request.ssid) >= 0) {
        return "popover";
    }
    const uuid = request.connection && request.connection.uuid;
    const at = uuid && startedAt ? startedAt[uuid] : undefined;
    if (at !== undefined && now - at < STARTED_MS) {
        return "prompt";
    }
    return request.userRequested ? "guard" : "notify";
}

// The popover a "popover" request is asked in: of `popovers`, each
// {popover, visible, pendingName}, the first shown that tried the
// request's network, else null.
export function ownerFor(request, popovers) {
    for (const p of popovers || []) {
        if (p.visible && p.pendingName && p.pendingName === request.ssid) {
            return p.popover;
        }
    }
    return null;
}

// Whether a popover still holds the request it was given: it's there, shown,
// and still trying the request's network. When it isn't (closed, its monitor
// unplugged, another network clicked), the request moves on by `route` with
// no popover, so it's never left held where nothing shows it.
export function holds(request, owner) {
    return !!owner && owner.visible && owner.pendingName === request.ssid;
}

// What becomes of an outstanding request, the one shown or one waiting,
// whenever anything around it changes (SPEC.md §5.6). AgentData asks this
// of every one of them after each change, so each ends in one place:
//   "drop": tide-agent has gone, and NetworkManager's call with it, so
//     there's nothing to answer;
//   "decline": the session locked, so it's answered no at once, and kept
//     for the missed-request offer after unlock (missedOnDecline);
//   "reroute": the popover it was shown in let it go (holds);
//   "keep": nothing about it changed.
// env is {helperRunning, locked, showing, ownerHolds}; a waiting request
// has no showing.
export function fate(request, env) {
    if (!env.helperRunning) {
        return "drop";
    }
    if (env.locked) {
        return "decline";
    }
    if (env.showing === "popover" && !env.ownerHolds) {
        return "reroute";
    }
    return "keep";
}

// Whether a declined request is offered again after unlock: one with a
// connection to bring up. A Bluetooth pairing isn't: the device asks again.
export function missedOnDecline(request) {
    return !isBluetooth(request) && !!(request.connection && request.connection.uuid);
}

// The name a request goes by: a Wi-Fi network's SSID, else the
// connection's.
export function connectionName(request) {
    return request.ssid || (request.connection && request.connection.id) || "the network";
}

export function escapeMarkup(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// The notification that offers a request's prompt. Like polkit's, it's
// critical and from `tide`, so it waits and shows through Do not disturb,
// and a click on it opens the prompt as its button does. Names come from
// the air or a connection file, so they're escaped.
export const OPEN = "open";

export function isBluetooth(request) {
    return String(request.kind || "").indexOf("bt-") === 0;
}

export function notifyCommand(request) {
    const name = connectionName(request);
    const dialog = request.kind === "vpn-dialog";
    const bt = isBluetooth(request);
    const label = dialog ? "Sign in" : bt ? "Open" : "Enter password";
    let what = `“${name}” needs a password`;
    if (request.kind === "wifi") {
        what = `Wi-Fi “${name}” needs a password`;
    } else if (dialog) {
        what = `“${name}” needs you to sign in`;
    } else if (request.kind === "bt-service") {
        what = `“${name}” asks to connect`;
    } else if (bt) {
        what = `“${name}” asks to pair`;
    }
    return [
        "notify-send",
        "--app-name=tide",
        "--urgency=critical",
        "--icon=dialog-password-symbolic",
        `--action=default=${label}`,
        `--action=${OPEN}=${label}`,
        "--wait",
        escapeMarkup(what),
        escapeMarkup(request.message || "")
    ];
}

// What became of it, from notify-send --wait: "open", "dismissed" (which
// cancels the request), or "failed" (couldn't be shown: the prompt then
// shows without the keyboard, so a click opens it).
export function notifyOutcome(started, code, output) {
    if (!started || code !== 0) {
        return "failed";
    }
    const lines = String(output ?? "").split("\n").map(l => l.trim());
    return lines.indexOf(OPEN) >= 0 || lines.indexOf("default") >= 0 ? "open" : "dismissed";
}

// Missed requests (declined while locked, or unanswered), one per
// connection, kept until the lock goes.
export function addMissed(missed, connection) {
    if (!connection || !connection.uuid) {
        return missed;
    }
    return missed.filter(c => c.uuid !== connection.uuid).concat([connection]);
}

export const CONNECT = "connect";

export function missedCommand(connection) {
    return [
        "notify-send",
        "--app-name=tide",
        "--icon=network-error-symbolic",
        `--action=default=Connect`,
        `--action=${CONNECT}=Connect`,
        "--wait",
        escapeMarkup(`Couldn't connect to “${connection.id || "the network"}”`),
        "It needs a password."
    ];
}

export function missedOutcome(started, code, output) {
    if (!started || code !== 0) {
        return "failed";
    }
    const lines = String(output ?? "").split("\n").map(l => l.trim());
    return lines.indexOf(CONNECT) >= 0 || lines.indexOf("default") >= 0 ? "connect" : "dismissed";
}

// Connect brings it up again by uuid, through the shell, so the prompt
// then takes the keyboard.
export function connectCommand(uuid) {
    return ["nmcli", "connection", "up", "uuid", uuid];
}

// The wildcard focus grant (§14.3) for a VPN's own dialog window, which
// opens from tide-agent rather than a launch.
export const GRANT_ANY = ["hyprctl", "eval", "tide_focus.grant(\"*\")"];

// `ipc call agent status`, for `tide doctor` and `tide autostart-allowed`:
// "off" (TIDE_AGENT=0), "missing" (tide-agent isn't running), "starting"
// (it is, but hasn't said where it stands), or tide-agent's own status:
// "registered", "standing-aside PID", "waiting", "unregistered MESSAGE".
export function statusText(enabled, running, status) {
    if (!enabled) {
        return "off";
    }
    if (!running) {
        return "missing";
    }
    if (!status) {
        return "starting";
    }
    switch (status.state) {
    case "standing-aside":
        return `standing-aside ${status.pid || 0}`;
    case "unregistered":
        return `unregistered ${status.message || ""}`.trim();
    case "registered":
    case "waiting":
        return status.state;
    default:
        return "missing";
    }
}

// The prompt's buttons: [secondary, primary], primary null for a code
// that's only shown. The secondary declines (Rejected, for BlueZ) when the
// request names a decline, else cancels.
export function buttons(request) {
    const secondary = { label: request.decline || "Cancel", answer: request.decline ? "decline" : "cancel" };
    if (request.kind === "bt-display") {
        return [secondary, null];
    }
    return [secondary, { label: request.accept || "Connect", answer: "reply" }];
}

// The prompt's icon.
export function icon(request) {
    if (isBluetooth(request)) {
        return "bluetooth-symbolic";
    }
    if (request.kind === "wifi") {
        return "network-wireless-symbolic";
    }
    return request.kind === "vpn" || request.kind === "vpn-dialog" ? "network-vpn-symbolic" : "dialog-password-symbolic";
}

// The values typed into a prompt's fields, by key: what a reply carries.
export function values(fields, typed) {
    const out = {};
    for (let i = 0; i < fields.length; i++) {
        out[fields[i].key] = typed[i] ?? "";
    }
    return out;
}
