// Tests for outputs.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    POSITIONS, parseOutputs, loadOutputs, monitorSettings, withOutputSetting, steppedScale,
    formatScale, outputsLua, listedMonitors, shownMonitors, withoutMonitor, localOutputs,
} from "./outputs.mjs";

const DELL = "Dell Inc. DELL U2720Q 1234ABC";
const PANEL = "BOE 0x0BCA";

test("outputs.json sets each monitor's scale and place, by its description", () => {
    const text = JSON.stringify({ monitors: { [DELL]: { scale: 1.5, position: "auto-right" }, [PANEL]: { scale: 1.25 } } });
    assert.deepEqual(parseOutputs(text).settings.monitors[DELL], { scale: 1.5, position: "auto-right" });
});

test("a bad setting names itself", () => {
    const cases = [
        [{ monitors: { [DELL]: { scale: 0.1 } } }, `monitors."${DELL}".scale must be a number from 0.25 to 10`],
        [{ monitors: { [DELL]: { scale: "2" } } }, `monitors."${DELL}".scale must be a number from 0.25 to 10`],
        [{ monitors: { [DELL]: { position: "0x0" } } }, `monitors."${DELL}".position must be one of auto, auto-right, auto-left, auto-up, auto-down`],
        [{ monitors: { [DELL]: { mode: "preferred" } } }, `monitors."${DELL}".mode is not a setting`],
        [{ monitors: { [DELL]: 2 } }, `monitors."${DELL}" must be an object of scale and position`],
        [{ monitors: [] }, "monitors must be an object, each monitor by its description"],
        [{ monitors: { "": {} } }, "a monitor's description must be one line of text"],
        [{ monitors: { "two\nlines": {} } }, "a monitor's description must be one line of text"],
        [{ outputs: {} }, 'unknown setting "outputs"'],
        [[], "expected an object of settings"],
    ];
    for (const [settings, error] of cases) {
        assert.equal(parseOutputs(JSON.stringify(settings)).error, error, JSON.stringify(settings));
    }
    assert.match(parseOutputs("{").error, /^line 1: /);
});

test("the local file goes over the shared one, monitor by monitor and setting by setting", () => {
    const shared = JSON.stringify({ monitors: { [DELL]: { scale: 1.5, position: "auto-left" }, [PANEL]: { scale: 2 } } });
    const local = JSON.stringify({ monitors: { [DELL]: { scale: 1.25 } } });
    assert.deepEqual(loadOutputs(shared, local), {
        settings: { monitors: { [DELL]: { scale: 1.25, position: "auto-left" }, [PANEL]: { scale: 2 } } },
        errors: [],
    });
    assert.deepEqual(monitorSettings(loadOutputs(shared, local).settings, "unknown"), {});
});

test("a bad file keeps the last good settings, and every bad file is named", () => {
    const last = { monitors: { [DELL]: { scale: 1.5 } } };
    const r = loadOutputs("{", '{"x": 1}', last);
    assert.deepEqual(r.settings, last);
    assert.deepEqual(r.errors.map(e => e.split(":")[0]), ["outputs.json", "outputs.local.json"]);
});

test("a setting goes into outputs.local.json, and a monitor with none left goes", () => {
    let text = withOutputSetting(null, DELL, "scale", 1.5).text;
    assert.deepEqual(JSON.parse(text), { monitors: { [DELL]: { scale: 1.5 } } });
    text = withOutputSetting(text, DELL, "position", "auto-up").text;
    assert.deepEqual(JSON.parse(text), { monitors: { [DELL]: { scale: 1.5, position: "auto-up" } } });
    text = withOutputSetting(text, DELL, "scale", undefined).text;
    assert.deepEqual(JSON.parse(text), { monitors: { [DELL]: { position: "auto-up" } } });
    text = withOutputSetting(text, DELL, "position", undefined).text;
    assert.deepEqual(JSON.parse(text), { monitors: {} });
});

test("a bad value or a file that doesn't parse is refused, never overwritten", () => {
    assert.match(withOutputSetting(null, DELL, "scale", 20).error, /scale must be a number/);
    assert.match(withOutputSetting(null, DELL, "position", "left").error, /position must be one of/);
    assert.match(withOutputSetting("{", DELL, "scale", 1).error, /^outputs\.local\.json: line 1: /);
    assert.match(withOutputSetting(null, DELL, "scale", 1, "[]").error, /^outputs\.json: expected an object/);
});

test("− and + step a scale a quarter, from a half to three", () => {
    assert.equal(steppedScale(1, 1), 1.25);
    assert.equal(steppedScale(1.25, -1), 1);
    assert.equal(steppedScale(1.6, 1), 1.75, "off a step, onto the next");
    assert.equal(steppedScale(1.6, -1), 1.5, "and the same the other way");
    assert.equal(steppedScale(1.4, 1), 1.5, "never past the next");
    assert.equal(steppedScale(3, 1), 3);
    assert.equal(steppedScale(0.5, -1), 0.5);
    assert.equal(formatScale(1.5, 1), "1.5×");
    assert.equal(formatScale(undefined, 1.25), "Auto (1.25×)");
    assert.equal(formatScale(undefined, null), "Auto");
});

test("a scale set past the page's range never steps backward", () => {
    // The files accept scales from 0.25 to 10.
    assert.equal(steppedScale(4, 1), 4, "+ past the top stays");
    assert.equal(steppedScale(4, -1), 3, "− comes back into range");
    assert.equal(steppedScale(0.25, -1), 0.25, "− past the bottom stays");
    assert.equal(steppedScale(0.25, 1), 0.5, "+ comes back into range");
});

test("Reset clears the local file's settings for a monitor, and only them", () => {
    const local = JSON.stringify({ monitors: { [DELL]: { scale: 1.5, position: "auto-left" }, [PANEL]: { scale: 1.25 } } });
    const shared = JSON.stringify({ monitors: { [DELL]: { position: "auto-up" } } });
    const text = withoutMonitor(local, DELL, shared).text;
    assert.deepEqual(JSON.parse(text), { monitors: { [PANEL]: { scale: 1.25 } } });
    assert.deepEqual(loadOutputs(shared, text).settings.monitors[DELL], { position: "auto-up" }, "the shared file's still applies");
    assert.deepEqual(monitorSettings(localOutputs(text), DELL), {}, "so Reset has nothing left to clear");
    assert.deepEqual(monitorSettings(localOutputs(local), DELL), { scale: 1.5, position: "auto-left" });
    assert.deepEqual(localOutputs(null), {});
    assert.deepEqual(localOutputs("{"), {}, "a bad file has none; loadOutputs reports it");
    assert.match(withoutMonitor("{", DELL).error, /outputs.local.json/);
});

test("the page offers Hyprland's places, automatic first", () => {
    assert.deepEqual(POSITIONS.map(p => p.position), ["auto", "auto-right", "auto-left", "auto-up", "auto-down"]);
});

test("what's set is written as hl.monitor outputs, sorted", () => {
    const lua = outputsLua({ monitors: { [PANEL]: { scale: 1.25 }, [DELL]: { scale: 1.5, position: "auto-right" } } });
    assert.equal(lua.split("\n").slice(2).join("\n"), [
        "return {",
        `    ["desc:${PANEL}"] = { scale = 1.25 },`,
        `    ["desc:${DELL}"] = { scale = 1.5, position = "auto-right" },`,
        "}",
        "",
    ].join("\n"));
    assert.equal(outputsLua({}).split("\n").slice(2).join("\n"), "return {\n}\n");
});

test("a description is quoted for Lua, whatever it holds", () => {
    const lua = outputsLua({ monitors: { 'Odd "Inc" \\ 7': { scale: 2 } } });
    assert.match(lua, /\["desc:Odd \\"Inc\\" \\\\ 7"\] = \{ scale = 2 \},/);
});

test("hyprctl monitors gives each monitor's name, description and scale", () => {
    const text = JSON.stringify([
        { id: 0, name: "DP-1", description: DELL, scale: 1.5, width: 3840 },
        { id: 1, name: "eDP-1", description: PANEL, scale: 1.25, disabled: true },
    ]);
    assert.deepEqual(listedMonitors(false, text), {
        monitors: [
            { name: "DP-1", description: DELL, scale: 1.5 },
            { name: "eDP-1", description: PANEL, scale: 1.25 },
        ],
        error: "",
    });
    assert.deepEqual(listedMonitors(true, ""), { monitors: [], error: "couldn't run hyprctl monitors" });
    assert.equal(listedMonitors(false, "{").error, "hyprctl monitors: not JSON");
    assert.equal(listedMonitors(false, "{}").error, "hyprctl monitors: expected a list of monitors");
    assert.equal(listedMonitors(false, '[{"name": "DP-1"}]').error, "hyprctl monitors: a monitor without its name or description");
});

test("the page lists each connected monitor, then each with settings that isn't", () => {
    const connected = [{ name: "DP-1", description: DELL, scale: 1.5 }];
    const shown = shownMonitors({ monitors: { [PANEL]: { scale: 2 }, [DELL]: { scale: 1.5 } } }, connected);
    assert.deepEqual(shown, [
        { name: "DP-1", description: DELL, scale: 1.5 },
        { name: "", description: PANEL, scale: null },
    ]);
});
