// The Borders settings on KDE Plasma (SPEC.md §8.5): what tide's window
// decoration there (mikelward/tide-kde's `decoration/`, KWin's
// org.tide.decoration) reads from kwinrc's [tide-decoration], from tide's
// appearance.json and appearance.local.json. tide-kde's `make setup`
// writes the same from the same files (its scripts/setup.mjs); `make
// check-tide-kde` compares the two.
// Pure functions, so they test with no Plasma; KdeBorders.qml runs the
// command.

import { parseAppearance, shadows, shadowSize, borderWidth, roundedCorners } from "./appearance.mjs";
import { jsonError } from "./clocks.mjs";

// The decoration's name, as KWin keeps its choice of one, in kwinrc's
// [org.kde.kdecoration2] library.
export const DECORATION = "org.tide.decoration";
export const CHOICE = Object.freeze(["org.kde.kdecoration2", "library"]);
// kwinrc's group the decoration reads.
export const GROUP = "tide-decoration";

// The settings the decoration takes, of all appearance.json's.
const KEYS = ["shadows", "shadowSize", "borderWidth", "roundedCorners"];

// The Borders settings in effect, from [[name, text], ...]: each file's
// name and its text, or null when there's no such file, the shared file
// first. A later file's settings win, and tide's defaults stand for the
// rest. A file that isn't an object of settings, or a setting that makes
// no sense, is named in `errors` and left out, as tide-kde's setup does:
// one bad setting doesn't cost the others. Settings the decoration doesn't
// take aren't looked at.
export function borders(files) {
    const set = {};
    const errors = [];
    for (const [name, text] of files) {
        if (text === null || text === undefined) {
            continue;
        }
        let value;
        try {
            value = JSON.parse(text);
        } catch (e) {
            errors.push(`${name}: ${jsonError(text)}`);
            continue;
        }
        if (value === null || typeof value !== "object" || Array.isArray(value)) {
            errors.push(`${name}: expected an object of settings`);
            continue;
        }
        for (const key of KEYS) {
            if (value[key] === undefined) {
                continue;
            }
            // The settings pages' own check, a setting at a time.
            const one = {};
            one[key] = value[key];
            const parsed = parseAppearance(JSON.stringify(one));
            if (parsed.error) {
                errors.push(`${name}: ${parsed.error}`);
            } else {
                set[key] = value[key];
            }
        }
    }
    const settings = { shadows: shadows(set), shadowSize: shadowSize(set), borderWidth: borderWidth(set), roundedCorners: roundedCorners(set) };
    return { settings, errors };
}

// [tide-decoration]'s entries for `settings`, [[key, value], ...], as the
// decoration reads them.
export function entries(settings) {
    return [
        ["Shadows", settings.shadows],
        ["ShadowSize", String(settings.shadowSize)],
        ["BorderWidth", String(settings.borderWidth)],
        ["RoundedCorners", String(settings.roundedCorners)],
    ];
}

// Gives the decoration the entries passed after it, a key then its value,
// and has KWin read its settings again, which the decoration follows.
// Only while the decoration is the one KWin uses: otherwise nothing is
// written, and KWin isn't asked. Only an entry that differs is written,
// and KWin is asked once, and only when one was. It says what it did on
// stderr, which the shell logs.
// kreadconfig6 prints an entry's value and a newline, or the newline alone
// for one that isn't set (kconfig's kreadconfig.cpp); `reconfigure` is
// org.kde.KWin's (kwin's org.kde.KWin.xml).
const SCRIPT = `chosen=$(kreadconfig6 --file kwinrc --group ${CHOICE[0]} --key ${CHOICE[1]}) || exit
if test "$chosen" != ${DECORATION}; then
    echo "KWin's decoration isn't tide's, so there's nothing to set" >&2
    exit 0
fi
changed=
while test $# -gt 1; do
    now=$(kreadconfig6 --file kwinrc --group ${GROUP} --key "$1") || exit
    if test "$now" != "$2"; then
        kwriteconfig6 --file kwinrc --group ${GROUP} --key "$1" "$2" || exit
        changed="$changed $1=$2"
    fi
    shift 2
done
test -n "$changed" || exit 0
if ! busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure; then
    echo "wrote$changed, but couldn't have KWin read its settings again; they apply at the next login" >&2
    exit 1
fi
echo "set$changed" >&2
`;

// The command that applies `settings` (borders' own).
export function applyCommand(settings) {
    return entries(settings).reduce((command, entry) => command.concat(entry), ["sh", "-c", SCRIPT, "sh"]);
}

// What the shell's log calls that command, in place of its text.
export const SHOWN = Object.freeze(["Borders", "on", "Plasma"]);

// Applying, one run at a time: {running, again}. A change while a run is
// going is held, and runs once that run ends, on the files as they are
// then. Each step returns {state, start}: whether to start a run now, on
// the files as they are.
// The events are {type: "change", readable}, as a file's load ends, and
// {type: "done", readable}, as a run does; `readable` is whether both
// files can be read now (one that doesn't exist can). A file that can't be
// read is neither missing nor empty, so nothing runs on it, then or later:
// a held change is let go, and the decoration keeps what it has until a
// change that can be read.
export const IDLE = Object.freeze({ running: false, again: false });

export function next(state, event) {
    switch (event.type) {
    case "change":
        if (!event.readable) {
            return { state: state.running ? Object.freeze({ running: true, again: false }) : IDLE, start: false };
        }
        if (state.running) {
            return { state: Object.freeze({ running: true, again: true }), start: false };
        }
        return { state: Object.freeze({ running: true, again: false }), start: true };
    case "done":
        if (state.again && event.readable) {
            return { state: Object.freeze({ running: true, again: false }), start: true };
        }
        return { state: IDLE, start: false };
    default:
        throw new Error(`unknown Borders event: ${event.type}`);
    }
}
