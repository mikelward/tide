// Tests for check-tide-kde.mjs, against stand-ins for tide on KDE's
// setup.mjs: one that agrees with the shell, and ones that differ.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import * as shell from "../lib/kdeborders.mjs";
import { differences } from "./check-tide-kde.mjs";

// A setup.mjs that gives what the shell does.
const agreeing = {
    appearance: (files) => shell.borders(files),
    decorationSettings: (s) => [["org.kde.kdecoration2", "library", "org.tide.decoration"]]
        .concat(shell.entries(s).map((e) => ["tide-decoration"].concat(e))),
};

test("a setup that gives the same settings passes", () => {
    assert.deepEqual(differences(shell, agreeing), []);
});

test("a different default is named", () => {
    const kde = Object.assign({}, agreeing, {
        appearance: (files) => {
            const found = shell.borders(files);
            const unset = files.every(([, text]) => text === null || !text.includes("shadowSize"));
            return unset ? { settings: Object.assign({}, found.settings, { shadowSize: 12 }), errors: found.errors } : found;
        },
    });
    const found = differences(shell, kde);
    assert.ok(found.length > 0);
    assert.match(found[0], /^the settings from \[null,null\]: the shell has \{"shadows":"focused","shadowSize":16,.*tide on KDE \{"shadows":"focused","shadowSize":12,/);
});

test("a setting one side refuses and the other takes is named", () => {
    const kde = Object.assign({}, agreeing, {
        appearance: (files) => shell.borders(files.map(([name, text]) => [name, text === null ? null : text.replace('"borderWidth": 17', '"borderWidth": 16')])),
    });
    const found = differences(shell, kde);
    assert.ok(found.some((line) => line.startsWith("the errors from ") && line.includes("borderWidth must be a whole number from 0 to 16")), found.join("\n"));
});

test("a different entry in kwinrc is named", () => {
    const kde = Object.assign({}, agreeing, {
        decorationSettings: (s) => agreeing.decorationSettings(s).map(([group, key, value]) => [group, key === "ShadowSize" ? "ShadowRadius" : key, value]),
    });
    const found = differences(shell, kde);
    assert.equal(found.length > 0 && found.every((line) => line.startsWith("kwinrc's entries from ") && line.includes('"ShadowRadius"')), true, found.join("\n"));
});

test("without a checkout it fails, saying what to give", (t) => {
    const dir = mkdtempSync(join(tmpdir(), "check-tide-kde-"));
    t.after(() => rmSync(dir, { recursive: true }));
    const r = spawnSync(process.execPath, [fileURLToPath(new URL("./check-tide-kde.mjs", import.meta.url)), dir], { encoding: "utf8" });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /give a mikelward\/tide-kde checkout, as make check-tide-kde TIDE_KDE=DIR/);
});

test("a checkout from before tide on KDE had a decoration fails, saying so", (t) => {
    const dir = mkdtempSync(join(tmpdir(), "check-tide-kde-"));
    t.after(() => rmSync(dir, { recursive: true }));
    mkdirSync(join(dir, "scripts"));
    writeFileSync(join(dir, "scripts", "setup.mjs"), "export const KWINRC = [];\n");
    const r = spawnSync(process.execPath, [fileURLToPath(new URL("./check-tide-kde.mjs", import.meta.url)), dir], { encoding: "utf8" });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /gives tide's decoration no settings: it's from before tide on KDE had one, so update that checkout/);
});
