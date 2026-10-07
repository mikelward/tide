// Tests for popover.mjs, at the mock's instant: 2026-09-28 17:41 UTC, with
// local in Central Europe.
import { test } from "node:test";
import { nextDstChange } from "./dst.mjs";
import assert from "node:assert/strict";
import {
    cityOf, formatOffset, stripSegments, popoverZones, nowFraction, heading,
    isoWeek, monthTitle, dstClocks, escapeStyled, calendarCells, stepMonth, monthGrid, changeDays, dstLead, SOON,
} from "./popover.mjs";

const instant = Date.parse("2026-09-28T17:41:00Z");
const offsets = {
    "America/Los_Angeles": [-420, "PDT"],
    "America/New_York": [-240, "EDT"],
    "Europe/London": [60, "BST"],
    "Europe/Berlin": [120, "CEST"],
    "Asia/Kolkata": [330, "IST"],
    "": [0, "UTC"],
};
const offsetOf = (zone) => offsets[zone][0];
const abbrOf = (zone) => offsets[zone][1];
const clocks = [
    { zone: "America/Los_Angeles", label: "SF" },
    { zone: "America/New_York", label: "NYC" },
    { zone: "Europe/London", label: "LON" },
];

test("cities come from the zone ID", () => {
    assert.equal(cityOf("America/Los_Angeles"), "Los Angeles");
    assert.equal(cityOf("America/Argentina/Buenos_Aires"), "Buenos Aires");
    assert.equal(cityOf(""), "");
});

test("offsets from local read as hours, with minutes when there are any", () => {
    assert.equal(formatOffset(0), "");
    assert.equal(formatOffset(-540), "−9 h");
    assert.equal(formatOffset(60), "+1 h");
    assert.equal(formatOffset(210), "+3:30 h");
    assert.equal(formatOffset(-570), "−9:30 h");
});

test("each zone lists its city, abbreviation, time and offset, then local", () => {
    const rows = popoverZones({ clocks, localZone: "Europe/Berlin", instant, offsetOf, abbrOf });
    assert.deepEqual(rows.map(r => [r.label, r.city, r.abbr, r.time, r.offset, r.local]), [
        ["SF", "Los Angeles", "PDT", "10:41", "−9 h", false],
        ["NYC", "New York", "EDT", "13:41", "−6 h", false],
        ["LON", "London", "BST", "18:41", "−1 h", false],
        ["", "Berlin", "CEST", "19:41", "", true],
    ]);
});

test("a listed clock in the local zone is the local row, in its place", () => {
    const rows = popoverZones({ clocks, localZone: "Europe/London", instant, offsetOf, abbrOf });
    assert.deepEqual(rows.map(r => [r.label, r.local]), [["SF", false], ["NYC", false], ["LON", true]]);
});

test("a local zone with no ID is called Local and hides nothing", () => {
    const rows = popoverZones({ clocks: clocks.slice(0, 1), localZone: "", instant, offsetOf, abbrOf });
    assert.deepEqual(rows.map(r => [r.city, r.local]), [["Los Angeles", false], ["Local", true]]);
});

test("a clock labeled abbr shows its abbreviation", () => {
    const rows = popoverZones({
        clocks: [{ zone: "Europe/London", label: "abbr" }], localZone: "Europe/Berlin", instant, offsetOf, abbrOf,
    });
    assert.equal(rows[0].label, "BST");
});

test("the strip shows each zone's hours in local time, split where it wraps", () => {
    // Local's own 09-17.
    assert.deepEqual(stripSegments([9, 17], 120, 120), [{ x: 9 / 24, width: 8 / 24 }]);
    // Los Angeles's 09-17 is 18-02 in Berlin.
    assert.deepEqual(stripSegments([9, 17], -420, 120), [
        { x: 18 / 24, width: 6 / 24 },
        { x: 0, width: 2 / 24 },
    ]);
    // Kolkata's 09-17 is 05:30-13:30 in Berlin.
    assert.deepEqual(stripSegments([9, 17], 330, 120), [{ x: 5.5 / 24, width: 8 / 24 }]);
});

test("now and the heading are in local time", () => {
    assert.equal(nowFraction(instant, 120), (19 + 41 / 60) / 24);
    assert.deepEqual(heading(instant, 120), { time: "19:41", date: "Monday, September 28" });
    // Still Sunday in Los Angeles at 03:00 UTC on Monday.
    assert.equal(heading(Date.parse("2026-09-28T03:00:00Z"), -420).date, "Sunday, September 27");
    assert.equal(heading(instant, 120, false).time, "7:41 PM", "with 24-hour time off");
});

test("with 24-hour time off, each row's time has AM or PM", () => {
    const rows = popoverZones({ clocks, localZone: "Europe/Berlin", instant, offsetOf, abbrOf, hour24: false });
    assert.deepEqual(rows.map(r => r.time), ["10:41 AM", "1:41 PM", "6:41 PM", "7:41 PM"]);
});

test("ISO weeks start on Monday, and week 1 holds the year's first Thursday", () => {
    assert.equal(isoWeek(2026, 8, 28), 40);
    assert.equal(isoWeek(2026, 0, 1), 1);
    assert.equal(isoWeek(2027, 0, 1), 53);
    assert.equal(isoWeek(2027, 0, 4), 1);
    assert.equal(isoWeek(2024, 11, 30), 1);
});

test("months step across years", () => {
    assert.deepEqual(stepMonth(2026, 11, 1), { year: 2027, month: 0 });
    assert.deepEqual(stepMonth(2026, 0, -1), { year: 2025, month: 11 });
    assert.equal(monthTitle(2026, 8), "September 2026");
});

test("the month grid runs Monday to Sunday, padded from the months either side", () => {
    const weeks = monthGrid(2026, 8, { year: 2026, month: 8, date: 28 },
        [{ year: 2026, month: 9, date: 4 }, { year: 2026, month: 8, date: 3 }]);
    assert.equal(weeks.length, 5);
    assert.deepEqual(weeks.map(w => w.week), [36, 37, 38, 39, 40]);
    assert.deepEqual(weeks[0].days.map(d => d.date), [31, 1, 2, 3, 4, 5, 6]);
    assert.equal(weeks[0].days[0].outside, true);
    assert.deepEqual(weeks[4].days.map(d => d.date), [28, 29, 30, 1, 2, 3, 4]);
    assert.equal(weeks[4].days[0].today, true);
    assert.equal(weeks[0].days.filter(d => d.today).length, 0);
    assert.equal(weeks[0].days[3].mark, true);
    assert.equal(weeks[4].days[6].mark, true);
});

test("a month starting on Monday has no days from before it", () => {
    // June 2026 starts on a Monday.
    const weeks = monthGrid(2026, 5, null);
    assert.deepEqual(weeks[0].days.map(d => d.date), [1, 2, 3, 4, 5, 6, 7]);
    assert.equal(weeks.length, 5);
});

test("the calendar marks each change's local date", () => {
    const change = {
        first: { at: 1, changes: [{ at: Date.parse("2026-10-25T01:00:00Z") }] },
        then: { at: 2, changes: [{ at: Date.parse("2026-11-01T09:00:00Z") }] },
    };
    assert.deepEqual(changeDays(change, () => 60), [
        { year: 2026, month: 9, date: 25 },
        { year: 2026, month: 10, date: 1 },
    ]);
    assert.deepEqual(changeDays(null, () => 0), []);
});

test("the DST line leads with soon only when it is", () => {
    const change = { first: { at: instant + SOON }, then: null };
    assert.equal(dstLead(change, instant), "Clocks change soon.");
    assert.equal(dstLead(change, instant - 1), "Next clock change:");
    assert.equal(dstLead(null, instant), "");
});

test("local's DST changes count when it isn't a listed clock", () => {
    assert.deepEqual(dstClocks(clocks, "Australia/Sydney").map(c => [c.zone, c.label]), [
        ["America/Los_Angeles", "SF"],
        ["America/New_York", "NYC"],
        ["Europe/London", "LON"],
        ["Australia/Sydney", ""],
    ]);
    assert.equal(dstClocks(clocks, "Europe/London"), clocks);
    assert.deepEqual(dstClocks([], "").map(c => [c.zone, c.label]), [["", "Local"]]);
});

test("local's change names its city in the sentence", () => {
    const at = (iso) => Date.parse(iso);
    const periods = {
        "Europe/London": [
            { start: at("2026-09-01T00:00:00Z"), offset: 60, abbr: "BST" },
            { start: at("2026-10-25T01:00:00Z"), offset: 0, abbr: "GMT" },
        ],
        "Australia/Sydney": [
            { start: at("2026-09-01T00:00:00Z"), offset: 600, abbr: "AEST" },
            { start: at("2026-10-03T16:00:00Z"), offset: 660, abbr: "AEDT" },
        ],
    };
    const change = nextDstChange({
        clocks: dstClocks([{ zone: "Europe/London", label: "LON" }], "Australia/Sydney"),
        periodsOf: (zone) => periods[zone],
        now: at("2026-09-28T00:00:00Z"),
    });
    assert.deepEqual(change.first.labels, ["Sydney"]);
});

test("labels are escaped for styled text", () => {
    assert.equal(escapeStyled("<b>HQ</b> & \"A\""), "&lt;b&gt;HQ&lt;/b&gt; &amp; &quot;A&quot;");
    assert.equal(escapeStyled("LON"), "LON");
});

test("each calendar row starts with its ISO week number", () => {
    const cells = calendarCells(monthGrid(2026, 8, null));
    assert.equal(cells.length, 5 * 8);
    assert.deepEqual(cells.filter((_, i) => i % 8 === 0), [{ week: 36 }, { week: 37 }, { week: 38 }, { week: 39 }, { week: 40 }]);
    assert.equal(cells[1].date, 31);
    assert.equal(cells[8 + 1].date, 7);
});
