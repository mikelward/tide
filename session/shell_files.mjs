// Writes the settings files tide's shell writes for tidewm and tidesway,
// with settings a user has, into DIR (session/compositors_test.sh): the
// Keyboard shortcuts, Input, Displays, Layouts, Floating and Appearance
// pages', and tidesway's own in DIR/tidesway.d. Run as
// node --import ./shell/lib/qtjs_env_test.mjs session/shell_files.mjs DIR
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { appearanceConf, tideswayConf } from "../shell/lib/appearance.mjs";
import { floatingConf } from "../shell/lib/floating.mjs";
import { inputConf } from "../shell/lib/input.mjs";
import { keysConf } from "../shell/lib/keys.mjs";
import { layoutsConf } from "../shell/lib/layouts.mjs";
import { outputsConf } from "../shell/lib/outputs.mjs";

const dir = process.argv[2];
if (!dir) {
    console.error("usage: shell_files.mjs DIR");
    process.exit(2);
}
const appearance = { dimStrength: 0.12, borderWidth: 2, shadowSize: 16, roundedCorners: true };
mkdirSync(join(dir, "tidesway.d"), { recursive: true });
const files = {
    "tide-keys.conf": keysConf({ preset: "tide", keys: {} }).text,
    "tide-input.conf": inputConf({ keyboard: { variant: "dvorak" }, touchpad: { tapToClick: true } }),
    "tide-outputs.conf": outputsConf({ monitors: { "Example Panel 0x1": { scale: 1.25 } } }),
    "tide-layouts.conf": layoutsConf({}),
    "tide-floating.conf": floatingConf([]),
    "tide-appearance.conf": appearanceConf(appearance, true),
    "tidesway.d/tide-appearance.conf": tideswayConf(appearance),
};
for (const [name, text] of Object.entries(files)) {
    writeFileSync(join(dir, name), text);
}
