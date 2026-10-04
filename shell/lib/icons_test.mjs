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

function named() {
    const names = new Set();
    for (const f of readdirSync(shell).filter((n) => n.endsWith(".qml"))) {
        const text = readFileSync(join(shell, f), "utf8");
        for (const m of text.matchAll(/\bfile:\s*"([^"]+)"/g)) {
            names.add(m[1]);
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
