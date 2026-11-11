// Tests for tzdata.mjs, against tide-tz output written out by hand.
import { test } from "node:test";
import assert from "node:assert/strict";
import { zoneTable, periodAt, offsetOf, abbrOf, refreshAt } from "./tzdata.mjs";

const at = (iso) => Date.parse(iso);

const output = {
    local: {
        zone: "Europe/London",
        periods: [
            { start: at("2026-10-02T12:00:00Z"), offset: 60, abbr: "BST" },
            { start: at("2026-10-25T01:00:00Z"), offset: 0, abbr: "GMT" },
        ],
    },
    zones: [
        {
            zone: "America/Los_Angeles",
            periods: [
                { start: at("2026-10-02T12:00:00Z"), offset: -420, abbr: "PDT" },
                { start: at("2026-11-01T09:00:00Z"), offset: -480, abbr: "PST" },
            ],
        },
        { zone: "US/Pacific", error: "unknown time zone US/Pacific; use a zone ID" },
    ],
};

test("zoneTable files each zone's periods and names the errors", () => {
    const t = zoneTable(output);
    assert.equal(t.localZone, "Europe/London");
    assert.deepEqual([...t.periods.keys()], ["America/Los_Angeles", "Europe/London"]);
    assert.deepEqual(t.errors, [{ zone: "US/Pacific", error: "unknown time zone US/Pacific; use a zone ID" }]);
    assert.equal(t.localError, null);
    assert.equal(t.localPlace, null, "no place in the output is none");
});

test("zoneTable passes on local's place", () => {
    const place = { latitude: 51.5083, longitude: -0.1253, city: "London" };
    const t = zoneTable({ local: Object.assign({ place }, output.local), zones: [] });
    assert.deepEqual(t.localPlace, place);
});

test("zoneTable passes on why local's ID wasn't found", () => {
    const t = zoneTable({
        local: { periods: output.local.periods, error: "readlink /etc/localtime: permission denied" },
        zones: [],
    });
    assert.equal(t.localZone, "");
    assert.equal(t.localError, "readlink /etc/localtime: permission denied");
    assert.deepEqual(t.errors, []);
});

test("a local zone with no ID is filed under the empty string", () => {
    const t = zoneTable({ local: { periods: output.local.periods }, zones: [] });
    assert.equal(t.localZone, "");
    assert.equal(offsetOf(t)("", at("2026-10-03T00:00:00Z")), 60);
});

test("lookups follow the periods across a change", () => {
    const t = zoneTable(output);
    assert.equal(offsetOf(t)("Europe/London", at("2026-10-25T00:59:00Z")), 60);
    assert.equal(abbrOf(t)("Europe/London", at("2026-10-25T00:59:00Z")), "BST");
    assert.equal(offsetOf(t)("Europe/London", at("2026-10-25T01:00:00Z")), 0);
    assert.equal(abbrOf(t)("Europe/London", at("2026-10-25T01:00:00Z")), "GMT");
    // Before the first period, the first stands in.
    assert.equal(periodAt(output.local.periods, at("2026-10-01T00:00:00Z")).abbr, "BST");
});

test("refreshAt is the next change in any zone, and at most a day away", () => {
    const t = zoneTable(output);
    assert.equal(refreshAt(t, at("2026-10-24T12:00:00Z")), at("2026-10-25T01:00:00Z"));
    assert.equal(refreshAt(t, at("2026-10-31T12:00:00Z")), at("2026-11-01T09:00:00Z"));
    assert.equal(refreshAt(t, at("2026-10-10T00:00:00Z")), at("2026-10-11T00:00:00Z"));
    assert.equal(refreshAt(t, at("2026-12-01T00:00:00Z")), at("2026-12-02T00:00:00Z"));
});
