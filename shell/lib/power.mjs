// The Power page (SPEC.md §16): what closing the lid does and the power
// profile on AC power and on battery, from power.json and power.local.json,
// and whether power-profiles-daemon is there for the page's power profile,
// as pure functions the QML binds to.

import { jsonError } from "./clocks.mjs";

// What closing the lid does, undocked. Suspend is logind's own default
// (HandleLidSwitch=suspend), so it needs nothing from tide.
export const LID_CHOICES = Object.freeze([
    { value: "suspend", label: "Suspend" },
    { value: "lock", label: "Lock" },
    { value: "nothing", label: "Do nothing" },
]);

// The power profile to switch to as the power source changes: "" leaves
// it as it is. Values are power-profiles-daemon's names.
export const PROFILE_CHOICES = Object.freeze([
    { value: "", label: "Leave it" },
    { value: "power-saver", label: "Power saver" },
    { value: "balanced", label: "Balanced" },
    { value: "performance", label: "Performance" },
]);

export const DEFAULTS = Object.freeze({ lidClose: "suspend", onAC: "", onBattery: "" });

// The unit that holds logind's lid switch for Lock and Do nothing.
export const INHIBIT_UNIT = "tide-lid-inhibit.service";

// The names power-profiles-daemon owns on the system bus: its own, and the
// one 0.20 and later (and tuned-ppd) add.
const PROFILE_NAMES = ["net.hadess.PowerProfiles", "org.freedesktop.UPower.PowerProfiles"];

// Why `value` can't be setting `key`, or "".
export function valueError(key, value) {
    if (key === "lidClose") {
        return LID_CHOICES.some(c => c.value === value)
            ? ""
            : `lidClose must be ${LID_CHOICES.map(c => c.value).join(", ")}, not ${JSON.stringify(value)}`;
    }
    if (key === "onAC" || key === "onBattery") {
        return PROFILE_CHOICES.some(c => c.value === value)
            ? ""
            : `${key} must be ${PROFILE_CHOICES.map(c => JSON.stringify(c.value)).join(", ")}, not ${JSON.stringify(value)}`;
    }
    return `${JSON.stringify(key)} isn't a setting (lidClose, onAC, onBattery)`;
}

function parse(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: "expected an object of settings" };
    }
    for (const key of Object.keys(value)) {
        const bad = valueError(key, value[key]);
        if (bad !== "") {
            return { error: bad };
        }
    }
    return { settings: value };
}

// The settings in effect, key by key (§16.1). A file that's wrong keeps
// `lastGood`, and `errors` names it.
export function loadPowerSettings(sharedText, localText, lastGood = DEFAULTS) {
    const settings = Object.assign({}, DEFAULTS);
    const errors = [];
    for (const [name, text] of [["power.json", sharedText], ["power.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parse(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        Object.assign(settings, parsed.settings);
    }
    return errors.length > 0 ? { settings: lastGood, errors } : { settings, errors };
}

// power.local.json's text with `key` set to `value`: {text}, or {error}.
export function withSetting(localText, key, value) {
    const bad = valueError(key, value);
    if (bad !== "") {
        return { error: bad };
    }
    let local = {};
    if (localText !== null && localText !== undefined) {
        const parsed = parse(localText);
        if (parsed.error) {
            return { error: `power.local.json: ${parsed.error}` };
        }
        local = parsed.settings;
    }
    return { text: JSON.stringify(Object.assign({}, local, { [key]: value }), null, 2) + "\n" };
}

// What conf's hyprland.lua reads, ~/.config/hypr/tide-power.lua.
export function powerLua(s) {
    return `-- Written by tide's settings panel (SPEC.md §16); edit power.local.json instead.\nreturn {\n    lid_close = "${s.lidClose}",\n}\n`;
}

// The systemctl command that puts the lid inhibitor as `s` wants it: held
// for Lock and Do nothing, let go for Suspend.
export function inhibitCommand(s) {
    return ["systemctl", "--user", s.lidClose === "suspend" ? "stop" : "start", INHIBIT_UNIT];
}

// Whether power-profiles-daemon is there, from `busctl --system list
// --no-legend --acquired --activatable`'s output: a name it owns, running
// or activatable.
export function hasProfilesDaemon(output) {
    return (output || "").split("\n").some(line => PROFILE_NAMES.includes(line.trim().split(/\s+/)[0]));
}

// The command that lists them.
export const PROFILES_COMMAND = Object.freeze(["busctl", "--system", "list", "--no-legend", "--acquired", "--activatable"]);

// The page's lid choice `steps` from `value`, stopping at either end.
export function steppedLid(value, steps) {
    const at = LID_CHOICES.findIndex(c => c.value === value);
    return LID_CHOICES[Math.max(0, Math.min(LID_CHOICES.length - 1, (at < 0 ? 0 : at) + steps))].value;
}

export function lidLabel(value) {
    return (LID_CHOICES.find(c => c.value === value) ?? LID_CHOICES[0]).label;
}

// The profile `s` wants on this power source, as Quickshell's PowerProfile
// number (power saver 0, balanced 1, performance 2), or null to leave it.
// Performance on a machine without it is balanced, as power-profiles-daemon
// offers it only where the platform has one.
export function profileFor(s, onBattery, hasPerformance) {
    const wanted = onBattery ? s.onBattery : s.onAC;
    if (wanted === "power-saver") {
        return 0;
    }
    if (wanted === "balanced" || (wanted === "performance" && !hasPerformance)) {
        return 1;
    }
    return wanted === "performance" ? 2 : null;
}

// The page's profile choice `steps` from `value`, stopping at either end.
export function steppedProfile(value, steps) {
    const at = PROFILE_CHOICES.findIndex(c => c.value === value);
    return PROFILE_CHOICES[Math.max(0, Math.min(PROFILE_CHOICES.length - 1, (at < 0 ? 0 : at) + steps))].value;
}

export function profileLabel(value) {
    return (PROFILE_CHOICES.find(c => c.value === value) ?? PROFILE_CHOICES[0]).label;
}
