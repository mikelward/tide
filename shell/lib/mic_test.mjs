// Tests for mic.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MIC_TYPES, captureLinks, captureRows, captureStreams, isInputStream, isMicSource, isMonitor, liveCaptures } from "./mic.mjs";

const ACTIVE = 4;
const PAUSED = 3;
// Quickshell 0.3's PwNodeType flags: Audio 1, Video 2, Stream 4, Source 8,
// Sink 16, as audio_test.mjs has them.
const AUDIO_SOURCE = 0b01001;
const AUDIO_SINK = 0b10001;
const AUDIO_IN_STREAM = 0b01101;
const AUDIO_OUT_STREAM = 0b10101;
const VIDEO_SOURCE = 0b01010;
const mic = { id: 1, type: AUDIO_SOURCE };
const speakers = { id: 2, type: AUDIO_SINK };
const call = { id: 3, type: AUDIO_IN_STREAM, properties: { "application.name": "Chrome" } };
const meter = { id: 4, type: AUDIO_IN_STREAM, properties: { "stream.monitor": "true" } };
const player = { id: 5, type: AUDIO_OUT_STREAM };
const camera = { id: 6, type: VIDEO_SOURCE };
const recorder = { id: 7, type: AUDIO_IN_STREAM };

test("MIC_TYPES are Quickshell's AudioSource and AudioInStream", () => {
    assert.deepEqual(MIC_TYPES, { source: AUDIO_SOURCE, inStream: AUDIO_IN_STREAM });
});

test("a microphone is an audio source device", () => {
    assert.equal(isMicSource(mic), true);
    assert.equal(isMicSource(speakers), false);
    assert.equal(isMicSource(player), false);
    assert.equal(isMicSource(camera), false);
    // An app recording is a source too, but a stream, not a device.
    assert.equal(isMicSource(call), false);
    assert.equal(isMicSource(null), false);
});

test("an input stream takes audio in, meter or not", () => {
    assert.equal(isInputStream(call), true);
    assert.equal(isInputStream(recorder), true);
    // A meter is bound like any input stream, so its properties can be read.
    assert.equal(isInputStream(meter), true);
    assert.equal(isInputStream(player), false);
    assert.equal(isInputStream(speakers), false);
});

test("a meter marks itself a monitor, either way", () => {
    assert.equal(isMonitor(meter), true);
    assert.equal(isMonitor({ ...meter, properties: { "media.category": "Monitor" } }), true);
    assert.equal(isMonitor({ ...meter, properties: { "media.category": "Manager" } }), true);
    assert.equal(isMonitor({ ...meter, properties: { "media.category": "Capture" } }), false);
    assert.equal(isMonitor(call), false);
    // Unbound, its properties are unread: no claim it's a meter.
    assert.equal(isMonitor({ ...meter, properties: undefined }), false);
});

test("links from a microphone into any input stream are bound, with their streams", () => {
    const groups = [
        { source: mic, target: call, state: ACTIVE },
        { source: mic, target: meter, state: ACTIVE },
        { source: player, target: speakers, state: ACTIVE },
        { source: speakers, target: recorder, state: ACTIVE },
        { source: mic, target: call, state: ACTIVE },
    ];
    const links = captureLinks(groups);
    assert.deepEqual(links, [groups[0], groups[1], groups[4]]);
    assert.deepEqual(captureStreams(links), [call, meter]);
});

test("a meter's live link doesn't make the mic live", () => {
    assert.deepEqual(liveCaptures([{ source: mic, target: meter, state: ACTIVE }], ACTIVE), []);
});

test("the mic is live while a capture link is active", () => {
    assert.deepEqual(liveCaptures([], ACTIVE), []);
    assert.deepEqual(liveCaptures([{ source: mic, target: call, state: PAUSED }], ACTIVE), []);
    assert.deepEqual(liveCaptures([{ source: mic, target: call, state: ACTIVE }], ACTIVE), [call]);
});

test("a stream fed by two links counts once", () => {
    const mic2 = { ...mic, id: 9 };
    const live = liveCaptures([
        { source: mic, target: call, state: ACTIVE },
        { source: mic2, target: call, state: ACTIVE },
        { source: mic, target: recorder, state: ACTIVE },
    ], ACTIVE);
    assert.deepEqual(live, [call, recorder]);
});

test("the QML's own type values are what's matched", () => {
    const types = { source: 100, inStream: 200 };
    const groups = [{ source: { id: 1, type: 100 }, target: { id: 2, type: 200 }, state: ACTIVE }];
    assert.equal(captureLinks(groups, types).length, 1);
    assert.equal(captureLinks(groups).length, 0);
});

test("each app capturing gets a row saying whether it's muted", () => {
    const label = n => n.properties?.["application.name"] ?? "Unknown";
    const rows = captureRows([
        { ...call, ready: true, audio: { muted: false } },
        { ...recorder, properties: { "application.name": "Recorder" }, ready: true, audio: { muted: true } },
        { ...recorder, id: 8, ready: true, audio: null },
        // Discovered but not bound yet: audio exists, but its mute is invalid.
        { ...recorder, id: 9, ready: false, audio: { muted: true } },
    ], label);
    assert.deepEqual(rows.map(r => [r.label, r.muted, r.icon, r.ready]), [
        ["Chrome", false, "audio-input-microphone-symbolic", true],
        ["Recorder · Muted", true, "microphone-disabled-symbolic", true],
        ["Unknown", false, "audio-input-microphone-symbolic", false],
        ["Unknown", false, "audio-input-microphone-symbolic", false],
    ]);
    assert.equal(rows[0].node.id, call.id);
});
