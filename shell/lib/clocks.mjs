// The bar's clocks (SPEC.md §7.3), as pure functions the QML binds to.
//
// QML's JavaScript engine has no Intl, and CLDR's abbreviations are wrong for
// this anyway, so time zone facts come in from the caller (tide-tz):
// `offsetOf(zone, ms)` is the zone's UTC offset in minutes at that instant,
// and `abbrOf(zone, ms)` is tzdata's abbreviation.

export const DEFAULT_CLOCKS = Object.freeze([
    Object.freeze({ zone: "America/Los_Angeles", label: "SF" }),
    Object.freeze({ zone: "America/New_York", label: "NYC" }),
    Object.freeze({ zone: "Europe/London", label: "LON" }),
]);

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const MINUTE = 60 * 1000;
const DAY = 24 * 60 * MINUTE;

// Where JSON text first goes wrong, as "line N: what": JSON.parse's own
// messages differ between engines and often give no line (Node's "Unexpected
// end of JSON input"), so this walks the text itself. Only called once
// JSON.parse has failed.
export function jsonError(text) {
    let i = 0;
    const fail = (what) => {
        const line = text.slice(0, Math.min(i, text.length)).split("\n").length;
        throw new Error(`line ${line}: ${what}`);
    };
    const space = () => {
        while (i < text.length && " \t\n\r".includes(text[i])) {
            i++;
        }
    };
    const expect = (c) => {
        space();
        if (text[i] !== c) {
            fail(i >= text.length ? `expected ${c} before the end` : `expected ${c}, found ${text[i]}`);
        }
        i++;
    };
    const string = () => {
        expect('"');
        while (i < text.length && text[i] !== '"') {
            if (text[i] === "\n") {
                fail("unterminated string");
            }
            if (text.charCodeAt(i) < 0x20) {
                fail("control character in string");
            }
            if (text[i] === "\\") {
                const esc = /^\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})/.exec(text.slice(i));
                if (!esc) {
                    fail("bad escape in string");
                }
                i += esc[0].length;
                continue;
            }
            i++;
        }
        if (i >= text.length) {
            fail("unterminated string");
        }
        i++;
    };
    const value = () => {
        space();
        const c = text[i];
        if (c === "{") {
            i++;
            space();
            if (text[i] === "}") {
                i++;
                return;
            }
            for (;;) {
                space();
                string();
                expect(":");
                value();
                space();
                if (text[i] === ",") {
                    i++;
                    continue;
                }
                expect("}");
                return;
            }
        } else if (c === "[") {
            i++;
            space();
            if (text[i] === "]") {
                i++;
                return;
            }
            for (;;) {
                value();
                space();
                if (text[i] === ",") {
                    i++;
                    continue;
                }
                expect("]");
                return;
            }
        } else if (c === '"') {
            string();
        } else {
            const m = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(text.slice(i));
            if (!m) {
                fail(i >= text.length ? "expected a value before the end" : `unexpected ${c}`);
            }
            i += m[0].length;
        }
    };
    try {
        value();
        space();
        if (i < text.length) {
            fail(`unexpected ${text[i]} after the value`);
        }
    } catch (e) {
        if (e instanceof RangeError) {
            // The call stack ran out: nesting no config needs.
            return `line ${text.slice(0, Math.min(i, text.length)).split("\n").length}: nested too deeply`;
        }
        return e.message;
    }
    // The walker accepted what JSON.parse didn't; still name a line.
    return `line ${text.split("\n").length}: invalid JSON`;
}

// Parses one clocks.json: a list of {zone, label}. Returns {clocks} or
// {error}, never throws. `isZone(zone)`, when given, says whether the time
// zone reader knows a zone, so an unknown one is an error here rather than
// a broken clock later.
export function parseClocks(text, isZone) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (!Array.isArray(value)) {
        return { error: "expected a list of {zone, label}" };
    }
    const clocks = [];
    for (let i = 0; i < value.length; i++) {
        const c = value[i];
        if (c === null || typeof c !== "object" || Array.isArray(c)) {
            return { error: `entry ${i + 1}: expected {zone, label}` };
        }
        if (typeof c.zone !== "string" || c.zone === "") {
            return { error: `entry ${i + 1}: zone must be a time zone name` };
        }
        if (isZone && !isZone(c.zone)) {
            return { error: `entry ${i + 1}: unknown time zone "${c.zone}"` };
        }
        if (typeof c.label !== "string") {
            return { error: `entry ${i + 1}: label must be text, or "abbr"` };
        }
        // The bar is one line: a break would make the clock two lines tall.
        // Any line or paragraph separator counts, Unicode's included.
        if (/[\n\r\v\f\u0085\u2028\u2029]/.test(c.label)) {
            return { error: `entry ${i + 1}: label must be one line` };
        }
        clocks.push({ zone: c.zone, label: c.label });
    }
    return { clocks };
}

// The clocks to show, from clocks.json and clocks.local.json (SPEC.md
// §16.1). Each text is the file's contents, or null when it doesn't exist.
// The local list replaces the shared one whole. A file that fails to parse,
// or names a zone `isZone` doesn't know, keeps `lastGood` (the defaults the
// first time). Every file is checked, so `errors` names each one that's
// wrong, not just the first. `source` names the file the clocks came from,
// or is null for the defaults and `lastGood`.
export function loadClocks(sharedText, localText, lastGood = DEFAULT_CLOCKS, isZone = undefined) {
    const errors = [];
    let clocks = DEFAULT_CLOCKS;
    let source = null;
    for (const [name, text] of [["clocks.json", sharedText], ["clocks.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseClocks(text, isZone);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        clocks = parsed.clocks;
        source = name;
    }
    if (errors.length > 0) {
        return { clocks: lastGood, errors, source: null };
    }
    return { clocks, errors, source };
}

// A zone tide-tz couldn't load, as an error naming where it was set: the
// file and every entry that names it, numbered from 1 like a parse
// error's, so a zone listed twice is fixed in both places at once.
export function zoneError(clocks, source, zone, error) {
    const entries = [];
    clocks.forEach((c, i) => {
        if (c.zone === zone) {
            entries.push(i + 1);
        }
    });
    let where = "";
    if (entries.length === 1) {
        where = `entry ${entries[0]}: `;
    } else if (entries.length > 1) {
        where = `entries ${entries.slice(0, -1).join(", ")} and ${entries[entries.length - 1]}: `;
    }
    return source ? `${source}: ${where}${error}` : `${where}${error}`;
}

// The listed clocks minus any in the local zone, compared by zone ID; zones
// are canonical IDs (SPEC.md §7.3). A local zone with no ID ("") hides
// none. A zone that only shares the current offset stays, so no clock comes
// and goes at a DST change.
export function visibleClocks(clocks, localZone) {
    return clocks.filter((c) => c.zone !== localZone);
}

function pad(n) {
    return String(n).padStart(2, "0");
}

// The wall-clock fields of `ms` at a UTC offset in minutes.
function wallClock(ms, offset) {
    const d = new Date(ms + offset * MINUTE);
    return {
        days: Math.floor((ms + offset * MINUTE) / DAY),
        month: d.getUTCMonth(),
        date: d.getUTCDate(),
        hours: d.getUTCHours(),
        minutes: d.getUTCMinutes(),
    };
}

// The zone's date against the local date at `ms`, in days: usually -1, 0
// or +1, and -2 or +2 only between zones on opposite sides of the date line
// (UTC-12 against UTC+14).
export function dayOffset(ms, zoneOffset, localOffset) {
    return wallClock(ms, zoneOffset).days - wallClock(ms, localOffset).days;
}

// "HH:MM", 24-hour.
export function formatTime(ms, offset) {
    const w = wallClock(ms, offset);
    return `${pad(w.hours)}:${pad(w.minutes)}`;
}

// The local clock: "MMM d HH:MM".
export function formatLocal(ms, offset) {
    const w = wallClock(ms, offset);
    return `${MONTHS[w.month]} ${w.date} ${pad(w.hours)}:${pad(w.minutes)}`;
}

// What the bar shows, left to right: each visible clock as
// {text, dayOffset}, then local as {text, dayOffset: 0, local: true}. A
// label of "abbr" shows the zone's current tzdata abbreviation.
export function barClocks({ clocks, localZone, instant, offsetOf, abbrOf }) {
    const localOffset = offsetOf(localZone, instant);
    const shown = visibleClocks(clocks, localZone).map((c) => {
        const offset = offsetOf(c.zone, instant);
        const label = c.label === "abbr" ? abbrOf(c.zone, instant) : c.label;
        const time = formatTime(instant, offset);
        return {
            text: label === "" ? time : `${label} ${time}`,
            dayOffset: dayOffset(instant, offset, localOffset),
        };
    });
    shown.push({ text: formatLocal(instant, localOffset), dayOffset: 0, local: true });
    return shown;
}

// Scrolling over the clocks moves the time they show by this much a notch.
export const SCRUB_STEP = 15 * MINUTE;

// The instant the clocks show after `notches` of scrolling (positive is
// later) from `from`: the first notch lands on the next quarter hour that
// way, so 10:41 goes to 10:45 or 10:30, and each one after moves a step.
// Quarter hours line up in every zone, since all offsets are whole quarters.
export function scrubbed(from, notches) {
    const n = Math.trunc(notches);
    if (n === 0) {
        return from;
    }
    if (from % SCRUB_STEP === 0) {
        return from + n * SCRUB_STEP;
    }
    const edge = n > 0 ? Math.ceil(from / SCRUB_STEP) : Math.floor(from / SCRUB_STEP);
    return edge * SCRUB_STEP + (n - Math.sign(n)) * SCRUB_STEP;
}
