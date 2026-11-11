// Tests for kwin.mjs. The busctl output is what a headless KWin 6.7.5
// (kwin_wayland --virtual) gave with two foot windows open.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    DESKTOPS_COMMAND, WINDOWS_COMMAND, infoCommand, activateCommand, goCommand, jsonLines, parseDesktops, parseWindows, parseInfo,
    launcherWindows, launcherWorkspaces,
} from "./kwin.mjs";

const D1 = "12ff2cac-c6ec-42cb-870c-68a2adeded1d";
const D2 = "273bc6e9-9299-4472-b72c-32c21d557888";
const SHELL = "{23a4241e-349c-4fbc-8e69-4f6eee306b85}";
const FIREFOX = "{787c1260-89a6-49e7-9dab-7918b3938dbd}";

const DESKTOPS = `{"type":"a(uss)","data":[[1,"${D2}","re"],[0,"${D1}","in"]]}
{"type":"s","data":"${D1}"}
`;

const MATCH = `{"type":"a(sssida{sv})","data":[[["0_${SHELL}","shell","wayland",100,8.000000000000000444089e-01,{"subtext":{"type":"s","data":"Activate running window on in"}}],["0_${FIREFOX}","Some page — Firefox","wayland",100,8.000000000000000444089e-01,{"subtext":{"type":"s","data":"Activate running window on re"}}],["0_${SHELL}","shell","wayland",30,5.000000000000000000000e-01,{"subtext":{"type":"s","data":"Activate running window on in"}}],["8_${D2}","re","user-desktop",30,5.000000000000000000000e-01,{}]]]}
`;

function info(app, desktops, extra = "") {
    return `{"type":"a{sv}","data":[{"uuid":{"type":"s","data":"x"},"caption":{"type":"s","data":"x"},"desktopFile":{"type":"s","data":"${app}"},"desktops":{"type":"as","data":${JSON.stringify(desktops)}},"resourceClass":{"type":"s","data":"${app}-class"}${extra}}]}`;
}

test("the commands are KWin's own D-Bus, through busctl", () => {
    assert.deepEqual([...DESKTOPS_COMMAND], ["busctl", "--user", "--json=short", "get-property", "org.kde.KWin", "/VirtualDesktopManager",
        "org.kde.KWin.VirtualDesktopManager", "desktops", "current"]);
    assert.equal(WINDOWS_COMMAND[WINDOWS_COMMAND.length - 3], "Match");
    assert.deepEqual(infoCommand([SHELL]).slice(-2), ["sh", SHELL]);
    assert.deepEqual(activateCommand(`0_${SHELL}`).slice(-4), ["Run", "ss", `0_${SHELL}`, ""]);
    assert.deepEqual(goCommand(D2).slice(-3), ["current", "s", D2]);
});

test("desktops come in KWin's order, with the current one", () => {
    assert.deepEqual(parseDesktops(DESKTOPS), { desktops: [{ id: D1, name: "in" }, { id: D2, name: "re" }], current: D1 });
});

test("each window is listed once, though the runner matches it twice, and desktops aren't windows", () => {
    assert.deepEqual(parseWindows(MATCH), [
        { match: `0_${SHELL}`, uuid: SHELL, title: "shell" },
        { match: `0_${FIREFOX}`, uuid: FIREFOX, title: "Some page — Firefox" },
    ]);
    assert.deepEqual(parseWindows(`{"type":"a(sssida{sv})","data":[[]]}`), []);
});

test("a window's app is its desktop file, else its class, and a gone one is left out", () => {
    const text = [info("kitty", [D1]), '{"type":"a{sv}","data":[{}]}', info("", [D2])].join("\n");
    const out = parseInfo(text, [SHELL, "{gone}", FIREFOX]);
    assert.deepEqual(out[SHELL], { app: "kitty", desktops: [D1], skip: false });
    assert.equal(out["{gone}"], undefined);
    assert.equal(out[FIREFOX].app, "-class");
});

test("output that isn't JSON is an error saying so", () => {
    assert.throws(() => jsonLines("Failed to connect to bus"), /isn't JSON: Failed to connect to bus/);
});

test("the Windows tab lists each window with its app and desktop", () => {
    const { desktops } = parseDesktops(DESKTOPS);
    const windows = parseWindows(MATCH);
    const infos = parseInfo([info("kitty", [D1]), info("firefox", [D2])].join("\n"), [SHELL, FIREFOX]);
    assert.deepEqual(launcherWindows(windows, infos, desktops), [
        { address: `0_${SHELL}`, title: "shell", app: "kitty", workspace: "in", urgent: false, focus: 0 },
        { address: `0_${FIREFOX}`, title: "Some page — Firefox", app: "firefox", workspace: "re", urgent: false, focus: 1 },
    ]);
});

test("a window on every desktop names none, and one kept from switchers isn't listed", () => {
    const windows = parseWindows(MATCH);
    const infos = parseInfo([info("kitty", []), info("firefox", [D2], ',"skipSwitcher":{"type":"b","data":true}')].join("\n"),
        [SHELL, FIREFOX]);
    assert.deepEqual(launcherWindows(windows, infos, []).map((w) => [w.title, w.workspace]), [["shell", ""]]);
});

test("the Workspaces tab lists every desktop, current first by state", () => {
    const { desktops, current } = parseDesktops(DESKTOPS);
    const windows = parseWindows(MATCH);
    const infos = parseInfo([info("kitty", [D1]), info("firefox", [D2])].join("\n"), [SHELL, FIREFOX]);
    const list = launcherWorkspaces(desktops.concat([{ id: "d3", name: "oc" }]), current, windows, infos);
    assert.deepEqual(list.map((w) => [w.name, w.state, w.count, w.app, w.desktop]), [
        ["in", "current", 1, "kitty", D1],
        ["re", "occupied", 1, "firefox", D2],
        ["oc", "empty", 0, "", "d3"],
    ]);
});

test("a window on every desktop counts on each", () => {
    const { desktops, current } = parseDesktops(DESKTOPS);
    const windows = parseWindows(MATCH);
    const infos = parseInfo([info("kitty", []), info("firefox", [D2])].join("\n"), [SHELL, FIREFOX]);
    assert.deepEqual(launcherWorkspaces(desktops, current, windows, infos).map((w) => w.count), [1, 2]);
});
