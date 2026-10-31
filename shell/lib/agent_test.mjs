// Tests for agent.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { CONNECT, GRANT_ANY, OPEN, STARTED_MS, addMissed, buttons, fate, holds, icon, isBluetooth, missedOnDecline, ownerFor, answerLine, connectCommand, connectionName, missedCommand, missedOutcome, noteStarted, notifyCommand, notifyOutcome, parseLine, route, statusText, values } from "./agent.mjs";

const wifi = { kind: "wifi", id: "1", ssid: "Home Net", connection: { id: "Home", uuid: "u-1", type: "802-11-wireless" }, userRequested: true, message: "“Home Net” needs a password." };
const vpn = { kind: "vpn", id: "2", connection: { id: "Work VPN", uuid: "u-3", type: "vpn" }, userRequested: true, message: "Sign in." };

test("a line is a message tide-agent sends", () => {
    assert.deepEqual(parseLine('{"type":"status","state":"registered"}'), { message: { type: "status", state: "registered" } });
    assert.equal(parseLine('{"type":"request","id":"1"}').message.id, "1");
});

test("a bad line is an error that never quotes it, since it may hold a password", () => {
    for (const line of ['not json "hunter22"', '{"type":"bogus","value":"hunter22"}', '{"type":"request","value":"hunter22"}', "null"]) {
        const r = parseLine(line);
        assert.ok(r.error, line);
        assert.ok(!r.error.includes("hunter22"), r.error);
    }
});

test("answers are one JSON line each, and only a reply carries values", () => {
    assert.equal(answerLine("reply", "1", { psk: "x" }), '{"type":"reply","id":"1","values":{"psk":"x"}}\n');
    assert.equal(answerLine("cancel", "1"), '{"type":"cancel","id":"1"}\n');
    assert.equal(answerLine("go", "2", { psk: "x" }), '{"type":"go","id":"2"}\n');
});

test("a Wi-Fi key for the network a popover tried is asked in that popover", () => {
    assert.equal(route(wifi, ["Other", "Home Net"], {}, 0), "popover");
    // Only a Wi-Fi key: a VPN never goes there.
    assert.equal(route(Object.assign({}, vpn, { ssid: "Home Net" }), ["Home Net"], {}, 0), "guard");
});

test("a connection the shell just brought up takes the keyboard", () => {
    const started = noteStarted({}, "u-3", 1000);
    assert.equal(route(vpn, [], started, 1000 + STARTED_MS - 1), "prompt");
    assert.equal(route(vpn, [], started, 1000 + STARTED_MS), "guard", "only for 10 s");
});

test("a request you asked for elsewhere asks the guard; one NetworkManager made itself notifies", () => {
    assert.equal(route(wifi, [], {}, 0), "guard");
    assert.equal(route(Object.assign({}, wifi, { userRequested: false }), [], {}, 0), "notify");
    // Even one the shell started, if NetworkManager reconnects later on its
    // own, after the 10 s.
    assert.equal(route(Object.assign({}, vpn, { userRequested: false }), [], { "u-3": 0 }, STARTED_MS), "notify");
});

test("a Wi-Fi request goes to the shown popover that tried its network", () => {
    const a = {}, b = {};
    assert.equal(ownerFor(wifi, [{ popover: a, visible: false, pendingName: "Home Net" }, { popover: b, visible: true, pendingName: "Home Net" }]), b);
    assert.equal(ownerFor(wifi, [{ popover: a, visible: true, pendingName: "Other" }]), null);
});

test("a popover gone before the request arrives isn't asked: the request routes on", () => {
    // Closed (its pending network forgotten), or never there.
    assert.equal(route(wifi, [], {}, 0), "guard");
    assert.equal(ownerFor(wifi, []), null);
    assert.equal(route(Object.assign({}, wifi, { userRequested: false }), [], {}, 0), "notify");
});

test("a popover that stops holding its request lets it go, however it went", () => {
    const shown = { visible: true, pendingName: "Home Net" };
    assert.equal(holds(wifi, shown), true);
    assert.equal(holds(wifi, null), false, "destroyed: a monitor unplugged");
    assert.equal(holds(wifi, { visible: false, pendingName: "Home Net" }), false, "hidden");
    assert.equal(holds(wifi, { visible: true, pendingName: "Other" }), false, "another network clicked");
    assert.equal(holds(wifi, { visible: true, pendingName: "" }), false, "its prompt canceled");
    // And it then routes as if no popover had tried it.
    assert.equal(route(wifi, [], {}, 0), "guard");
});

// Every transition an outstanding request can meet, shown or waiting.
const up = { helperRunning: true, locked: false };
test("a request kept while nothing around it changes", () => {
    assert.equal(fate(wifi, up), "keep", "waiting");
    assert.equal(fate(wifi, Object.assign({ showing: "prompt" }, up)), "keep");
    assert.equal(fate(wifi, Object.assign({ showing: "notified" }, up)), "keep");
    assert.equal(fate(wifi, Object.assign({ showing: "", ownerHolds: false }, up)), "keep", "while the guard is asked");
    assert.equal(fate(wifi, Object.assign({ showing: "popover", ownerHolds: true }, up)), "keep");
});

test("locking declines every outstanding request, whatever its state", () => {
    const locked = { helperRunning: true, locked: true };
    for (const showing of [undefined, "", "popover", "prompt", "notified", "running"]) {
        assert.equal(fate(wifi, Object.assign({ showing: showing, ownerHolds: true }, locked)), "decline", String(showing));
    }
    assert.equal(fate(vpn, locked), "decline", "a waiting VPN");
});

test("a declined request with a connection is offered after unlock", () => {
    assert.equal(missedOnDecline(wifi), true);
    assert.equal(missedOnDecline({ kind: "wifi" }), false);
    assert.equal(missedOnDecline({ kind: "bt-confirm", connection: { id: "Headphones", uuid: "/org/bluez/hci0/dev_AA" } }), false, "a pairing isn't brought up by nmcli");
});

test("a popover letting go reroutes, unless the lock or tide-agent's exit came first", () => {
    assert.equal(fate(wifi, Object.assign({ showing: "popover", ownerHolds: false }, up)), "reroute");
    assert.equal(fate(wifi, { helperRunning: true, locked: true, showing: "popover", ownerHolds: false }), "decline");
    assert.equal(fate(wifi, { helperRunning: false, locked: false, showing: "popover", ownerHolds: false }), "drop");
});

test("tide-agent exiting or restarting drops every outstanding request", () => {
    for (const showing of [undefined, "popover", "prompt", "notified"]) {
        assert.equal(fate(wifi, { helperRunning: false, locked: false, showing: showing, ownerHolds: true }), "drop", String(showing));
    }
    assert.equal(fate(wifi, { helperRunning: false, locked: true }), "drop", "nobody to decline to");
});

const pair = { kind: "bt-confirm", id: "3", connection: { id: "Headphones", uuid: "/org/bluez/hci0/dev_AA", type: "bluetooth" }, userRequested: false, message: "Does “Headphones” show 012345?", accept: "Pair" };

test("a pairing is a notification first, and a code to show takes no keyboard", () => {
    assert.equal(route(pair, ["Headphones"], {}, 0), "notify");
    assert.equal(route(Object.assign({}, pair, { kind: "bt-display" }), [], {}, 0), "display");
    assert.ok(isBluetooth(pair) && !isBluetooth(wifi));
});

test("a pairing's notification says the device asks", () => {
    const c = notifyCommand(pair);
    assert.ok(c.includes(`--action=${OPEN}=Open`));
    assert.equal(c[c.length - 2], "“Headphones” asks to pair");
    assert.equal(notifyCommand(Object.assign({}, pair, { kind: "bt-service" })).slice(-2)[0], "“Headphones” asks to connect");
});

test("the prompt's buttons follow the request", () => {
    assert.deepEqual(buttons(wifi), [{ label: "Cancel", answer: "cancel" }, { label: "Connect", answer: "reply" }]);
    assert.deepEqual(buttons(pair), [{ label: "Cancel", answer: "cancel" }, { label: "Pair", answer: "reply" }]);
    assert.deepEqual(buttons({ kind: "bt-service", accept: "Allow", decline: "Deny" }), [{ label: "Deny", answer: "decline" }, { label: "Allow", answer: "reply" }]);
    assert.deepEqual(buttons({ kind: "bt-display" }), [{ label: "Cancel", answer: "cancel" }, null]);
});

test("the prompt's icon", () => {
    assert.equal(icon(pair), "bluetooth-symbolic");
    assert.equal(icon(wifi), "network-wireless-symbolic");
    assert.equal(icon(vpn), "network-vpn-symbolic");
    assert.equal(icon({ kind: "8021x" }), "dialog-password-symbolic");
});

test("tide-agent's Bluetooth status is a message the shell knows", () => {
    assert.equal(parseLine('{"type":"bt-status","state":"registered"}').message.state, "registered");
});

test("noting a start forgets old ones", () => {
    assert.deepEqual(noteStarted({ a: 0, b: 5000 }, "c", STARTED_MS + 1), { b: 5000, c: STARTED_MS + 1 });
});

test("a request goes by its network's name", () => {
    assert.equal(connectionName(wifi), "Home Net");
    assert.equal(connectionName(vpn), "Work VPN");
    assert.equal(connectionName({}), "the network");
});

test("the notification offers the prompt, escaped, critical and from tide", () => {
    const c = notifyCommand(Object.assign({}, wifi, { ssid: "<b>Café</b>" }));
    assert.equal(c[0], "notify-send");
    assert.ok(c.includes("--app-name=tide") && c.includes("--urgency=critical") && c.includes("--wait"));
    assert.ok(c.includes(`--action=${OPEN}=Enter password`) && c.includes("--action=default=Enter password"));
    assert.equal(c[c.length - 2], "Wi-Fi “&lt;b&gt;Café&lt;/b&gt;” needs a password");
    const d = notifyCommand({ kind: "vpn-dialog", connection: { id: "Work" } });
    assert.ok(d.includes(`--action=${OPEN}=Sign in`));
    assert.equal(d[d.length - 2], "“Work” needs you to sign in");
});

test("the notification's outcome", () => {
    assert.equal(notifyOutcome(true, 0, "open\n"), "open");
    assert.equal(notifyOutcome(true, 0, "default\n"), "open");
    assert.equal(notifyOutcome(true, 0, ""), "dismissed");
    assert.equal(notifyOutcome(false, null, ""), "failed");
    assert.equal(notifyOutcome(true, 1, ""), "failed");
});

test("missed requests are kept once per connection", () => {
    let m = addMissed([], { id: "Home", uuid: "u-1" });
    m = addMissed(m, { id: "Work", uuid: "u-3" });
    m = addMissed(m, { id: "Home", uuid: "u-1" });
    assert.deepEqual(m.map(c => c.uuid), ["u-3", "u-1"]);
    assert.equal(addMissed(m, {}), m);
});

test("a missed request's notification offers Connect, by uuid", () => {
    const c = missedCommand({ id: "A & B", uuid: "u-1" });
    assert.ok(c.includes(`--action=${CONNECT}=Connect`));
    assert.equal(c[c.length - 2], "Couldn't connect to “A &amp; B”");
    assert.equal(missedOutcome(true, 0, "connect\n"), "connect");
    assert.equal(missedOutcome(true, 0, ""), "dismissed");
    assert.deepEqual(connectCommand("u-1"), ["nmcli", "connection", "up", "uuid", "u-1"]);
});

test("the dialog's grant is the guard's wildcard", () => {
    assert.deepEqual(GRANT_ANY, ["hyprctl", "eval", 'tide_focus.grant("*")']);
});

test("the status doctor reads", () => {
    assert.equal(statusText(false, true, { state: "registered" }), "off");
    assert.equal(statusText(true, false, { state: "registered" }), "missing");
    assert.equal(statusText(true, true, null), "starting", "running, with no status yet");
    assert.equal(statusText(true, true, { state: "registered" }), "registered");
    assert.equal(statusText(true, true, { state: "waiting" }), "waiting");
    assert.equal(statusText(true, true, { state: "standing-aside", pid: 42 }), "standing-aside 42");
    assert.equal(statusText(true, true, { state: "unregistered", message: "denied" }), "unregistered denied");
});

test("a reply's values are the fields' keys with what was typed", () => {
    assert.deepEqual(values([{ key: "password" }, { key: "otp" }], ["p", undefined]), { password: "p", otp: "" });
});
