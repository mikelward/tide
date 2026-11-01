#!/usr/bin/env node
// Builds shell/lib/unicode.mjs, the Unicode classes floating rules' title
// patterns mean by \w and \d (SPEC.md §16, Floating), from Unicode 16.0's
// UnicodeData.txt:
//
//   node shell/unicode/generate.mjs UNICODE_DATA > shell/lib/unicode.mjs
//
// The shell's JavaScript (Qt's V4) parses property escapes under the u
// flag but has no tables for them (Qt 6.10's
// src/3rdparty/masm/stubs/yarr/YarrUnicodeProperties.cpp), so the classes
// are code point ranges. They're made from a pinned file, checked by its
// SHA-256, not the host's own tables, so every host makes the same module.
// Hyprland's RE2 spells the same classes by their categories, as its own
// Unicode version has them.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The file the module is made from: Unicode 16.0.0's, as ICU 76.1 carries
// it (icu4c/source/data/unidata/UnicodeData.txt), the version the
// picker's characters are from (shell/chars).
export const PIN = Object.freeze({
    version: "16.0.0",
    sha256: "ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f",
});

// Each code point's general category, from UnicodeData.txt's text: a Map
// from code point to category, with `<…, First>` / `<…, Last>` pairs as
// ranges.
export function categories(text) {
    const out = new Map();
    let first = null;
    for (const line of text.split("\n")) {
        if (line.trim() === "") {
            continue;
        }
        const fields = line.split(";");
        const cp = parseInt(fields[0], 16);
        const category = fields[2];
        if (fields[1].endsWith(", First>")) {
            first = cp;
            continue;
        }
        const from = fields[1].endsWith(", Last>") ? first : cp;
        for (let c = from; c <= cp; c++) {
            out.set(c, category);
        }
        first = null;
    }
    return out;
}

// The code points `keep` takes, as [first, last] ranges in order.
function ranges(cats, keep) {
    const out = [];
    let start = -1;
    for (let cp = 0; cp <= 0x110000; cp++) {
        const inside = cp < 0x110000 && keep(cp, cats.get(cp) ?? "Cn");
        if (inside && start < 0) {
            start = cp;
        } else if (!inside && start >= 0) {
            out.push([start, cp - 1]);
            start = -1;
        }
    }
    return out;
}

function spelled(list) {
    const one = (cp) => cp === 0x5f ? "_" : `\\u{${cp.toString(16).toUpperCase()}}`;
    return list.map(([a, b]) => a === b ? one(a) : `${one(a)}-${one(b)}`).join("");
}

// The module, from UnicodeData.txt's text, or an Error when it isn't the
// pinned file.
export function module(text) {
    const sha = createHash("sha256").update(text).digest("hex");
    if (sha !== PIN.sha256) {
        throw new Error(`UnicodeData.txt's SHA-256 is ${sha}, not Unicode ${PIN.version}'s ${PIN.sha256}`);
    }
    const cats = categories(text);
    const word = ranges(cats, (cp, c) => cp === 0x5f || /^[LMN]/.test(c));
    const digit = ranges(cats, (cp, c) => c === "Nd");
    return "// Written by shell/unicode/generate.mjs from Unicode's UnicodeData.txt;\n"
        + "// run `make unicode` to remake it, not by hand.\n\n"
        + "// The Unicode version these are from, and its file's SHA-256.\n"
        + `export const UNICODE_VERSION = ${JSON.stringify(PIN.version)};\n`
        + `export const SOURCE_SHA256 = ${JSON.stringify(PIN.sha256)};\n\n`
        + "// \\w in a floating rule's title: letters, marks, numbers and _.\n"
        + `export const WORD = ${JSON.stringify(spelled(word))};\n\n`
        + "// \\d: decimal digits.\n"
        + `export const DIGIT = ${JSON.stringify(spelled(digit))};\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    if (process.argv.length !== 3) {
        console.error("usage: generate.mjs UNICODE_DATA");
        process.exit(2);
    }
    try {
        process.stdout.write(module(readFileSync(process.argv[2], "utf8")));
    } catch (e) {
        console.error(`generate.mjs: ${e.message}`);
        process.exit(1);
    }
}
