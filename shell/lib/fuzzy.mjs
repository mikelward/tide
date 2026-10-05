// The launcher's fuzzy matcher (SPEC.md §8): a query matches a text when
// its letters appear in it in order, case-insensitively, and the score
// rewards what fzf rewards. A run of consecutive letters and a letter that
// starts a word beat letters scattered through the middle of words, so
// "scr" puts "Screenshot" ahead of "Secure Shell".
//
// The scorer tries every alignment rather than taking the first one it
// finds: "ss" in "Secure Shell" should match both word starts, not the "s"
// and "c"-adjacent "s"s a greedy scan would take. Of the alignments with
// the best score, it takes the earliest unbroken run if there is one,
// then the one that starts earliest: the keys, in the order, launcher.mjs
// ranks equal scores by, so the match it judges is the one it would rank
// highest.

const MATCH = 16;
// For a letter right after the previous match.
const CONSECUTIVE = 12;
// For a letter that starts a word: the text's start, after a non-letter,
// or an uppercase letter after a lowercase one ("NetworkManager").
const WORD_START = 10;
// Extra for matching the text's first letter.
const FIRST = 8;
// Per letter skipped between two matches, up to MAX_GAP letters.
const GAP = 1;
const MAX_GAP = 8;

// Qt's JavaScript engine has no Unicode property escapes: one matches
// nothing there, without an error. So the classes are spelled out.
// The combining marks NFD splits off Latin, Greek and Cyrillic letters.
const MARKS = /[\u0300-\u036f\u0483-\u0489\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]/g;
// What isn't a letter or digit: spaces, controls, combining marks, and the
// punctuation and symbols of ASCII, Latin-1, the symbol blocks, CJK and
// fullwidth forms, and of the planes of emoji and other symbols (by their
// high surrogate). The rest counts as a letter, which takes in the scripts
// without case (日本, עברית).
const NOT_ALNUM = /[\s\x00-\x2f\x3a-\x40\x5b-\x60\x7b-\xa9\xab-\xb1\xb4\xb6-\xb8\xbb\xbf\xd7\xf7\u0300-\u036f\u0483-\u0489\u1ab0-\u1aff\u1dc0-\u1dff\u2000-\u206f\u20a0-\u20ff\u2100-\u2101\u2103-\u2106\u2108-\u2109\u2114\u2116-\u2118\u211e-\u2123\u2125\u2127\u2129\u212e\u213a-\u213b\u2140-\u2144\u214a-\u214d\u214f\u218a-\u218b\u2190-\u245f\u2500-\u2775\u2794-\u2bff\u2e00-\u2fff\u3000-\u3004\u3008-\u3020\u3030\u303d-\u303f\u3200-\u33ff\ufe00-\ufe2f\uff01-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65\ud833\ud834\ud836\ud83c-\ud83e\udb40]/;

// One code point folded for comparison, the same on both sides: lowercased,
// then without its accents, so "i" finds "İnternet" (whose lowercase is
// two code points) and "e" finds "é". Each text code point folds alone, so
// a match's positions still index the original text.
function fold(c) {
    return c.toLowerCase().normalize("NFD").replace(MARKS, "");
}

function isAlnum(c) {
    return !NOT_ALNUM.test(c);
}

function isWordStart(text, i) {
    if (i === 0) {
        return true;
    }
    const prev = text[i - 1];
    const here = text[i];
    if (!isAlnum(prev)) {
        return isAlnum(here);
    }
    return prev === prev.toLowerCase() && prev !== prev.toUpperCase() && here !== here.toLowerCase();
}

// {score, positions} for the best way `query` matches `text`, with the
// matched indexes in `text` in order, or null when it doesn't match. An
// empty query matches everything with a score of 0.
export function match(query, text) {
    const q = [...query].map(fold).filter(c => c !== "" && !/\s/.test(c));
    const chars = [...text];
    const t = chars.map(fold);
    if (q.length === 0) {
        return { score: 0, positions: [] };
    }
    if (q.length > t.length) {
        return null;
    }
    const bonus = chars.map((_, i) => (isWordStart(chars, i) ? WORD_START : 0) + (i === 0 ? FIRST : 0));
    // best[i][j]: the best score with q[i] matched at t[j], or -Infinity,
    // and start[i][j]: the earliest first position of an alignment with
    // that score. Start passes unchanged along an alignment, so keeping the
    // earliest at each step keeps the earliest overall.
    const best = q.map(() => new Array(t.length).fill(-Infinity));
    const start = q.map(() => new Array(t.length).fill(0));
    const from = q.map(() => new Array(t.length).fill(-1));
    for (let j = 0; j < t.length; j++) {
        if (t[j] === q[0]) {
            best[0][j] = MATCH + bonus[j];
            start[0][j] = j;
        }
    }
    for (let i = 1; i < q.length; i++) {
        for (let j = i; j < t.length; j++) {
            if (t[j] !== q[i]) {
                continue;
            }
            for (let k = i - 1; k < j; k++) {
                if (best[i - 1][k] === -Infinity) {
                    continue;
                }
                const gap = j - k - 1;
                const step = gap === 0 ? CONSECUTIVE : -GAP * Math.min(gap, MAX_GAP);
                const score = best[i - 1][k] + MATCH + bonus[j] + step;
                if (score > best[i][j] || (score === best[i][j] && start[i - 1][k] < start[i][j])) {
                    best[i][j] = score;
                    start[i][j] = start[i - 1][k];
                    from[i][j] = k;
                }
            }
        }
    }
    const last = q.length - 1;
    let end = -1;
    for (let j = 0; j < t.length; j++) {
        if (best[last][j] !== -Infinity && (end < 0 || best[last][j] > best[last][end] || (best[last][j] === best[last][end] && start[last][j] < start[last][end]))) {
            end = j;
        }
    }
    if (end < 0) {
        return null;
    }
    // An unbroken run beats a broken alignment of the same score. Whether
    // an alignment stays unbroken isn't known until it ends, so the program
    // above can't keep that preference step by step; a run is just a window
    // of the text, so check each one directly instead.
    for (let j = 0; j + q.length <= t.length; j++) {
        let score = 0;
        for (let i = 0; i < q.length && score !== -Infinity; i++) {
            score = t[j + i] === q[i] ? score + MATCH + bonus[j + i] + (i > 0 ? CONSECUTIVE : 0) : -Infinity;
        }
        if (score === best[last][end]) {
            return { score, positions: q.map((_, i) => j + i) };
        }
    }
    const positions = new Array(q.length);
    for (let i = last, j = end; i >= 0; j = from[i][j], i--) {
        positions[i] = j;
    }
    return { score: best[last][end], positions };
}
