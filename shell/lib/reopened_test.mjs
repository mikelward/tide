// Tests for reopened.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { NOTHING, KEEP_MS, REOPEN_MS, TITLE_MS, MAX_CLOSED, windowsChanged } from "./reopened.mjs";

const brave = (address, title, workspace) => ({ address, app: "brave-browser", title, workspace });
const term = (address, workspace) => ({ address, app: "kitty", title: "~", workspace });

// Runs each [windows, at] in turn from NOTHING, returning every move made
// and the last state.
function run(steps) {
    let state = NOTHING;
    const moves = [];
    for (const [windows, at] of steps) {
        const r = windowsChanged(state, windows, at);
        state = r.state;
        for (const m of r.moves) {
            moves.push([m.address, m.workspace]);
        }
    }
    return { state, moves };
}

const open = [brave("a", "Mail - Brave", "in"), brave("b", "Docs - Brave", "re"), term("t", "re")];

test("a browser restarting puts each window back on its workspace", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 1000],
        [[term("t", "re"), brave("c", "Mail - Brave", "oc")], 60000],
        [[term("t", "re"), brave("c", "Mail - Brave", "oc"), brave("d", "Docs - Brave", "oc")], 60500],
    ]);
    assert.deepEqual(moves, [["c", "in"], ["d", "re"]]);
});

test("windows that close and reopen one at a time go back too", () => {
    const { moves } = run([
        [open, 0],
        [[brave("b", "Docs - Brave", "re"), term("t", "re")], 100],
        [[term("t", "re")], 200],
        [[term("t", "re"), brave("c", "Docs - Brave", "oc"), brave("d", "Mail - Brave", "oc")], 5000],
    ]);
    assert.deepEqual(moves, [["c", "re"], ["d", "in"]]);
});

test("a window already on its workspace stays put", () => {
    const { moves, state } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "Docs - Brave", "re")], 2000],
    ]);
    assert.deepEqual(moves, []);
    assert.equal(state.closed.some(c => c.title === "Docs - Brave"), false, "the closed window is taken all the same");
});

test("a window that names itself once loaded goes back when its title matches", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "Brave", "oc")], 2000],
        [[term("t", "re"), brave("c", "Docs - Brave", "oc")], 2000 + TITLE_MS - 1],
    ]);
    assert.deepEqual(moves, [["c", "re"]]);
});

test("a title that comes to match too late moves nothing: you may have opened that page", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "New Tab - Brave", "oc")], 2000],
        [[term("t", "re"), brave("c", "Docs - Brave", "oc")], 2000 + TITLE_MS],
    ]);
    assert.deepEqual(moves, []);
});

test("a window moved before its title matched stays where it was moved", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "Brave", "oc")], 2000],
        [[term("t", "re"), brave("c", "Brave", "me")], 2500],
        [[term("t", "re"), brave("c", "Docs - Brave", "me")], 3000],
    ]);
    assert.deepEqual(moves, []);
});

test("a window minimized before its title matched stays minimized", () => {
    const where = (w, place) => Object.assign({}, w, { place });
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), where(brave("c", "Brave", "oc"), "oc")], 2000],
        [[term("t", "re"), where(brave("c", "Brave", "oc"), "special:minimized:oc")], 2500],
        [[term("t", "re"), where(brave("c", "Docs - Brave", "oc"), "special:minimized:oc")], 3000],
    ]);
    assert.deepEqual(moves, []);
});

test("a new window while the app has another open stays where it opens", () => {
    const { moves } = run([
        [open, 0],
        [[brave("a", "Mail - Brave", "in"), term("t", "re")], 100],
        [[brave("a", "Mail - Brave", "in"), term("t", "re"), brave("c", "Docs - Brave", "oc")], 2000],
    ]);
    assert.deepEqual(moves, [], "Ctrl+N, even with a closed window's title");
});

test("a window with a title no closed window had stays where it opens", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "New Tab - Brave", "oc")], 2000],
    ]);
    assert.deepEqual(moves, []);
});

test("windows open after the app's reopening ends stay where they open", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "Mail - Brave", "oc")], 2000],
        [[term("t", "re"), brave("c", "Mail - Brave", "oc"), brave("d", "Docs - Brave", "oc")], 2000 + REOPEN_MS],
    ]);
    assert.deepEqual(moves, [["c", "in"]]);
});

test("an app that restarts twice in a row gets a fresh reopening each time", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "Mail - Brave", "in"), brave("d", "Docs - Brave", "re")], 1000],
        [[term("t", "re")], 2000],
        [[term("t", "re"), brave("e", "Mail - Brave", "oc")], 30000],
        [[term("t", "re"), brave("e", "Mail - Brave", "oc"), brave("f", "Docs - Brave", "oc")], 32000],
    ]);
    assert.deepEqual(moves, [["e", "in"], ["f", "re"]]);
});

test("closed windows are forgotten after a while", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), brave("c", "Mail - Brave", "oc")], 100 + KEEP_MS],
    ]);
    assert.deepEqual(moves, []);
});

test("two closed windows with one title go back in the order they closed", () => {
    const { moves } = run([
        [[brave("a", "New Tab - Brave", "in"), brave("b", "New Tab - Brave", "re")], 0],
        [[brave("b", "New Tab - Brave", "re")], 100],
        [[], 200],
        [[brave("c", "New Tab - Brave", "oc")], 3000],
        [[brave("c", "New Tab - Brave", "oc"), brave("d", "New Tab - Brave", "oc")], 3100],
    ]);
    assert.deepEqual(moves, [["c", "in"], ["d", "re"]]);
});

test("the windows open when the shell starts were never closed", () => {
    const r = windowsChanged(NOTHING, open, 0);
    assert.deepEqual(r.moves, []);
    assert.deepEqual(r.state.closed, []);
    const again = windowsChanged(r.state, open.concat([brave("c", "Mail - Brave", "oc")]), 10);
    assert.deepEqual(again.moves, [], "an app's window opening beside its others");
});

test("a window on no workspace it could go back to isn't remembered", () => {
    const { state, moves } = run([
        [[brave("a", "Mail - Brave", "")], 0],
        [[], 100],
        [[brave("c", "Mail - Brave", "oc")], 2000],
    ]);
    assert.deepEqual(state.closed, []);
    assert.deepEqual(moves, []);
});

test("a window counts once it has an app", () => {
    const { moves } = run([
        [open, 0],
        [[term("t", "re")], 100],
        [[term("t", "re"), { address: "c", app: "", title: "", workspace: "oc" }], 2000],
        [[term("t", "re"), brave("c", "Mail - Brave", "oc")], 2100],
    ]);
    assert.deepEqual(moves, [["c", "in"]]);
});

test("other apps' closed windows don't move an app's", () => {
    const { moves } = run([
        [[term("t", "re"), brave("a", "Mail - Brave", "in")], 0],
        [[brave("a", "Mail - Brave", "in")], 100],
        [[brave("a", "Mail - Brave", "in"), { address: "u", app: "foot", title: "~", workspace: "oc" }], 2000],
    ]);
    assert.deepEqual(moves, []);
});

test("only the latest closed windows are remembered", () => {
    const many = [];
    for (let i = 0; i <= MAX_CLOSED; i++) {
        many.push(brave(`w${i}`, `Page ${i} - Brave`, "re"));
    }
    const { state } = run([[many, 0], [[], 100]]);
    assert.equal(state.closed.length, MAX_CLOSED);
    assert.equal(state.closed.some(c => c.title === "Page 0 - Brave"), false, "the oldest went");
});
