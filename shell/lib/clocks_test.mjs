// Tests for clocks.mjs. Node's ICU stands in for the shell's tzdata reader
// for offsets and zone IDs; abbreviations are stubbed, since ICU's are
// the ones SPEC.md §7.3 rules out.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DEFAULT_CLOCKS, jsonError, parseClocks, loadClocks, visibleClocks, dayOffset,
    formatTime, formatLocal, barClocks, scrubbed, SCRUB_STEP, zoneError, zoneClocks, fitCount,
} from "./clocks.mjs";

function canonical(zone) {
    return new Intl.DateTimeFormat("en", { timeZone: zone }).resolvedOptions().timeZone;
}

// The zone's UTC offset in minutes at `ms`.
function offsetOf(zone, ms) {
    const name = new Intl.DateTimeFormat("en", { timeZone: zone, timeZoneName: "longOffset" })
        .formatToParts(new Date(ms)).find((p) => p.type === "timeZoneName").value;
    const m = /^GMT(?:([+-])(\d\d):(\d\d))?$/.exec(name);
    assert.ok(m, `unexpected offset ${name}`);
    if (!m[1]) {
        return 0;
    }
    return (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
}

const at = (iso) => Date.parse(iso);

test("defaults are SF, NYC and LON", () => {
    assert.deepEqual(DEFAULT_CLOCKS.map((c) => c.label), ["SF", "NYC", "LON"]);
});

test("parseClocks reads a list of {zone, label}", () => {
    assert.deepEqual(parseClocks('[{"zone": "Asia/Tokyo", "label": "TYO"}]'),
        { clocks: [{ zone: "Asia/Tokyo", label: "TYO" }] });
});

test("parseClocks names what's wrong", () => {
    assert.equal(parseClocks("{").error, "line 1: expected \" before the end");
    assert.equal(parseClocks('{"zone": "UTC"}').error, "expected a list of {zone, label}");
    assert.equal(parseClocks('[{"label": "X"}]').error, "entry 1: zone must be a time zone name");
    assert.equal(parseClocks('[{"zone": "UTC", "label": "U"}, {"zone": "UTC"}]').error,
        'entry 2: label must be text, or "abbr"');
    assert.equal(parseClocks("[null]").error, "entry 1: expected {zone, label}");
});

test("an unknown zone is an error at load, keeping the last good clocks", () => {
    const isZone = (z) => { try { canonical(z); return true; } catch { return false; } };
    const lastGood = [{ zone: "Asia/Tokyo", label: "TYO" }];
    const r = loadClocks('[{"zone": "Not/AZone", "label": "X"}]', null, lastGood, isZone);
    assert.deepEqual(r.clocks, lastGood);
    assert.deepEqual(r.errors, ['clocks.json: entry 1: unknown time zone "Not/AZone"']);
    assert.deepEqual(loadClocks('[{"zone": "America/Los_Angeles", "label": "SF"}]', null, lastGood, isZone).errors, []);
});

test("every bad file is named, not just the first", () => {
    const r = loadClocks("[", '{"zone": 1}', DEFAULT_CLOCKS);
    assert.equal(r.errors.length, 2);
    assert.match(r.errors[0], /^clocks\.json: line 1: /);
    assert.equal(r.errors[1], "clocks.local.json: expected a list of {zone, label}");
    assert.deepEqual(r.clocks, DEFAULT_CLOCKS);
});

test("a bad shared file still keeps the last good list when the local one parses", () => {
    const lastGood = [{ zone: "Asia/Tokyo", label: "TYO" }];
    const r = loadClocks("[", '[{"zone": "UTC", "label": "U"}]', lastGood);
    assert.deepEqual(r.clocks, lastGood);
    assert.equal(r.source, null);
});

test("the clocks name the file they came from", () => {
    const list = '[{"zone": "Asia/Tokyo", "label": "TYO"}]';
    assert.equal(loadClocks(list, null).source, "clocks.json");
    assert.equal(loadClocks(list, list).source, "clocks.local.json");
    assert.equal(loadClocks(null, null).source, null);
    assert.equal(loadClocks("[", null).source, null);
});

test("the shell's JavaScript sticks to what QML's engine has", async () => {
    // QML implements ECMAScript 7: newer methods such as Array.prototype.at
    // pass under Node and throw in the shell.
    const { readdir, readFile } = await import("node:fs/promises");
    const dir = new URL(".", import.meta.url);
    const sources = (await readdir(dir)).filter(f => f.endsWith(".mjs") && !f.endsWith("_test.mjs"));
    assert.ok(sources.length > 0);
    for (const f of sources) {
        const text = await readFile(new URL(f, dir), "utf8");
        assert.doesNotMatch(text, /\.at\(/, `${f} uses .at()`);
    }
});

test("a zone tide-tz can't load is named by file and entry", () => {
    const clocks = [{ zone: "Asia/Tokyo", label: "TYO" }, { zone: "US/Nowhere", label: "X" }];
    assert.equal(zoneError(clocks, "clocks.local.json", "US/Nowhere", "unknown time zone US/Nowhere"),
        "clocks.local.json: entry 2: unknown time zone US/Nowhere");
    assert.equal(zoneError(clocks, null, "US/Nowhere", "bad"), "entry 2: bad");
    assert.equal(zoneError(clocks, "clocks.json", "Other/Zone", "bad"), "clocks.json: bad");
    const twice = clocks.concat([{ zone: "US/Nowhere", label: "Y" }, { zone: "US/Nowhere", label: "Z" }]);
    assert.equal(zoneError(twice, "clocks.json", "US/Nowhere", "bad"), "clocks.json: entries 2, 3 and 4: bad");
    assert.equal(zoneError(twice.slice(0, 3), "clocks.json", "US/Nowhere", "bad"), "clocks.json: entries 2 and 3: bad");
});

test("a JSON error names its line", () => {
    assert.equal(jsonError('[\n  {"zone": "UTC",\n   "label": }\n]'), "line 3: unexpected }");
    assert.equal(jsonError('[\n  {"zone": "UTC", "label": "U"}'), "line 2: expected ] before the end");
    assert.equal(jsonError('[\n1,\n2,]'), "line 3: unexpected ]");
    assert.equal(jsonError('[]\n x'), "line 2: unexpected x after the value");
    assert.equal(jsonError('["a\nb"]'), "line 1: unterminated string");
    assert.match(loadClocks('[\n{"zone": "UTC"\n', null).errors[0], /^clocks\.json: line 3: /);
    assert.equal(jsonError('[\n"\\x"]'), "line 2: bad escape in string");
    assert.equal(jsonError('[\n01]'), "line 2: expected ], found 1");
    assert.equal(jsonError('["a\tb"]'), "line 1: control character in string");
    assert.match(jsonError("[\n" + "[".repeat(100000)), /^line 2: nested too deeply$/);
    // Every JSON.parse failure gets a line, whatever the walker makes of it.
    for (const bad of ['[\n"\\x"]', "[01]", "[1.]", "[-]", '{"a" 1}', "[,1]", '"\\u12"', "", " "]) {
        assert.throws(() => JSON.parse(bad));
        assert.match(jsonError(bad), /^line \d+: /, bad);
    }
});

test("no files means the defaults", () => {
    assert.deepEqual(loadClocks(null, null), { clocks: DEFAULT_CLOCKS, errors: [], source: null });
});

test("the local list replaces the shared one whole", () => {
    const { clocks, errors } = loadClocks(
        '[{"zone": "America/Los_Angeles", "label": "SF"}, {"zone": "Asia/Tokyo", "label": "TYO"}]',
        '[{"zone": "Australia/Sydney", "label": "SYD"}]');
    assert.deepEqual(errors, []);
    assert.deepEqual(clocks, [{ zone: "Australia/Sydney", label: "SYD" }]);
});

test("a bad file keeps the last good clocks and is named", () => {
    const lastGood = [{ zone: "Asia/Tokyo", label: "TYO" }];
    const bad = loadClocks('[{"zone": "UTC", "label": "U"}]', "[{", lastGood);
    assert.deepEqual(bad.clocks, lastGood);
    assert.equal(bad.errors.length, 1);
    assert.match(bad.errors[0], /^clocks\.local\.json: /);
    const badShared = loadClocks("not json", null);
    assert.deepEqual(badShared.clocks, DEFAULT_CLOCKS);
    assert.match(badShared.errors[0], /^clocks\.json: /);
});

test("a clock in the local zone is hidden", () => {
    const shown = (local) => visibleClocks(DEFAULT_CLOCKS, local).map((c) => c.label);
    assert.deepEqual(shown("Europe/London"), ["SF", "NYC"]);
    assert.deepEqual(shown("America/New_York"), ["SF", "LON"]);
    assert.deepEqual(shown("America/Los_Angeles"), ["NYC", "LON"]);
    assert.deepEqual(shown("Asia/Tokyo"), ["SF", "NYC", "LON"]);
    // A local zone with no ID hides none.
    assert.deepEqual(shown(""), ["SF", "NYC", "LON"]);
});

test("a zone sharing only the current offset stays", () => {
    // Phoenix matches Los Angeles all summer, but it's a different zone.
    const summer = at("2026-07-01T12:00:00Z");
    assert.equal(offsetOf("America/Phoenix", summer), offsetOf("America/Los_Angeles", summer));
    assert.deepEqual(visibleClocks(DEFAULT_CLOCKS, "America/Phoenix").map((c) => c.label),
        ["SF", "NYC", "LON"]);
});

test("formatTime is 24-hour with leading zeros", () => {
    assert.equal(formatTime(at("2026-10-02T07:05:00Z"), 0), "07:05");
    assert.equal(formatTime(at("2026-10-02T07:05:00Z"), -420), "00:05");
    assert.equal(formatTime(at("2026-10-02T22:59:00Z"), 60), "23:59");
});

test("formatLocal is MMM d HH:MM", () => {
    assert.equal(formatLocal(at("2026-10-02T07:05:00Z"), 60), "Oct 2 08:05");
    assert.equal(formatLocal(at("2026-12-31T23:30:00Z"), 60), "Jan 1 00:30");
});

test("dayOffset marks a zone on another date", () => {
    const t = at("2026-10-02T23:30:00Z"); // 00:30 Oct 3 in London, 16:30 Oct 2 in SF
    assert.equal(dayOffset(t, -420, 60), -1);
    assert.equal(dayOffset(t, 60, -420), 1);
    assert.equal(dayOffset(t, 60, 60), 0);
});

test("dayOffset is two days across the date line", () => {
    // 23:30 Dec 31 at UTC-12, 01:30 Jan 2 at UTC+14.
    const t = at("2026-01-01T11:30:00Z");
    assert.equal(dayOffset(t, -720, 840), -2);
    assert.equal(dayOffset(t, 840, -720), 2);
});

// Instants either side of each 2026–2027 DST change in the default zones:
// [instant, offset, the bar's text, day offset against Honolulu]. Honolulu
// keeps no DST and sits behind all three, so the dates differ.
const DST = [
    // EU ends 2026-10-25 01:00Z: London BST (+60) -> GMT (0).
    { zone: "Europe/London",
      before: ["2026-10-25T00:59:00Z", 60, "BST 01:59", 1],
      after: ["2026-10-25T01:00:00Z", 0, "GMT 01:00", 1] },
    // US ends 2026-11-01: Eastern at 06:00Z, Pacific at 09:00Z.
    { zone: "America/New_York",
      before: ["2026-11-01T05:59:00Z", -240, "EDT 01:59", 1],
      after: ["2026-11-01T06:00:00Z", -300, "EST 01:00", 1] },
    { zone: "America/Los_Angeles",
      before: ["2026-11-01T08:59:00Z", -420, "PDT 01:59", 1],
      after: ["2026-11-01T09:00:00Z", -480, "PST 01:00", 1] },
    // US starts 2027-03-14: Eastern at 07:00Z, Pacific at 10:00Z.
    { zone: "America/New_York",
      before: ["2027-03-14T06:59:00Z", -300, "EST 01:59", 1],
      after: ["2027-03-14T07:00:00Z", -240, "EDT 03:00", 1] },
    // Honolulu reaches Mar 14 at 10:00Z too, so the day offset goes with it.
    { zone: "America/Los_Angeles",
      before: ["2027-03-14T09:59:00Z", -480, "PST 01:59", 1],
      after: ["2027-03-14T10:00:00Z", -420, "PDT 03:00", 0] },
    // EU starts 2027-03-28 01:00Z.
    { zone: "Europe/London",
      before: ["2027-03-28T00:59:00Z", 0, "GMT 00:59", 1],
      after: ["2027-03-28T01:00:00Z", 60, "BST 02:00", 1] },
];
// tzdata's abbreviations by offset, looked up at the instant abbrOf is given.
const ABBR = {
    "Europe/London": { 60: "BST", 0: "GMT" },
    "America/New_York": { "-240": "EDT", "-300": "EST" },
    "America/Los_Angeles": { "-420": "PDT", "-480": "PST" },
};
const abbrAt = (zone, ms) => ABBR[zone][offsetOf(zone, ms)];
for (const { zone, before, after } of DST) {
    test(`${zone} changes offset at ${after[0]}`, () => {
        assert.equal(offsetOf(zone, at(before[0])), before[1]);
        assert.equal(offsetOf(zone, at(after[0])), after[1]);
    });
    test(`the bar follows ${zone} across ${after[0]}`, () => {
        for (const [iso, , text, days] of [before, after]) {
            const bar = barClocks({
                clocks: [{ zone, label: "abbr" }], localZone: "Pacific/Honolulu",
                instant: at(iso), offsetOf, abbrOf: abbrAt,
            });
            assert.deepEqual(bar[0], { text, dayOffset: days }, iso);
            assert.equal(bar[1].local, true);
        }
    });
}

test("the week the London gap is off by an hour shows on the bar", () => {
    // Oct 26 2026: London is on GMT, SF still on PDT.
    const t = at("2026-10-26T16:00:00Z");
    const bar = barClocks({
        clocks: DEFAULT_CLOCKS, localZone: "Europe/London", instant: t,
        offsetOf, abbrOf: () => "",
    });
    assert.deepEqual(bar.map((c) => c.text), ["SF 09:00", "NYC 12:00", "Oct 26 16:00"]);
});

test("the bar ends with local and marks other days", () => {
    const t = at("2026-10-02T23:30:00Z");
    const bar = barClocks({
        clocks: DEFAULT_CLOCKS, localZone: "Europe/London", instant: t,
        offsetOf, abbrOf: () => "",
    });
    assert.deepEqual(bar, [
        { text: "SF 16:30", dayOffset: -1 },
        { text: "NYC 19:30", dayOffset: -1 },
        { text: "Oct 3 00:30", dayOffset: 0, local: true },
    ]);
});

test("the lock's zone clocks are the bar's without local", () => {
    const bar = barClocks({
        clocks: DEFAULT_CLOCKS, localZone: "Europe/London", instant: at("2026-10-02T23:30:00Z"),
        offsetOf, abbrOf: () => "",
    });
    assert.deepEqual(zoneClocks(bar).map((c) => c.text), ["SF 16:30", "NYC 19:30"]);
    // A label's line breaks read as spaces, so a clock stays one line.
    assert.deepEqual(zoneClocks([{ text: "NEW\nYORK\r\n2 13:47", dayOffset: 0 }]),
        [{ text: "NEW YORK 2 13:47", dayOffset: 0 }]);
    // Only local, when every listed zone is local's.
    assert.deepEqual(zoneClocks([{ text: "Oct 3 00:30", dayOffset: 0, local: true }]), []);
});

test("all the lock's clocks show when they fit on one line", () => {
    assert.equal(fitCount([60, 60, 60], 10, 200, 20), 3);
    assert.equal(fitCount([60, 60, 60], 10, 200.5, 20), 3);
    assert.equal(fitCount([], 10, 100, 20), 0);
});

test("the clocks that don't fit leave room for +N", () => {
    // 60+10+60 = 130, then 10 + 20 for "+N" = 160 <= 170; a third won't fit.
    assert.equal(fitCount([60, 60, 60, 60], 10, 170, 20), 2);
    // Exactly at the edge still fits.
    assert.equal(fitCount([60, 60, 60, 60], 10, 160, 20), 2);
    assert.equal(fitCount([60, 60, 60, 60], 10, 159, 20), 1);
    // Not even one clock beside "+N": only the count shows.
    assert.equal(fitCount([300, 60], 10, 100, 20), 0);
});

// The GMT+1 trap (SPEC.md §7.3): ICU's en-US names London's summer time
// "GMT+1". An "abbr" label shows whatever the tzdata reader says instead.
test("GMT+1 trap: abbr labels come from tzdata, not ICU", () => {
    const t = at("2026-07-01T12:00:00Z");
    const icu = new Intl.DateTimeFormat("en-US", { timeZone: "Europe/London", timeZoneName: "short" })
        .formatToParts(new Date(t)).find((p) => p.type === "timeZoneName").value;
    assert.equal(icu, "GMT+1");
    const tzdata = { "Europe/London": "BST", "America/Los_Angeles": "PDT" };
    const bar = barClocks({
        clocks: [{ zone: "Europe/London", label: "abbr" }, { zone: "America/Los_Angeles", label: "abbr" }],
        localZone: "Asia/Tokyo", instant: t, offsetOf,
        abbrOf: (zone) => tzdata[zone],
    });
    assert.deepEqual(bar.map((c) => c.text), ["BST 13:00", "PDT 05:00", "Jul 1 21:00"]);
});

test("an empty label shows just the time", () => {
    const bar = barClocks({
        clocks: [{ zone: "UTC", label: "" }], localZone: "Asia/Tokyo",
        instant: at("2026-10-02T12:00:00Z"), offsetOf, abbrOf: () => "",
    });
    assert.equal(bar[0].text, "12:00");
});

test("scrolling moves the clocks to the next quarter hour, then a quarter a notch", () => {
    const at = (iso) => Date.parse(iso);
    const t = at("2026-09-28T17:41:00Z");
    assert.equal(scrubbed(t, 1), at("2026-09-28T17:45:00Z"));
    assert.equal(scrubbed(t, 3), at("2026-09-28T18:15:00Z"));
    assert.equal(scrubbed(t, -1), at("2026-09-28T17:30:00Z"));
    assert.equal(scrubbed(t, -2), at("2026-09-28T17:15:00Z"));
    assert.equal(scrubbed(t, 0), t);
    const q = at("2026-09-28T17:45:00Z");
    assert.equal(scrubbed(q, 1), q + SCRUB_STEP);
    assert.equal(scrubbed(q, -1), q - SCRUB_STEP);
    // Seconds count: 17:45:30 is past the quarter.
    assert.equal(scrubbed(q + 30000, -1), q);
});
