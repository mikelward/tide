// Tests for baricons.mjs, and that the bar draws every icon it lists.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { END, GAP, ICONS, arranged, iconList, moved, stored, switched } from "./baricons.mjs";
import { BAR_SETTINGS } from "./barsettings.mjs";

const SHELL = join(dirname(fileURLToPath(import.meta.url)), "..");
const ids = (list) => list.map((e) => e.id);
const DEFAULT_IDS = ids(ICONS);

test("with nothing stored, every icon shows, in the bar's order, the clocks last", () => {
    for (const nothing of [undefined, null, "network", {}, []]) {
        const list = iconList(nothing);
        assert.deepEqual(ids(list), DEFAULT_IDS);
        assert.ok(list.every((e) => e.shown), JSON.stringify(nothing));
    }
    assert.equal(DEFAULT_IDS[DEFAULT_IDS.length - 1], "clocks");
    assert.equal(DEFAULT_IDS[0], "tray");
});

// The ids are the bar items' own names, but for the tray, whose right-click
// is the app's menu, and the audio devices, which open Bluetooth's page.
test("each icon has a name for the page, and is named as the bar names it", () => {
    for (const e of ICONS) {
        assert.ok(e.label !== "", e.id);
        assert.ok(["tray", "headphones"].includes(e.id) || Object.prototype.hasOwnProperty.call(BAR_SETTINGS, e.id),
            `${e.id} isn't a bar item`);
    }
    assert.equal(new Set(ICONS.map((e) => e.id)).size, ICONS.length, "each once");
});

test("a stored list keeps its order and what it turned off", () => {
    const list = iconList([{ id: "clocks", shown: true }, { id: "network", shown: false }].concat(
        DEFAULT_IDS.filter((id) => id !== "clocks" && id !== "network").map((id) => ({ id, shown: true }))));
    assert.deepEqual(ids(list).slice(0, 2), ["clocks", "network"]);
    assert.equal(list[1].shown, false);
    assert.equal(list[1].label, "Network");
    assert.equal(list.length, ICONS.length);
});

test("an id it doesn't know, or names twice, is dropped", () => {
    const list = iconList([{ id: "gone", shown: true }, { id: "battery", shown: false }, { id: "battery", shown: true }, null, "volume"]);
    assert.equal(list.filter((e) => e.id === "battery").length, 1);
    assert.equal(list.find((e) => e.id === "battery").shown, false, "the first one counts");
    assert.ok(!ids(list).includes("gone"));
    assert.deepEqual([...ids(list)].sort(), [...DEFAULT_IDS].sort());
});

test("an icon added since goes in after the one it follows by default", () => {
    // A list from before Notifications, moved around: it lands after the
    // system monitor wherever that went, and the tray, with nothing before
    // it, goes first.
    const old = ["clocks", "sysmon", "session", "keyboard", "keepawake", "bluetooth", "headphones", "network", "volume", "battery"];
    const list = iconList(old.map((id) => ({ id, shown: true })));
    assert.deepEqual(ids(list), ["tray", "clocks", "sysmon", "notifications", "session", "keyboard", "keepawake",
        "bluetooth", "headphones", "network", "volume", "battery"]);
});

test("↑ and ↓ move an icon one place, and not off either end", () => {
    const list = iconList(null);
    const up = moved(list, 1, -1);
    assert.deepEqual(ids(up).slice(0, 2), ["keyboard", "tray"]);
    assert.deepEqual(Object.keys(up[0]).sort(), ["id", "shown"], "as barIcons stores it");
    assert.deepEqual(ids(moved(list, 0, 1)).slice(0, 2), ["keyboard", "tray"]);
    assert.equal(moved(list, 0, -1), null);
    assert.equal(moved(list, list.length - 1, 1), null);
});

test("the switch turns one icon on or off, and the list stays whole", () => {
    const list = iconList(null);
    const off = iconList(switched(list, 5, false));
    assert.equal(off[5].id, "network");
    assert.equal(off[5].shown, false);
    assert.equal(off.filter((e) => !e.shown).length, 1);
    assert.equal(iconList(switched(off, 5, true))[5].shown, true);
    assert.deepEqual(stored(list).map((e) => e.id), DEFAULT_IDS);
});

test("icons sit GAP apart, the clocks' own room counted, and hidden or empty ones take none", () => {
    const items = {
        config: { width: 16, shown: false },
        tray: { width: 0, shown: true },
        network: { width: 16, shown: true },
        volume: { width: 40, shown: false },
        session: { width: 16, shown: true },
        clocks: { width: 100, shown: true },
    };
    const order = ["config", "tray", "network", "volume", "session", "clocks"];
    const a = arranged(order, items);
    assert.equal(a.x.network, 0);
    assert.equal(a.x.session, 16 + GAP);
    // The clocks keep 5 px inside, so their text is GAP from the session icon.
    assert.equal(a.x.clocks, 16 + GAP + 16 + GAP - 5);
    assert.equal(a.width, a.x.clocks + 100, "the clocks' own room ends the group");
    const moved = arranged(["clocks", "network", "session"], items);
    assert.equal(moved.x.network, 100 + GAP - 5);
    assert.equal(moved.width, moved.x.session + 16 + END, "the group ends as far past the last icon");
});

test("the tray sits 4 px further from its neighbors", () => {
    const items = { tray: { width: 44, shown: true }, network: { width: 16, shown: true } };
    assert.equal(arranged(["tray", "network"], items).x.network, 44 + GAP + 4);
    const last = arranged(["network", "tray"], items);
    assert.equal(last.width, last.x.tray + 44 + END, "but ends the bar as an icon does");
});

test("neighbors split the gap between them, and the ends reach the group's reach", () => {
    const items = { network: { width: 16, shown: true }, volume: { width: 0, shown: true }, session: { width: 16, shown: true } };
    const a = arranged(["network", "volume", "session"], items, { left: 3, right: 7 });
    assert.deepEqual(a.reach.network, { left: 3, right: GAP / 2 });
    assert.deepEqual(a.reach.session, { left: GAP / 2, right: END + 7 });
    assert.deepEqual(a.reach.volume, { left: 0, right: 0 });
});

// Each icon in the list is an item StatusIcons.qml places by its id.
test("the bar places every icon the page lists", () => {
    const qml = readFileSync(join(SHELL, "StatusIcons.qml"), "utf8");
    for (const id of DEFAULT_IDS) {
        assert.match(qml, new RegExp(`x: root\\.geometry\\.x\\.${id}\\b`), id);
    }
});

// In a binding on StatusIcons' root, a name finds the root's own property
// before an item's id, so an item measured there by a name the root also
// has (UPower's `battery`, say) measures the wrong thing.
test("the bar measures each icon's item, not a property of the same name", () => {
    const qml = readFileSync(join(SHELL, "StatusIcons.qml"), "utf8");
    // Each first group of re's matches, without matchAll, which the QML
    // engine (and qtjs_env_test.mjs) lacks.
    const all = (re) => {
        const found = [];
        for (let m = re.exec(qml); m !== null; m = re.exec(qml)) {
            found.push(m[1]);
        }
        return found;
    };
    const measured = all(/root\.size\((\w+)\)/g);
    const itemIds = new Set(all(/^\s+id: (\w+)$/gm));
    const rootProps = new Set(all(/^    (?:readonly )?property \w+ (\w+)/gm));
    assert.ok(measured.length >= DEFAULT_IDS.length);
    for (const name of measured) {
        assert.ok(itemIds.has(name), `${name} is an item's id`);
        assert.ok(!rootProps.has(name), `${name} isn't also a property of StatusIcons' root`);
    }
});
