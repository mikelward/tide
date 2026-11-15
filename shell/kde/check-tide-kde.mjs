// make check-tide-kde: the Borders settings the shell gives tide's
// decoration on KDE Plasma (shell/lib/kdeborders.mjs) are still the ones
// tide on KDE's `make setup` gives it (mikelward/tide-kde's
// scripts/setup.mjs), read from a tide-kde checkout (the path given,
// ../tide-kde by default): the same defaults, the same settings refused
// with the same words, and the same entries in kwinrc.
// Usage: node shell/kde/check-tide-kde.mjs DIR
// Build-time Node, not loaded by the shell.
import { existsSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as ours from "../lib/kdeborders.mjs";

const NAMES = ["appearance.json", "appearance.local.json"];

// Files to read both ways, [shared, local], each a text or null: every
// setting at its bounds and past them, a file winning over the other, and
// files that aren't settings. One that isn't JSON is left out: each side
// words that error its own way.
export const SAMPLES = [
    [null, null],
    ["{}", "{}"],
    ['{"shadows": "none", "shadowSize": 0, "borderWidth": 0, "roundedCorners": false}', null],
    ['{"shadows": "floating", "shadowSize": 32, "borderWidth": 16, "roundedCorners": true}', '{"shadows": "all", "borderWidth": 1}'],
    ['{"shadows": "focused"}', '{"shadowSize": 33, "borderWidth": 17, "roundedCorners": 1}'],
    ['{"shadows": "active", "shadowSize": -1, "borderWidth": 1.5, "roundedCorners": "true"}', '{"shadowSize": "8", "borderWidth": null}'],
    ['{"mode": "dark", "dimStrength": 0.2, "unknown": 1, "shadowSize": 4}', null],
    ["[]", '"shadows"'],
    ["null", '{"borderWidth": 3}'],
];

// What differs between the shell's side (kdeborders.mjs's exports) and
// tide on KDE's (setup.mjs's), a line each, or [] when nothing does.
export function differences(shell, kde) {
    const out = [];
    const same = (what, a, b) => {
        if (JSON.stringify(a) !== JSON.stringify(b)) {
            out.push(`${what}: the shell has ${JSON.stringify(a)}, tide on KDE ${JSON.stringify(b)}`);
        }
    };
    for (const sample of SAMPLES) {
        const files = NAMES.map((name, i) => [name, sample[i]]);
        const a = shell.borders(files);
        const b = kde.appearance(files);
        const what = `from ${JSON.stringify(sample)}`;
        same(`the settings ${what}`, a.settings, b.settings);
        same(`the errors ${what}`, a.errors, b.errors);
        // tide on KDE's entries also choose the decoration, which the shell
        // leaves to setup; the rest are the group's.
        const chosen = [shell.CHOICE.concat([shell.DECORATION])];
        same(`kwinrc's entries ${what}`, chosen.concat(shell.entries(a.settings).map((e) => [shell.GROUP].concat(e))), kde.decorationSettings(b.settings));
    }
    return out;
}

async function main(dir) {
    const setup = resolve(dir, "scripts/setup.mjs");
    if (!existsSync(setup)) {
        console.error(`check-tide-kde: no ${setup}: give a mikelward/tide-kde checkout, as make check-tide-kde TIDE_KDE=DIR`);
        return 2;
    }
    const theirs = await import(pathToFileURL(setup).href);
    if (typeof theirs.appearance !== "function" || typeof theirs.decorationSettings !== "function") {
        console.error(`check-tide-kde: ${setup} gives tide's decoration no settings: it's from before tide on KDE had one, so update that checkout`);
        return 2;
    }
    const found = differences(ours, theirs);
    for (const line of found) {
        console.error(`check-tide-kde: ${line}`);
    }
    if (found.length > 0) {
        console.error("check-tide-kde: shell/lib/kdeborders.mjs and tide-kde's scripts/setup.mjs must give tide's decoration the same settings");
        return 1;
    }
    console.log(`check-tide-kde: the shell and ${setup} give tide's decoration the same settings`);
    return 0;
}

if (process.argv[1] !== undefined && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
    process.exitCode = await main(process.argv[2] ?? "../tide-kde");
}
