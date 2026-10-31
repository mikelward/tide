// The picker on Super+C (SPEC.md §8.4): its two tabs, the clipboard
// history as `tide clipboard list` prints it (cliphist's list), and the
// character list in shell/chars/chars.tsv.

import { match } from "./fuzzy.mjs";

export const TABS = Object.freeze(["clipboard", "characters"]);

export const TAB_NAMES = Object.freeze({
    clipboard: "Clipboard",
    characters: "Characters",
});

export const PLACEHOLDERS = Object.freeze({
    clipboard: "Search what you've copied",
    characters: "Search by name: arrow, e acute, shrug",
});

// The Characters tab lists at most this many rows, so a one-letter query
// doesn't build thousands of delegates.
export const CHARACTER_LIMIT = 200;

function checkTab(tab) {
    if (!TABS.includes(tab)) {
        throw new Error(`not a picker tab: ${tab}`);
    }
}

// {visible, tab} after a key asks for `wanted`: it opens on that tab, the
// same tab's key again closes it, and the other tab's key moves there.
export function toggled(visible, tab, wanted) {
    checkTab(wanted);
    if (visible && tab === wanted) {
        return { visible: false, tab };
    }
    return { visible: true, tab: wanted };
}

// Tab and Shift+Tab: the next or previous tab, wrapping.
export function movedTab(tab, step) {
    checkTab(tab);
    const i = TABS.indexOf(tab);
    return TABS[(i + step + TABS.length) % TABS.length];
}

// cliphist's preview of an image: "[[ binary data 240 KiB png 1280x720 ]]".
const IMAGE = /^\[\[ binary data (.+) ([A-Za-z0-9]+) (\d+)x(\d+) \]\]$/;
// A preview that is one URL and nothing else.
const LINK = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/\S+$/;

// The history, newest first, from `cliphist list`: one "ID<TAB>preview"
// per line. Returns {entries: [{id, preview, kind, name, sub}], errors}:
// a line that isn't that shape is left out and named in `errors`, rather
// than shown as something Enter can't copy.
export function parseHistory(text) {
    const entries = [];
    const errors = [];
    const lines = String(text ?? "").split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line === "") {
            continue;
        }
        const tab = line.indexOf("\t");
        const id = tab > 0 ? line.slice(0, tab) : "";
        if (!/^[0-9]+$/.test(id)) {
            errors.push(`line ${i + 1}: not "ID<tab>preview": ${JSON.stringify(line.slice(0, 40))}`);
            continue;
        }
        const preview = line.slice(tab + 1);
        const image = IMAGE.exec(preview);
        if (image) {
            entries.push({ id, preview, kind: "image", name: "Image", sub: `${image[2].toUpperCase()} · ${image[3]}×${image[4]} · ${image[1]}` });
        } else if (LINK.test(preview)) {
            entries.push({ id, preview, kind: "link", name: preview, sub: "Link" });
        } else {
            entries.push({ id, preview, kind: "text", name: preview, sub: "Text" });
        }
    }
    return { entries, errors };
}

// The fuzzy scorer reads at most this many characters of a preview: it
// does work quadratic in the text's length, and the rows are built on the
// UI thread as you type.
export const FUZZY_CHARS = 100;

// Where `q` occurs in `text`, ignoring case, as code-point positions, or
// null. Linear in the text, so it can read a whole preview.
function substring(q, text) {
    const lower = text.toLowerCase();
    const at = lower.indexOf(q.toLowerCase());
    if (at < 0) {
        return null;
    }
    // Code points before the match, then one per code point matched.
    const start = [...text.slice(0, at)].length;
    const length = [...text.slice(at, at + q.length)].length;
    return Array.from({ length }, (_, i) => start + i);
}

// The Clipboard tab's rows: newest first, or, with a query, the
// launcher's fuzzy scorer over each preview's first FUZZY_CHARS
// characters, best first, then the entries that hold the query as plain
// text further on, each group newest first among equals. An image is
// matched by its description. `options.match` stands in for the fuzzy
// scorer in tests.
export function historyRows(entries, query, options = {}) {
    const score = options.match ?? match;
    const q = String(query ?? "").trim();
    const rows = [];
    entries.forEach((entry, order) => {
        const text = entry.kind === "image" ? `${entry.name} ${entry.sub}` : entry.name;
        const head = [...text].slice(0, FUZZY_CHARS).join("");
        const m = score(q, head);
        if (m) {
            rows.push({ item: entry, positions: entry.kind === "image" ? [] : m.positions, score: m.score, order });
            return;
        }
        const found = q === "" ? null : substring(q, text);
        if (found) {
            // Below every fuzzy match, whose scores are positive.
            rows.push({ item: entry, positions: entry.kind === "image" ? [] : found, score: -1, order });
        }
    });
    if (q !== "") {
        rows.sort((a, b) => (b.score - a.score) || (a.order - b.order));
    }
    return rows;
}

// A name's words, lowercase: what a typed word has to start.
export function words(text) {
    return String(text ?? "").toLowerCase().split(/[^a-z0-9]+/).filter((w) => w !== "");
}

// The character list, from chars.tsv: CHARACTER, NAME and GROUP per line,
// tab-separated, after `#` comments. A comment has no tab, so a row whose
// character starts with `#`, the keycap #️⃣, is still a row. Returns {chars: [{char, name, group,
// words, order}], errors}; a malformed line is left out and named.
export function parseChars(text) {
    const chars = [];
    const errors = [];
    const lines = String(text ?? "").split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line === "" || (line[0] === "#" && line.indexOf("\t") < 0)) {
            continue;
        }
        const f = line.split("\t");
        if (f.length !== 3 || f[0] === "" || f[1] === "") {
            errors.push(`line ${i + 1}: not "character<tab>name<tab>group"`);
            continue;
        }
        chars.push({ char: f[0], name: f[1], group: f[2], words: words(f[1]), order: chars.length });
    }
    return { chars, errors };
}

// Where each word of `name` starts, in order.
function wordStarts(name) {
    const starts = [];
    const re = /[a-z0-9]+/gi;
    for (let m = re.exec(name); m !== null; m = re.exec(name)) {
        starts.push(m.index);
    }
    return starts;
}

// How `c` matches the query's words: every one must start a word of the
// name, in any order. {exact, positions} or null. `exact` counts the
// query words that are whole words of the name; `positions` are the
// matched letters, for highlighting.
function matchChar(c, queryWords) {
    let exact = 0;
    const positions = [];
    const starts = wordStarts(c.name);
    for (const q of queryWords) {
        let best = -1;
        for (let i = 0; i < c.words.length; i++) {
            if (c.words[i] === q) {
                best = i;
                break;
            }
            if (best < 0 && c.words[i].startsWith(q)) {
                best = i;
            }
        }
        if (best < 0) {
            return null;
        }
        if (c.words[best] === q) {
            exact += 1;
        }
        for (let k = 0; k < q.length; k++) {
            positions.push(starts[best] + k);
        }
    }
    return { exact, positions: positions.sort((a, b) => a - b) };
}

// The Characters tab's rows (§8.4): whole-word matches first, then the
// list's order, at most `limit` of them. With no
// query, the list from the top.
export function characterRows(chars, query, limit = CHARACTER_LIMIT) {
    const q = words(query);
    if (q.length === 0) {
        return chars.slice(0, limit).map((c) => ({ item: c, positions: [] }));
    }
    const found = [];
    for (const c of chars) {
        const m = matchChar(c, q);
        if (m) {
            found.push({ item: c, positions: m.positions, exact: m.exact });
        }
    }
    found.sort((a, b) => (b.exact - a.exact) || (a.item.order - b.item.order));
    return found.slice(0, limit).map((r) => ({ item: r.item, positions: r.positions }));
}

// "U+00E9" for a character that is one code point, ignoring the emoji
// variation selector; "" for a sequence, whose code points say little.
export function codePoint(char) {
    const cps = [];
    for (let i = 0; i < char.length; i++) {
        const cp = char.codePointAt(i);
        if (cp > 0xffff) {
            i++;
        }
        if (cp !== 0xfe0f) {
            cps.push(cp);
        }
    }
    if (cps.length !== 1) {
        return "";
    }
    const hex = cps[0].toString(16).toUpperCase();
    return "U+" + "0000".slice(hex.length < 4 ? hex.length : 4) + hex;
}

// A row's second line on the Characters tab: its group, and its code
// point when it has one.
export function characterSub(c) {
    const cp = codePoint(c.char);
    return cp ? `${c.group} · ${cp}` : c.group;
}

// What the tab says when it has no rows.
export function emptyText(tab, query, state = {}) {
    checkTab(tab);
    if (tab === "clipboard" && state.error) {
        return state.error;
    }
    if (String(query ?? "").trim() !== "") {
        return "Nothing matches";
    }
    if (tab === "clipboard") {
        return state.loading ? "" : "Nothing copied yet";
    }
    return state.error || "";
}

// The Clipboard tab's state after `tide clipboard list` finishes:
// {entries, error, warnings}. A failed run shows its first line of stderr
// in the tab, without the command's own prefix: "cliphist isn't
// installed, so there's no clipboard history; install the cliphist
// package". Lines it couldn't read are `warnings`, for the log.
export function listedHistory(failed, out, errors) {
    if (failed) {
        const first = String(errors ?? "").trim().split("\n")[0].replace(/^tide clipboard: /, "");
        return { entries: [], error: first || "Couldn't read the clipboard history", warnings: [] };
    }
    const parsed = parseHistory(out);
    return { entries: parsed.entries, error: "", warnings: parsed.errors };
}
