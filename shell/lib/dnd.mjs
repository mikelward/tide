// The Notifications page's settings (SPEC.md §9, §16): Do not disturb on a
// schedule, and whether critical notifications break through it, from
// notifications.json and notifications.local.json, as pure functions the
// QML binds to.

import { jsonError } from "./clocks.mjs";
import { parseTime, steppedTimePast } from "./appearance.mjs";

// The days, as the files name them, in the page's order.
export const DAYS = Object.freeze(["mon", "tue", "wed", "thu", "fri", "sat", "sun"]);
// Their labels on the page.
export const DAY_LABELS = Object.freeze(["M", "T", "W", "T", "F", "S", "S"]);

export const DEFAULTS = Object.freeze({
    dndScheduled: false,
    dndFrom: "22:00",
    dndTo: "07:00",
    dndDays: DAYS,
    criticalsBreakThrough: true,
});

const KEYS = Object.keys(DEFAULTS);

function minutesOf(text) {
    const t = parseTime(text);
    return t.h * 60 + t.min;
}

// Why `value` can't be setting `key`, or "".
export function valueError(key, value) {
    switch (key) {
    case "dndScheduled":
    case "criticalsBreakThrough":
        return typeof value === "boolean" ? "" : `${key} must be true or false`;
    case "dndFrom":
    case "dndTo":
        return parseTime(value) === null ? `${key} must be a 24-hour time, such as 07:00` : "";
    case "dndDays": {
        if (!Array.isArray(value)) {
            return `dndDays must be a list of days, such as ["mon", "tue"]`;
        }
        const bad = value.find(d => !DAYS.includes(d));
        if (bad !== undefined) {
            return `dndDays: ${JSON.stringify(bad)} isn't a day; use ${DAYS.join(", ")}`;
        }
        if (new Set(value).size !== value.length) {
            return "dndDays names a day twice";
        }
        return "";
    }
    default:
        return `${JSON.stringify(key)} isn't a setting (${KEYS.join(", ")})`;
    }
}

// One file's settings: {settings} with what it sets, or {error}.
export function parseNotificationSettings(text) {
    let value;
    try {
        value = JSON.parse(text);
    } catch (e) {
        return { error: jsonError(text) };
    }
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        return { error: "expected an object of settings" };
    }
    for (const key of Object.keys(value)) {
        const bad = valueError(key, value[key]);
        if (bad !== "") {
            return { error: bad };
        }
    }
    return { settings: value };
}

// Why settings that each parse don't work together, or "": a schedule
// from and to the same time would be on all day or never. The times are
// compared as times, so 7:00 and 07:00 are the same.
export function checkSettings(s) {
    if (s.dndScheduled && minutesOf(s.dndFrom) === minutesOf(s.dndTo)) {
        return `dndFrom and dndTo are both ${s.dndTo}: Do not disturb can't start and end at the same time`;
    }
    return "";
}

// The settings in effect: the defaults, then the shared file's, then the
// local file's, key by key (§16.1). Each text is the file's, or null when
// it doesn't exist. A file that's wrong keeps `lastGood`, and `errors`
// names it: {settings, errors}.
export function loadNotificationSettings(sharedText, localText, lastGood = DEFAULTS) {
    const settings = Object.assign({}, DEFAULTS);
    const errors = [];
    for (const [name, text] of [["notifications.json", sharedText], ["notifications.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parseNotificationSettings(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        Object.assign(settings, parsed.settings);
    }
    const wrong = checkSettings(settings);
    if (wrong !== "") {
        errors.push(wrong);
    }
    return errors.length > 0 ? { settings: lastGood, errors } : { settings, errors };
}

// notifications.local.json's text with `key` set to `value`: {text}, or
// {error} for a bad value, a file that doesn't parse (left as it is), or
// a setting that wouldn't work with the rest.
export function withSetting(sharedText, localText, key, value) {
    const bad = valueError(key, value);
    if (bad !== "") {
        return { error: bad };
    }
    const files = {};
    for (const [name, text] of [["notifications.json", sharedText], ["notifications.local.json", localText]]) {
        if (text === null || text === undefined) {
            files[name] = {};
            continue;
        }
        const parsed = parseNotificationSettings(text);
        if (parsed.error) {
            return { error: `${name}: ${parsed.error}` };
        }
        files[name] = parsed.settings;
    }
    const local = Object.assign({}, files["notifications.local.json"], { [key]: value });
    const wrong = checkSettings(Object.assign({}, DEFAULTS, files["notifications.json"], local));
    if (wrong !== "") {
        return { error: wrong };
    }
    return { text: JSON.stringify(local, null, 2) + "\n" };
}

// notifications.local.json's text with `day` turned on or off in the days
// the files have now, not the ones last loaded, so a hand edit made a moment
// ago is built on (§16.1): {text} or {error}, as withSetting.
export function withDayToggled(sharedText, localText, day) {
    const loaded = loadNotificationSettings(sharedText, localText);
    if (loaded.errors.length > 0) {
        return { error: loaded.errors[0] };
    }
    return withSetting(sharedText, localText, "dndDays", toggledDay(loaded.settings.dndDays, day));
}

// A schedule time stepped `steps` quarter hours, going past `other`, the
// opposite time, as the Appearance page's times do. Both are compared as
// times, not text, so a hand-written 7:00 is the 07:00 a step lands on.
export function steppedDndTime(text, steps, other) {
    const t = parseTime(other);
    const normal = t === null ? other : `${String(t.h).padStart(2, "0")}:${String(t.min).padStart(2, "0")}`;
    return steppedTimePast(text, steps, normal);
}

// The days list with `day` turned on or off, in DAYS' order.
export function toggledDay(days, day) {
    const on = days.includes(day) ? days.filter(d => d !== day) : days.concat([day]);
    return DAYS.filter(d => on.includes(d));
}

// The window the schedule holds Do not disturb on in at `date` (local
// time), as when it started, in ms since the epoch, or null outside one. A
// window starts at dndFrom on a listed day and ends at dndTo, the next day
// when dndTo is earlier, so Friday 22:00 to 07:00 runs into Saturday. Each
// window has its own start, so two in a row are told apart.
export function windowStart(s, date) {
    const from = minutesOf(s.dndFrom);
    const to = minutesOf(s.dndTo);
    if (!s.dndScheduled || from === to) {
        return null;
    }
    const now = date.getHours() * 60 + date.getMinutes();
    // getDay(): 0 is Sunday.
    const today = DAYS[(date.getDay() + 6) % 7];
    const yesterday = DAYS[(date.getDay() + 5) % 7];
    const startOn = (dayOffset) => new Date(date.getFullYear(), date.getMonth(), date.getDate() + dayOffset,
        Math.floor(from / 60), from % 60).getTime();
    if (from < to) {
        return s.dndDays.includes(today) && now >= from && now < to ? startOn(0) : null;
    }
    if (s.dndDays.includes(today) && now >= from) {
        return startOn(0);
    }
    return s.dndDays.includes(yesterday) && now < to ? startOn(-1) : null;
}

// Whether the schedule holds Do not disturb on at `date`.
export function inWindow(s, date) {
    return windowStart(s, date) !== null;
}

// What the schedule does as a window starts or ends: {state, set}, where
// `set` is true or false to turn your own Do not disturb on or off, or
// null to leave it. `state` is {window, scheduledOn}: the window the last
// check was in (windowStart: its start, null outside one, undefined before
// the first check), and whether the schedule turned it on, which turning it
// on or off yourself clears (ownChanged).
// - A window starting turns it on, so a shell started in one has it on. So
//   does a new window following another with no check outside between (a
//   suspend across the gap): what you set in the last one expires with it.
// - A window ending turns it off only if the schedule turned it on, so one
//   you turned on yourself stays.
export const SCHEDULE_IDLE = Object.freeze({ window: undefined, scheduledOn: false });

export function scheduleStep(state, window, ownOn) {
    if (window === state.window) {
        return { state, set: null };
    }
    if (window !== null) {
        return { state: { window, scheduledOn: !ownOn || state.scheduledOn }, set: ownOn ? null : true };
    }
    if (state.window === undefined) {
        return { state: { window, scheduledOn: false }, set: null };
    }
    return { state: { window, scheduledOn: false }, set: state.scheduledOn && ownOn ? false : null };
}

// After you turn your own Do not disturb on or off: the schedule no longer
// owns it, so its window ending leaves it as you set it. Setting it to what
// it already is, as presenter mode and keep awake do whenever they change
// (PresenterData.apply), changes nothing, so it leaves the schedule's.
export function ownChanged(state, was, now) {
    return was === now ? state : Object.assign({}, state, { scheduledOn: false });
}

// What the page says of the schedule, such as "22:00 to 07:00, every day".
export function scheduleSummary(s) {
    if (!s.dndScheduled) {
        return "Off";
    }
    const days = s.dndDays.length === 7 ? "every day"
        : s.dndDays.length === 0 ? "no days"
        : DAYS.filter(d => s.dndDays.includes(d)).join(", ");
    return `${s.dndFrom} to ${s.dndTo}, ${days}`;
}
