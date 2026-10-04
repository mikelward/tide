// make palette: writes shell/lib/palette.mjs from theme/palette.json.
// With --check, writes nothing and fails if it is out of date.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { shellModule } from "./palette.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(root, "theme/palette.json");
const target = join(root, "shell/lib/palette.mjs");

let text;
try {
    text = shellModule(JSON.parse(readFileSync(source, "utf8")));
} catch (e) {
    console.error(`theme/palette.json: ${e.message}`);
    process.exit(1);
}
if (process.argv.includes("--check")) {
    let current = null;
    try {
        current = readFileSync(target, "utf8");
    } catch (e) {
        console.error(`shell/lib/palette.mjs: ${e.message}`);
    }
    if (current !== text) {
        console.error("shell/lib/palette.mjs is out of date with theme/palette.json; run `make palette`");
        process.exit(1);
    }
} else {
    writeFileSync(target, text);
}
