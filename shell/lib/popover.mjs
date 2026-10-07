// The clocks popover (SPEC.md §7.3, docs/mocks/clocks.html), as pure
// functions the QML binds to. Offsets and abbreviations come in from the
// caller, as in clocks.mjs.

import { formatTime } from "./clocks.mjs";

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November", "December"];

// The strip's day and working hours, in each zone's own time.
export const DAY_HOURS = Object.freeze([7, 20]);
export const WORK_HOURS = Object.freeze([9, 17]);
// A DST change this close gets "Clocks change soon."
export const SOON = 14 * DAY;

// `text` made literal for a QML Text in StyledText format, which would
// otherwise read a clock label such as "<b>HQ</b>" or "A&B" as markup.
export function escapeStyled(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// "Los Angeles" from America/Los_Angeles; "" for no zone ID.
export function cityOf(zone) {
    return zone ? zone.split("/").pop().replace(/_/g, " ") : "";
}

// A zone's offset from local: "" when level, else "+5 h", "−9 h" or
// "+5:30 h".
export function formatOffset(minutes) {
    if (minutes === 0) {
        return "";
    }
    const sign = minutes > 0 ? "+" : "−";
    const m = Math.abs(minutes);
    const h = Math.floor(m / 60);
    return m % 60 === 0 ? `${sign}${h} h` : `${sign}${h}:${String(m % 60).padStart(2, "0")} h`;
}

// The hours `from` to `to` in a zone `zoneOffset` minutes from UTC, as
// [{x, width}] fractions of a local 0-24 strip, split where it wraps.
export function stripSegments([from, to], zoneOffset, localOffset) {
    const shift = (localOffset - zoneOffset) / 60;
    const start = (((from + shift) % 24) + 24) % 24;
    const end = start + (to - from);
    const parts = end <= 24 ? [[start, end]] : [[start, 24], [0, end - 24]];
    return parts.map(([a, b]) => ({ x: a / 24, width: (b - a) / 24 }));
}

// One row per listed clock, in order, then local, each as {label, city,
// abbr, time, offset, local, day, work}. A listed clock in the local zone
// (hidden on the bar) is the local row, in its place, rather than a second
// one. `hour24` is the Clocks page's switch.
export function popoverZones({ clocks, localZone, instant, offsetOf, abbrOf, hour24 = true }) {
    const localOffset = offsetOf(localZone, instant);
    const row = (zone, label, local) => {
        const offset = offsetOf(zone, instant);
        return {
            label,
            city: cityOf(zone) || "Local",
            abbr: abbrOf(zone, instant),
            time: formatTime(instant, offset, hour24),
            offset: formatOffset(offset - localOffset),
            local,
            day: stripSegments(DAY_HOURS, offset, localOffset),
            work: stripSegments(WORK_HOURS, offset, localOffset),
        };
    };
    const rows = clocks.map((c) => {
        const local = localZone !== "" && c.zone === localZone;
        const label = c.label === "abbr" ? abbrOf(c.zone, instant) : c.label;
        return row(c.zone, label, local);
    });
    if (!rows.some((r) => r.local)) {
        rows.push(row(localZone, "", true));
    }
    return rows;
}

// The clocks whose DST changes the popover tells of: the listed ones, plus
// local when it isn't one of them, since it has a row too. Local without a
// zone ID is called "Local".
export function dstClocks(clocks, localZone) {
    if (localZone !== "" && clocks.some((c) => c.zone === localZone)) {
        return clocks;
    }
    return [...clocks, { zone: localZone, label: localZone === "" ? "Local" : "" }];
}

// Where "now" falls on the local strip, 0-1.
export function nowFraction(instant, localOffset) {
    const ms = instant + localOffset * MINUTE;
    return (((ms % DAY) + DAY) % DAY) / DAY;
}

// The popover's heading: {time: "19:41", date: "Monday, September 28"},
// the time as formatTime gives it with `hour24`.
export function heading(instant, localOffset, hour24 = true) {
    const d = new Date(instant + localOffset * MINUTE);
    return {
        time: formatTime(instant, localOffset, hour24),
        date: `${WEEKDAYS[d.getUTCDay()]}, ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`,
    };
}

// The local date at `instant`: {year, month (0-11), date}.
export function localDate(instant, localOffset) {
    const d = new Date(instant + localOffset * MINUTE);
    return { year: d.getUTCFullYear(), month: d.getUTCMonth(), date: d.getUTCDate() };
}

// The ISO 8601 week number of a date (`month` 0-11).
export function isoWeek(year, month, date) {
    const d = new Date(Date.UTC(year, month, date));
    // The Thursday of this week decides its year.
    const thursday = d.getTime() + (3 - ((d.getUTCDay() + 6) % 7)) * DAY;
    const yearStart = Date.UTC(new Date(thursday).getUTCFullYear(), 0, 1);
    return Math.floor((thursday - yearStart) / (7 * DAY)) + 1;
}

// "September 2026".
export function monthTitle(year, month) {
    return `${MONTHS[month]} ${year}`;
}

// The month after (`step` 1) or before (-1): {year, month}.
export function stepMonth(year, month, step) {
    const m = year * 12 + month + step;
    return { year: Math.floor(m / 12), month: ((m % 12) + 12) % 12 };
}

// The shown month as weeks from Monday: [{week, days: [{date, outside,
// today, mark}]}]. `today` and each of `marks` are {year, month, date};
// days from the months either side are `outside`.
export function monthGrid(year, month, today, marks = []) {
    const same = (a, y, m, d) => a && a.year === y && a.month === m && a.date === d;
    const first = Date.UTC(year, month, 1);
    const back = (new Date(first).getUTCDay() + 6) % 7;
    const weeks = [];
    let ms = first - back * DAY;
    do {
        const days = [];
        for (let i = 0; i < 7; i++, ms += DAY) {
            const d = new Date(ms);
            const y = d.getUTCFullYear();
            const m = d.getUTCMonth();
            const date = d.getUTCDate();
            days.push({
                date,
                outside: m !== month,
                today: same(today, y, m, date),
                mark: marks.some((x) => same(x, y, m, date)),
            });
        }
        const monday = new Date(ms - 7 * DAY);
        weeks.push({ week: isoWeek(monday.getUTCFullYear(), monday.getUTCMonth(), monday.getUTCDate()), days });
    } while (new Date(ms).getUTCMonth() === month);
    return weeks;
}

// monthGrid's weeks as one list of grid cells, eight to a row: the ISO week
// number as {week}, then that week's seven days.
export function calendarCells(weeks) {
    return [].concat(...weeks.map((w) => [{ week: w.week }, ...w.days]));
}

// The local dates the clocks change on, from nextDstChange's result, for
// the calendar's marks. `localOffsetAt(ms)` is local's offset then, which
// may itself be about to change.
export function changeDays(change, localOffsetAt) {
    if (!change) {
        return [];
    }
    const groups = change.then ? [change.first, change.then] : [change.first];
    return [].concat(...groups.map((g) => g.changes.map((c) => localDate(c.at, localOffsetAt(c.at)))));
}

// The DST line's lead: "Clocks change soon." within SOON of the first
// change, else "Next clock change:". "" when none is coming.
export function dstLead(change, now) {
    if (!change) {
        return "";
    }
    return change.first.at - now <= SOON ? "Clocks change soon." : "Next clock change:";
}
