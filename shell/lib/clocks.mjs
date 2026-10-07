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

// The switches clocks.json can set beside the list (SPEC.md §16), as they
// are when no file sets them: 24-hour time, and a listed zone that is the
// local one hidden on the bar (§7.3).
export const DEFAULT_SWITCHES = Object.freeze({ hour24: true, dedupeLocal: true });

// The switches as the Clocks page lists them, in order.
export const SWITCH_ROWS = Object.freeze([
    Object.freeze({ key: "hour24", label: "24-hour time" }),
    Object.freeze({ key: "dedupeLocal", label: "Hide a zone that's the local one" }),
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

// Parses a list of {zone, label}. Returns {clocks} or {error}, never
// throws. `isZone(zone)`, when given, says whether the time zone reader
// knows a zone, so an unknown one is an error here rather than a broken
// clock later.
export function parseClocks(text, isZone) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    return clockList(value, isZone);
}

// One clocks.json: a list of {zone, label}, or an object with that list as
// `clocks` beside the switches (DEFAULT_SWITCHES), each of which it may
// leave out. Returns {settings}, holding what the file sets, or {error}.
export function parseClocksFile(text, isZone) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (Array.isArray(value)) {
        const list = clockList(value, isZone);
        return list.error ? list : { settings: { clocks: list.clocks } };
    }
    // One clock not in a list is the likelier mistake than an unknown setting.
    if (value === null || typeof value !== "object" || "zone" in value || "label" in value) {
        return { error: "expected a list of {zone, label}" };
    }
    const settings = {};
    for (const key of Object.keys(value)) {
        if (key === "clocks") {
            const list = clockList(value.clocks, isZone);
            if (list.error) {
                return { error: `clocks: ${list.error}` };
            }
            settings.clocks = list.clocks;
        } else if (Object.prototype.hasOwnProperty.call(DEFAULT_SWITCHES, key)) {
            if (typeof value[key] !== "boolean") {
                return { error: `${key} must be true or false` };
            }
            settings[key] = value[key];
        } else {
            return { error: `unknown setting "${key}"` };
        }
    }
    return { settings };
}

function clockList(value, isZone) {
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

// The clocks to show, and the switches, from clocks.json and
// clocks.local.json (SPEC.md §16.1). Each text is the file's contents, or
// null when it doesn't exist. The local list replaces the shared one
// whole, and a switch the local file sets wins. A file that fails to
// parse, or names a zone `isZone` doesn't know, keeps `lastGood` and
// `lastSwitches` (the defaults the first time). Every file is checked, so
// `errors` names each one that's wrong, not just the first. `source` names
// the file the clocks came from, or is null for the defaults and
// `lastGood`.
export function loadClocks(sharedText, localText, lastGood = DEFAULT_CLOCKS, isZone = undefined, lastSwitches = DEFAULT_SWITCHES) {
    const errors = [];
    let clocks = DEFAULT_CLOCKS;
    let source = null;
    const switches = Object.assign({}, DEFAULT_SWITCHES);
    for (const [name, text] of [["clocks.json", sharedText], ["clocks.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseClocksFile(text, isZone);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        if (parsed.settings.clocks) {
            clocks = parsed.settings.clocks;
            source = name;
        }
        for (const key of Object.keys(DEFAULT_SWITCHES)) {
            if (parsed.settings[key] !== undefined) {
                switches[key] = parsed.settings[key];
            }
        }
    }
    if (errors.length > 0) {
        return { clocks: lastGood, switches: lastSwitches, errors, source: null };
    }
    return { clocks, switches, errors, source };
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

// The tzdata areas a canonical zone ID starts with, as tide-tz's (SPEC.md
// §7.3). Link names such as US/Pacific and GB fall outside them.
const AREAS = ["Africa/", "America/", "Antarctica/", "Arctic/", "Asia/", "Atlantic/",
               "Australia/", "Europe/", "Indian/", "Pacific/"];

// Why `zone` isn't a canonical zone ID, or "": tide-tz's check by form,
// so the settings panel refuses at once what the bar would. Stricter on
// the characters, which tzdata's names keep to, so a space typed for an
// underscore is caught here rather than when tide-tz can't find it.
export function zoneFormError(zone) {
    const parts = zone.split("/");
    const canonical = zone === "UTC" || (AREAS.some(a => zone.startsWith(a)) &&
        // No empty part, and no . or .., as path.Clean would change.
        parts.every(p => /^[A-Za-z0-9_+-][A-Za-z0-9._+-]*$/.test(p)));
    if (canonical) {
        return "";
    }
    return `unknown time zone ${zone}; use a zone ID from timedatectl list-timezones, such as America/Los_Angeles`;
}

// What a clock added on the settings panel is labeled: its city, as the
// zone ID names it, with spaces for underscores ("Los Angeles").
export function cityLabel(zone) {
    const parts = zone.split("/");
    return parts[parts.length - 1].replace(/_/g, " ");
}

// The list the settings panel shows and changes (SPEC.md §16), as
// loadClocks takes it: clocks.local.json's when it exists, since it
// replaces the shared one whole, else clocks.json's, else the defaults.
// Each text is the file's, or null when it doesn't exist. Returns {clocks,
// source}, `source` being the file or null for the defaults, or {error}
// naming a file that doesn't parse: either one keeps the bar on its last
// good list, so the page has none to show or change until it's fixed.
export function editableClocks(sharedText, localText) {
    let found = { clocks: DEFAULT_CLOCKS.map(c => ({ zone: c.zone, label: c.label })), source: null };
    for (const [name, text] of [["clocks.json", sharedText], ["clocks.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseClocksFile(text);
        if (parsed.error) {
            return { error: `${name}: ${parsed.error}` };
        }
        if (parsed.settings.clocks) {
            found = { clocks: parsed.settings.clocks, source: name };
        }
    }
    return found;
}

// clocks.local.json's text after `change`, a function from the list to
// {clocks} or {error}, such as movedClock's, as {text, clocks}. The
// settings panel writes only the .local file (§16.1), so the first change
// copies the shared list or the defaults into it. A file that doesn't
// parse is an {error}, so a hand edit gone wrong is never overwritten.
export function editedClocks(sharedText, localText, change) {
    const base = editableClocks(sharedText, localText);
    if (base.error) {
        return { error: base.error };
    }
    const result = change(base.clocks);
    if (result.error) {
        return { error: result.error };
    }
    // A local file of switches keeps them; a list stays a list.
    const local = localText === null || localText === undefined ? null : JSON.parse(localText);
    const value = local !== null && !Array.isArray(local)
        ? Object.assign({}, parseClocksFile(localText).settings, { clocks: result.clocks })
        : result.clocks;
    return { text: JSON.stringify(value, null, 2) + "\n", clocks: result.clocks };
}

// clocks.local.json's text with switch `key` (hour24 or dedupeLocal) set to
// `value`, keeping its list if it has one. Each text is the file's, or null
// when it doesn't exist. A file that doesn't parse is an {error}, as
// editedClocks's: the bar keeps its last good settings while it doesn't.
export function withClockSwitch(sharedText, localText, key, value) {
    if (!Object.prototype.hasOwnProperty.call(DEFAULT_SWITCHES, key)) {
        return { error: `unknown setting "${key}"` };
    }
    if (typeof value !== "boolean") {
        return { error: `${key} must be true or false` };
    }
    let settings = {};
    for (const [name, text] of [["clocks.json", sharedText], ["clocks.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseClocksFile(text);
        if (parsed.error) {
            return { error: `${name}: ${parsed.error}` };
        }
        settings = name === "clocks.local.json" ? parsed.settings : settings;
    }
    return { text: JSON.stringify(Object.assign({}, settings, { [key]: value }), null, 2) + "\n" };
}

// The clock a change is for: entry `index` (from 0), if it still names
// `zone`, so a change can't land on another clock after a hand edit has
// moved them; with no index, the first that names it. -1 when none does.
function clockIndex(clocks, index, zone) {
    if (index === undefined || index === null) {
        return clocks.findIndex(c => c.zone === zone);
    }
    return index >= 0 && index < clocks.length && clocks[index].zone === zone ? index : -1;
}

function missing(index, zone) {
    return index === undefined || index === null
        ? { error: `no clock for ${zone}` }
        : { error: `entry ${index + 1} isn't ${zone}` };
}

// The list with the clock for `zone` moved `step` places (negative is
// left on the bar), stopping at either end.
export function movedClock(clocks, index, zone, step) {
    const from = clockIndex(clocks, index, zone);
    if (from < 0) {
        return missing(index, zone);
    }
    const to = Math.max(0, Math.min(clocks.length - 1, from + step));
    const next = clocks.slice();
    next.splice(to, 0, next.splice(from, 1)[0]);
    return { clocks: next };
}

// The list without the clock for `zone`.
export function withoutClock(clocks, index, zone) {
    const at = clockIndex(clocks, index, zone);
    if (at < 0) {
        return missing(index, zone);
    }
    return { clocks: clocks.filter((c, i) => i !== at) };
}

// The list with the clock for `zone` labeled `label`: any one line of
// text, "" for just the time, or "abbr" (SPEC.md §7.3).
export function relabeledClock(clocks, index, zone, label) {
    const at = clockIndex(clocks, index, zone);
    if (at < 0) {
        return missing(index, zone);
    }
    const bad = parseClocks(JSON.stringify([{ zone, label }]));
    if (bad.error) {
        return { error: bad.error.replace(/^entry 1: /, "") };
    }
    return { clocks: clocks.map((c, i) => i === at ? { zone: c.zone, label } : c) };
}

// The list with a clock for `zone` added at the end, just before local on
// the bar, labeled with its city. A zone that isn't a canonical ID, or is
// listed already, is an {error}.
export function withClock(clocks, zone) {
    const bad = zoneFormError(zone);
    if (bad !== "") {
        return { error: bad };
    }
    if (clocks.some(c => c.zone === zone)) {
        return { error: `${zone} is listed already` };
    }
    return { clocks: clocks.concat([{ zone, label: cityLabel(zone) }]) };
}

// What loaded settings need, given the list the bar shows (`good`, and
// `shown` once its zones' table is in with no file errors) and the list a
// lookup still running is for (`pending`, or null). Returns {lookUp: true}
// when tide-tz has to read `clocks`' zones, the switches waiting for it,
// since a list it refuses keeps the last good switches too. Otherwise the
// list is unchanged and only the switches can be new: `now` when the bar
// shows that list already, `pending` when the lookup running is for it,
// so it lands with them rather than restarting.
export function loadPlan(clocks, good, shown, pending) {
    const same = other => JSON.stringify(other) === JSON.stringify(clocks);
    if (pending !== null ? !same(pending) : !(shown && same(good))) {
        return { lookUp: true, now: false, pending: false };
    }
    return { lookUp: false, now: shown && same(good), pending: pending !== null };
}

// The listed clocks minus any in the local zone, compared by zone ID; zones
// are canonical IDs (SPEC.md §7.3). A local zone with no ID ("") hides
// none. A zone that only shares the current offset stays, so no clock comes
// and goes at a DST change. With `dedupeLocal` off, none is hidden.
export function visibleClocks(clocks, localZone, dedupeLocal = true) {
    return dedupeLocal ? clocks.filter((c) => c.zone !== localZone) : clocks;
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

// "HH:MM", 24-hour, or "h:MM AM" with `hour24` off.
export function formatTime(ms, offset, hour24 = true) {
    const w = wallClock(ms, offset);
    if (hour24) {
        return `${pad(w.hours)}:${pad(w.minutes)}`;
    }
    return `${w.hours % 12 || 12}:${pad(w.minutes)} ${w.hours < 12 ? "AM" : "PM"}`;
}

// The local clock's date: "MMM d".
function formatDate(ms, offset) {
    const w = wallClock(ms, offset);
    return `${MONTHS[w.month]} ${w.date}`;
}

// The local clock: "MMM d HH:MM", or its time as formatTime gives it.
export function formatLocal(ms, offset, hour24 = true) {
    return `${formatDate(ms, offset)} ${formatTime(ms, offset, hour24)}`;
}

// What the bar shows, left to right: each visible clock as {text, label,
// time, dayOffset}, then local, its date the label, with dayOffset 0 and
// local true. A label of "abbr" shows the zone's current tzdata
// abbreviation. `hour24` and `dedupeLocal` are the switches.
export function barClocks({ clocks, localZone, instant, offsetOf, abbrOf, hour24 = true, dedupeLocal = true }) {
    const localOffset = offsetOf(localZone, instant);
    const shown = visibleClocks(clocks, localZone, dedupeLocal).map((c) => {
        const offset = offsetOf(c.zone, instant);
        const label = c.label === "abbr" ? abbrOf(c.zone, instant) : c.label;
        const time = formatTime(instant, offset, hour24);
        return {
            text: label === "" ? time : `${label} ${time}`,
            label,
            time,
            dayOffset: dayOffset(instant, offset, localOffset),
        };
    });
    const date = formatDate(instant, localOffset);
    const time = formatTime(instant, localOffset, hour24);
    shown.push({ text: `${date} ${time}`, label: date, time, dayOffset: 0, local: true });
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
