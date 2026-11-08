// Settings search (SPEC.md §16): the field over the settings sidebar keeps
// the pages a query finds. Pure, and copied unchanged into tide for macOS's
// settings window and tide for Chrome's settings page, so a query finds the
// same pages on every desktop.

// The words of `text`, in lowercase: its runs of letters and digits, so
// "Wi-Fi" is "wi" and "fi". Anything past ASCII counts as a letter.
export function words(text) {
    return String(text ?? "").toLowerCase().split(/[^a-z0-9\u0080-￿]+/).filter(w => w !== "");
}

// What a query can find in `terms`, a page's name and keywords: each term's
// words, and each term whole with its spaces and marks taken out, so "wifi"
// finds "Wi-Fi" and "ctrltab" finds "Ctrl+Tab".
export function searchWords(terms) {
    const out = [];
    for (const term of terms) {
        const parts = words(term);
        out.push(...parts);
        if (parts.length > 1) {
            out.push(parts.join(""));
        }
    }
    return out;
}

// Whether every word of `query` starts a word of `terms`, in any order, so
// "tap click" finds "tap to click" and "dis" finds "Displays". A query of
// no words finds everything.
export function matches(query, terms) {
    const wanted = words(query);
    if (wanted.length === 0) {
        return true;
    }
    const have = searchWords(terms);
    return wanted.every(w => have.some(h => h.startsWith(w)));
}

// The sidebar's rows that `query` keeps: the pages it finds, each under its
// group's heading, and no heading left with no page under it. A row is a
// heading when `isHeading(row)` says so; a page's terms are `termsOf(row)`.
export function searchedRows(rows, query, isHeading, termsOf) {
    const out = [];
    let heading = null;
    for (const row of rows) {
        if (isHeading(row)) {
            heading = row;
        } else if (matches(query, termsOf(row))) {
            if (heading !== null) {
                out.push(heading);
                heading = null;
            }
            out.push(row);
        }
    }
    return out;
}
