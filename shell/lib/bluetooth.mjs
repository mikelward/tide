// The bar's Bluetooth icon and popover (SPEC.md §7.4), as pure functions
// the QML binds to. Adapters and devices are Quickshell.Bluetooth's (BlueZ),
// or plain objects with the same fields in the tests.

// Quickshell's BluetoothAdapterState and BluetoothDeviceState.
const ADAPTER_ENABLED = 1;
const ADAPTER_ENABLING = 2;
const DEVICE_CONNECTED = 1;
const DEVICE_DISCONNECTING = 2;
const DEVICE_CONNECTING = 3;

// The bar icon: hidden with no adapter, else the one Bluetooth glyph, faint
// while off (or blocked) and in the text color while on. Connected devices
// don't change it; audio ones get icons of their own (audioIcons).
// bluetooth-active-symbolic is the plain glyph in Adwaita 46, and older
// than its bluetooth-symbolic.
export function bluetoothIcon(adapter) {
    if (!adapter) {
        return { visible: false, icon: "", on: false };
    }
    return { visible: true, icon: "bluetooth-active-symbolic", on: isOn(adapter) };
}

function isOn(adapter) {
    return adapter.state === ADAPTER_ENABLED || adapter.state === ADAPTER_ENABLING;
}

// BlueZ's device icons for audio (class_to_icon in src/dbus-common.c, BlueZ
// 5.x): audio-card is any other audio device, such as speakers or earbuds
// that don't say they're a headset.
const AUDIO_ICONS = {
    "audio-headset": "audio-headset-symbolic",
    "audio-headphones": "audio-headphones-symbolic",
    "audio-card": "audio-speakers-symbolic",
};

// The bar's icons for connected audio devices, one each, by name: the
// device's kind of icon, and a tooltip of its name and battery when it
// reports one. Other devices (mice, keyboards) get none.
export function audioIcons(adapter, devices) {
    if (!adapter || !isOn(adapter)) {
        return [];
    }
    return devices.filter((d) => d.state === DEVICE_CONNECTED && AUDIO_ICONS[d.icon])
        .sort((a, b) => deviceName(a).localeCompare(deviceName(b)))
        .map((d) => ({ address: d.address, icon: AUDIO_ICONS[d.icon], tooltip: audioTooltip(d) }));
}

function audioTooltip(device) {
    if (device.batteryAvailable && Number.isFinite(device.battery)) {
        return `${deviceName(device)} · ${Math.round(device.battery * 100)}%`;
    }
    return deviceName(device);
}

// What a device is called: the name you gave it, else its own, else its
// address.
export function deviceName(device) {
    return device.name || device.deviceName || device.address || "";
}

// A device's line in the popover: connecting or disconnecting, or
// connected with its battery when it reports one; "" when disconnected.
export function deviceStatus(device) {
    if (device.state === DEVICE_CONNECTING) {
        return "Connecting…";
    }
    if (device.state === DEVICE_DISCONNECTING) {
        return "Disconnecting…";
    }
    if (device.state !== DEVICE_CONNECTED) {
        return "";
    }
    if (device.batteryAvailable && Number.isFinite(device.battery)) {
        return `Connected · ${Math.round(device.battery * 100)}%`;
    }
    return "Connected";
}

// The devices the popover lists: the paired ones, connected first, then
// by name. Pairing a new one happens in blueman-manager (SPEC.md §7.4).
export function pairedDevices(devices) {
    const rank = (d) => (d.state === DEVICE_CONNECTED ? 0 : 1);
    return devices.filter((d) => d.paired || d.bonded)
        .sort((a, b) => rank(a) - rank(b) || deviceName(a).localeCompare(deviceName(b)));
}

// Whether clicking a device should connect it (true) or disconnect it.
export function shouldConnect(device) {
    return device.state !== DEVICE_CONNECTED && device.state !== DEVICE_CONNECTING;
}
