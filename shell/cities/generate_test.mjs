// Tests for generate.mjs, on small pieces of GeoNames' own files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { citiesTsv, parseCountries, parseRegions, pickCities } from "./generate.mjs";

// geonameid, name, asciiname, alternatenames, latitude, longitude, feature
// class, feature code, country, cc2, admin1..4, population, elevation, dem,
// timezone, modification date.
const row = (id, name, ascii, lat, lon, code, cc, admin1, pop) =>
    [id, name, ascii, "", lat, lon, "P", code, cc, "", admin1, "", "", "", pop, "", "0", "Etc/UTC", "2024-01-01"].join("\t");

const CITIES = [
    row("1", "Smallville", "Smallville", "40.1", "-90.2", "PPL", "US", "IL", "4999"),
    row("2", "Novosibirsk", "Novosibirsk", "55.0415", "82.9346", "PPLA", "RU", "53", "1612833"),
    row("3", "Valletta", "Valletta", "35.89968", "14.5148", "PPLC", "MT", "60", "6794"),
    row("4", "Tromsø", "Tromso", "69.6489", "18.95508", "PPLA", "NO", "54", "41915"),
    row("5", "Middletown", "Middletown", "41.4", "-74.4", "PPL", "US", "NY", "99999"),
    row("6", "Big City", "Big City", "10", "20", "PPL", "XX", "01", "100000"),
    row("5861897", "Fairbanks", "Fairbanks", "64.83778", "-147.71639", "PPLA2", "US", "AK", "32325"),
].join("\n") + "\n";

const ADMIN1 = "RU.53\tNovosibirsk Oblast\tNovosibirsk Oblast\t1496745\nMT.60\tValletta\tValletta\t1\nNO.54\tTroms\tTroms\t1\nUS.AK\tAlaska\tAlaska\t1\n";
const COUNTRIES = "#ISO\tISO3\tISO-Numeric\tfips\tCountry\n" +
    "RU\tRUS\t643\tRS\tRussia\nMT\tMLT\t470\tMT\tMalta\nNO\tNOR\t578\tNO\tNorway\nUS\tUSA\t840\tUS\tUnited States\n";

test("it keeps big cities, capitals and the far towns, most people first", () => {
    const cities = pickCities(CITIES, parseRegions(ADMIN1), parseCountries(COUNTRIES));
    assert.deepEqual(cities.map((c) => c.name), ["Novosibirsk", "Big City", "Tromsø", "Fairbanks", "Valletta"]);
});

test("each city has its region, country, plain name and rounded coordinates", () => {
    const [nsk, big, tromso] = pickCities(CITIES, parseRegions(ADMIN1), parseCountries(COUNTRIES));
    assert.deepEqual(nsk, { name: "Novosibirsk", ascii: "", region: "Novosibirsk Oblast", country: "Russia", latitude: "55.04", longitude: "82.93", population: 1612833 });
    assert.equal(tromso.ascii, "Tromso");
    assert.equal(big.region, "", "a region GeoNames doesn't name is empty");
    assert.equal(big.country, "XX", "a country it doesn't name keeps its code");
});

test("the file credits GeoNames and has a line a city", () => {
    const text = citiesTsv(pickCities(CITIES, parseRegions(ADMIN1), parseCountries(COUNTRIES)));
    assert.match(text, /^# Data: GeoNames .*CC BY 4\.0/m);
    const lines = text.split("\n").filter((l) => l !== "" && !l.startsWith("#"));
    assert.equal(lines.length, 5);
    assert.equal(lines[0], "Novosibirsk\t\tNovosibirsk Oblast\tRussia\t55.04\t82.93\t1612833");
});

test("a short line is an error, not a city", () => {
    assert.throws(() => pickCities("1\tNowhere\n", new Map(), new Map()), /fields/);
});
