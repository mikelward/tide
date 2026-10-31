// The OSD (SPEC.md §9): a pill at the bottom center of the focused monitor
// that shows a volume or mic-mute change for 1.2 s, as pure functions the
// QML binds to.

import { volumeIcon } from "./status.mjs";

export const SHOWN_MS = 1200;

// What a node's audio looked like, to compare with the next change: the
// node itself, so a different default device isn't mistaken for a change.
// None until the node is ready (bound, with its levels read), so binding
// it isn't mistaken for one either.
export function snapshot(node, audio) {
    if (!node?.ready || !audio) {
        return null;
    }
    return Object.freeze({ node, volume: audio.volume, muted: audio.muted });
}

// Whether going from `before` to `after` is a change worth showing: the same
// node's volume or mute moved. The first look at a node, or a new default
// device, isn't one, so the OSD doesn't flash at startup or on a switch.
export function changed(before, after) {
    if (!before || !after || before.node !== after.node) {
        return false;
    }
    return before.muted !== after.muted || Math.abs(before.volume - after.volume) >= 0.005;
}

// Whether the same node's mute moved: all the mic's OSD shows, since an
// app's gain control moving its level isn't news.
export function muteChanged(before, after) {
    return changed(before, after) && before.muted !== after.muted;
}

// Whether the OSD shows on the monitor named `screen`: while it's up, on
// the monitor that had focus when it was shown (`monitor`). That's state
// recorded by show(), not read back from the window, whose own screen and
// visibility would feed back into this.
export function shownOn({ showing, pill, monitor }, screen) {
    return Boolean(showing && pill && monitor && monitor === screen);
}

// The pill for the output: its icon, the level as a fraction for the bar
// (capped at 1; an app may push the volume past 100%), and the percentage.
export function volumePill({ volume, muted }) {
    const level = Number.isFinite(volume) ? Math.max(0, volume) : 0;
    return Object.freeze({
        icon: volumeIcon({ muted, volume: level }),
        level: muted ? 0 : Math.min(1, level),
        label: muted ? "Muted" : `${Math.round(level * 100)}%`,
    });
}

// The pill for the backlight: its level, from `tide brightness`,
// as a whole percentage (clamped to 0-100).
export function brightnessPill(percent) {
    const level = Number.isFinite(percent) ? Math.min(100, Math.max(0, Math.round(percent))) : 0;
    return Object.freeze({
        icon: "display-brightness-symbolic",
        level: level / 100,
        label: `${level}%`,
    });
}

// The pill for the input: only whether the mic is muted, so no level.
export function micPill({ muted }) {
    return Object.freeze({
        icon: muted ? "microphone-sensitivity-muted-symbolic" : "audio-input-microphone-symbolic",
        level: null,
        label: muted ? "Mic off" : "Mic on",
    });
}

// The pill for keep awake after Super+S (SPEC.md §10): whether it's on now,
// and why when only a live mic holds it, since the key can't turn that off.
// `on` is what's in effect, `asked` your own toggle, `presenting` presenter
// mode.
export function keepAwakePill({ on, asked, presenting }) {
    let label = "Keep awake off";
    if (on) {
        label = asked || presenting ? "Keep awake on" : "Awake while the mic is live";
    }
    return Object.freeze({ icon: "display-brightness-symbolic", level: null, label });
}

// The pill for presenter mode after Super+P. Without the shell as the
// notification server there's no Do not disturb to turn on, so it says so.
export function presenterPill({ presenting, dndAvailable }) {
    let label = "Presenter mode off";
    if (presenting) {
        label = dndAvailable ? "Presenting" : "Presenting, keep awake only";
    }
    return Object.freeze({ icon: "x-office-presentation-symbolic", level: null, label });
}
