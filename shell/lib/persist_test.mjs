// Checks shell/*.qml for a PersistentProperties property that can't
// survive a config reload. Quickshell copies each one from the old
// engine's object to the new one's (QObject::setProperty, Quickshell 0.3.1
// persistentprops.cpp), and a JS object or array is a value of the old
// engine, which Qt won't move to another ("JSValue can't be reassigned to
// another engine"): the property reads undefined after the reload. So
// each holds a string, number or bool, and anything richer is JSON text.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SHELL = join(dirname(fileURLToPath(import.meta.url)), "..");
const PLAIN = new Set(["string", "bool", "int", "real", "double"]);

// Each property declared directly in a PersistentProperties in `source`,
// as {line, type, name}. Objects open as `Type {` on a line of their own,
// as the shell's files are formatted.
export function persistedProperties(source) {
    const found = [];
    let depth = 0;
    let inside = -1;
    source.split("\n").forEach((line, i) => {
        const code = line.replace(/\/\/.*$/, "");
        if (inside < 0 && /^\s*PersistentProperties\s*\{\s*$/.test(code)) {
            inside = depth;
        } else if (inside >= 0 && depth === inside + 1) {
            const m = code.match(/^\s*(?:readonly\s+)?property\s+([\w.<>]+)\s+(\w+)/);
            if (m) {
                found.push({ line: i + 1, type: m[1], name: m[2] });
            }
        }
        for (const ch of code) {
            if (ch === "{") {
                depth++;
            } else if (ch === "}") {
                depth--;
                if (depth === inside) {
                    inside = -1;
                }
            }
        }
    });
    return found;
}

test("persistedProperties finds a PersistentProperties' own properties", () => {
    const source = [
        "Item {",
        "    property var other: ({})",
        "    PersistentProperties {",
        "        reloadableId: \"x\"",
        "        property bool on: false",
        "        property var state: ({ a: 1 })",
        "        QtObject {",
        "            property var nested: null",
        "        }",
        "    }",
        "    property var after: []",
        "}",
    ].join("\n");
    assert.deepEqual(persistedProperties(source), [
        { line: 5, type: "bool", name: "on" },
        { line: 6, type: "var", name: "state" },
    ]);
});

test("every property kept across a reload is a string, number or bool", () => {
    const bad = [];
    let seen = 0;
    for (const file of readdirSync(SHELL).filter(f => f.endsWith(".qml"))) {
        for (const p of persistedProperties(readFileSync(join(SHELL, file), "utf8"))) {
            seen++;
            if (!PLAIN.has(p.type)) {
                bad.push(`${file}:${p.line}: ${p.type} ${p.name}`);
            }
        }
    }
    assert.ok(seen > 0, "found no PersistentProperties at all");
    assert.deepEqual(bad, []);
});
