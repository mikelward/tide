// Tests for overview.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { groups, filtered, cards, startAt, choice, shotFile, shotsCommand } from "./overview.mjs";

const win = (address, workspace, workspaceName, extra = {}) => ({
    address, workspace, workspaceName, title: `Window ${address}`, app: "foot",
    monitor: "DP-1", floating: false, identifier: "", ...extra,
});
const workspaces = [{ id: 1, name: "in" }, { id: 2, name: "re" }, { id: 3, name: "web" }];
const names = list => list.map(g => [g.name, g.windows.map(w => w.address)]);

test("the current workspace comes first, then the bar's order, and empty ones are left out", () => {
    const list = groups({
        workspaces, standing: ["in", "re", "web"], current: 3,
        windows: [win("a", 1, "in"), win("b", 3, "web"), win("c", 1, "in")],
    });
    assert.deepEqual(names(list), [["web", ["b"]], ["in", ["a", "c"]]]);
    assert.deepEqual(list.map(g => g.current), [true, false]);
});

test("each monitor's tiled windows come before its floating ones, monitor by monitor", () => {
    const list = groups({
        workspaces, current: 1, monitors: ["DP-1", "HDMI-A-1"],
        windows: [
            win("float1", 1, "in", { floating: true }),
            win("other", 1, "in", { monitor: "HDMI-A-1" }),
            win("gone", 1, "in", { monitor: "DP-9" }),
            win("tile1", 1, "in"),
        ],
    });
    assert.deepEqual(names(list), [["in", ["tile1", "float1", "other", "gone"]]]);
});

test("a minimized window is in the group of the workspace it came from, marked", () => {
    const list = groups({
        workspaces, current: 1,
        windows: [win("a", 1, "in"), win("m", null, "special:minimized:re")],
    });
    assert.deepEqual(names(list), [["in", ["a"]], ["re", ["m"]]]);
    assert.equal(list[1].windows[0].minimized, true);
    assert.deepEqual(choice(list[1].windows[0]), { restore: "m", to: "re" });
    assert.deepEqual(choice(list[0].windows[0]), { focus: "a" });
});

test("a workspace spanning monitors is one group", () => {
    const list = groups({
        workspaces: [{ id: 1, name: "in" }, { id: 4, name: "in@HDMI-A-1" }], current: 4,
        monitors: ["DP-1", "HDMI-A-1"],
        windows: [win("left", 1, "in"), win("right", 4, "in@HDMI-A-1", { monitor: "HDMI-A-1" })],
    });
    assert.deepEqual(names(list), [["in", ["left", "right"]]]);
    assert.equal(list[0].current, true);
});

test("typing keeps the cards whose title or app matches, and says where", () => {
    const list = groups({
        workspaces, current: 1,
        windows: [win("a", 1, "in", { title: "Inbox" }), win("b", 2, "re", { app: "firefox", title: "News" })],
    });
    const fire = filtered(list, "fire", app => (app === "firefox" ? "Firefox" : ""));
    assert.deepEqual(names(fire), [["re", ["b"]]]);
    assert.deepEqual(fire[0].windows[0].appAt, [0, 1, 2, 3]);
    assert.deepEqual(fire[0].windows[0].titleAt, []);
    assert.equal(fire[0].windows[0].appName, "Firefox");
    const inbox = filtered(list, "inb");
    assert.deepEqual(inbox[0].windows[0].titleAt, [0, 1, 2]);
    assert.deepEqual(names(filtered(list, "")), names(list));
    assert.deepEqual(filtered(list, "zzz"), []);
});

test("the selection starts on the focused window, else the first", () => {
    const list = groups({ workspaces, current: 2, windows: [win("a", 1, "in"), win("b", 2, "re")] });
    assert.deepEqual(cards(list).map(w => w.address), ["b", "a"]);
    assert.equal(startAt(list, "a"), 1);
    assert.equal(startAt(list, "nope"), 0);
    assert.equal(startAt(list, null), 0);
});

test("a minimized window whose workspace has gone still has a group, after the bar's", () => {
    const list = groups({
        workspaces, current: 1,
        windows: [win("a", 1, "in"), win("n", null, "special:minimized:notes"), win("z", null, "special:minimized:Notes")],
    });
    assert.deepEqual(names(list), [["in", ["a"]], ["notes", ["n", "z"]]]);
    assert.deepEqual(choice(list[1].windows[0]), { restore: "n", to: "notes" });
});

test("tidewm's pictures are taken at once with grim -T, only for identifiers a file name can hold", () => {
    assert.equal(shotFile("/run/user/1000/tide/overview", "0123abcd"), "/run/user/1000/tide/overview/0123abcd.jpg");
    assert.equal(shotFile("/run/x", "../etc"), null);
    assert.equal(shotFile("/run/x", ""), null);
    assert.equal(shotFile("", "abc"), null);
    assert.equal(shotsCommand("/run/x", ["a/b", ""]), null);
    const c = shotsCommand("/run/x", ["abc", "../x", "def"]);
    assert.deepEqual(c.slice(3), ["sh", "/run/x", "abc", "def"]);
    assert.match(c[2], /grim -T "\$id" -t jpeg "\$f"/);
});

test("a failed or closed window leaves no old picture behind, and the command says one failed", async () => {
    const { mkdtempSync, writeFileSync, chmodSync, existsSync, readFileSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const { spawnSync } = await import("node:child_process");
    const tmp = mkdtempSync(join(tmpdir(), "overview-"));
    const bin = join(tmp, "bin");
    const dir = join(tmp, "shots");
    spawnSync("mkdir", ["-p", bin, dir]);
    // A grim that fails for "bad", having written part of a file.
    writeFileSync(join(bin, "grim"), '#!/bin/sh\necho part > "$5"\ntest "$2" != bad\n');
    chmodSync(join(bin, "grim"), 0o755);
    writeFileSync(join(dir, "bad.jpg"), "old");
    writeFileSync(join(dir, "closed.jpg"), "old");
    const [cmd, ...args] = shotsCommand(dir, ["good", "bad"]);
    const run = spawnSync(cmd, args, { env: { PATH: `${bin}:/usr/bin:/bin` } });
    assert.equal(run.status, 1);
    assert.equal(readFileSync(join(dir, "good.jpg"), "utf8"), "part\n");
    assert.equal(existsSync(join(dir, "bad.jpg")), false);
    assert.equal(existsSync(join(dir, "closed.jpg")), false, "a closed window's picture goes");
});
