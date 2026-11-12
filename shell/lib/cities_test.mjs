import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { cityLabel, distanceKm, nearestCities, parseCities, plain, searchCities } from "./cities.mjs";

const { cities, errors } = parseCities(readFileSync(new URL("../cities/cities.tsv", import.meta.url), "utf8"));
const first = (q) => searchCities(cities, q, 1)[0]?.label;

test("the shipped list reads cleanly, with thousands of cities", () => {
    assert.deepEqual(errors, []);
    assert.ok(cities.length > 8000, `${cities.length} cities`);
});

test("plain drops accents and punctuation and spells out short words", () => {
    assert.equal(plain("Xi’an"), "xian");
    assert.equal(plain("St. Petersburg"), "saint petersburg");
    assert.equal(plain("Ste-Foy"), "sainte foy");
    assert.equal(plain("São Paulo"), "sao paulo");
});

test("the cities people asked for are found as typed", () => {
    assert.equal(first("novosibirsk"), "Novosibirsk, Novosibirsk Oblast, Russia");
    assert.equal(first("st petersburg"), "Saint Petersburg, Russia");
    assert.equal(first("xian"), "Xi’an, Shaanxi, China");
    assert.equal(first("tromso"), "Tromsø, Troms, Norway");
    assert.equal(first("valletta"), "Valletta, Malta");
    assert.equal(first("fairbanks"), "Fairbanks, Alaska, United States");
});

test("a few letters find big cities first, and fuzzily", () => {
    assert.equal(first("novos"), "Novosibirsk, Novosibirsk Oblast, Russia");
    assert.equal(first("lond"), "London, England, United Kingdom");
    assert.equal(first("sydny"), "Sydney, New South Wales, Australia");
});

test("a letter or two finds names that start with them, biggest first", () => {
    const sa = searchCities(cities, "sa", 3).map((c) => c.name);
    assert.deepEqual(sa, ["São Paulo", "Saint Petersburg", "Santiago"]);
    assert.ok(searchCities(cities, "x").every((c) => c.keys.some((k) => /(^| )x/.test(k))));
});

test("after a comma, the region or country narrows it", () => {
    assert.equal(first("saint petersburg, florida"), "St. Petersburg, Florida, United States");
    assert.equal(first("london, canada"), "London, Ontario, Canada");
    assert.equal(searchCities(cities, "london, atlantis").length, 0);
});

test("nothing typed finds nothing, and the list stops at the limit", () => {
    assert.deepEqual(searchCities(cities, ""), []);
    assert.deepEqual(searchCities(cities, " , "), []);
    assert.equal(searchCities(cities, "san").length, 8);
});

test("a bad line is named and left out", () => {
    const r = parseCities("# header\nGood\t\tR\tC\t1.5\t2.5\t100\nBad\t\tR\tC\tnorth\t2\t100\n");
    assert.equal(r.cities.length, 1);
    assert.match(r.errors[0], /^line 3: /);
});

test("the label leaves out a region named for the city", () => {
    assert.equal(cityLabel("Valletta", "Valletta", "Malta"), "Valletta, Malta");
    assert.equal(cityLabel("Big City", "", "XX"), "Big City, XX");
});

const TORONTO = { latitude: 43.65, longitude: -79.38 };
const LOS_ANGELES = { latitude: 34.05, longitude: -118.24 };

test("distances are great-circle kilometers", () => {
    const london = { latitude: 51.51, longitude: -0.13 };
    assert.ok(Math.abs(distanceKm(london, { latitude: 48.86, longitude: 2.35 }) - 344) < 5, "London to Paris");
    assert.equal(distanceKm(london, london), 0);
});

test("among equal matches, the nearer city comes first unless it's much smaller", () => {
    const top = (q, near) => searchCities(cities, q, 1, near)[0].label;
    assert.equal(top("london", TORONTO), "London, Ontario, Canada");
    assert.equal(top("london", LOS_ANGELES), "London, England, United Kingdom");
    assert.equal(top("london", null), "London, England, United Kingdom");
    assert.equal(top("springfield", { latitude: 42.36, longitude: -71.06 }), "Springfield, Massachusetts, United States");
    assert.equal(top("springfield", { latitude: 38.63, longitude: -90.2 }), "Springfield, Illinois, United States");
});

test("with nothing typed, the nearest cities are listed", () => {
    const near = nearestCities(cities, LOS_ANGELES, 3).map((c) => c.name);
    assert.equal(near[0], "Los Angeles");
    assert.equal(near.length, 3);
});
