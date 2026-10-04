// Whether the microphone is live (SPEC.md §7.4, §10): an app's capture
// stream with an active link from a microphone, from PipeWire. The QML
// passes Quickshell's PipeWire objects, its node types and its
// PwLinkState.Active in, so this file names no Quickshell type.

// Quickshell 0.3's PwNodeType values for the two kinds that matter here,
// standing in for the QML's PwNodeType.AudioSource and AudioInStream in
// the tests. Quickshell maps PipeWire's media classes to them:
// "Audio/Source", a microphone or other capture device, is Audio | Source;
// "Stream/Input/Audio", an app recording, is Audio | Source | Stream
// (src/services/pipewire/node.cpp). Neither has the Sink flag, so a
// sink's monitor, which is the sink node itself, is neither.
export const MIC_TYPES = Object.freeze({
    source: 0b01001,
    inStream: 0b01101,
});

// A microphone, or any other audio capture device.
export function isMicSource(node, types = MIC_TYPES) {
    return node?.type === types.source;
}

// An app's audio input stream. Whether it's recording or only a meter
// needs its properties (isMonitor), which are valid only once the node is
// bound, so this is the test that picks what to bind.
export function isInputStream(node, types = MIC_TYPES) {
    return node?.type === types.inStream;
}

// A level meter or patchbay isn't recording. PipeWire's own mark for one
// is media.category Monitor or Manager, as Quickshell's monitor filtering
// reads it; pipewire-pulse's peak-detect streams (pavucontrol's meters)
// set stream.monitor. Read only from a bound node.
export function isMonitor(node) {
    const p = node?.properties ?? {};
    return p["stream.monitor"] === "true" || p["media.category"] === "Monitor" || p["media.category"] === "Manager";
}

// The link groups from a microphone into an input stream: the ones the
// shell binds (with a PwObjectTracker), since a link group's state is only
// valid while bound, and only these, rather than every audio link.
export function captureLinks(linkGroups, types = MIC_TYPES) {
    return linkGroups.filter(g => isMicSource(g.source, types) && isInputStream(g.target, types));
}

// The input streams those links feed, once each: bound too, so their
// properties can say which are meters.
export function captureStreams(links) {
    return [...new Set(links.map(g => g.target))];
}

// The streams a microphone is feeding now that are recording, not
// metering. `links` must be bound, and so must their streams.
export function liveCaptures(links, ACTIVE) {
    const live = new Set(links.filter(g => g.state === ACTIVE).map(g => g.target));
    return captureStreams(links).filter(s => live.has(s) && !isMonitor(s));
}

// The mic popover's rows: one per app capturing, named by `label` (the
// volume popover's streamLabel), muted or not. A stream's mute is invalid
// until it's bound (`ready`), even though its `audio` already exists, so an
// unbound one isn't `ready`, shows as not muted, and can't be toggled.
export function captureRows(captures, label) {
    return captures.map(node => {
        const ready = Boolean(node.ready && node.audio);
        const muted = ready && Boolean(node.audio.muted);
        return {
            node,
            label: muted ? `${label(node)} · Muted` : label(node),
            icon: muted ? "microphone-disabled-symbolic" : "audio-input-microphone-symbolic",
            muted,
            ready,
        };
    });
}
