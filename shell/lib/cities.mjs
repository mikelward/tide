// The Appearance page's city picker (SPEC.md §16): the cities in
// shell/cities/cities.tsv, from GeoNames, searched as you type.
//
// A search matches a city's name, or its plain ASCII spelling, with the
// launcher's fuzzy matcher, so "novos" finds Novosibirsk and "tromso"
// Tromsø. Both sides drop punctuation, so "xian" finds Xi’an, and read
// "St", "Ste", "Ft" and "Mt" as the words they shorten, so "st petersburg"
// finds Saint Petersburg and "saint petersburg" St. Petersburg, Florida.
// After a comma, the rest has to match the region or country:
// "springfield, il" or "portland, maine". Of cities that match as well,
// the bigger and nearer comes first: near the time zone's city or the
// location set, London, Ontario beats London, England in Toronto, but not
// in Los Angeles. With nothing typed, the picker lists the nearest.

import { match } from "./fuzzy.mjs";

// Combining marks, as fuzzy.mjs spells them: Qt's JavaScript has no
// Unicode property escapes.
const MARKS = /[̀-ͯ҃-҉᪰-᫿᷀-᷿⃐-⃿︠-︯]/g;
const SHORT = { st: "saint", ste: "sainte", ft: "fort", mt: "mount" };

// Lowercase, without accents or punctuation, with the short words spelled
// out: what a search compares.
export function plain(text) {
    const words = String(text ?? "").toLowerCase().normalize("NFD").replace(MARKS, "")
        .replace(/['’‘ʼ`.]/g, "")
        .split(/[\s\-‐–,/()]+/)
        .filter((w) => w !== "");
    return words.map((w) => SHORT[w] ?? w).join(" ");
}

// cities.tsv as {cities, errors}: each city {name, region, country,
// latitude, longitude, population, label, keys, where}, `keys` the plain
// names to search and `where` the plain region and country. A line that
// isn't seven fields with numbers where they belong is left out and named.
export function parseCities(text) {
    const cities = [];
    const errors = [];
    const lines = String(text ?? "").split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line === "" || line[0] === "#") {
            continue;
        }
        const f = line.split("\t");
        const latitude = Number(f[4]);
        const longitude = Number(f[5]);
        const population = Number(f[6]);
        if (f.length !== 7 || f[0] === "" || f[4] === "" || f[5] === "" || !(latitude >= -90 && latitude <= 90) || !(longitude >= -180 && longitude <= 180) || !Number.isFinite(population)) {
            errors.push(`line ${i + 1}: not "name<tab>ascii<tab>region<tab>country<tab>latitude<tab>longitude<tab>population"`);
            continue;
        }
        const keys = [plain(f[0])];
        if (f[1] !== "" && plain(f[1]) !== keys[0]) {
            keys.push(plain(f[1]));
        }
        cities.push({
            name: f[0], region: f[2], country: f[3], latitude, longitude, population,
            label: cityLabel(f[0], f[2], f[3]),
            keys,
            where: plain(`${f[2]} ${f[3]}`),
        });
    }
    return { cities, errors };
}

// "Novosibirsk, Novosibirsk Oblast, Russia", leaving out a region that's
// missing or the city's own name again ("Saint Petersburg, Russia").
export function cityLabel(name, region, country) {
    const parts = [name];
    if (region !== "" && plain(region) !== plain(name)) {
        parts.push(region);
    }
    if (country !== "") {
        parts.push(country);
    }
    return parts.join(", ");
}

// Whether `query`'s letters appear in `text` in order: a quick test that
// spares the full matcher most of the list.
function inOrder(query, text) {
    let at = 0;
    for (const c of query) {
        if (c === " ") {
            continue;
        }
        at = text.indexOf(c, at);
        if (at < 0) {
            return false;
        }
        at += 1;
    }
    return true;
}

const EARTH_KM = 6371;

// The great-circle distance in km between two {latitude, longitude}.
export function distanceKm(a, b) {
    const rad = Math.PI / 180;
    const dLat = (b.latitude - a.latitude) * rad;
    const dLon = (b.longitude - a.longitude) * rad;
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.latitude * rad) * Math.cos(b.latitude * rad) * Math.sin(dLon / 2) ** 2;
    return 2 * EARTH_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

// How strongly a city is suggested among equal matches: more people, and
// nearer `near` when there is one. Both count by orders of magnitude, so
// a city ten times the size is worth one that's ten times nearer, about.
export function weight(city, near) {
    const people = Math.log10(Math.max(1, city.population));
    return near ? people - 2 * Math.log10(1 + distanceKm(city, near) / 100) : people;
}

// The `limit` cities nearest `near`, nearest first.
export function nearestCities(cities, near, limit = 8) {
    return cities.map((c) => ({ city: c, d: distanceKm(c, near) }))
        .sort((a, b) => a.d - b.d)
        .slice(0, limit)
        .map((f) => f.city);
}

// The best `limit` cities for what's typed, best first; none for nothing.
// `near`, a {latitude, longitude} or null, favors the cities near it.
export function searchCities(cities, query, limit = 8, near = null) {
    const comma = String(query ?? "").indexOf(",");
    const name = plain(comma < 0 ? query : query.slice(0, comma));
    const where = comma < 0 ? "" : plain(query.slice(comma + 1));
    if (name === "") {
        return [];
    }
    const found = [];
    // A letter or two says little: those cities whose name starts with
    // them, then those with a later word that does, bigger first. It
    // spares the matcher the whole list on the first keystroke.
    const short = name.length <= 2;
    for (const c of cities) {
        if (where !== "" && !inOrder(where, c.where)) {
            continue;
        }
        if (short) {
            const at = c.keys.some((k) => k.startsWith(name)) ? 2 : c.keys.some((k) => k.includes(` ${name}`)) ? 1 : 0;
            if (at > 0 && (where === "" || match(where, c.where))) {
                found.push({ city: c, score: at });
            }
            continue;
        }
        let best = null;
        for (const key of c.keys) {
            if (!inOrder(name, key)) {
                continue;
            }
            const m = match(name, key);
            if (m && (best === null || m.score > best)) {
                best = m.score;
            }
        }
        if (best !== null && (where === "" || match(where, c.where))) {
            found.push({ city: c, score: best });
        }
    }
    for (const f of found) {
        f.weight = weight(f.city, near);
    }
    found.sort((a, b) => b.score - a.score || b.weight - a.weight);
    return found.slice(0, limit).map((f) => f.city);
}

// The city picker's Find (SPEC.md §16): beacondb.net's geolocation API,
// asked with nothing but the request itself, so it answers from this
// machine's IP address. Only on a click; never on the hot path.
export const GEOLOCATE_URL = "https://api.beacondb.net/v1/geolocate";
export const GEOLOCATE_BODY = "{}";
// What the picker says the answer came from: beacondb.net's, and the
// IP-to-city data's credit, which its license asks for.
export const GEOLOCATE_CREDIT = "From your IP address, by beacondb.net, with DB-IP's data (CC BY 4.0)";

// beacondb.net's answer, as {latitude, longitude, accuracyKm} or {error}:
// {"location": {"lat": .., "lng": ..}, "accuracy": metres}, or an error
// object, or a page that isn't JSON at all.
export function parseGeolocation(status, text) {
    let value = null;
    try {
        value = JSON.parse(text);
    } catch (e) {
        value = null;
    }
    if (status !== 200) {
        const said = value?.error?.message ?? (status === 0 ? "no answer" : `HTTP ${status}`);
        return { error: `beacondb.net: ${said}` };
    }
    const lat = value?.location?.lat;
    const lng = value?.location?.lng;
    if (typeof lat !== "number" || typeof lng !== "number" || !(lat >= -90 && lat <= 90) || !(lng >= -180 && lng <= 180)) {
        return { error: "beacondb.net: an answer with no location" };
    }
    const accuracy = typeof value.accuracy === "number" && value.accuracy > 0 ? Math.round(value.accuracy / 1000) : null;
    return { latitude: lat, longitude: lng, accuracyKm: accuracy };
}

// The line under the results once Find has answered.
export function foundText(found) {
    return found.accuracyKm === null ? "Nearest to you first" : `Nearest to you first, to within about ${found.accuracyKm} km`;
}
