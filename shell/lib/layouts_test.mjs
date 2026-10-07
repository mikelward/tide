// Tests for layouts.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
    SYMBOLS, defaultMode, parseAnnouncement, layoutSymbol, DEFAULT_LAYOUTS, MODE_NAMES,
    parseLayouts, loadLayouts, effectiveLayouts, shownLayout, steppedLayout, formatLayout,
    withLayoutSetting, layoutsLua, layoutRows, steppedSingle,
} from "./layouts.mjs";

test("a workspace starts in threecol on an ultrawide work area, else tile", () => {
    assert.equal(defaultMode({ width: 3440, height: 1440 }, 36), "threecol");
    assert.equal(defaultMode({ width: 2560, height: 1440 }, 36), "tile");
    assert.equal(defaultMode({ width: 1920, height: 1080, scale: 1.25 }, 36), "tile");
    assert.equal(defaultMode({ width: 5120, height: 1440, scale: 1.5 }, 36), "threecol");
});

test("the bar's height counts against the work area, as the layout sees it", () => {
    // 2.09 as a whole monitor, 2.15 below a 36 px bar.
    assert.equal(defaultMode({ width: 2508, height: 1200 }, 0), "tile");
    assert.equal(defaultMode({ width: 2508, height: 1200 }, 36), "threecol");
});

test("a rotated monitor is measured as it's shown", () => {
    assert.equal(defaultMode({ width: 3440, height: 1440, transform: 1 }, 36), "tile");
    assert.equal(defaultMode({ width: 1440, height: 3440, transform: 3 }, 36), "threecol");
    assert.equal(defaultMode({ width: 3440, height: 1440, transform: 2 }, 36), "threecol");
});

test("a monitor with no size yet starts in tile", () => {
    assert.equal(defaultMode({ width: 0, height: 0 }, 36), "tile");
});

test("announcements name a workspace and a known mode", () => {
    assert.deepEqual(parseAnnouncement("tide-layout>>3,monocle"), { workspace: 3, mode: "monocle" });
    assert.deepEqual(parseAnnouncement("tide-layout>>-98,tile"), { workspace: -98, mode: "tile" });
    assert.equal(parseAnnouncement("tide-layout>>3,spiral"), null);
    assert.equal(parseAnnouncement("tide-layout>>three,tile"), null);
    assert.equal(parseAnnouncement("tide-layout>>3"), null);
    assert.equal(parseAnnouncement("something-else>>3,tile"), null);
    assert.equal(parseAnnouncement(undefined), null);
});

test("each mode shows its symbol, and monocle its hidden count", () => {
    for (const [mode, symbol] of Object.entries(SYMBOLS)) {
        assert.equal(layoutSymbol(mode, 1), symbol);
    }
    assert.equal(layoutSymbol("tile", 4), "[]=");
    assert.equal(layoutSymbol("monocle", 0), "[M]");
    assert.equal(layoutSymbol("monocle", 4), "[3]");
    assert.equal(layoutSymbol("spiral", 2), "");
});

// layout.lua's M.defaults, as `key=value` lines, from the Lua the Makefile
// runs the layout's own tests with.
function luaDefaults() {
    const script = `
        local M = dofile("hypr/tide/layout.lua")
        local d = M.defaults
        print("ultrawideAspect=" .. d.ultrawide_aspect)
        print("defaultMode.normal=" .. d.default_mode.normal)
        print("defaultMode.ultrawide=" .. d.default_mode.ultrawide)
        for _, m in ipairs({ "tile", "threecol", "twocol" }) do
            print("modes." .. m .. ".mfact=" .. d.modes[m].mfact)
            print("modes." .. m .. ".nmaster=" .. d.modes[m].nmaster)
        end
        for i, r in ipairs(d.single) do
            print("single." .. i .. "=" .. r.min_aspect .. "," .. r.width)
        end
    `;
    for (const lua of [process.env.LUA, "lua5.5", "lua5.4", "lua"].filter(Boolean)) {
        const r = spawnSync(lua, ["-e", script], { encoding: "utf8" });
        if (r.error && r.error.code === "ENOENT") {
            continue;
        }
        assert.equal(r.status, 0, `${lua}: ${r.stderr}`);
        return r.stdout.trim().split("\n");
    }
    assert.fail("no lua5.5, lua5.4 or lua on PATH");
}

test("the page's defaults are layout.lua's", () => {
    const d = DEFAULT_LAYOUTS;
    const lines = [
        `ultrawideAspect=${d.ultrawideAspect}`,
        `defaultMode.normal=${d.defaultMode.normal}`,
        `defaultMode.ultrawide=${d.defaultMode.ultrawide}`,
    ];
    for (const m of ["tile", "threecol", "twocol"]) {
        lines.push(`modes.${m}.mfact=${d.modes[m].mfact}`, `modes.${m}.nmaster=${d.modes[m].nmaster}`);
    }
    d.single.forEach((r, i) => lines.push(`single.${i + 1}=${r.minAspect},${r.width}`));
    assert.deepEqual(luaDefaults(), lines);
});

test("the bar's guess at a new workspace's mode follows the settings", () => {
    const layouts = effectiveLayouts({ ultrawideAspect: 2.5, defaultMode: { normal: "monocle", ultrawide: "twocol" } });
    // 3440x1440 below a 36 px bar is about 2.45: not ultrawide at 2.5.
    assert.equal(defaultMode({ width: 3440, height: 1440 }, 36, layouts), "monocle");
    assert.equal(defaultMode({ width: 5120, height: 1440 }, 36, layouts), "twocol");
});

test("the page offers every mode a workspace can start in", () => {
    assert.deepEqual(MODE_NAMES.map(m => m.mode), Object.keys(SYMBOLS));
});

test("layouts.json reads layout.lua's settings in its own names", () => {
    const text = JSON.stringify({
        ultrawideAspect: 2.4,
        defaultMode: { ultrawide: "twocol" },
        modes: { tile: { mfact: 0.6, nmaster: 0 }, twocol: { nmaster: 3 } },
        single: [{ minAspect: 2, width: 0.75 }],
    });
    assert.deepEqual(parseLayouts(text).settings.modes.tile, { mfact: 0.6, nmaster: 0 });
});

test("a bad setting names itself", () => {
    const cases = [
        [{ ultrawideAspect: 0 }, "ultrawideAspect must be a number from 0.1 to 100"],
        [{ defaultMode: { normal: "spiral" } }, "defaultMode.normal must be one of tile, threecol, twocol, monocle"],
        [{ defaultMode: { wide: "tile" } }, "defaultMode.wide is not a setting"],
        [{ modes: { tile: { mfact: 0.95 } } }, "modes.tile.mfact must be a number from 0.1 to 0.9"],
        [{ modes: { threecol: { nmaster: 0 } } }, "modes.threecol.nmaster must be a whole number from 1 to 100"],
        [{ modes: { tile: { nmaster: 1.5 } } }, "modes.tile.nmaster must be a whole number from 0 to 100"],
        [{ modes: { monocle: {} } }, "modes.monocle is not a setting"],
        [{ modes: { tile: { mfat: 0.5 } } }, "modes.tile.mfat is not a setting"],
        [{ single: [{ minAspect: 2.1 }] }, "single entry 1: width must be a number from 0.1 to 1"],
        [{ single: [{ minAspect: 2.1, width: 0.8, widht: 1 }] }, "single entry 1: widht is not a setting"],
        [{ single: { minAspect: 2.1, width: 0.8 } }, "single must be a list of {minAspect, width}"],
        [{ cycle: ["tile"] }, 'unknown setting "cycle"'],
        [[], "expected an object of settings"],
    ];
    for (const [settings, error] of cases) {
        assert.equal(parseLayouts(JSON.stringify(settings)).error, error, JSON.stringify(settings));
    }
    assert.match(parseLayouts("{").error, /^line 1: /);
});

test("the local file goes over the shared one, objects by key and lists whole", () => {
    const shared = JSON.stringify({ modes: { tile: { mfact: 0.6, nmaster: 2 } }, single: [{ minAspect: 2, width: 0.7 }, { minAspect: 3, width: 0.5 }] });
    const local = JSON.stringify({ modes: { tile: { mfact: 0.5 } }, single: [] });
    const r = loadLayouts(shared, local);
    assert.deepEqual(r, { settings: { modes: { tile: { mfact: 0.5, nmaster: 2 } }, single: [] }, errors: [] });
    assert.equal(shownLayout(r.settings, "modes.tile.mfact"), 0.5);
    assert.equal(shownLayout(r.settings, "modes.twocol.mfact"), 0.72, "the default where nothing's set");
    assert.equal(shownLayout(r.settings, "defaultMode.ultrawide"), "threecol");
});

test("a bad file keeps the last good settings, and every bad file is named", () => {
    const last = { modes: { tile: { mfact: 0.6 } } };
    assert.deepEqual(loadLayouts("{", '{"x": 1}', last), {
        settings: last,
        errors: ["layouts.json: line 1: expected \" before the end", 'layouts.local.json: unknown setting "x"'],
    });
});

test("− and + step a setting, stopping at either end", () => {
    assert.equal(steppedLayout("modes.tile.mfact", 0.55, 1), 0.6);
    assert.equal(steppedLayout("modes.tile.mfact", 0.55, -1), 0.5);
    assert.equal(steppedLayout("modes.tile.mfact", 0.9, 1), 0.9);
    assert.equal(steppedLayout("modes.tile.mfact", 0.72, 1), 0.75, "off a step, onto the next");
    assert.equal(steppedLayout("modes.tile.mfact", 0.72, -1), 0.7, "and the same the other way");
    assert.equal(steppedLayout("modes.tile.mfact", 0.73, 1), 0.75, "never past the next");
    assert.equal(steppedLayout("modes.tile.nmaster", 0, -1), 0, "tile goes down to plain rows");
    assert.equal(steppedLayout("modes.threecol.nmaster", 1, -1), 1, "a column mode keeps a master");
    assert.equal(steppedLayout("ultrawideAspect", 2.1, 1), 2.2);
    assert.equal(steppedLayout("ultrawideAspect", 1, -1), 1);
    assert.equal(steppedLayout("single.0.width", 0.8, -1), 0.75);
    assert.equal(formatLayout("modes.tile.mfact", 0.55), "55%");
    assert.equal(formatLayout("ultrawideAspect", 2), "2.0");
    assert.equal(formatLayout("modes.tile.nmaster", 1), "1");
});

test("a value set past the page's range never steps backward", () => {
    // The files accept nmaster to 100 and ultrawideAspect from 0.1.
    assert.equal(steppedLayout("modes.tile.nmaster", 10, 1), 10, "+ past the top stays");
    assert.equal(steppedLayout("modes.tile.nmaster", 10, -1), 9, "− comes back into range");
    assert.equal(steppedLayout("ultrawideAspect", 0.5, -1), 0.5, "− past the bottom stays");
    assert.equal(steppedLayout("ultrawideAspect", 0.5, 1), 1, "+ comes back into range");
    assert.equal(steppedLayout("ultrawideAspect", 8, 1), 8);
});

test("a setting goes into layouts.local.json, keeping the rest", () => {
    const local = '{\n  "modes": {\n    "tile": {\n      "nmaster": 2\n    }\n  }\n}\n';
    assert.deepEqual(JSON.parse(withLayoutSetting(local, "modes.tile.mfact", 0.6).text), { modes: { tile: { nmaster: 2, mfact: 0.6 } } });
    assert.deepEqual(JSON.parse(withLayoutSetting(null, "defaultMode.normal", "monocle").text), { defaultMode: { normal: "monocle" } });
    // A list is set whole.
    const single = [{ minAspect: 2.1, width: 0.75 }];
    assert.deepEqual(JSON.parse(withLayoutSetting(null, "single", single).text), { single });
});

test("a bad value or a file that doesn't parse is refused, never overwritten", () => {
    assert.equal(withLayoutSetting(null, "modes.tile.mfact", 2).error, "modes.tile.mfact must be a number from 0.1 to 0.9");
    assert.equal(withLayoutSetting(null, "defaultMode.normal", "spiral").error, "defaultMode.normal must be one of tile, threecol, twocol, monocle");
    assert.match(withLayoutSetting("{", "ultrawideAspect", 2).error, /^layouts\.local\.json: line 1: /);
    assert.match(withLayoutSetting(null, "ultrawideAspect", 2, "[]").error, /^layouts\.json: expected an object/);
});

test("what's set is written as layout.lua's options", () => {
    assert.equal(layoutsLua({}).split("\n").slice(3).join("\n"), "return {\n}\n");
    const lua = layoutsLua({
        ultrawideAspect: 2.4,
        defaultMode: { ultrawide: "twocol" },
        modes: { tile: { mfact: 0.6, nmaster: 0 }, twocol: { nmaster: 3 } },
        single: [{ minAspect: 2, width: 0.75 }],
    });
    assert.equal(lua.split("\n").slice(3).join("\n"), [
        "return {",
        "    ultrawide_aspect = 2.4,",
        '    default_mode = { ultrawide = "twocol" },',
        "    modes = { tile = { mfact = 0.6, nmaster = 0 }, twocol = { nmaster = 3 } },",
        "    single = { { min_aspect = 2, width = 0.75 } },",
        "}",
        "",
    ].join("\n"));
});

test("layout.lua takes what layoutsLua writes", () => {
    const settings = {
        ultrawideAspect: 2.4,
        defaultMode: { normal: "monocle", ultrawide: "twocol" },
        modes: { tile: { mfact: 0.6, nmaster: 0 }, threecol: { mfact: 0.45 }, twocol: { nmaster: 3 } },
        single: [{ minAspect: 2, width: 0.75 }],
    };
    const script = `
        local chunk = assert(load(io.read("a"), "tide-layouts.lua", "t", {}))
        local t = chunk()
        hl = { layout = { register = function() end }, on = function() end, notification = { create = function(n) error(n.text) end } }
        local M = dofile("hypr/tide/layout.lua")
        M.settings_file = "/nonexistent/tide-layouts.lua"
        M.setup(t)
        print(t.modes.tile.mfact, t.default_mode.ultrawide, t.single[1].width)
    `;
    for (const lua of [process.env.LUA, "lua5.5", "lua5.4", "lua"].filter(Boolean)) {
        const r = spawnSync(lua, ["-e", script], { input: layoutsLua(settings), encoding: "utf8" });
        if (r.error && r.error.code === "ENOENT") {
            continue;
        }
        assert.equal(r.status, 0, `${lua}: ${r.stderr}`);
        assert.equal(r.stdout.trim(), "0.6\ttwocol\t0.75");
        return;
    }
    assert.fail("no lua5.5, lua5.4 or lua on PATH");
});

test("the page has a row for each setting, and one per lone-window rule", () => {
    const rows = layoutRows(effectiveLayouts({}));
    const paths = rows.filter(r => r.kind !== "heading").map(r => r.kind === "single" ? `single[${r.index}]` : r.path);
    assert.deepEqual(paths, [
        "ultrawideAspect", "defaultMode.normal", "defaultMode.ultrawide",
        "modes.tile.mfact", "modes.threecol.mfact", "modes.twocol.mfact",
        "modes.tile.nmaster", "modes.threecol.nmaster", "modes.twocol.nmaster",
        "single[0]", "single[1]",
    ]);
    // Every number row's value steps.
    for (const r of rows.filter(r => r.kind === "number")) {
        const v = shownLayout({}, r.path);
        assert.equal(typeof steppedLayout(r.path, v, 1), "number", r.path);
    }
    // No rules, no heading for them.
    assert.equal(layoutRows(effectiveLayouts({ single: [] })).some(r => r.label === "A LONE WINDOW'S WIDTH"), false);
});

test("a lone window's width steps in its own rule, keeping the others", () => {
    const single = DEFAULT_LAYOUTS.single;
    assert.deepEqual(steppedSingle(single, 0, -1), [{ minAspect: 2.1, width: 0.75 }, { minAspect: 3.2, width: 0.6 }]);
    assert.deepEqual(steppedSingle(single, 1, 1), [{ minAspect: 2.1, width: 0.8 }, { minAspect: 3.2, width: 0.65 }]);
    assert.equal(withLayoutSetting(null, "single", steppedSingle(single, 0, 10)).error, undefined, "the result is a valid list");
});
