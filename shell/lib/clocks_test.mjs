// Tests for clocks.mjs. Node's ICU stands in for the shell's tzdata reader
// for offsets and zone IDs; abbreviations are stubbed, since ICU's are
// the ones SPEC.md §7.3 rules out.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DEFAULT_CLOCKS, jsonError, parseClocks, loadClocks, visibleClocks, dayOffset,
    formatTime, formatLocal, barClocks, scrubbed, SCRUB_STEP, zoneError,
    zoneFormError, cityLabel, editableClocks, editedClocks, movedClock, withoutClock,
    relabeledClock, withClock, DEFAULT_SWITCHES, SWITCH_ROWS, parseClocksFile, withClockSwitch,
    loadPlan,
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

test("a label with a line break is an error, naming the entry", () => {
    for (const brk of ["\\n", "\\r", "\\u000b", "\\f", "\\u0085", "\\u2028", "\\u2029"]) {
        assert.equal(parseClocks(`[{"zone": "UTC", "label": "U"}, {"zone": "Asia/Tokyo", "label": "TY${brk}O"}]`).error,
            "entry 2: label must be one line", JSON.stringify(brk));
    }
    // Spaces and tabs stay one line.
    assert.deepEqual(parseClocks('[{"zone": "Asia/Tokyo", "label": "T\\tY O"}]'),
        { clocks: [{ zone: "Asia/Tokyo", label: "T\tY O" }] });
});

test("a broken label keeps the last good clocks", () => {
    const lastGood = [{ zone: "Asia/Tokyo", label: "TYO" }];
    const r = loadClocks('[{"zone": "UTC", "label": "A\\nB"}]', null, lastGood);
    assert.deepEqual(r.clocks, lastGood);
    assert.deepEqual(r.errors, ["clocks.json: entry 1: label must be one line"]);
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
    // pass under Node and throw in the shell. Newer regular expressions
    // don't throw there; they match nothing, or the wrong thing.
    const { readdir, readFile } = await import("node:fs/promises");
    const dir = new URL(".", import.meta.url);
    const sources = (await readdir(dir)).filter(f => f.endsWith(".mjs") && !f.endsWith("_test.mjs"));
    assert.ok(sources.length > 0);
    for (const f of sources) {
        const text = await readFile(new URL(f, dir), "utf8");
        assert.doesNotMatch(text, /\.at\(/, `${f} uses .at()`);
        assert.doesNotMatch(text, /\\[pP]\{/, `${f} uses a \\p{} property escape`);
        assert.doesNotMatch(text, /\(\?</, `${f} uses a lookbehind or a named group`);
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
    assert.deepEqual(loadClocks(null, null), { clocks: DEFAULT_CLOCKS, switches: DEFAULT_SWITCHES, errors: [], source: null });
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
            assert.deepEqual({ text: bar[0].text, dayOffset: bar[0].dayOffset }, { text, dayOffset: days }, iso);
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
        { text: "SF 16:30", label: "SF", time: "16:30", dayOffset: -1 },
        { text: "NYC 19:30", label: "NYC", time: "19:30", dayOffset: -1 },
        { text: "Oct 3 00:30", label: "Oct 3", time: "00:30", dayOffset: 0, local: true },
    ]);
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

test("the settings panel takes a zone by tide-tz's check of its form", () => {
    for (const zone of ["America/Los_Angeles", "Asia/Kolkata", "America/Argentina/Buenos_Aires",
                        "America/Port-au-Prince", "UTC"]) {
        assert.equal(zoneFormError(zone), "", zone);
    }
    for (const zone of ["US/Pacific", "GB", "PST", "+05:30", "Etc/UTC", "/etc/localtime",
                        "America//New_York", "America/New_York/", "Europe/../Asia/Tokyo",
                        "America/New York", "Asia", ""]) {
        assert.match(zoneFormError(zone), /^unknown time zone .*timedatectl list-timezones/, zone);
    }
});

test("a clock added on the settings panel is labeled with its city", () => {
    assert.equal(cityLabel("America/Los_Angeles"), "Los Angeles");
    assert.equal(cityLabel("America/Argentina/Buenos_Aires"), "Buenos Aires");
    assert.equal(cityLabel("UTC"), "UTC");
});

test("the panel changes the local list when there is one, else the shared one, else the defaults", () => {
    const shared = JSON.stringify([{ zone: "Asia/Tokyo", label: "TYO" }]);
    const local = JSON.stringify([{ zone: "UTC", label: "" }]);
    assert.deepEqual(editableClocks(shared, local), { clocks: [{ zone: "UTC", label: "" }], source: "clocks.local.json" });
    assert.deepEqual(editableClocks(shared, null), { clocks: [{ zone: "Asia/Tokyo", label: "TYO" }], source: "clocks.json" });
    assert.deepEqual(editableClocks(null, null), { clocks: DEFAULT_CLOCKS.map(c => ({ ...c })), source: null });
});

test("a bad shared file stops the panel even under a local list, as it stops the bar", () => {
    const local = JSON.stringify([{ zone: "UTC", label: "" }]);
    assert.match(editableClocks("[", local).error, /^clocks\.json: line 1: /);
    assert.match(editedClocks("[", local, c => withClock(c, "Asia/Tokyo")).error, /^clocks\.json: line 1: /);
    // The bar keeps its last good list for the same file.
    assert.deepEqual(loadClocks("[", local, DEFAULT_CLOCKS).clocks, DEFAULT_CLOCKS);
});

test("the panel's first change copies the list into clocks.local.json", () => {
    const shared = JSON.stringify([{ zone: "Asia/Tokyo", label: "TYO" }]);
    const r = editedClocks(shared, null, c => withClock(c, "Asia/Kolkata"));
    assert.equal(r.text, `[
  {
    "zone": "Asia/Tokyo",
    "label": "TYO"
  },
  {
    "zone": "Asia/Kolkata",
    "label": "Kolkata"
  }
]
`);
    assert.deepEqual(parseClocks(r.text).clocks, r.clocks);
});

test("the panel never writes over a file that doesn't parse", () => {
    assert.match(editedClocks(null, "[{", c => withClock(c, "UTC")).error, /^clocks\.local\.json: line 1: /);
    // With no local file, the shared list is the one to change.
    assert.match(editedClocks('{"zone": "UTC", "label": ""}', null, c => withClock(c, "UTC")).error, /^clocks\.json: expected a list/);
});

test("a refused change writes nothing", () => {
    assert.deepEqual(editedClocks(null, null, c => withClock(c, "US/Pacific")),
                     { error: zoneFormError("US/Pacific") });
});

test("a clock moves left or right, stopping at either end", () => {
    const clocks = DEFAULT_CLOCKS.map(c => ({ ...c }));
    const zones = r => r.clocks.map(c => c.label);
    assert.deepEqual(zones(movedClock(clocks, 1, "America/New_York", -1)), ["NYC", "SF", "LON"]);
    assert.deepEqual(zones(movedClock(clocks, 1, "America/New_York", 1)), ["SF", "LON", "NYC"]);
    assert.deepEqual(zones(movedClock(clocks, 0, "America/Los_Angeles", -1)), ["SF", "NYC", "LON"]);
    assert.deepEqual(zones(movedClock(clocks, 2, "Europe/London", 1)), ["SF", "NYC", "LON"]);
    // Unchanged.
    assert.deepEqual(clocks.map(c => c.label), ["SF", "NYC", "LON"]);
});

test("a change is for the clock the page showed, not whatever a hand edit put there", () => {
    const clocks = DEFAULT_CLOCKS.map(c => ({ ...c }));
    assert.deepEqual(movedClock(clocks, 0, "Europe/London", 1), { error: "entry 1 isn't Europe/London" });
    assert.deepEqual(withoutClock(clocks, 5, "Europe/London"), { error: "entry 6 isn't Europe/London" });
    assert.deepEqual(relabeledClock(clocks, 2, "Asia/Tokyo", "TYO"), { error: "entry 3 isn't Asia/Tokyo" });
    // With no entry, as IPC gives it, the first clock for the zone.
    assert.deepEqual(withoutClock(clocks, undefined, "America/New_York").clocks.map(c => c.label), ["SF", "LON"]);
    assert.deepEqual(withoutClock(clocks, undefined, "Asia/Tokyo"), { error: "no clock for Asia/Tokyo" });
});

test("removing every clock leaves the bar local's alone", () => {
    let clocks = [{ zone: "UTC", label: "" }];
    clocks = withoutClock(clocks, 0, "UTC").clocks;
    assert.deepEqual(clocks, []);
    assert.deepEqual(parseClocks(editedClocks(null, "[]", c => ({ clocks: c })).text).clocks, []);
});

test("a label is any one line, empty, or abbr", () => {
    const clocks = DEFAULT_CLOCKS.map(c => ({ ...c }));
    assert.equal(relabeledClock(clocks, 0, "America/Los_Angeles", "abbr").clocks[0].label, "abbr");
    assert.equal(relabeledClock(clocks, 0, "America/Los_Angeles", "").clocks[0].label, "");
    assert.equal(relabeledClock(clocks, 0, "America/Los_Angeles", "Bay Area").clocks[0].label, "Bay Area");
    assert.deepEqual(relabeledClock(clocks, 0, "America/Los_Angeles", "two\nlines"), { error: "label must be one line" });
});

test("a zone already listed isn't added twice", () => {
    const clocks = DEFAULT_CLOCKS.map(c => ({ ...c }));
    assert.deepEqual(withClock(clocks, "Europe/London"), { error: "Europe/London is listed already" });
    assert.deepEqual(withClock(clocks, "UTC").clocks[3], { zone: "UTC", label: "UTC" });
});

test("clocks.json can be an object of the list and the switches", () => {
    const text = '{"clocks": [{"zone": "Asia/Tokyo", "label": "TYO"}], "hour24": false, "dedupeLocal": false}';
    assert.deepEqual(parseClocksFile(text).settings, {
        clocks: [{ zone: "Asia/Tokyo", label: "TYO" }], hour24: false, dedupeLocal: false,
    });
    assert.deepEqual(parseClocksFile('{"hour24": false}').settings, { hour24: false }, "the list is optional");
    assert.deepEqual(parseClocksFile('[{"zone": "UTC", "label": ""}]').settings, { clocks: [{ zone: "UTC", label: "" }] });
    assert.equal(parseClocksFile('{"hour24": "no"}').error, "hour24 must be true or false");
    assert.equal(parseClocksFile('{"seconds": true}').error, 'unknown setting "seconds"');
    assert.equal(parseClocksFile('{"clocks": [{"zone": "UTC"}]}').error, 'clocks: entry 1: label must be text, or "abbr"');
    assert.equal(parseClocksFile('{"zone": "UTC", "label": ""}').error, "expected a list of {zone, label}");
});

test("the local file's switches win, and its list still replaces the shared one", () => {
    const shared = '{"clocks": [{"zone": "Asia/Tokyo", "label": "TYO"}], "hour24": false, "dedupeLocal": false}';
    let r = loadClocks(shared, '{"hour24": true}');
    assert.deepEqual(r.clocks, [{ zone: "Asia/Tokyo", label: "TYO" }], "the local file has no list");
    assert.equal(r.source, "clocks.json");
    assert.deepEqual(r.switches, { hour24: true, dedupeLocal: false });
    r = loadClocks(shared, '[{"zone": "UTC", "label": ""}]');
    assert.deepEqual(r.clocks, [{ zone: "UTC", label: "" }]);
    assert.deepEqual(r.switches, { hour24: false, dedupeLocal: false }, "a list sets no switch");
    // A bad file keeps the last good of both.
    r = loadClocks(shared, '{"hour24": 1}', DEFAULT_CLOCKS, undefined, { hour24: false, dedupeLocal: true });
    assert.deepEqual(r.switches, { hour24: false, dedupeLocal: true });
    assert.deepEqual(r.errors, ["clocks.local.json: hour24 must be true or false"]);
});

test("a switch goes into clocks.local.json, keeping its list", () => {
    let text = withClockSwitch(null, null, "hour24", false).text;
    assert.deepEqual(JSON.parse(text), { hour24: false });
    text = withClockSwitch(null, '[{"zone": "UTC", "label": ""}]', "dedupeLocal", false).text;
    assert.deepEqual(JSON.parse(text), { clocks: [{ zone: "UTC", label: "" }], dedupeLocal: false });
    text = withClockSwitch(null, text, "dedupeLocal", true).text;
    assert.deepEqual(JSON.parse(text), { clocks: [{ zone: "UTC", label: "" }], dedupeLocal: true });
    assert.equal(withClockSwitch(null, null, "seconds", true).error, 'unknown setting "seconds"');
    assert.equal(withClockSwitch(null, null, "hour24", "no").error, "hour24 must be true or false");
    assert.match(withClockSwitch("[{", null, "hour24", false).error, /^clocks\.json: line 1/);
    assert.match(withClockSwitch(null, "[{", "hour24", false).error, /^clocks\.local\.json: line 1/);
});

test("a change to the list keeps the local file's switches", () => {
    const r = editedClocks(null, '{"hour24": false}', c => withClock(c, "UTC"));
    assert.deepEqual(JSON.parse(r.text).hour24, false);
    assert.equal(JSON.parse(r.text).clocks.length, DEFAULT_CLOCKS.length + 1);
    // A list stays a list.
    assert.ok(Array.isArray(JSON.parse(editedClocks(null, '[{"zone": "UTC", "label": ""}]', c => withClock(c, "Asia/Tokyo")).text)));
});

test("with 24-hour time off, the bar shows the time with AM or PM", () => {
    const bar = barClocks({
        clocks: DEFAULT_CLOCKS, localZone: "Europe/London", instant: at("2026-10-02T23:30:00Z"),
        offsetOf, abbrOf: () => "", hour24: false,
    });
    assert.deepEqual(bar.map(c => [c.label, c.time]), [["SF", "4:30 PM"], ["NYC", "7:30 PM"], ["Oct 3", "12:30 AM"]]);
    assert.equal(bar[0].text, "SF 4:30 PM");
    const noon = barClocks({ clocks: [], localZone: "UTC", instant: at("2026-10-02T12:05:00Z"), offsetOf: () => 0, abbrOf: () => "", hour24: false });
    assert.equal(noon[0].time, "12:05 PM");
});

test("with dedupe-local off, a listed zone that is the local one shows too", () => {
    const t = at("2026-10-02T23:30:00Z");
    const shown = dedupeLocal => barClocks({
        clocks: DEFAULT_CLOCKS, localZone: "Europe/London", instant: t, offsetOf, abbrOf: () => "", dedupeLocal,
    }).map(c => c.label);
    assert.deepEqual(shown(true), ["SF", "NYC", "Oct 3"]);
    assert.deepEqual(shown(false), ["SF", "NYC", "LON", "Oct 3"]);
});

test("the Clocks page lists every switch", () => {
    assert.deepEqual(SWITCH_ROWS.map(r => r.key), Object.keys(DEFAULT_SWITCHES));
});

test("a switch alone needs no lookup, and doesn't restart one running for the same list", () => {
    const good = DEFAULT_CLOCKS.map(c => ({ ...c }));
    const utc = [{ zone: "UTC", label: "" }];
    const plan = (clocks, shown, pending) => loadPlan(clocks, good, shown, pending);
    assert.deepEqual(plan(DEFAULT_CLOCKS, true, null), { lookUp: false, now: true, pending: false }, "shown");
    assert.deepEqual(plan(DEFAULT_CLOCKS, true, good), { lookUp: false, now: true, pending: true }, "shown, a refresh running");
    assert.deepEqual(plan(utc, true, utc), { lookUp: false, now: false, pending: true }, "the lookup running is for it");
    assert.equal(plan(DEFAULT_CLOCKS, false, null).lookUp, true, "nothing shown yet");
    assert.equal(plan(utc, true, null).lookUp, true, "another list");
    assert.equal(plan(DEFAULT_CLOCKS, true, utc).lookUp, true, "a lookup running for another list");
    assert.equal(plan(good.map(c => ({ ...c, label: c.label + "!" })), true, null).lookUp, true, "a new label");
});
