// The picker on Super+V (SPEC.md §8.4): its three tabs, the clipboard
// history as `tide clipboard list` prints it (as cliphist's list was), the
// character list in shell/chars/chars.tsv, and the snippets and Bitwarden
// logins `tide fill list` prints, on Super+Shift+V.

import { match } from "./fuzzy.mjs";

export const TABS = Object.freeze(["clipboard", "characters", "fill"]);

export const TAB_NAMES = Object.freeze({
    clipboard: "Clipboard",
    characters: "Characters",
    fill: "Fill",
});

export const PLACEHOLDERS = Object.freeze({
    clipboard: "Search what you've copied",
    characters: "Search by name: arrow, e acute, shrug",
    fill: "Search snippets and logins: address, github",
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

// The preview of an image, as cliphist showed one: "[[ binary data 240 KiB
// png 1280x720 ]]", the size in pixels only for a PNG.
const IMAGE = /^\[\[ binary data (.+?) ([A-Za-z0-9.+-]+)(?: (\d+)x(\d+))? \]\]$/;
// A preview that is one URL and nothing else.
const LINK = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/\S+$/;

// The history, newest first, from `tide clipboard list`: one "ID<TAB>preview"
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
            const pixels = image[3] ? ` · ${image[3]}×${image[4]}` : "";
            entries.push({ id, preview, kind: "image", name: "Image", sub: `${image[2].toUpperCase()}${pixels} · ${image[1]}` });
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

// The Fill tab's rows, from `tide fill list`: KIND, KEY, FIELD, LABEL and
// DETAIL per line, tab-separated (bin/tide-fill). Returns {entries: [{kind,
// key, field, name, sub}], errors}; a line that isn't that shape, or of a
// kind it doesn't know, is left out and named.
export function parseFill(text) {
    const entries = [];
    const errors = [];
    const lines = String(text ?? "").split("\n");
    for (let i = 0; i < lines.length; i++) {
        if (lines[i] === "") {
            continue;
        }
        const f = lines[i].split("\t");
        const known = f.length === 5 && ["snippet", "login", "unlock"].includes(f[0]) && f[1] !== "" && f[3] !== "";
        if (!known) {
            errors.push(`line ${i + 1}: not "KIND<tab>KEY<tab>FIELD<tab>LABEL<tab>DETAIL"`);
            continue;
        }
        entries.push({ kind: f[0], key: f[1], field: f[2], name: f[3], sub: f[4] });
    }
    return { entries, errors };
}

// The Fill tab's rows: in `tide fill list`'s order (snippets, then logins
// by name), or, with a query, the fuzzy scorer over each label and its
// detail (the user and folder), best first. The Unlock row stays first
// whatever's typed, since the logins wait behind it.
export function fillRows(entries, query, options = {}) {
    const score = options.match ?? match;
    const q = String(query ?? "").trim();
    const rows = [];
    entries.forEach((entry, order) => {
        if (entry.kind === "unlock") {
            rows.push({ item: entry, positions: [], score: Infinity, order });
            return;
        }
        const m = score(q, `${entry.name} ${entry.sub}`.slice(0, FUZZY_CHARS));
        if (m) {
            rows.push({ item: entry, positions: m.positions.filter((p) => p < [...entry.name].length), score: m.score, order });
        }
    });
    if (q !== "") {
        rows.sort((a, b) => (b.score - a.score) || (a.order - b.order));
    }
    return rows;
}

// What Enter on a Fill row runs: `tide fill type` for a snippet or a
// login's field, or `tide fill unlock`.
export function fillCommand(item) {
    if (item.kind === "unlock") {
        return ["tide", "fill", "unlock"];
    }
    if (item.kind === "snippet") {
        return ["tide", "fill", "type", "snippet", item.key];
    }
    return ["tide", "fill", "type", "login", item.key, item.field];
}

// Where a finished listing's rows go: "clipboard" or "fill", the tab
// `what` lists, or null when a newer listing of that tab has started since
// (`tokens` holds each tab's latest). One tab's listing never fills the
// other's, whatever the counts.
export function listingTarget(what, token, tokens) {
    if (what !== "clipboard" && what !== "fill") {
        return null;
    }
    return token === tokens[what] ? what : null;
}

// A Fill row's icon, by Adwaita's names.
export function fillIcon(item) {
    if (item.kind === "unlock") {
        return "changes-allow-symbolic";
    }
    if (item.kind === "snippet") {
        return "edit-paste-symbolic";
    }
    return { username: "avatar-default-symbolic", totp: "appointment-soon-symbolic" }[item.field] ?? "dialog-password-symbolic";
}

// The Fill tab's state after `tide fill list` finishes, as listedHistory.
export function listedFill(failed, out, errors) {
    if (failed) {
        const first = String(errors ?? "").trim().split("\n")[0].replace(/^tide fill: /, "");
        return { entries: [], error: first || "Couldn't list the snippets and logins", warnings: [] };
    }
    const parsed = parseFill(out);
    // A snippets file it couldn't read is said on stderr, and the rest
    // still lists: that's a warning, for the log.
    const said = String(errors ?? "").trim().split("\n").filter((l) => l !== "");
    return { entries: parsed.entries, error: "", warnings: parsed.errors.concat(said) };
}

// What the tab says when it has no rows.
export function emptyText(tab, query, state = {}) {
    checkTab(tab);
    if ((tab === "clipboard" || tab === "fill") && state.error) {
        return state.error;
    }
    if (String(query ?? "").trim() !== "") {
        return "Nothing matches";
    }
    if (tab === "clipboard") {
        return state.loading ? "" : "Nothing copied yet";
    }
    if (tab === "fill") {
        return state.loading ? "" : "No snippets or logins: add snippets to ~/.config/tide/snippets.json, or install rbw for Bitwarden";
    }
    return state.error || "";
}

// The Clipboard tab's state after `tide clipboard list` finishes:
// {entries, error, warnings}. A failed run shows its first line of stderr
// in the tab, without the command's own prefix: "secret-tool isn't
// installed, so there's no clipboard history; install the libsecret-tools
// package". Lines it couldn't read are `warnings`, for the log.
export function listedHistory(failed, out, errors) {
    if (failed) {
        const first = String(errors ?? "").trim().split("\n")[0].replace(/^tide clipboard: /, "");
        return { entries: [], error: first || "Couldn't read the clipboard history", warnings: [] };
    }
    const parsed = parseHistory(out);
    return { entries: parsed.entries, error: "", warnings: parsed.errors };
}

// Terminals, by window class, which paste on Ctrl+Shift+V: their Ctrl+V
// goes to the program running in them. Not kitty: conf's kitty.conf maps
// Ctrl+V to paste_from_clipboard and sends Ctrl+Shift+V as a literal ^V.
export const TERMINALS = Object.freeze([
    "foot",
    "footclient",
    "Alacritty",
    "org.wezfurlong.wezterm",
    "com.mitchellh.ghostty",
    "org.kde.konsole",
    "org.gnome.Terminal",
    "org.gnome.Ptyxis",
    "org.gnome.Console",
]);

// Enter's paste: the shortcut that pastes into a window of class `cls`,
// as {mods, key} in Hyprland's spelling.
export function pasteShortcut(cls) {
    const c = String(cls ?? "").toLowerCase();
    const terminal = TERMINALS.some(t => t.toLowerCase() === c);
    return { mods: terminal ? "CTRL SHIFT" : "CTRL", key: "V" };
}

// The window Enter pastes into, {address, class}, from the focused window
// when the picker opens (floating.mjs's windowOf of FocusData.active,
// which is null on an empty workspace), or null for none.
export function pasteTarget(window) {
    if (!window || !window.address) {
        return null;
    }
    return { address: window.address, class: window.class ?? "" };
}
