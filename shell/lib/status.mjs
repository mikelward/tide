// The bar's battery and volume icons (SPEC.md §7.4), as pure functions the
// QML binds to. Icons are the desktop icon theme's symbolic names, which
// Adwaita has; the QML tints them to the bar's palette.

// Below this charge the battery shows red, unless it's charging.
export const LOW_BATTERY = 0.15;
// One scroll notch over the volume icon changes it by this much.
export const VOLUME_STEP = 0.05;

const CHARGING = 1;
const FULLY_CHARGED = 4;
const PENDING_CHARGE = 5;

// What the battery icon shows, from UPower's display device: `percentage`
// 0-1 and `state` as UPowerDeviceState numbers. `present` false (a desktop,
// or a removed battery) hides it.
export function batteryView({ present, percentage, state }) {
    if (!present || !Number.isFinite(percentage)) {
        return { visible: false, text: "", icon: "", low: false };
    }
    const pct = Math.round(Math.min(1, Math.max(0, percentage)) * 100);
    const charging = state === CHARGING || state === PENDING_CHARGE;
    // Adwaita has battery-level-0 to -100 in tens, -0 to -90 charging, and
    // -100-charged, which stands in for a full battery still charging.
    const level = Math.round(pct / 10) * 10;
    const icon = state === FULLY_CHARGED || (charging && level === 100) ? "battery-level-100-charged-symbolic"
        : `battery-level-${level}${charging ? "-charging" : ""}-symbolic`;
    return {
        visible: true,
        text: `${pct}%`,
        icon,
        low: !charging && state !== FULLY_CHARGED && percentage < LOW_BATTERY,
    };
}

// What the volume icon shows for the default output: muted, or a level by
// thirds. No output (`volume` not a number) shows it muted.
export function volumeIcon({ muted, volume }) {
    if (muted || !Number.isFinite(volume) || volume <= 0) {
        return "audio-volume-muted-symbolic";
    }
    if (volume < 1 / 3) {
        return "audio-volume-low-symbolic";
    }
    return volume < 2 / 3 ? "audio-volume-medium-symbolic" : "audio-volume-high-symbolic";
}

// The volume's percentage beside its icon, "45%"; above 100% when an app
// set it there. "" with no output. Muted keeps its level, which the bar
// dims, so unmuting shows what comes back.
export function volumeText(volume) {
    return Number.isFinite(volume) ? `${Math.round(Math.max(0, volume) * 100)}%` : "";
}

// The volume after `notches` of scrolling (positive is up), VOLUME_STEP a
// notch from wherever it is, within 0 to 1. A volume already above 1,
// which some apps set, isn't pulled down by scrolling up.
export function scrolledVolume(volume, notches) {
    const from = Number.isFinite(volume) ? volume : 0;
    const to = from + Math.trunc(notches) * VOLUME_STEP;
    if (notches > 0 && from >= 1) {
        return from;
    }
    // Rounded to 0.01%, enough to drop float error without moving the level.
    return Math.min(1, Math.max(0, Math.round(to * 10000) / 10000));
}

// "3 h 20 min", "45 min" or "under a minute", for UPower's estimates in
// seconds; "" when there's no estimate (UPower's 0).
export function formatDuration(seconds) {
    if (!Number.isFinite(seconds) || seconds <= 0) {
        return "";
    }
    const minutes = Math.round(seconds / 60);
    if (minutes < 1) {
        return "under a minute";
    }
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    if (h === 0) {
        return `${m} min`;
    }
    return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

// The battery popover's line under the percentage: what it's doing and how
// long until empty or full, as far as UPower knows.
export function batteryStatus({ state, timeToEmpty, timeToFull }) {
    if (state === FULLY_CHARGED) {
        return "Fully charged";
    }
    if (state === CHARGING) {
        const t = formatDuration(timeToFull);
        return t ? `Charging, full in ${t}` : "Charging";
    }
    if (state === PENDING_CHARGE) {
        return "Plugged in, not charging";
    }
    const t = formatDuration(timeToEmpty);
    return t ? `${t} left` : "On battery";
}

// The power profiles the popover offers, as power-profiles-daemon numbers
// them (Quickshell's PowerProfile): Performance only where the machine has
// one, as power-profiles-daemon won't set it otherwise.
export function profileChoices(hasPerformance) {
    const all = [
        { profile: 2, label: "Performance", icon: "power-profile-performance-symbolic" },
        { profile: 1, label: "Balanced", icon: "power-profile-balanced-symbolic" },
        { profile: 0, label: "Power saver", icon: "power-profile-power-saver-symbolic" },
    ];
    return hasPerformance ? all : all.slice(1);
}

// Why performance is held back, from power-profiles-daemon's degradation
// reason (Quickshell's PerformanceDegradationReason); "" when it isn't.
export function degradedText(reason) {
    if (reason === 1) {
        return "Performance is limited while the laptop is on a lap.";
    }
    if (reason === 2) {
        return "Performance is limited while the system is hot.";
    }
    return "";
}
