// Tests for barlayout.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ITEMS, layoutList, stored, byZone, moved, switched, zoned, placed, GAP, PILLS_GAP, TITLE_GAP } from "./barlayout.mjs";

const ids = (list) => list.map((e) => `${e.id}:${e.zone}${e.shown ? "" : ":off"}`);

test("with nothing stored, the bar is today's: logo and workspaces left, the title centered, the icons right", () => {
    assert.deepEqual(ids(layoutList(undefined)), ["logo:left", "workspaces:left", "title:center", "icons:right"]);
    assert.deepEqual(layoutList(null).map((e) => e.label), ITEMS.map((e) => e.label));
});

test("a stored layout keeps its order and zones, and makes itself whole", () => {
    const list = layoutList([
        { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: false },
        { id: "bogus", zone: "left", shown: true },
        { id: "workspaces", zone: "right", shown: true },
        { id: "icons", zone: "middle", shown: true },
    ]);
    assert.deepEqual(ids(list), ["logo:left", "workspaces:center", "title:center:off", "icons:right"],
        "an unknown id and a repeat dropped, an unknown zone the default, the missing logo first");
});

test("the page lists the items by zone, and the arrows move them through every place", () => {
    let list = layoutList(undefined);
    // Workspaces down: past the end of left, into center, before the title.
    list = layoutList(moved(list, 1, 1));
    assert.deepEqual(ids(byZone(list)), ["logo:left", "workspaces:center", "title:center", "icons:right"]);
    // Down again: after the title, still center.
    list = layoutList(moved(list, 1, 1));
    assert.deepEqual(ids(byZone(list)), ["logo:left", "title:center", "workspaces:center", "icons:right"]);
    // Down again: into right, before the icons.
    list = layoutList(moved(list, 2, 1));
    assert.deepEqual(ids(byZone(list)), ["logo:left", "title:center", "workspaces:right", "icons:right"]);
    // Up from the icons: past the workspaces.
    list = layoutList(moved(list, 3, -1));
    assert.deepEqual(ids(byZone(list)), ["logo:left", "title:center", "icons:right", "workspaces:right"]);
    // The logo up, and the last item down, go nowhere.
    assert.equal(moved(list, 0, -1), null);
    assert.equal(moved(list, 3, 1), null);
    assert.equal(moved(list, 9, 1), null);
});

test("an item moves into an empty zone", () => {
    let list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "left", shown: true },
        { id: "title", zone: "right", shown: true }, { id: "icons", zone: "right", shown: true }]);
    list = layoutList(moved(list, 1, 1));
    assert.deepEqual(ids(byZone(list)), ["logo:left", "workspaces:center", "title:right", "icons:right"]);
});

test("an item goes into a zone, at its end, and shows or hides", () => {
    let list = layoutList(undefined);
    list = layoutList(zoned(list, 1, "center"));
    assert.deepEqual(ids(byZone(list)), ["logo:left", "title:center", "workspaces:center", "icons:right"]);
    list = layoutList(switched(list, 1, false));
    assert.deepEqual(ids(byZone(list)), ["logo:left", "title:center:off", "workspaces:center", "icons:right"]);
    assert.equal(zoned(list, 1, "top"), null);
    assert.deepEqual(stored(list)[0], { id: "logo", zone: "left", shown: true });
});

const SIZES = { logo: 20, workspaces: 300, title: 400, icons: 500 };

test("today's layout: the title centered on the bar, the icons ending at its right edge", () => {
    const p = placed(layoutList(undefined), SIZES, { width: 1920 });
    assert.equal(p.x.logo, 12);
    assert.equal(p.x.workspaces, 12 + 20 + GAP);
    assert.equal(p.title, 400);
    assert.equal(p.x.title, (1920 - 400) / 2, "on the bar's true middle");
    assert.equal(p.x.icons, 1920 - 6 - 500);
    assert.equal(p.pills, p.x.icons, "no pills: they'd start where the icons do");
});

test("the workspaces centered, the title hidden: the workspaces on the bar's middle", () => {
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: false }, { id: "icons", zone: "right", shown: true }]);
    const p = placed(list, SIZES, { width: 1920 });
    assert.equal(p.x.workspaces, (1920 - 300) / 2);
    assert.equal(p.x.title, undefined, "a hidden item has no place");
    assert.equal(p.title, 0);
});

test("the workspaces and the title both centered: the workspaces end at the middle, the title starts there", () => {
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: true }, { id: "icons", zone: "right", shown: true }]);
    const p = placed(list, SIZES, { width: 1920 });
    assert.equal(p.x.workspaces + 300, 960 - TITLE_GAP / 2, "the workspaces end at the middle");
    assert.equal(p.x.title, 960 + TITLE_GAP / 2, "the title starts there");
});

test("three centered: the middle one on the middle, the others either side", () => {
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: true }, { id: "icons", zone: "center", shown: true }]);
    const p = placed(list, { logo: 20, workspaces: 300, title: 400, icons: 200 }, { width: 1920 });
    assert.equal(p.x.title + 400 / 2, 960, "the title centered");
    assert.equal(p.x.workspaces + 300 + TITLE_GAP, p.x.title, "the workspaces to its left");
    assert.equal(p.x.icons, p.x.title + 400 + TITLE_GAP, "the icons to its right");
});

test("a center half too wide for its side moves the zone, and the title takes what's left", () => {
    // Codex's case: wide workspaces, then the title, centered.
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: true }, { id: "icons", zone: "right", shown: true }]);
    const p = placed(list, { logo: 20, workspaces: 700, title: 400, icons: 200 }, { width: 1280 });
    assert.ok(p.x.title + p.title + TITLE_GAP <= p.x.icons, "the title clears the icons");
    assert.equal(p.x.workspaces, 12 + 20 + GAP, "the workspaces moved over as far as the left lets them");
    assert.equal(p.x.title + p.title + TITLE_GAP, p.x.icons, "and the title fills the rest");
});

test("a long title in the center's second half is cut where the right side starts", () => {
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: true }, { id: "icons", zone: "right", shown: true }]);
    const p = placed(list, Object.assign({}, SIZES, { title: 5000 }), { width: 1920 });
    assert.equal(p.x.workspaces + 300, 960 - TITLE_GAP / 2, "the workspaces still end at the middle");
    assert.equal(p.x.title + p.title, 1920 - 6 - 500 - TITLE_GAP, "the title runs up to the icons' gap");
});

test("a long centered title is cut to stay centered between the sides", () => {
    const p = placed(layoutList(undefined), Object.assign({}, SIZES, { title: 5000 }), { width: 1920 });
    const leftEnd = 12 + 20 + GAP + 300;
    const rightStart = 1920 - 6 - 500;
    const half = Math.min(960 - leftEnd - TITLE_GAP, rightStart - 960 - TITLE_GAP);
    assert.equal(p.title, Math.floor(2 * half));
    assert.equal(p.x.title, Math.round((1920 - p.title) / 2));
});

test("a title on the left fills only the room up to the center", () => {
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "title", zone: "left", shown: true },
        { id: "workspaces", zone: "center", shown: true }, { id: "icons", zone: "right", shown: true }]);
    const p = placed(list, Object.assign({}, SIZES, { title: 5000 }), { width: 1920 });
    assert.equal(p.x.title, 12 + 20 + TITLE_GAP);
    assert.ok(p.x.title + p.title + GAP <= p.x.workspaces, "clear of the centered workspaces");
    assert.equal(p.x.workspaces, (1920 - 300) / 2, "which stay centered");
});

test("the pills come first in the right zone, or at the right edge with it empty", () => {
    let p = placed(layoutList(undefined), SIZES, { width: 1920, pills: 80 });
    assert.equal(p.pills, 1920 - 6 - 500 - PILLS_GAP - 80);
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "left", shown: true },
        { id: "title", zone: "center", shown: true }, { id: "icons", zone: "left", shown: true }]);
    p = placed(list, SIZES, { width: 1920, pills: 80 });
    assert.equal(p.pills, 1920 - 6 - 80);
});

test("a crowded center moves over only as far as it must, and keeps clear of the left", () => {
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: false }, { id: "icons", zone: "right", shown: true }]);
    // Wide icons push the centered workspaces left.
    let p = placed(list, Object.assign({}, SIZES, { icons: 900 }), { width: 1920 });
    assert.equal(p.x.workspaces, 1920 - 6 - 900 - GAP - 300);
    // With no room on either side, clear of the left.
    p = placed(list, Object.assign({}, SIZES, { icons: 1700 }), { width: 1920 });
    assert.equal(p.x.workspaces, 12 + 20 + GAP);
});

test("an item with nothing to show, an empty title say, leaves no gap", () => {
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: true }, { id: "icons", zone: "right", shown: true }]);
    const p = placed(list, Object.assign({}, SIZES, { title: 0 }), { width: 1920 });
    assert.equal(p.x.workspaces, (1920 - 300) / 2, "centered alone, with no title gap beside it");
    assert.equal(p.x.title, undefined);
});

test("a title beside a centered zone that the other side pushes over leaves the center room", () => {
    // Codex's case: wide icons push the centered workspaces left, and the
    // title on the left stops short of where they really are.
    const left = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "title", zone: "left", shown: true },
        { id: "workspaces", zone: "center", shown: true }, { id: "icons", zone: "right", shown: true }]);
    const sizes = { logo: 20, title: 400, workspaces: 300, icons: 600 };
    let p = placed(left, sizes, { width: 1280 });
    assert.ok(p.x.workspaces + 300 + GAP <= p.x.icons, "the workspaces clear the icons");
    assert.ok(p.x.title + p.title + TITLE_GAP <= p.x.workspaces, "and the title clears the workspaces");
    // The mirror: wide left side, title on the right.
    const right = layoutList([{ id: "icons", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "right", shown: true }, { id: "logo", zone: "right", shown: true }]);
    p = placed(right, sizes, { width: 1280 });
    assert.ok(p.x.icons + 600 + GAP <= p.x.workspaces, "the workspaces clear the icons");
    assert.ok(p.x.workspaces + 300 + TITLE_GAP <= p.x.title, "and the title clears the workspaces");
    assert.ok(p.x.title + p.title + TITLE_GAP <= p.x.logo, "and the logo after it");
});

test("a title squeezed to nothing leaves no gaps that push the others off the bar", () => {
    // Codex's case: everything but the logo centered, the icons wide.
    const list = layoutList([{ id: "logo", zone: "left", shown: true }, { id: "workspaces", zone: "center", shown: true },
        { id: "title", zone: "center", shown: true }, { id: "icons", zone: "center", shown: true }]);
    const p = placed(list, { logo: 20, workspaces: 300, title: 400, icons: 900 }, { width: 1280 });
    assert.equal(p.title, 0);
    assert.equal(p.x.title, undefined, "no place, so no gaps");
    assert.ok(p.x.icons + 900 <= 1280, "the icons stay on the bar");
    assert.equal(p.x.icons, p.x.workspaces + 300 + GAP, "beside the workspaces, as with the title hidden");
});
