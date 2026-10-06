// Tests for tray.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { shownItems, clickAction, menuRows, rowClick } from "./tray.mjs";

const PASSIVE = 0;
const ACTIVE = 1;
const ATTENTION = 2;

test("passive items are hidden, the rest keep their order", () => {
    const items = [{ id: "a", status: ACTIVE }, { id: "b", status: PASSIVE }, { id: "c", status: ATTENTION }];
    assert.deepEqual(shownItems(items, PASSIVE).map(i => i.id), ["a", "c"]);
    assert.deepEqual(shownItems([], PASSIVE), []);
});

test("a left or right click opens the menu, as §7.4 says", () => {
    const item = { hasMenu: true, onlyMenu: false };
    assert.equal(clickAction("left", item), "menu");
    assert.equal(clickAction("right", item), "menu");
});

test("a middle click activates the app", () => {
    assert.equal(clickAction("middle", { hasMenu: true, onlyMenu: false }), "activate");
});

test("without a menu, a left click activates and a right click is the secondary action", () => {
    const item = { hasMenu: false, onlyMenu: false };
    assert.equal(clickAction("left", item), "activate");
    assert.equal(clickAction("right", item), "secondary");
});

test("other buttons do nothing", () => {
    assert.equal(clickAction("back", { hasMenu: true, onlyMenu: false }), null);
});

// A QsMenuEntry as Quickshell gives it, for menuRows.
function entry(text, props = {}) {
    return {
        isSeparator: false,
        text: text,
        icon: "",
        enabled: true,
        buttonType: 0,
        checkState: 0,
        hasChildren: false,
        ...props,
    };
}
const SEPARATOR = { isSeparator: true };

test("a menu row carries its entry's label, icon and state", () => {
    const quit = entry("Quit", { icon: "image://icon/application-exit" });
    const [row] = menuRows([quit]);
    assert.equal(row.separator, false);
    assert.equal(row.entry, quit);
    assert.equal(row.label, "Quit");
    assert.equal(row.icon, "image://icon/application-exit");
    assert.equal(row.enabled, true);
    assert.equal(row.checked, false);
    assert.equal(row.submenu, false);
});

test("a checkbox or radio entry is checked only when it's fully checked", () => {
    const rows = menuRows([
        entry("Wi-Fi", { buttonType: 1, checkState: 2 }),
        entry("Bluetooth", { buttonType: 1, checkState: 0 }),
        entry("Balanced", { buttonType: 2, checkState: 2 }),
        entry("Some", { buttonType: 1, checkState: 1 }),
        // A plain entry's check state means nothing.
        entry("Plain", { checkState: 2 }),
    ]);
    assert.deepEqual(rows.map(r => r.checked), [true, false, true, false, false]);
});

test("separators stay only between entries", () => {
    const rows = menuRows([SEPARATOR, entry("a"), SEPARATOR, SEPARATOR, entry("b"), SEPARATOR]);
    assert.deepEqual(rows.map(r => r.separator ? "-" : r.label), ["a", "-", "b"]);
    assert.deepEqual(menuRows([SEPARATOR, SEPARATOR]), []);
    assert.deepEqual(menuRows([]), []);
});

test("a click opens a submenu, triggers an entry, and does nothing on a disabled row or a separator", () => {
    const [submenu, item, disabled, , last] = menuRows([
        entry("VPN Connections", { hasChildren: true }),
        entry("Quit"),
        entry("Unavailable", { enabled: false }),
        SEPARATOR,
        entry("About"),
    ]);
    assert.equal(rowClick(submenu), "open");
    assert.equal(rowClick(item), "trigger");
    assert.equal(rowClick(disabled), null);
    assert.equal(rowClick({ separator: true }), null);
    assert.equal(rowClick(last), "trigger");
});
