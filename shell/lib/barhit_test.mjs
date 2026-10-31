// Checks shell/*.qml for a BarHit that is a positioner's own child. A Row
// (Column, Flow, Grid) culls a child with no width or height from Qt 6.10
// (qquickpositioners.cpp prePositioning), and a culled item gets no
// pointer events, so that click target would be dead (BarHit.qml).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SHELL = join(dirname(fileURLToPath(import.meta.url)), "..");
const POSITIONERS = new Set(["Row", "Column", "Flow", "Grid"]);

// Each BarHit in `source` as {line, parent}: the type of the object it's
// declared in. Objects open as `Type {` on a line of their own, as the
// shell's files are formatted; any other brace (an object literal, a
// function body) is counted only to keep the nesting.
export function barHitParents(source) {
    const stack = [];
    const found = [];
    source.split("\n").forEach((line, i) => {
        const code = line.replace(/\/\/.*$/, "");
        const open = code.match(/^\s*([A-Z][\w.]*)\s*\{\s*$/);
        if (open) {
            if (open[1] === "BarHit") {
                found.push({ line: i + 1, parent: stack.length ? stack[stack.length - 1] : null });
            }
            stack.push(open[1]);
            return;
        }
        for (const ch of code) {
            if (ch === "{") {
                stack.push("{");
            } else if (ch === "}") {
                stack.pop();
            }
        }
    });
    return found;
}

test("the checker finds a BarHit's parent type", () => {
    const qml = "Row {\n    Item {\n        reach: ({ left: 1 })\n        BarHit {\n        }\n    }\n    BarHit {\n    }\n}\n";
    assert.deepEqual(barHitParents(qml), [{ line: 4, parent: "Item" }, { line: 7, parent: "Row" }]);
});

test("no BarHit is a positioner's own child", () => {
    const bad = [];
    for (const file of readdirSync(SHELL).filter((f) => f.endsWith(".qml"))) {
        for (const hit of barHitParents(readFileSync(join(SHELL, file), "utf8"))) {
            if (POSITIONERS.has(hit.parent)) {
                bad.push(`${file}:${hit.line} in a ${hit.parent}`);
            }
        }
    }
    assert.deepEqual(bad, []);
});
