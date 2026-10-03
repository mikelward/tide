// The clocks popover's next DST change (SPEC.md §7.3), as pure functions
// the QML binds to. The input is tide-tz's periods of constant offset
// per zone (see tzdata.mjs), so no time zone rules live here.

const MINUTE = 60 * 1000;
const DAY = 24 * 60 * MINUTE;
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// Changes in other zones this soon after the first are part of the same
// story: the weeks the usual gap between them is off.
export const FOLLOW_WINDOW = 6 * 7 * DAY;

// The offset changes in `periods` after `after`: [{at, from, to, abbr,
// fromAbbr}], in order, skipping periods that only change the abbreviation.
export function offsetChanges(periods, after) {
    const changes = [];
    for (let i = 1; i < periods.length; i++) {
        const prev = periods[i - 1];
        const p = periods[i];
        if (p.start > after && p.offset !== prev.offset) {
            changes.push({ at: p.start, from: prev.offset, to: p.offset, abbr: p.abbr, fromAbbr: prev.abbr });
        }
    }
    return changes;
}

// What the sentence calls a clock: its bar label, or for a clock labeled
// "abbr" (whose label changes) its abbreviation before the change, or for
// one with no label the city in its zone ID (Europe/London gives London).
export function clockName(clock, fromAbbr) {
    if (clock.label === "abbr") {
        return fromAbbr;
    }
    if (clock.label) {
        return clock.label;
    }
    const city = clock.zone.split("/").pop();
    return city.replace(/_/g, " ");
}

// The next DST change among `clocks` ([{zone, label}]) after `now`, with
// `periodsOf(zone)` giving each zone's periods: null if none is coming, or
//
//   {first: group, then: group | null}
//
// where a group is {at, labels, abbrs, zones, changes} for the zones that
// change on the first change's day, and `then` is the next such group
// within FOLLOW_WINDOW. A zone with no periods is skipped.
export function nextDstChange({ clocks, periodsOf, now }) {
    const pending = [];
    for (const [order, c] of clocks.entries()) {
        const periods = periodsOf(c.zone);
        if (!periods) {
            continue;
        }
        // Every change, not just the next: a zone can change twice within
        // FOLLOW_WINDOW, and its second change ends the altered gap too.
        for (const change of offsetChanges(periods, now)) {
            pending.push(Object.assign({}, change, { zone: c.zone, label: clockName(c, change.fromAbbr), order }));
        }
    }
    if (pending.length === 0) {
        return null;
    }
    pending.sort((a, b) => a.at - b.at);
    const group = (start) => {
        // In the clocks' own order, as the popover lists them.
        const members = pending.filter(p => p.at >= start.at && p.at - start.at < DAY)
            .sort((x, y) => x.order - y.order);
        return {
            at: Math.min(...members.map(p => p.at)),
            labels: members.map(p => p.label),
            abbrs: [...new Set(members.map(p => p.abbr))],
            zones: members.map(p => p.zone),
            changes: members,
        };
    };
    const first = group(pending[0]);
    const later = pending.find(p => p.at - first.at >= DAY && p.at - first.at <= FOLLOW_WINDOW);
    return { first, then: later ? group(later) : null };
}

function list(words) {
    if (words.length <= 1) {
        return words.join("");
    }
    return `${words.slice(0, -1).join(", ")} and ${words[words.length - 1]}`;
}

// "Sun Oct 25" for `ms` in the zone `offset` minutes from UTC.
export function formatDay(ms, offset) {
    const d = new Date(ms + offset * MINUTE);
    return `${WEEKDAYS[d.getUTCDay()]} ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

function gapPhrase(days) {
    if (days === 7) {
        return "a week";
    }
    if (days % 7 === 0) {
        return `${["", "", "two", "three", "four", "five", "six"][days / 7]} weeks`;
    }
    return days === 1 ? "a day" : `${days} days`;
}

function hours(minutes) {
    const h = Math.abs(minutes) / 60;
    return Number.isInteger(h) ? `${h}` : `${Math.round(h * 100) / 100}`;
}

// "8 h ahead of" or "level with": where a zone at `aOffset` stands
// against one at `bOffset`.
function relation(aOffset, bOffset) {
    const diff = aOffset - bOffset;
    if (diff === 0) {
        return { phrase: "level with", sign: 0, hours: "0" };
    }
    const sign = Math.sign(diff);
    return { phrase: `${hours(diff)} h ${sign > 0 ? "ahead of" : "behind"}`, sign, hours: hours(diff) };
}

// A group's clause, each zone dated in its own time before the change:
// clocks change on a Sunday where they change, whatever the day is here,
// and zones changing at one instant can be on different days. Zones on
// the same day share a clause, in the clocks' order.
function groupClause(g) {
    const days = [];
    for (const c of g.changes) {
        const day = formatDay(c.at, c.from);
        let d = days.find(x => x.day === day);
        if (!d) {
            d = { day, labels: [], abbrs: [] };
            days.push(d);
        }
        d.labels.push(c.label);
        if (!d.abbrs.includes(c.abbr)) {
            d.abbrs.push(c.abbr);
        }
    }
    return days.map(d => `${list(d.labels)} ${d.labels.length === 1 ? "moves" : "move"} to ${d.abbrs.join("/")} on ${d.day}`)
        .join(" and ");
}

// The popover's sentence for nextDstChange's result. "" when no change is
// coming.
export function dstMessage(change) {
    if (!change) {
        return "";
    }
    const { first, then } = change;
    const text = groupClause(first);
    if (!then) {
        return `${text}.`;
    }
    // From the instants, not from either zone's calendar: the groups are at
    // least a day apart.
    const days = Math.round((then.at - first.at) / DAY);
    const sentence = `${text}, ${gapPhrase(days)} before ${groupClause(then)}.`;
    // A zone whose gap is off between the two changes: one that changes
    // first, against one that changes only second. Zones that move together
    // keep their gap, so there's no sentence about them.
    const a = first.changes[0];
    const firstZones = new Set(first.changes.map(c => c.zone));
    const b = then.changes.find(c => !firstZones.has(c.zone));
    // The gap is only "off for a while" if the second change puts it back
    // (counting `a`'s own second change, if it has one); zones in opposite
    // hemispheres move it twice the same way instead.
    const aAfter = then.changes.find(c => c.zone === a.zone)?.to ?? a.to;
    if (!b || aAfter - b.to !== a.from - b.from) {
        return sentence;
    }
    const usual = relation(a.from, b.from);
    const during = relation(a.to, b.from);
    // "instead of 8", "instead of 1 h ahead" or "instead of level with NYC".
    const instead = usual.sign === 0 ? `level with ${b.label}`
        : usual.sign === during.sign ? usual.hours
        : usual.phrase.replace(/ of$/, "");
    const span = days === 7 ? "For that week" : days % 7 === 0 ? "For those weeks" : "Until then";
    return `${sentence} ${span}, ${a.label} is ${during.phrase} ${b.label} instead of ${instead}.`;
}
