// Tests for kdeborders.mjs. The command runs for real, in sh, against
// stand-ins for kreadconfig6, kwriteconfig6 and busctl that keep a kwinrc
// as a file per entry and a line per call: no KWin and no KConfig ran.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DECORATION, CHOICE, GROUP, IDLE, borders, entries, applyCommand, next } from "./kdeborders.mjs";

const DEFAULTS = { shadows: "focused", shadowSize: 16, borderWidth: 0, roundedCorners: true };

test("with no files, the decoration gets tide's defaults", () => {
    assert.deepEqual(borders([["appearance.json", null], ["appearance.local.json", null]]), { settings: DEFAULTS, errors: [] });
});

test("the local file's settings win, one by one", () => {
    const found = borders([
        ["appearance.json", '{"shadows": "all", "shadowSize": 8, "borderWidth": 2}'],
        ["appearance.local.json", '{"shadowSize": 24, "roundedCorners": false}'],
    ]);
    assert.deepEqual(found, { settings: { shadows: "all", shadowSize: 24, borderWidth: 2, roundedCorners: false }, errors: [] });
});

test("settings the decoration doesn't take aren't looked at", () => {
    const found = borders([["appearance.json", '{"mode": "dark", "dimStrength": 7, "nonsense": 1, "borderWidth": 3}']]);
    assert.deepEqual(found, { settings: Object.assign({}, DEFAULTS, { borderWidth: 3 }), errors: [] });
});

test("a bad setting is named and left out, and the rest stand", () => {
    const found = borders([
        ["appearance.json", '{"shadows": "some", "shadowSize": 33, "borderWidth": 4}'],
        ["appearance.local.json", '{"borderWidth": 1.5, "roundedCorners": "no"}'],
    ]);
    assert.deepEqual(found.settings, Object.assign({}, DEFAULTS, { borderWidth: 4 }));
    assert.deepEqual(found.errors, [
        'appearance.json: shadows must be one of "none", "floating", "focused", "all"',
        "appearance.json: shadowSize must be a whole number from 0 to 32",
        "appearance.local.json: borderWidth must be a whole number from 0 to 16",
        "appearance.local.json: roundedCorners must be true or false",
    ]);
});

test("a file that isn't an object of settings is named, and the other file stands", () => {
    const found = borders([["appearance.json", '{"shadows": "none"}'], ["appearance.local.json", "[1]"]]);
    assert.deepEqual(found, { settings: Object.assign({}, DEFAULTS, { shadows: "none" }), errors: ["appearance.local.json: expected an object of settings"] });
    const broken = borders([["appearance.json", '{"shadows": '], ["appearance.local.json", '{"borderWidth": 2}']]);
    assert.deepEqual(broken.settings, Object.assign({}, DEFAULTS, { borderWidth: 2 }));
    assert.equal(broken.errors.length, 1);
    assert.match(broken.errors[0], /^appearance\.json: line 1: /);
});

test("the entries are the decoration's, as text", () => {
    assert.deepEqual(entries({ shadows: "floating", shadowSize: 0, borderWidth: 16, roundedCorners: false }),
        [["Shadows", "floating"], ["ShadowSize", "0"], ["BorderWidth", "16"], ["RoundedCorners", "false"]]);
    assert.deepEqual([DECORATION, CHOICE, GROUP], ["org.tide.decoration", ["org.kde.kdecoration2", "library"], "tide-decoration"]);
});

// A Plasma of stand-ins in a directory of its own: kwinrc as
// DIR/kwinrc/GROUP/KEY, and each kwriteconfig6 and busctl call as a line of
// DIR/calls. `missing` names the stand-ins to leave out, and `failing` those
// that fail.
function plasma(kwinrc, { missing = [], failing = [] } = {}) {
    const dir = mkdtempSync(join(tmpdir(), "kdeborders-"));
    mkdirSync(join(dir, "bin"));
    for (const [group, key, value] of kwinrc) {
        mkdirSync(join(dir, "kwinrc", group), { recursive: true });
        writeFileSync(join(dir, "kwinrc", group, key), value);
    }
    const stand_ins = {
        // As kreadconfig6: the value and a newline, or the newline alone.
        kreadconfig6: 'test "$1 $3 $5" = "--file --group --key" && test "$2" = kwinrc || exit 2\n'
            + 'cat "$DIR/kwinrc/$4/$6" 2>/dev/null; echo\n',
        kwriteconfig6: 'test "$1 $3 $5" = "--file --group --key" && test "$2" = kwinrc || exit 2\n'
            + 'echo "kwriteconfig6 $4 $6 $7" >>"$DIR/calls"\nmkdir -p "$DIR/kwinrc/$4" && printf %s "$7" >"$DIR/kwinrc/$4/$6"\n',
        busctl: 'echo "busctl $*" >>"$DIR/calls"\n',
    };
    for (const name of Object.keys(stand_ins)) {
        if (missing.includes(name)) {
            continue;
        }
        const body = failing.includes(name) ? `echo "${name}: no" >&2\nexit 1\n` : stand_ins[name];
        writeFileSync(join(dir, "bin", name), `#!/bin/sh\n${body}`);
        chmodSync(join(dir, "bin", name), 0o755);
    }
    return {
        apply(settings) {
            const [cmd, ...args] = applyCommand(settings);
            // The system's sh and its builtins, and only the stand-ins beside them.
            const r = spawnSync(cmd, args, { encoding: "utf8", env: { PATH: `${join(dir, "bin")}:/usr/bin:/bin`, DIR: dir, LC_ALL: "C" } });
            const calls = existsSync(join(dir, "calls")) ? readFileSync(join(dir, "calls"), "utf8").split("\n").filter(l => l !== "") : [];
            rmSync(join(dir, "calls"), { force: true });
            return { code: r.status, said: r.stderr.trim(), calls };
        },
        remove: () => rmSync(dir, { recursive: true }),
    };
}

const CHOSEN = ["org.kde.kdecoration2", "library", "org.tide.decoration"];
const RECONFIGURE = "busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure";
const ALL = { shadows: "all", shadowSize: 8, borderWidth: 2, roundedCorners: false };

test("with tide's decoration chosen, a change is written and KWin asked once", (t) => {
    const p = plasma([CHOSEN]);
    t.after(p.remove);
    assert.deepEqual(p.apply(ALL), {
        code: 0,
        said: "set Shadows=all ShadowSize=8 BorderWidth=2 RoundedCorners=false",
        calls: [
            "kwriteconfig6 tide-decoration Shadows all",
            "kwriteconfig6 tide-decoration ShadowSize 8",
            "kwriteconfig6 tide-decoration BorderWidth 2",
            "kwriteconfig6 tide-decoration RoundedCorners false",
            RECONFIGURE,
        ],
    });
});

test("only what differs is written, and nothing at all when nothing does", (t) => {
    const p = plasma([CHOSEN, ["tide-decoration", "Shadows", "all"], ["tide-decoration", "ShadowSize", "8"],
        ["tide-decoration", "BorderWidth", "2"], ["tide-decoration", "RoundedCorners", "false"]]);
    t.after(p.remove);
    assert.deepEqual(p.apply(ALL), { code: 0, said: "", calls: [] });
    assert.deepEqual(p.apply(Object.assign({}, ALL, { borderWidth: 0 })),
        { code: 0, said: "set BorderWidth=0", calls: ["kwriteconfig6 tide-decoration BorderWidth 0", RECONFIGURE] });
    // And that change, applied again, is no change.
    assert.deepEqual(p.apply(Object.assign({}, ALL, { borderWidth: 0 })), { code: 0, said: "", calls: [] });
});

test("with another decoration, or none chosen, nothing is written and KWin isn't asked", (t) => {
    for (const kwinrc of [[["org.kde.kdecoration2", "library", "org.kde.breeze"]], []]) {
        const p = plasma(kwinrc);
        t.after(p.remove);
        assert.deepEqual(p.apply(ALL), { code: 0, said: "KWin's decoration isn't tide's, so there's nothing to set", calls: [] });
    }
});

test("without kreadconfig6 it fails, having written nothing", (t) => {
    const p = plasma([CHOSEN], { missing: ["kreadconfig6"] });
    t.after(p.remove);
    const r = p.apply(ALL);
    assert.equal(r.code, 127);
    assert.match(r.said, /kreadconfig6/);
    assert.deepEqual(r.calls, []);
});

test("a write that fails stops it, before KWin is asked", (t) => {
    const p = plasma([CHOSEN], { failing: ["kwriteconfig6"] });
    t.after(p.remove);
    assert.deepEqual(p.apply(ALL), { code: 1, said: "kwriteconfig6: no", calls: [] });
});

test("a KWin that can't be asked is said, with what was written", (t) => {
    const p = plasma([CHOSEN], { failing: ["busctl"] });
    t.after(p.remove);
    const r = p.apply(Object.assign({}, DEFAULTS, { shadows: "none" }));
    assert.equal(r.code, 1);
    assert.equal(r.said, "busctl: no\nwrote Shadows=none ShadowSize=16 BorderWidth=0 RoundedCorners=true, but couldn't have KWin read its settings again; they apply at the next login");
});

// The runs a sequence of events starts, as KdeBorders.qml feeds them:
// "change" and "done" with both files readable, "broken" a change that
// leaves one unreadable, and "done-broken" a run ending while one is.
function runs(events) {
    let state = IDLE;
    const started = [];
    for (const [i, name] of events.entries()) {
        const r = next(state, { type: name.startsWith("done") ? "done" : "change", readable: name === "change" || name === "done" });
        state = r.state;
        if (r.start) {
            started.push(i);
        }
    }
    return { started, state };
}

test("each change gets one run, and those during a run share one after it", () => {
    assert.deepEqual(runs(["change", "done", "change", "done"]), { started: [0, 2], state: IDLE });
    assert.deepEqual(runs(["change", "change", "change", "done", "done"]), { started: [0, 3], state: IDLE });
});

test("a file that can't be read starts nothing", () => {
    assert.deepEqual(runs(["broken"]), { started: [], state: IDLE });
    assert.deepEqual(runs(["broken", "change", "done"]), { started: [1], state: IDLE });
});

test("a change held during a run is let go when a file then can't be read", () => {
    // Codex's sequence: a run, a change held, a file breaks, the run ends.
    assert.deepEqual(runs(["change", "change", "broken", "done-broken"]), { started: [0], state: IDLE });
    // And the next change that can be read runs.
    assert.deepEqual(runs(["change", "change", "broken", "done-broken", "change"]).started, [0, 4]);
});

test("a held change doesn't run on a file that's unreadable as the run ends", () => {
    assert.deepEqual(runs(["change", "change", "done-broken"]), { started: [0], state: IDLE });
});

test("a file that's readable again before the run ends gets the held run", () => {
    assert.deepEqual(runs(["change", "broken", "change", "done"]), { started: [0, 3], state: { running: true, again: false } });
});

test("an event it doesn't know is refused", () => {
    assert.throws(() => next(IDLE, { type: "stopped", readable: true }), /unknown Borders event: stopped/);
});
