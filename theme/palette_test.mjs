import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { camel, checked, cssTokens, qmlColor, shellModule } from "./palette.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = path => readFileSync(join(root, path), "utf8");
const palette = JSON.parse(read("theme/palette.json"));

test("qmlColor keeps #rrggbb and turns rgba into #aarrggbb", () => {
    assert.equal(qmlColor("x", "#1a2b3c"), "#1a2b3c");
    assert.equal(qmlColor("x", "rgba(22, 22, 26, 0.96)"), "#f516161a");
    assert.equal(qmlColor("x", "rgba(0, 0, 0, 1)"), "#ff000000");
    assert.equal(qmlColor("x", "rgba(255, 255, 255, 0)"), "#00ffffff");
    assert.equal(qmlColor("x", "rgba(246, 211, 45, .2)"), "#33f6d32d");
});

test("qmlColor names the color it can't read", () => {
    for (const bad of ["#abc", "#ABCDEF", "red", "rgba(256, 0, 0, 1)", "rgba(0, 0, 0, 1.5)", "rgb(0, 0, 0)", 7, null]) {
        assert.throws(() => qmlColor("dark.fg", bad), /^Error: dark\.fg: /, String(bad));
    }
});

test("camel turns token names into QML property names", () => {
    assert.equal(camel("fg"), "fg");
    assert.equal(camel("fg-dim"), "fgDim");
    assert.equal(camel("surface-2"), "surface2");
    assert.equal(camel("urgent-ring"), "urgentRing");
});

test("checked needs both modes with the same names", () => {
    assert.throws(() => checked({ dark: { fg: "#000000" } }), /no "light" palette/);
    assert.throws(() => checked({ dark: { fg: "#000000" }, light: {} }), /light\.fg: missing/);
    assert.throws(() => checked({ dark: {}, light: {}, dusk: {} }), /"dusk": not "dark" or "light"/);
    assert.throws(() => checked({ dark: { Fg: "#000000" }, light: { Fg: "#000000" } }), /"Fg": names are/);
});

test("checked rejects two names that are one QML name", () => {
    const p = { dark: { "surface-2": "#000000", surface2: "#111111" }, light: { "surface-2": "#000000", surface2: "#111111" } };
    assert.throws(() => checked(p), /"surface2" and "surface-2": both are surface2 in QML/);
});

test("checked reports every problem at once", () => {
    assert.throws(
        () => checked({ dark: { fg: "red", bg: "#000000" }, light: { fg: "blue" } }),
        e => /dark\.fg/.test(e.message) && /light\.fg/.test(e.message) && /light\.bg: missing/.test(e.message),
    );
});

test("the palette file is valid", () => {
    const p = checked(palette);
    assert.ok(Object.keys(p.dark).length > 0);
    assert.deepEqual(Object.keys(p.dark), Object.keys(p.light));
});

test("shell/lib/palette.mjs is generated from the palette file", async () => {
    assert.equal(read("shell/lib/palette.mjs"), shellModule(palette));
    const { PALETTE } = await import("../shell/lib/palette.mjs");
    assert.deepEqual(PALETTE, checked(palette));
});

// The mocks are what the palette was drawn from; a color changed in one
// and not the other would leave the docs showing a different desktop.
test("the palette matches the mocks' common.css where both have a color", () => {
    const css = read("docs/mocks/common.css");
    let compared = 0;
    for (const mode of ["dark", "light"]) {
        const tokens = cssTokens(css, `.theme-${mode}`);
        assert.ok(Object.keys(tokens).length > 0, `no tokens in .theme-${mode}`);
        for (const [name, value] of Object.entries(palette[mode])) {
            if (name in tokens) {
                assert.equal(value, tokens[name], `${mode}.${name}`);
                compared++;
            }
        }
    }
    assert.ok(compared >= 30, `only ${compared} colors compared`);
});

test("every palette color Theme.qml reads is in the palette", () => {
    const qml = read("shell/Theme.qml");
    const used = [...qml.matchAll(/:\s*palette\.([A-Za-z0-9]+)\s*$/gm)].map(m => m[1]);
    assert.ok(used.length > 0, "Theme.qml reads no palette colors");
    const names = Object.keys(checked(palette).dark);
    for (const name of used) {
        assert.ok(names.includes(name), `Theme.qml reads palette.${name}, which the palette doesn't have`);
    }
});

test("cssTokens reads one block's custom properties", () => {
    const css = ".a { --x: #000000; --y-2: rgba(0, 0, 0, 0.5); color: red; }\n.b { --x: #ffffff; }";
    assert.deepEqual(cssTokens(css, ".a"), { x: "#000000", "y-2": "rgba(0, 0, 0, 0.5)" });
    assert.deepEqual(cssTokens(css, ".b"), { x: "#ffffff" });
    assert.throws(() => cssTokens(css, ".c"), /no "\.c" block/);
});

// A color that differs between light and dark belongs in the palette, so a
// change there reaches the whole shell; Theme.qml is the one file that
// picks the mode.
test("no shell file but Theme.qml chooses a color by mode", () => {
    const files = readdirSync(join(root, "shell")).filter(f => f.endsWith(".qml") && f !== "Theme.qml");
    assert.ok(files.length > 10, `only ${files.length} QML files found`);
    for (const f of files) {
        assert.doesNotMatch(read(`shell/${f}`), /Theme\.dark\b/, f);
    }
});
