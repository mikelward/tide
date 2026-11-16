// The bar's layout as the Bar page chooses it (SPEC.md §7.1, §16): which of
// its items show, and where, in three zones, left, center and right, each
// in the order you give, kept as appearance.json's barLayout. The center
// zone sits on the bar's true middle, whatever the sides hold.
//
// The items are the bar's top-level groups. The status icons are one item,
// the tray and the clocks among them, ordered within it as barIcons says
// (baricons.mjs). The pills (presenter mode, sharing, the mic) and the
// config errors aren't items: each shows only while it has something to
// say, at the start of the right zone, so a warning is never hidden or
// moved off the side.

export const ZONES = Object.freeze(["left", "center", "right"]);
export const ZONE_LABELS = Object.freeze({ left: "Left", center: "Center", right: "Right" });

// The items the Bar page lists, in today's bar's order: each one's id, the
// name the page gives it, and its zone and whether it shows unless you
// say. The ids are barsettings.mjs's names for the same items.
export const ITEMS = Object.freeze([
    Object.freeze({ id: "logo", label: "Logo", zone: "left", shown: true }),
    Object.freeze({ id: "workspaces", label: "Workspaces", zone: "left", shown: true }),
    Object.freeze({ id: "title", label: "Window title", zone: "center", shown: true }),
    Object.freeze({ id: "icons", label: "Status icons", zone: "right", shown: true }),
]);

// A stored list (barLayout) as every item of ITEMS once, [{id, label, zone,
// shown}], in the stored order: an id it doesn't know or names twice is
// dropped, a zone it doesn't know is the item's default, and an item it
// leaves out (one added since) goes in after the one it follows by
// default, or first. Anything but a list is the default.
export function layoutList(stored) {
    const known = new Map(ITEMS.map((e) => [e.id, e]));
    const out = [];
    for (const v of Array.isArray(stored) ? stored : []) {
        const e = v !== null && typeof v === "object" ? known.get(v.id) : undefined;
        if (e === undefined || out.some((o) => o.id === e.id)) {
            continue;
        }
        out.push({
            id: e.id,
            label: e.label,
            zone: ZONES.includes(v.zone) ? v.zone : e.zone,
            shown: typeof v.shown === "boolean" ? v.shown : e.shown,
        });
    }
    ITEMS.forEach((e, i) => {
        if (out.some((o) => o.id === e.id)) {
            return;
        }
        let at = 0;
        for (let j = i - 1; j >= 0; j--) {
            const found = out.findIndex((o) => o.id === ITEMS[j].id);
            if (found >= 0) {
                at = found + 1;
                break;
            }
        }
        out.splice(at, 0, { id: e.id, label: e.label, zone: e.zone, shown: e.shown });
    });
    return out;
}

// The list as barLayout stores it: [{id, zone, shown}].
export function stored(list) {
    return list.map((e) => ({ id: e.id, zone: e.zone, shown: e.shown }));
}

// The list as the Bar page shows it: by zone, left, center, right, and in
// the stored order within each.
export function byZone(list) {
    return ZONES.reduce((out, z) => out.concat(list.filter((e) => e.zone === z)), []);
}

// The page's list (byZone) with the item at `i` moved `step` places, as
// barLayout stores it, or null when that would move it off either end. A
// step past the first or last item of its zone moves it into the next
// zone, at that zone's near end, so the arrows reach every place.
export function moved(list, i, step) {
    const shown = byZone(list);
    const item = shown[i];
    if (item === undefined) {
        return null;
    }
    const zone = ZONES.indexOf(item.zone);
    const inZone = shown.filter((e) => e.zone === item.zone);
    const at = inZone.indexOf(item);
    const next = shown.slice();
    if ((step < 0 && at > 0) || (step > 0 && at < inZone.length - 1)) {
        next.splice(i, 1);
        next.splice(i + step, 0, item);
        return stored(next);
    }
    const to = zone + Math.sign(step);
    if (to < 0 || to >= ZONES.length) {
        return null;
    }
    // Into the next zone: the end of the one before, or the start of the
    // one after.
    next.splice(i, 1);
    const moved = Object.assign({}, item, { zone: ZONES[to] });
    const others = next.filter((e) => e.zone === ZONES[to]);
    let where;
    if (step < 0) {
        where = others.length > 0 ? next.indexOf(others[others.length - 1]) + 1 : next.findIndex((e) => ZONES.indexOf(e.zone) > to);
    } else {
        where = others.length > 0 ? next.indexOf(others[0]) : next.findIndex((e) => ZONES.indexOf(e.zone) > to);
    }
    next.splice(where < 0 ? next.length : where, 0, moved);
    return stored(byZone(next));
}

// The list with the item at `i` of the page's list (byZone) shown or not,
// as barLayout stores it.
export function switched(list, i, shown) {
    const item = byZone(list)[i];
    return stored(list.map((e) => (e === item ? Object.assign({}, e, { shown }) : e)));
}

// The list with the item at `i` of the page's list (byZone) in `zone`, at
// that zone's end, as barLayout stores it.
export function zoned(list, i, zone) {
    const item = byZone(list)[i];
    if (item === undefined || !ZONES.includes(zone)) {
        return null;
    }
    const rest = list.filter((e) => e !== item);
    return stored(byZone(rest.concat([Object.assign({}, item, { zone })])));
}

// The gap between two items in a zone, in px: the logo's from the
// workspaces, as the bar has always had it.
export const GAP = 8;
// The pills' gap from the item after them.
export const PILLS_GAP = 10;
// The window title keeps this far from whatever is beside it, so it never
// reads as part of a workspace or an icon.
export const TITLE_GAP = 32;

// Where each shown item goes on a bar `width` wide: `sizes` gives each id's
// width (the title's is the width it would like, its text's; one of 0 has
// nothing to show and takes no place), and `pills`
// the width of the pills group, 0 with none showing. `margin` is the room
// at the bar's left and right edges. The left zone runs from the left
// edge, the right zone ends at the right edge with the pills first, and
// the center zone is centered on the bar, moved over only as far as it
// must to clear the sides. The title takes the room its zone leaves, no
// more than it would like. Returns {x, title, pills}: each shown id's x,
// the title's width, and the pills' x.
export function placed(list, sizes, { width, pills = 0, margin = { left: 12, right: 6 } }) {
    // An item with nothing to show, 0 px wide (an empty title, say), takes
    // no place, so it leaves no gap.
    const zones = {};
    for (const z of ZONES) {
        zones[z] = list.filter((e) => e.zone === z && e.shown && (sizes[e.id] ?? 0) > 0).map((e) => e.id);
    }
    const w = (id, title) => (id === "title" ? title : Math.max(0, sizes[id] ?? 0));
    // The gap after `a` and before `b`: wider beside the title.
    const gap = (a, b) => (a === "title" || b === "title" ? TITLE_GAP : GAP);
    const span = (ids, title) => ids.reduce((sum, id, k) => sum + w(id, title) + (k > 0 ? gap(ids[k - 1], id) : 0), 0);
    // The right zone's items, then the pills before them.
    const rightSpan = (title) => span(zones.right, title) + (pills > 0 ? pills + (zones.right.length > 0 ? PILLS_GAP : 0) : 0);
    const leftEnd = (title) => margin.left + span(zones.left, title);
    const rightStart = (title) => width - margin.right - rightSpan(title);
    const has = (ids) => ids.length > 0;
    const last = (ids) => ids[ids.length - 1];
    // What the right side starts with: the pills, or the right zone's first.
    const rightFirst = pills > 0 ? "pills" : zones.right[0];
    const hasRight = rightFirst !== undefined;
    // Where the right side starts, and where the left ends.
    const rightBound = (title) => (hasRight ? rightStart(title) : width - margin.right);
    // The center's edges: how far left it may start, and how far right it
    // may end, clear of the sides by the gap its neighbors call for.
    const loEdge = (title) => (has(zones.left) ? leftEnd(title) + gap(last(zones.left), zones.center[0]) : margin.left);
    const hiEdge = (title) => rightBound(title) - (hasRight ? gap(last(zones.center), rightFirst) : 0);
    // The center's x: on the bar's middle, moved only as far as it must to
    // clear the sides; too crowded to clear both, it keeps clear of the left.
    const centerX = (title) => {
        const cw = span(zones.center, title);
        return Math.max(loEdge(title), Math.min((width - cw) / 2, hiEdge(title) - cw));
    };

    // The title's width: the most its zone leaves once the others are
    // where they'll really be, at most what it would like.
    let title = 0;
    const want = Math.max(0, sizes.title ?? 0);
    const zone = ZONES.find((z) => zones[z].includes("title"));
    if (zone === "center") {
        // The zone stays centered, so the nearer side limits it on both.
        // Its width with a title of 0 is the other items and their gaps.
        const half = Math.min(width / 2 - loEdge(0), hiEdge(0) - width / 2);
        title = 2 * half - span(zones.center, 0);
    } else if (zone === "left") {
        // Up to where the center really starts, or the right side.
        const next = has(zones.center) ? zones.center[0] : rightFirst;
        const bound = has(zones.center) ? centerX(0) : rightBound(0);
        title = bound - (next !== undefined ? gap(last(zones.left), next) : 0) - leftEnd(0);
    } else if (zone === "right") {
        // From where the center really ends, or the left side.
        const before = has(zones.center) ? last(zones.center) : last(zones.left);
        const bound = has(zones.center) ? centerX(0) + span(zones.center, 0) : (has(zones.left) ? leftEnd(0) : margin.left);
        title = rightBound(0) - (before !== undefined ? gap(before, rightFirst) : 0) - bound;
    }
    title = Math.max(0, Math.floor(Math.min(want, title)));
    // A title squeezed to nothing takes no place, as an empty one doesn't,
    // so its gaps can't push the others off the bar.
    if (zone !== undefined && title === 0) {
        zones[zone] = zones[zone].filter((id) => id !== "title");
    }

    const x = {};
    const lay = (ids, from) => {
        let at = from;
        ids.forEach((id, k) => {
            if (k > 0) {
                at += gap(ids[k - 1], id);
            }
            x[id] = at;
            at += w(id, title);
        });
    };
    lay(zones.left, margin.left);
    lay(zones.right, width - margin.right - span(zones.right, title));
    lay(zones.center, Math.round(centerX(title)));
    return { x, title, pills: rightStart(title) };
}
