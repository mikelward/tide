// Tests for vpn.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LIST_COMMAND, lock, parseConnections, settledFailure, splitTerse, toggleAction, toggleCommand, vpnList, vpnStatus } from "./vpn.mjs";

test("splitTerse splits on unescaped colons", () => {
    assert.deepEqual(splitTerse("a:b::c"), ["a", "b", "", "c"]);
    assert.deepEqual(splitTerse("work\\:vpn:x"), ["work:vpn", "x"]);
    assert.deepEqual(splitTerse("back\\\\slash:x"), ["back\\slash", "x"]);
    assert.deepEqual(splitTerse(""), [""]);
});

test("the list command asks for the five fields parseConnections reads, untranslated", () => {
    assert.deepEqual(LIST_COMMAND.slice(0, 3), ["env", "LC_ALL=C", "nmcli"]);
    assert.ok(LIST_COMMAND.includes("-t"));
    assert.equal(LIST_COMMAND[LIST_COMMAND.indexOf("-f") + 1], "NAME,UUID,TYPE,ACTIVE,STATE");
});

const output = [
    "Home Wi-Fi:11111111-1111-1111-1111-111111111111:802-11-wireless:yes:activated",
    "Office\\:VPN:22222222-2222-2222-2222-222222222222:vpn:yes:activated",
    "wg0:33333333-3333-3333-3333-333333333333:wireguard:no:",
    "Wired connection 1:44444444-4444-4444-4444-444444444444:802-3-ethernet:no:",
    "",
].join("\n");

test("parseConnections keeps VPN and WireGuard connections only", () => {
    const { vpns, errors } = parseConnections(output);
    assert.deepEqual(errors, []);
    assert.deepEqual(vpns, [
        { name: "Office:VPN", uuid: "22222222-2222-2222-2222-222222222222", active: true, state: "activated" },
        { name: "wg0", uuid: "33333333-3333-3333-3333-333333333333", active: false, state: "" },
    ]);
});

test("parseConnections reports a line it can't read, and keeps the rest", () => {
    const { vpns, errors } = parseConnections("garbage\nvpn1:55555555-5555-5555-5555-555555555555:vpn:no:\n:::: \n");
    assert.equal(vpns.length, 1);
    assert.equal(errors.length, 2);
    assert.match(errors[0], /"garbage"/);
    // Five fields, but no uuid to bring it up by.
    assert.match(errors[1], /"::::/);
});

test("parseConnections ignores a state on an inactive connection", () => {
    const { vpns } = parseConnections("v:66666666-6666-6666-6666-666666666666:vpn:no:activated\n");
    assert.equal(vpns[0].state, "");
});

test("lock is on while any VPN is up, connecting while one comes up", () => {
    assert.equal(lock([]), "");
    assert.equal(lock([{ state: "" }]), "");
    assert.equal(lock([{ state: "activating" }]), "connecting");
    assert.equal(lock([{ state: "activating" }, { state: "activated" }]), "on");
    assert.equal(lock([{ state: "deactivating" }]), "");
});

test("vpnList puts active ones first, then by name", () => {
    const list = vpnList([
        { name: "b", active: false },
        { name: "c", active: true },
        { name: "a", active: false },
    ]);
    assert.deepEqual(list.map((v) => v.name), ["c", "a", "b"]);
});

test("vpnStatus says what a VPN is doing", () => {
    const v = { uuid: "u", active: false, state: "" };
    assert.equal(vpnStatus({ ...v, active: true, state: "activated" }, null), "Connected");
    assert.equal(vpnStatus({ ...v, active: true, state: "activating" }, null), "Connecting…");
    assert.equal(vpnStatus({ ...v, active: true, state: "deactivating" }, null), "Disconnecting…");
    assert.equal(vpnStatus(v, null), "");
});

test("vpnStatus says a toggle failed while the VPN stays where it was", () => {
    const down = { uuid: "u", active: false, state: "" };
    const up = { uuid: "u", active: true, state: "activated" };
    assert.equal(vpnStatus(down, { uuid: "u", action: "up" }), "Couldn't connect");
    assert.equal(vpnStatus(up, { uuid: "u", action: "down" }), "Couldn't disconnect");
    // It got there after all (up by other means, say): no stale error.
    assert.equal(vpnStatus(up, { uuid: "u", action: "up" }), "Connected");
    assert.equal(vpnStatus(down, { uuid: "u", action: "down" }), "");
    // Another VPN's failure isn't this one's.
    assert.equal(vpnStatus(down, { uuid: "other", action: "up" }), "");
});

test("toggleCommand brings a VPN down if it's up, else up, by uuid", () => {
    assert.equal(toggleAction({ active: true }), "down");
    assert.equal(toggleAction({ active: false }), "up");
    assert.deepEqual(toggleCommand({ uuid: "u", active: true }), ["nmcli", "connection", "down", "uuid", "u"]);
    assert.deepEqual(toggleCommand({ uuid: "u", active: false }), ["nmcli", "connection", "up", "uuid", "u"]);
});

test("settledFailure drops a failure once its VPN gets where it was asked to go", () => {
    const up = { uuid: "u", active: true };
    const down = { uuid: "u", active: false };
    const failedUp = { uuid: "u", action: "up" };
    const failedDown = { uuid: "u", action: "down" };
    assert.equal(settledFailure(null, [down]), null);
    // Still where the toggle failed to move it from: kept.
    assert.equal(settledFailure(failedUp, [down]), failedUp);
    assert.equal(settledFailure(failedDown, [up]), failedDown);
    // Got there some other way: dropped, so it can't return on the next move.
    assert.equal(settledFailure(failedUp, [up]), null);
    assert.equal(settledFailure(failedDown, [down]), null);
    // The connection was deleted.
    assert.equal(settledFailure(failedUp, []), null);
});
