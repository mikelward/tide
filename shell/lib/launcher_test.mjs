// Tests for launcher.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initial, record } from "./frecency.mjs";
import { blockedHeading, confirmRows, highlighted, launchCommand, launcherItems, moved, nextSection, quickActions, quickCommand, reselect, rowKey, scoreItem, search, startsSection, windowScreenshot } from "./launcher.mjs";

const chrome = {
    id: "google-chrome",
    name: "Google Chrome",
    genericName: "Web Browser",
    comment: "Access the Internet",
    icon: "google-chrome",
    keywords: ["web", "internet"],
    command: ["/usr/bin/google-chrome-stable", "%U"],
    runInTerminal: false,
    workingDirectory: "",
    startupClass: "Google-chrome",
    noDisplay: false,
    actions: [
        { id: "new-window", name: "New Window", icon: "", command: ["/usr/bin/google-chrome-stable"] },
        { id: "new-private-window", name: "New Incognito Window", icon: "", command: ["/usr/bin/google-chrome-stable", "--incognito"] },
    ],
};
const kitty = { id: "kitty", name: "kitty", genericName: "Terminal emulator", command: ["kitty"], keywords: [], actions: [] };
const htop = { id: "htop", name: "Htop", comment: "Process viewer", command: ["htop"], runInTerminal: true, actions: [] };
const hidden = { id: "hidden", name: "Hidden", command: ["hidden"], noDisplay: true, actions: [] };
const broken = { id: "broken", name: "Broken", command: [], actions: [] };
const shell = { id: "ssh", name: "Secure Shell", genericName: "SSH", command: ["ssh-app"], actions: [] };

const items = launcherItems([chrome, kitty, htop, hidden, broken, shell]);

test("an entry gives a row, and one per desktop action", () => {
    assert.deepEqual(items.map(i => [i.kind, i.id, i.name, i.sub]), [
        ["app", "google-chrome", "Google Chrome", "Web Browser"],
        ["action", "google-chrome:new-window", "New Window", "Google Chrome"],
        ["action", "google-chrome:new-private-window", "New Incognito Window", "Google Chrome"],
        ["app", "kitty", "kitty", "Terminal emulator"],
        ["app", "htop", "Htop", "Process viewer"],
        ["app", "ssh", "Secure Shell", "SSH"],
    ]);
    assert.equal(items[0].exec, "google-chrome-stable");
    // An action keeps its app's class and icon.
    assert.equal(items[2].appId, "Google-chrome");
    assert.equal(items[2].icon, "google-chrome");
});

test("an entry hidden from menus, or with nothing to run, has no row", () => {
    assert.equal(items.some(i => i.id === "hidden" || i.id === "broken"), false);
});

test("the empty query lists the apps by name, without their actions", () => {
    assert.deepEqual(search(items, "").map(r => r.item.name), ["Google Chrome", "Htop", "kitty", "Secure Shell"]);
    assert.deepEqual(search(items, " ")[0].positions, []);
});

test("the empty query lists the apps you use first, most used on top", () => {
    const now = 1e12;
    let used = record(initial(), "app:ssh", now - 1000);
    used = record(used, "app:kitty", now - 1000);
    used = record(used, "app:kitty", now);
    assert.deepEqual(search(items, "", used, now).map(r => r.item.name), ["kitty", "Secure Shell", "Google Chrome", "Htop"]);
    // An action's use doesn't put it in the empty list.
    used = record(used, "action:google-chrome:new-window", now);
    assert.equal(search(items, "", used, now).some(r => r.item.kind === "action"), false);
});

test("use breaks a tie but never beats a better match", () => {
    const now = 1e12;
    const term = { id: "term", name: "Term", command: ["term"], actions: [] };
    const tmux = { id: "tmux", name: "Tmux", command: ["tmux"], actions: [] };
    const skit = { id: "skit", name: "Skit", command: ["skit"], actions: [] };
    const all = launcherItems([term, tmux, kitty, skit]);
    let used = initial();
    for (let i = 0; i < 50; i++) {
        used = record(used, "app:tmux", now);
        used = record(used, "app:skit", now);
    }
    // An equal match: by name without use, the one you use with it.
    assert.equal(search(all, "t")[0].item.id, "term");
    assert.equal(search(all, "t", used, now)[0].item.id, "tmux");
    // kitty's prefix beats a much-used Skit.
    assert.equal(search(all, "kit", used, now)[0].item.id, "kitty");
});

test("an equal score goes by the match's shape before use", () => {
    const now = 1e12;
    const app = (id, name) => ({ id, name, command: [id], actions: [] });
    const all = launcherItems([app("terminal", "Terminal"), app("term", "Term"), app("xab", "X Abc"), app("xyab", "Xy Ab")]);
    let used = initial();
    for (let i = 0; i < 50; i++) {
        used = record(used, "app:terminal", now);
        used = record(used, "app:xyab", now);
    }
    // Both a prefix of the same score: the shorter name, however much the
    // longer one is used.
    assert.equal(scoreItem(all[0], "term").score, scoreItem(all[1], "term").score);
    assert.equal(search(all, "term", used, now)[0].item.id, "term");
    // Both a word-start run of the same score: the earlier one.
    assert.equal(scoreItem(all[2], "ab").score, scoreItem(all[3], "ab").score);
    assert.deepEqual(search(all, "ab", used, now).map(r => r.item.id).slice(0, 2), ["xab", "xyab"]);
});

test("the shape is judged on the cleanest of equally scored alignments", () => {
    const app = (id, name) => ({ id, name, command: [id], actions: [] });
    const all = launcherItems([app("run", "bxxx-BbA_B"), app("gap", "b------a")]);
    assert.equal(scoreItem(all[0], "ba").score, scoreItem(all[1], "ba").score);
    assert.equal(search(all, "ba")[0].item.id, "run");
    // Both broken: the one with an alignment that starts earlier.
    const broken = launcherItems([app("early", "axxxxxab--xB"), app("late", "babaa-b")]);
    assert.equal(scoreItem(broken[0], "abb").score, scoreItem(broken[1], "abb").score);
    assert.equal(search(broken, "abb")[0].item.id, "early");
});

test("use doesn't reorder the quick actions, so scr and Enter stays a window screenshot", () => {
    const now = 1e12;
    const screenshotApp = { id: "org.gnome.Screenshot", name: "Screenshot", command: ["gnome-screenshot"], actions: [] };
    const all = launcherItems([screenshotApp]).concat(quickActions());
    let used = initial();
    for (let i = 0; i < 50; i++) {
        used = record(used, "quick:screenshot-screen", now);
        used = record(used, "app:org.gnome.Screenshot", now);
    }
    assert.equal(search(all, "scr", used, now)[0].item.id, "screenshot-window");
});

test("a query ranks matching rows best first, and drops the rest", () => {
    const rows = search(items, "inc");
    assert.equal(rows[0].item.name, "New Incognito Window");
    assert.deepEqual(rows[0].positions, [4, 5, 6]);
    assert.equal(rows.some(r => r.item.name === "kitty"), false);
});

test("a match in the name beats one in another field", () => {
    const rows = search(items, "sh");
    assert.equal(rows[0].item.name, "Secure Shell");
});

test("the generic name, keywords and command find an app, unhighlighted", () => {
    assert.deepEqual(scoreItem(items[0], "browser").positions, []);
    assert.notEqual(scoreItem(items[0], "internet"), null);
    assert.notEqual(scoreItem(items[0], "stable"), null);
    assert.equal(scoreItem(items[3], "zzz"), null);
});

test("an app comes before its own actions on an equal score", () => {
    const rows = search(launcherItems([{ ...kitty, actions: [{ id: "k", name: "kitty", command: ["kitty", "-1"] }] }]), "kitty");
    assert.deepEqual(rows.map(r => r.item.kind), ["app", "action"]);
});

test("an app is launched through tide launch, granting its window class", () => {
    assert.deepEqual(launchCommand(items[2]), ["tide", "launch", "--app", "Google-chrome", "--", "/usr/bin/google-chrome-stable", "--incognito"]);
    // With no class named, the command may be a wrapper whose name no
    // window has, so any app's first window may take focus.
    assert.deepEqual(launchCommand(items[3]), ["tide", "launch", "--app", "*", "--", "kitty"]);
});

test("a terminal app runs in the terminal, granting any first window", () => {
    assert.deepEqual(launchCommand(items[4]), ["tide", "launch", "--app", "*", "--", "xdg-terminal-exec", "htop"]);
    // Even when the entry names a class: the window is still the terminal's.
    const named = launcherItems([{ ...htop, startupClass: "htop" }])[0];
    assert.deepEqual(launchCommand(named), ["tide", "launch", "--app", "*", "--", "xdg-terminal-exec", "htop"]);
});

test("the matched letters are underlined, and the rest is escaped", () => {
    assert.equal(highlighted("a<b", [0], "#fff"), '<u><font color="#fff">a</font></u>&lt;b');
    assert.equal(highlighted("x & y", [], "#fff"), "x &amp; y");
});

test("moving the selection stops at the ends", () => {
    assert.equal(moved(0, -1, 3), 0);
    assert.equal(moved(1, 1, 3), 2);
    assert.equal(moved(2, 1, 3), 2);
    assert.equal(moved(0, 1, 0), -1);
});

test("the quick actions are the screenshots, the session, the toggles and reload", () => {
    assert.deepEqual(quickActions({ notifications: true }).map(q => q.id), [
        "screenshot-window", "screenshot-screen", "screenshot-region",
        "lock", "logout", "suspend", "reboot", "poweroff",
        "dnd", "keep-awake", "reload",
    ]);
    // Every one has something to run.
    for (const q of quickActions({ notifications: true })) {
        assert.ok(quickCommand(q.id));
    }
    assert.throws(() => quickCommand("nope"));
});

test("a quick action shows the key that does the same", () => {
    const hints = Object.fromEntries(quickActions().map(q => [q.id, q.hint]));
    assert.equal(hints["screenshot-window"], "Alt+Print");
    assert.equal(hints.lock, "Super+L");
    assert.equal(hints.reload, "");
});

test("Do not disturb is there only while the shell serves notifications", () => {
    // Under swaync it would hold nothing, so it's left out, as the bell is.
    assert.equal(quickActions({}).some(q => q.id === "dnd"), false);
    assert.equal(quickActions({ notifications: true }).some(q => q.id === "dnd"), true);
});

test("the toggles say whether they're on", () => {
    const sub = state => Object.fromEntries(quickActions(state).map(q => [q.id, q.sub]));
    assert.equal(sub({ notifications: true, dnd: true }).dnd, "On");
    assert.equal(sub({ notifications: true }).dnd, "Off");
    assert.equal(sub({ keepAwake: true })["keep-awake"], "On");
    assert.equal(sub({ keepAwake: true, micHolds: true })["keep-awake"], "On while the mic is live");
});

test("screenshots wait for the launcher to go, the session runs through logind or uwsm", () => {
    assert.deepEqual(quickCommand("screenshot-window"), { run: ["screenshot", "--window"], afterClose: true });
    assert.deepEqual(quickCommand("screenshot-region"), { run: ["screenshot", "--region"], afterClose: true });
    assert.deepEqual(quickCommand("lock"), { run: ["loginctl", "lock-session"], afterClose: false, power: false });
    // A power action checks inhibitors, so it fails when something blocks it.
    assert.deepEqual(quickCommand("suspend"), { run: ["systemctl", "--check-inhibitors=yes", "suspend"], afterClose: false, power: true });
    assert.equal(quickCommand("logout").power, false);
    assert.deepEqual(quickCommand("dnd"), { shell: "dnd" });
});

test("a blocked power action asks: anyway, or cancel", () => {
    assert.deepEqual(confirmRows("suspend").map(r => [r.item.kind, r.item.id, r.item.name]), [
        ["confirm", "anyway", "Suspend anyway"],
        ["confirm", "cancel", "Cancel"],
    ]);
    assert.equal(blockedHeading("poweroff"), "Shut down is blocked by:");
});

test("the selection stays on its row unless the query changed", () => {
    const rows = ids => ids.map(id => ({ item: { kind: "app", id } }));
    const key = id => `app:${id}`;
    // A toggle's state changed: the same row, wherever it went.
    assert.equal(reselect(key("b"), rows(["a", "b", "c"]), false), 1);
    assert.equal(reselect(key("b"), rows(["b", "a"]), false), 0);
    // A new query preselects its top hit.
    assert.equal(reselect(key("b"), rows(["a", "b"]), true), 0);
    // A row that's gone, or nothing selected before, falls back to the top.
    assert.equal(reselect(key("z"), rows(["a", "b"]), false), 0);
    assert.equal(reselect(null, rows(["a"]), false), 0);
    assert.equal(reselect(key("a"), [], false), -1);
});

test("a row is known by its kind and id, so an app can't stand in for an action", () => {
    // A desktop entry with a quick action's id, listed first.
    const rows = [
        { item: { kind: "app", id: "keep-awake" } },
        { item: { kind: "quick", id: "keep-awake" } },
    ];
    assert.equal(reselect(rowKey(rows[1]), rows, false), 1);
    assert.equal(rowKey(null), null);
});

test("quick actions are searched with the apps, and listed after them when empty", () => {
    const all = items.concat(quickActions());
    assert.equal(search(all, "scr")[0].item.id, "screenshot-window");
    assert.equal(search(all, "caffeine")[0].item.id, "keep-awake");
    const empty = search(all, "").map(r => r.item.kind);
    assert.deepEqual(empty.slice(0, 4), ["app", "app", "app", "app"]);
    assert.equal(empty.at(-1), "quick");
});

// Runs windowScreenshot's command against a fake `hyprctl` printing
// `clients` and a fake `screenshot` that records its arguments, with the real
// sh and jq, and returns what screenshot was asked for and the stderr.
function runWindowScreenshot(address, clients) {
    const dir = mkdtempSync(join(tmpdir(), "launcher-test-"));
    writeFileSync(join(dir, "clients.json"), clients);
    writeFileSync(join(dir, "hyprctl"), `#!/bin/sh\ncat "${dir}/clients.json"\n`);
    writeFileSync(join(dir, "screenshot"), `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/args"\n`);
    chmodSync(join(dir, "hyprctl"), 0o755);
    chmodSync(join(dir, "screenshot"), 0o755);
    const [command, ...args] = windowScreenshot(address);
    const run = spawnSync(command, args, { env: { ...process.env, PATH: `${dir}:${process.env.PATH}` }, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    return { args: readFileSync(join(dir, "args"), "utf8").trim().split("\n"), stderr: run.stderr };
}

test("Screenshot window takes the recorded window where it is now", () => {
    const clients = JSON.stringify([
        { address: "0x55aa01", at: [0, 0], size: [10, 10] },
        { address: "0x55AA02", at: [100, 40], size: [800, 600] },
    ]);
    // Matched however Hyprland and Quickshell write the address.
    const found = runWindowScreenshot("55aa02", clients);
    assert.deepEqual(found.args, ["--geometry", "100,40 800x600"]);
    assert.equal(found.stderr, "");
    // quickCommand passes the recorded address through.
    assert.deepEqual(quickCommand("screenshot-window", { window: "55aa02" }).run.slice(0, 2), ["sh", "-c"]);
});

test("Screenshot window falls back to the focused window, and says so", () => {
    const gone = JSON.stringify([{ address: "0x1", at: [0, 0], size: [1, 1] }]);
    const fallback = runWindowScreenshot("2", gone);
    assert.deepEqual(fallback.args, ["--window"]);
    assert.match(fallback.stderr, /gone or unreadable; taking the focused window/);
    // With nothing recorded, the script finds the focused window itself.
    assert.deepEqual(windowScreenshot(null), ["screenshot", "--window"]);
    assert.deepEqual(windowScreenshot(""), ["screenshot", "--window"]);
});

test("a quick action wins a tie with an app, so scr and Enter is a screenshot", () => {
    const screenshotApp = { id: "org.gnome.Screenshot", name: "Screenshot", command: ["gnome-screenshot"], actions: [] };
    const all = launcherItems([screenshotApp]).concat(quickActions());
    assert.equal(search(all, "scr")[0].item.id, "screenshot-window");
    // The app is still found, just below.
    assert.ok(search(all, "scr").some(r => r.item.id === "org.gnome.Screenshot"));
});

test("the empty query comes in sections: recent apps, the rest, then actions", () => {
    const now = 1e12;
    const used = record(initial(), "app:kitty", now);
    const rows = search(items.concat(quickActions()), "", used, now);
    assert.deepEqual(rows.slice(0, 3).map(r => [r.item.id, r.section]), [
        ["kitty", "Recent"],
        ["google-chrome", "Apps"],
        ["htop", "Apps"],
    ]);
    assert.equal(rows.at(-1).section, "Actions");
    // With nothing used yet there's no Recent section.
    assert.equal(search(items, "").some(r => r.section === "Recent"), false);
});

test("a query puts its best match first, then actions, then apps", () => {
    const screenshotApp = { id: "org.gnome.Screenshot", name: "Screenshot", command: ["gnome-screenshot"], actions: [] };
    const rows = search(launcherItems([screenshotApp, shell]).concat(quickActions()), "scr");
    assert.deepEqual(rows[0].item.id, "screenshot-window");
    assert.equal(rows[0].section, "Best match");
    // Lock matches too, by its "screen" keyword.
    assert.deepEqual(rows.slice(1).map(r => r.section), ["Actions", "Actions", "Actions", "Apps", "Apps"]);
    // Each section keeps rank order: Screenshot outranks Secure Shell.
    assert.deepEqual(rows.filter(r => r.section === "Apps").map(r => r.item.id), ["org.gnome.Screenshot", "ssh"]);
    // An app on top is the best match, and actions still come before apps.
    const top = search(launcherItems([kitty]).concat(quickActions()), "kit");
    assert.deepEqual(top.map(r => [r.item.id, r.section]), [["kitty", "Best match"]]);
});

test("Tab steps to the next section's first row, and Shift+Tab back", () => {
    const rows = ["Best match", "Actions", "Actions", "Apps", "Apps"].map((section, i) => ({ item: { kind: "app", id: String(i) }, positions: [], section }));
    assert.deepEqual(rows.map((_, i) => startsSection(rows, i)), [true, true, false, true, false]);
    assert.equal(nextSection(rows, 0, 1), 1);
    assert.equal(nextSection(rows, 2, 1), 3);
    assert.equal(nextSection(rows, 4, 1), 0);
    // Shift+Tab: to its own section's start first, then the one before.
    assert.equal(nextSection(rows, 4, -1), 3);
    assert.equal(nextSection(rows, 3, -1), 1);
    assert.equal(nextSection(rows, 0, -1), 3);
    // Confirmation rows have no sections: Tab leaves the selection alone.
    assert.equal(nextSection(confirmRows("reboot"), 1, 1), 1);
    assert.equal(startsSection(confirmRows("reboot"), 0), false);
});
