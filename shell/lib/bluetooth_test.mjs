// Tests for bluetooth.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { audioIcons, bluetoothIcon, deviceName, deviceStatus, pairedDevices, shouldConnect } from "./bluetooth.mjs";

const dev = (fields) => ({ name: "", deviceName: "", address: "00:11:22:33:44:55", icon: "", state: 0, paired: true, bonded: false, batteryAvailable: false, battery: 0, ...fields });

test("the icon is hidden with no adapter, else one glyph, faint while off", () => {
    assert.equal(bluetoothIcon(null).visible, false);
    for (const state of [0, 1, 2, 3, 4]) {
        assert.equal(bluetoothIcon({ state }).visible, true);
        assert.equal(bluetoothIcon({ state }).icon, "bluetooth-active-symbolic");
    }
    // Disabled, disabling and blocked read as off; enabling as on.
    assert.deepEqual([0, 1, 2, 3, 4].map((state) => bluetoothIcon({ state }).on), [false, true, true, false, false]);
});

test("connecting a device doesn't change the Bluetooth icon", () => {
    // Regression: it used to swap to a connected glyph, and to one with an
    // x while on with nothing connected.
    assert.deepEqual(bluetoothIcon({ state: 1 }, [dev({ state: 1 })]), bluetoothIcon({ state: 1 }, []));
});

test("each connected audio device gets an icon for its kind", () => {
    const icons = audioIcons({ state: 1 }, [
        dev({ name: "Speaker", icon: "audio-card", state: 1, address: "a" }),
        dev({ name: "Buds", icon: "audio-headphones", state: 1, address: "b" }),
        dev({ name: "Headset", icon: "audio-headset", state: 1, address: "c" }),
    ]);
    assert.deepEqual(icons.map((i) => i.icon), ["audio-headphones-symbolic", "audio-headset-symbolic", "audio-speakers-symbolic"]);
    assert.deepEqual(icons.map((i) => i.address), ["b", "c", "a"]);
});

test("audio devices not connected, and other kinds, get no icon", () => {
    assert.deepEqual(audioIcons({ state: 1 }, [
        dev({ icon: "audio-headphones", state: 0 }),
        dev({ icon: "audio-headphones", state: 3 }),
        dev({ icon: "audio-headphones", state: 2 }),
        dev({ icon: "input-mouse", state: 1 }),
        dev({ icon: "input-keyboard", state: 1 }),
        dev({ icon: "", state: 1 }),
    ]), []);
});

test("audio icons need an adapter that's on", () => {
    const buds = [dev({ icon: "audio-headphones", state: 1 })];
    assert.deepEqual(audioIcons(null, buds), []);
    assert.deepEqual(audioIcons({ state: 0 }, buds), []);
    assert.equal(audioIcons({ state: 1 }, buds).length, 1);
});

test("an audio icon's tooltip is its name, with battery when it reports one", () => {
    const tip = (fields) => audioIcons({ state: 1 }, [dev({ icon: "audio-headphones", state: 1, ...fields })])[0].tooltip;
    assert.equal(tip({ name: "Buds" }), "Buds");
    assert.equal(tip({ name: "Buds", batteryAvailable: true, battery: 0.55 }), "Buds · 55%");
    assert.equal(tip({ name: "Buds", batteryAvailable: true, battery: NaN }), "Buds");
});

test("devices are named by alias, then their own name, then address", () => {
    assert.equal(deviceName(dev({ name: "My buds", deviceName: "WF-1000" })), "My buds");
    assert.equal(deviceName(dev({ deviceName: "WF-1000" })), "WF-1000");
    assert.equal(deviceName(dev({})), "00:11:22:33:44:55");
});

test("a device's status says what it's doing, with battery when connected", () => {
    assert.equal(deviceStatus(dev({ state: 0 })), "");
    assert.equal(deviceStatus(dev({ state: 3 })), "Connecting…");
    assert.equal(deviceStatus(dev({ state: 2 })), "Disconnecting…");
    assert.equal(deviceStatus(dev({ state: 1 })), "Connected");
    assert.equal(deviceStatus(dev({ state: 1, batteryAvailable: true, battery: 0.8 })), "Connected · 80%");
});

test("the list is the paired devices, connected first, then by name", () => {
    const list = pairedDevices([
        dev({ name: "Zed", state: 0 }),
        dev({ name: "Mouse", state: 1 }),
        dev({ name: "Stranger", paired: false }),
        dev({ name: "Bonded", paired: false, bonded: true }),
        dev({ name: "Alpha", state: 0 }),
    ]);
    assert.deepEqual(list.map(deviceName), ["Mouse", "Alpha", "Bonded", "Zed"]);
});

test("clicking connects a disconnected device and disconnects a connected one", () => {
    assert.equal(shouldConnect(dev({ state: 0 })), true);
    assert.equal(shouldConnect(dev({ state: 2 })), true);
    assert.equal(shouldConnect(dev({ state: 1 })), false);
    assert.equal(shouldConnect(dev({ state: 3 })), false);
});
