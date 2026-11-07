// Tests for network.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { WIFI, WIRED, signalIcon, connectedWifi, networkIcon, networkTip, wifiStatus, wifiList, trackOpen, shouldScan, NO_PROMPT, prompt, speedText, wiredList, wiredLabel, wiredStatus, wiredAction, wiredProfiles, wiredProfileCommand } from "./network.mjs";

const net = (name, fields = {}) => ({ name, connected: false, known: false, state: 4, signalStrength: 0.5, ...fields });
const wifi = (networks, fields = {}) => ({ type: WIFI, connected: networks.some(n => n.connected), networks, ...fields });
const wired = (connected, fields = {}) => ({ type: WIRED, name: "enp3s0", connected, state: connected ? 2 : 4, hasLink: connected, linkSpeed: 0, networks: [], ...fields });

test("signal strength picks one of five icons", () => {
    assert.equal(signalIcon(0.9), "network-wireless-signal-excellent-symbolic");
    assert.equal(signalIcon(0.6), "network-wireless-signal-good-symbolic");
    assert.equal(signalIcon(0.4), "network-wireless-signal-ok-symbolic");
    assert.equal(signalIcon(0.1), "network-wireless-signal-weak-symbolic");
    assert.equal(signalIcon(0), "network-wireless-signal-none-symbolic");
    assert.equal(signalIcon(undefined), "network-wireless-signal-none-symbolic");
});

test("a cable wins over Wi-Fi, and Wi-Fi shows its strength", () => {
    const home = net("home", { connected: true, signalStrength: 0.9 });
    assert.equal(networkIcon({ devices: [wired(true), wifi([home])], wifiEnabled: true, connectivity: 4 }).icon, "network-wired-symbolic");
    assert.equal(networkIcon({ devices: [wired(false), wifi([home])], wifiEnabled: true, connectivity: 4 }).icon, "network-wireless-signal-excellent-symbolic");
    assert.equal(connectedWifi([wifi([net("a"), home])]), home);
});

test("no internet shows the no-route form", () => {
    const home = net("home", { connected: true });
    assert.equal(networkIcon({ devices: [wifi([home])], wifiEnabled: true, connectivity: 2 }).icon, "network-wireless-no-route-symbolic");
    assert.equal(networkIcon({ devices: [wired(true)], wifiEnabled: true, connectivity: 3 }).icon, "network-wired-no-route-symbolic");
    // Unknown means the check hasn't run, not that it failed.
    assert.equal(networkIcon({ devices: [wired(true)], wifiEnabled: true, connectivity: 0 }).icon, "network-wired-symbolic");
});

test("nothing connected is offline, or Wi-Fi off when it's switched off", () => {
    assert.equal(networkIcon({ devices: [wifi([net("a")])], wifiEnabled: true, connectivity: 1 }).icon, "network-offline-symbolic");
    assert.equal(networkIcon({ devices: [wifi([])], wifiEnabled: false, connectivity: 1 }).icon, "network-wireless-disabled-symbolic");
    assert.equal(networkIcon({ devices: [wired(false)], wifiEnabled: false, connectivity: 1 }).icon, "network-offline-symbolic");
    assert.equal(networkIcon({ devices: [], wifiEnabled: true, connectivity: 0 }).visible, false);
});

test("a network says whether it's connected, connecting or saved", () => {
    assert.equal(wifiStatus(net("a", { connected: true, state: 2 })), "Connected");
    assert.equal(wifiStatus(net("a", { state: 1 })), "Connecting…");
    assert.equal(wifiStatus(net("a", { state: 3 })), "Disconnecting…");
    assert.equal(wifiStatus(net("a", { known: true })), "Saved");
    assert.equal(wifiStatus(net("a")), "");
});

test("the list puts the connected network first, then saved, then strongest", () => {
    const list = wifiList([wired(true), wifi([
        net("weak", { signalStrength: 0.2 }),
        net("strong", { signalStrength: 0.9 }),
        net("saved", { known: true, signalStrength: 0.1 }),
        net("home", { connected: true, signalStrength: 0.3 }),
        net("", { signalStrength: 1 }),
    ])]);
    assert.deepEqual(list.map(n => n.name), ["home", "saved", "strong", "weak"]);
});

test("scanning runs while any monitor's popover is open", () => {
    const left = { name: "left" };
    const right = { name: "right" };
    let open = [];
    assert.equal(shouldScan(open), false);
    open = trackOpen(open, left, true);
    assert.equal(shouldScan(open), true);
    open = trackOpen(open, right, true);
    open = trackOpen(open, left, false);
    assert.equal(shouldScan(open), true);
    open = trackOpen(open, right, false);
    assert.equal(shouldScan(open), false);
});

test("a repeated or stray transition can't leave scanning stuck", () => {
    const left = { name: "left" };
    const right = { name: "right" };
    let open = trackOpen(trackOpen([], left, true), left, true);
    assert.deepEqual(open, [left]);
    // Closing one that was never open, then the one that was.
    open = trackOpen(open, right, false);
    open = trackOpen(open, left, false);
    open = trackOpen(open, left, false);
    assert.deepEqual(open, []);
    assert.equal(shouldScan(open), false);
});

test("NoSecrets for the network asked about prompts for its password", () => {
    const home = { name: "home" };
    let state = prompt(NO_PROMPT, { type: "connect", network: home });
    assert.equal(state.pending, home);
    state = prompt(state, { type: "failed", network: home, noSecrets: true });
    assert.deepEqual(state, { pending: null, asking: home });
    state = prompt(state, { type: "submit" });
    assert.deepEqual(state, { pending: home, asking: null });
});

test("another failure clears the prompt without asking", () => {
    const home = { name: "home" };
    const state = prompt(prompt(NO_PROMPT, { type: "connect", network: home }),
        { type: "failed", network: home, noSecrets: false });
    assert.deepEqual(state, { pending: null, asking: null });
});

test("a late failure for a network moved on from is ignored", () => {
    const a = { name: "a" };
    const b = { name: "b" };
    let state = prompt(NO_PROMPT, { type: "connect", network: a });
    state = prompt(state, { type: "connect", network: b });
    assert.equal(prompt(state, { type: "failed", network: a, noSecrets: true }), state);
});

test("Wi-Fi going off, however it happens, cancels the prompt", () => {
    const home = { name: "home" };
    const asking = prompt(prompt(NO_PROMPT, { type: "connect", network: home }),
        { type: "failed", network: home, noSecrets: true });
    assert.deepEqual(prompt(asking, { type: "wifi", enabled: false }), NO_PROMPT);
    assert.equal(prompt(asking, { type: "wifi", enabled: true }), asking);
    assert.deepEqual(prompt(asking, { type: "cancel" }), NO_PROMPT);
    assert.equal(prompt(NO_PROMPT, { type: "submit" }), NO_PROMPT);
});

test("an unknown prompt event is an error", () => {
    assert.throws(() => prompt(NO_PROMPT, { type: "scan" }), /unknown prompt event: scan/);
});

test("the network's hover text names the network, as tide for macOS's, then the internet and the VPN", () => {
    const home = net("home", { connected: true, signalStrength: 0.9 });
    const tip = (devices, fields = {}) => networkTip({ devices, wifiEnabled: true, connectivity: 4, ...fields });
    assert.equal(tip([wifi([home])]), "home, 90%", "with its signal");
    assert.equal(tip([wifi([net("dim", { connected: true, signalStrength: undefined })])]), "dim", "no signal reported, none shown");
    assert.equal(tip([wired(true), wifi([home])]), "Wired network", "a cable wins, as on the icon");
    assert.equal(tip([wifi([net("off")])], { wifiEnabled: false }), "Wi-Fi off");
    assert.equal(tip([wifi([net("off")])]), "No network");
    assert.equal(tip([wifi([home])], { connectivity: 2 }), "home, 90%, sign in to reach the internet");
    assert.equal(tip([wired(true)], { connectivity: 3 }), "Wired network, no internet");
    assert.equal(tip([wifi([home])], { vpn: "on" }), "home, 90%, VPN on");
    assert.equal(tip([wifi([home])], { vpn: "connecting" }), "home, 90%, VPN connecting");
});

test("a wired connection coming up, or a cable with none, shows on the bar", () => {
    const offline = { wifiEnabled: true, connectivity: 1 };
    assert.equal(networkIcon({ ...offline, devices: [wired(false, { hasLink: true, state: 1 }), wifi([])] }).icon, "network-wired-acquiring-symbolic");
    assert.equal(networkIcon({ ...offline, devices: [wired(false, { hasLink: true }), wifi([])] }).icon, "network-wired-disconnected-symbolic");
    // No cable is just offline, and Wi-Fi that's up still wins.
    assert.equal(networkIcon({ ...offline, devices: [wired(false), wifi([])] }).icon, "network-offline-symbolic");
    const home = net("home", { connected: true, signalStrength: 0.9 });
    assert.equal(networkIcon({ devices: [wired(false, { hasLink: true }), wifi([home])], wifiEnabled: true, connectivity: 4 }).icon, "network-wireless-signal-excellent-symbolic");
});

test("the hover text gives a cable's speed, or what it's waiting for", () => {
    const at = (devices) => networkTip({ devices, wifiEnabled: true, connectivity: 4 });
    assert.equal(at([wired(true, { linkSpeed: 1000 })]), "Wired network, 1 Gb/s");
    assert.equal(at([wired(true)]), "Wired network");
    assert.equal(at([wired(false, { hasLink: true, state: 1 })]), "Wired network, connecting");
    assert.equal(at([wired(false, { hasLink: true })]), "Wired network, not connected");
    assert.equal(at([wired(false)]), "No network");
});

test("link speeds read as people say them", () => {
    assert.equal(speedText(100), "100 Mb/s");
    assert.equal(speedText(1000), "1 Gb/s");
    assert.equal(speedText(2500), "2.5 Gb/s");
    assert.equal(speedText(10000), "10 Gb/s");
    assert.equal(speedText(0), "");
    assert.equal(speedText(undefined), "");
});

test("each wired device says what it's doing, named when there are several", () => {
    assert.equal(wiredStatus(wired(true, { linkSpeed: 1000 })), "Connected, 1 Gb/s");
    assert.equal(wiredStatus(wired(true)), "Connected");
    assert.equal(wiredStatus(wired(false, { hasLink: true, state: 1 })), "Connecting…");
    assert.equal(wiredStatus(wired(true, { state: 3 })), "Disconnecting…");
    assert.equal(wiredStatus(wired(false, { hasLink: true })), "");
    assert.equal(wiredStatus(wired(false)), "Unplugged");
    assert.equal(wiredLabel(wired(false), 1), "Wired · Unplugged");
    assert.equal(wiredLabel(wired(false, { hasLink: true }), 1), "Wired");
    assert.equal(wiredLabel(wired(true, { name: "enx001122" }), 2), "Wired (enx001122) · Connected");
});

test("the wired list puts the connected device first, then by name", () => {
    const list = wiredList([wifi([]), wired(false, { name: "enp1s0" }), wired(true, { name: "enx9" }), wired(false, { name: "enp0s1" })]);
    assert.deepEqual(list.map(d => d.name), ["enx9", "enp0s1", "enp1s0"]);
});

test("a click on a wired device connects it, or disconnects it, if there's a cable", () => {
    assert.equal(wiredAction(wired(true)), "disconnect");
    assert.equal(wiredAction(wired(false, { hasLink: true, state: 1 })), "disconnect");
    assert.equal(wiredAction(wired(false, { hasLink: true })), "connect");
    assert.equal(wiredAction(wired(false)), "");
});

test("a device's profiles are offered when there's a choice, the active one marked", () => {
    const office = { id: "Office", uuid: "u1" };
    const home = { id: "Home", uuid: "u2" };
    const device = wired(true, { network: { nmSettings: [office, home] } });
    assert.deepEqual(wiredProfiles(device, [{ uuid: "u1", active: true, device: "enp3s0" }, { uuid: "u2", active: false, device: "" }]), [
        { settings: home, name: "Home", active: false },
        { settings: office, name: "Office", active: true },
    ]);
    // A profile two adapters share is up on one of them only, so the other
    // can still switch to it.
    assert.deepEqual(wiredProfiles(device, [{ uuid: "u1", active: true, device: "enx001122" }]).map(p => p.active), [false, false]);
    // One profile is no choice, and with no cable there's nothing to use one on.
    assert.deepEqual(wiredProfiles(wired(true, { network: { nmSettings: [office] } }), []), []);
    assert.deepEqual(wiredProfiles(wired(false, { network: { nmSettings: [office, home] } }), []), []);
    // No network yet (no cable) is no profiles, not an error.
    assert.deepEqual(wiredProfiles(wired(true, { network: null }), []), []);
});

// Switching profiles goes through nmcli on that device, since Quickshell
// won't connect a network that's already connected.
test("switching profiles names the profile and the device", () => {
    const profile = { settings: { id: "Office", uuid: "u1" }, name: "Office", active: false };
    assert.deepEqual(wiredProfileCommand(profile, wired(true, { name: "enx001122" })),
        ["nmcli", "connection", "up", "uuid", "u1", "ifname", "enx001122"]);
});
