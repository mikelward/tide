// Tests for tide's own icons in shell/icons.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// tide's own icons (SPEC.md §15): each one the shell names is shipped, and
// each one shipped is named, so a typo or a leftover can't go unnoticed
// until a blank space shows up in the bar.
const shell = join(dirname(fileURLToPath(import.meta.url)), "..");
const icons = join(shell, "icons");

// They're named in the QML as `file: "..."`, or anywhere in the QML or the
// shell's modules as a "...-symbolic.svg" string, the form SymbolicIcon
// also takes as a `name` (keep awake's cup, which the OSD and the switcher
// name too).
function named() {
    const names = new Set();
    const sources = readdirSync(shell).filter((n) => n.endsWith(".qml")).map((n) => join(shell, n))
        .concat(readdirSync(join(shell, "lib")).filter((n) => n.endsWith(".mjs") && !n.endsWith("_test.mjs")).map((n) => join(shell, "lib", n)));
    for (const f of sources) {
        const text = readFileSync(f, "utf8");
        // Exec loops: the tests run without matchAll (qtjs_env_test.mjs).
        for (const pattern of [/\bfile:\s*"([^"]+)"/g, /"([\w-]+-symbolic\.svg)"/g]) {
            for (let m = pattern.exec(text); m !== null; m = pattern.exec(text)) {
                names.add(m[1]);
            }
        }
    }
    return names;
}

test("every icon the shell names is shipped, and every one shipped is named", () => {
    const want = named();
    const have = new Set(readdirSync(icons).filter((n) => n.endsWith(".svg")));
    assert.ok(want.size > 0, "found no icons named in shell/*.qml");
    assert.deepEqual([...want].sort(), [...have].sort());
});

test("each icon is a 16 px symbolic SVG", () => {
    const files = readdirSync(icons).filter((n) => n.endsWith(".svg"));
    assert.ok(files.length > 0);
    for (const f of files) {
        assert.match(f, /-symbolic\.svg$/, f);
        const svg = readFileSync(join(icons, f), "utf8");
        assert.match(svg, /<svg[^>]*\bwidth="16"[^>]*\bheight="16"/, f);
        assert.match(svg, /viewBox="0 0 16 16"/, f);
    }
});
