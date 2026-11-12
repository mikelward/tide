// The bar's status icons as the Bar page chooses them (SPEC.md §7.1, §16):
// which show, and their order, kept as appearance.json's barIcons. tide for
// macOS's bar.lua has the same list and the same rules (`icon_list`), with
// its own icons; a module both copy could take their place.

import { chainReaches } from "./barclick.mjs";

// The icons the Bar page lists, in the bar's order unless you choose
// another: each one's id, the name the page gives it, and whether it shows
// unless you say. The ids are barsettings.mjs's names for the same items.
// The pills (presenter mode, sharing, the mic) and the config errors'
// warning aren't here: each shows only while it has something to say.
export const ICONS = Object.freeze([
    Object.freeze({ id: "tray", label: "Other apps' icons", shown: true }),
    Object.freeze({ id: "keyboard", label: "Keyboard", shown: true }),
    Object.freeze({ id: "keepawake", label: "Keep awake", shown: true }),
    Object.freeze({ id: "bluetooth", label: "Bluetooth", shown: true }),
    Object.freeze({ id: "headphones", label: "Headphones", shown: true }),
    Object.freeze({ id: "network", label: "Network", shown: true }),
    Object.freeze({ id: "volume", label: "Sound", shown: true }),
    Object.freeze({ id: "battery", label: "Battery", shown: true }),
    Object.freeze({ id: "sysmon", label: "System monitor", shown: true }),
    Object.freeze({ id: "notifications", label: "Notifications", shown: true }),
    Object.freeze({ id: "session", label: "Lock and power", shown: true }),
    Object.freeze({ id: "clocks", label: "Clocks", shown: true }),
]);

// A stored list (barIcons) as every icon of ICONS once, [{id, label,
// shown}], in the stored order: an id it doesn't know or names twice is
// dropped, and an icon it leaves out (one added since) goes in after the
// one it follows by default, or first. Anything but a list is the default.
export function iconList(stored) {
    const known = new Map(ICONS.map((e) => [e.id, e]));
    const out = [];
    for (const v of Array.isArray(stored) ? stored : []) {
        const e = v !== null && typeof v === "object" ? known.get(v.id) : undefined;
        if (e === undefined || out.some((o) => o.id === e.id)) {
            continue;
        }
        out.push({ id: e.id, label: e.label, shown: typeof v.shown === "boolean" ? v.shown : e.shown });
    }
    ICONS.forEach((e, i) => {
        if (out.some((o) => o.id === e.id)) {
            return;
        }
        let at = 0;
        for (let j = i - 1; j >= 0; j--) {
            const found = out.findIndex((o) => o.id === ICONS[j].id);
            if (found >= 0) {
                at = found + 1;
                break;
            }
        }
        out.splice(at, 0, { id: e.id, label: e.label, shown: e.shown });
    });
    return out;
}

// The list as barIcons stores it: [{id, shown}].
export function stored(list) {
    return list.map((e) => ({ id: e.id, shown: e.shown }));
}

// The list with the icon at `i` moved `step` places, as barIcons stores
// it, or null when that would move it off either end.
export function moved(list, i, step) {
    const to = i + step;
    if (i < 0 || i >= list.length || to < 0 || to >= list.length) {
        return null;
    }
    const next = list.slice();
    const [e] = next.splice(i, 1);
    next.splice(to, 0, e);
    return stored(next);
}

// The list with the icon at `i` shown or not, as barIcons stores it.
export function switched(list, i, shown) {
    return stored(list.map((e, j) => (j === i ? Object.assign({}, e, { shown }) : e)));
}

// The status icons' gap, in px (§7.4).
export const GAP = 10;
// How far past the last icon the group ends, less the room it keeps inside.
export const END = 5;
// Room an item keeps inside its own edges, which counts toward the gap:
// the clocks' 5 px either side of their text. The tray's is less than
// none, so it sits 14 px from the icons beside it.
export const INSETS = Object.freeze({ clocks: 5, tray: -4 });

// Where each item goes, left to right, in `order` (ids): `items` gives
// each id's {width, shown}, and `reach` how far the group's ends reach past
// it ({left, right}, Bar.qml's). An item that's hidden or 0 px wide takes
// no room. Returns {x, reach, width}: each id's x and click reach
// (barclick.mjs's), and the group's width.
export function arranged(order, items, reach = { left: 0, right: 0 }) {
    const x = {};
    let at = 0;
    let last = null;
    for (const id of order) {
        const item = items[id];
        if (!item || !item.shown || !(item.width > 0)) {
            x[id] = at;
            continue;
        }
        if (last !== null) {
            at += Math.max(0, GAP - (INSETS[last] ?? 0) - (INSETS[id] ?? 0));
        }
        x[id] = at;
        at += item.width;
        last = id;
    }
    const width = last === null ? 0 : at + Math.max(0, END - Math.max(0, INSETS[last] ?? 0));
    const spans = order.map((id) => ({
        left: x[id],
        right: x[id] + (items[id]?.width ?? 0),
        shown: Boolean(items[id]?.shown),
    }));
    const reaches = chainReaches(spans, { start: -reach.left, end: width + reach.right });
    const reachOf = {};
    order.forEach((id, i) => {
        reachOf[id] = reaches[i];
    });
    return { x, reach: reachOf, width };
}
