// tide-tz's output, as the clocks' `offsetOf` and `abbrOf` (SPEC.md
// §7.3). tide-tz lists each zone's periods of constant offset; the
// shell runs it at startup, when the clock config changes, and when a
// period ends, so a minute's tick only looks up a period here.

const DAY = 24 * 60 * 60 * 1000;

// The table of periods by zone ID from tide-tz's JSON. Local's
// periods are filed under its ID, or "" when it has none, so `localZone`
// always finds them. `errors` names each zone tide-tz couldn't load,
// and `localError` says why local's ID couldn't be found, if it couldn't.
export function zoneTable(output) {
    const periods = new Map();
    const errors = [];
    for (const z of output.zones) {
        if (z.error) {
            errors.push({ zone: z.zone, error: z.error });
        } else {
            periods.set(z.zone, z.periods);
        }
    }
    const localZone = output.local.zone ?? "";
    periods.set(localZone, output.local.periods);
    // Where tzdata puts the local zone's main city, or null (SPEC.md §15).
    const localPlace = output.local.place ?? null;
    return { periods, localZone, localPlace, errors, localError: output.local.error ?? null };
}

// The period in force at `ms`: the last one starting at or before it. Before
// the first, the first stands in; tide-tz starts its list at now.
export function periodAt(periods, ms) {
    let found = periods[0];
    for (const p of periods) {
        if (p.start > ms) {
            break;
        }
        found = p;
    }
    return found;
}

export function offsetOf(table) {
    return (zone, ms) => periodAt(table.periods.get(zone), ms).offset;
}

export function abbrOf(table) {
    return (zone, ms) => periodAt(table.periods.get(zone), ms).abbr;
}

// When to run tide-tz again: at the next period change in any zone,
// and at least daily, so a list that ran out is never relied on.
export function refreshAt(table, ms) {
    let next = ms + DAY;
    for (const periods of table.periods.values()) {
        for (const p of periods) {
            if (p.start > ms && p.start < next) {
                next = p.start;
            }
        }
    }
    return next;
}
