// The Clipboard page's settings (SPEC.md §8.4, §16): whether the history
// keeps copies, and how many, from clipboard.json and clipboard.local.json,
// as pure functions the QML binds to. The shell writes them to
// ~/.config/hypr/tide-clipboard.conf, which `tide clipboard store` reads at
// each copy.

import { jsonError } from "./clocks.mjs";

// cliphist's own default is 750; tide keeps 200 (§8.4).
export const DEFAULTS = Object.freeze({ history: true, maxItems: 200 });

// The marks − and + step the cap through.
export const MAX_MARKS = Object.freeze([25, 50, 100, 200, 500, 750, 1000]);
export const MAX_ITEMS_LIMIT = 10000;

const KEYS = Object.keys(DEFAULTS);

// Why `value` can't be setting `key`, or "".
export function valueError(key, value) {
    if (key === "history") {
        return typeof value === "boolean" ? "" : "history must be true or false";
    }
    if (key === "maxItems") {
        return Number.isInteger(value) && value >= 1 && value <= MAX_ITEMS_LIMIT
            ? ""
            : `maxItems must be a whole number from 1 to ${MAX_ITEMS_LIMIT}`;
    }
    return `${JSON.stringify(key)} isn't a setting (${KEYS.join(", ")})`;
}

function parse(text) {
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

// The settings in effect, the defaults then each file's, key by key
// (§16.1). A file that's wrong keeps `lastGood`, and `errors` names it.
export function loadClipboardSettings(sharedText, localText, lastGood = DEFAULTS) {
    const settings = Object.assign({}, DEFAULTS);
    const errors = [];
    for (const [name, text] of [["clipboard.json", sharedText], ["clipboard.local.json", localText]]) {
        if (text === null || text === undefined) {
            continue;
        }
        const parsed = parse(text);
        if (parsed.error) {
            errors.push(`${name}: ${parsed.error}`);
            continue;
        }
        Object.assign(settings, parsed.settings);
    }
    return errors.length > 0 ? { settings: lastGood, errors } : { settings, errors };
}

// clipboard.local.json's text with `key` set to `value`: {text}, or {error}
// for a bad value or a local file that doesn't parse, left as it is.
export function withSetting(localText, key, value) {
    const bad = valueError(key, value);
    if (bad !== "") {
        return { error: bad };
    }
    let local = {};
    if (localText !== null && localText !== undefined) {
        const parsed = parse(localText);
        if (parsed.error) {
            return { error: `clipboard.local.json: ${parsed.error}` };
        }
        local = parsed.settings;
    }
    return { text: JSON.stringify(Object.assign({}, local, { [key]: value }), null, 2) + "\n" };
}

// The cap `steps` marks from `value`. Off a mark, the first step goes to
// the nearest one that way; past either end, a press back across stays.
export function steppedMax(value, steps) {
    if (steps === 0) {
        return value;
    }
    if (steps > 0) {
        const above = MAX_MARKS.filter(m => m > value);
        return above.length === 0 ? value : above[Math.min(above.length, steps) - 1];
    }
    const below = MAX_MARKS.filter(m => m < value);
    return below.length === 0 ? value : below[Math.max(0, below.length + steps)];
}

// What `tide clipboard store` reads (bin/tide-clipboard).
export function storeConf(s) {
    return `# Written by tide's settings panel (SPEC.md §16); edit clipboard.local.json instead.\nhistory=${s.history ? "on" : "off"}\nmax_items=${s.maxItems}\n`;
}

// The page's line about the history.
export function historySummary(s) {
    return s.history ? `Keeps the newest ${s.maxItems} copies` : "Off: new copies aren't kept";
}
