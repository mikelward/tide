// Tests for launcher.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initial, record } from "./frecency.mjs";
import { PAGES } from "./settings.mjs";
import { SHOW_IN_SCRIPT, blockedHeading, confirmRows, desktopNames, highlighted, grantIds, launchCommand, launcherItems, moved, otherDesktopSettings, parseShowIn, shownIn, nextSection, opensWindow, quickActions, quickCommand, reselect, rowKey, scoreItem, search, startsSection, windowScreenshot } from "./launcher.mjs";

// Array.prototype.at and Object.fromEntries, which the shell's engine lacks
// (qtjs_env_test.mjs).
const last = (list) => list[list.length - 1];
const byId = (rows, field) => {
    const out = {};
    for (const r of rows) {
        out[r.id] = r[field];
    }
    return out;
};

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

// Other desktops' settings apps, as their upstream desktop files have them
// (SPEC.md §8.2), and the apps tide's own Settings pages open.
const entry = (id, command, categories) => ({ id, name: id, command, categories, actions: [] });
const gnomeSettings = entry("org.gnome.Settings", ["gnome-control-center"], ["GNOME", "GTK", "Settings"]);
const kdeSettings = entry("systemsettings", ["systemsettings"], ["Qt", "KDE", "Settings"]);
const kdeElsewhere = entry("kdesystemsettings", ["systemsettings"], ["Qt", "KDE", "Settings"]);
const plasma5Elsewhere = entry("kdesystemsettings5", ["systemsettings5"], ["Qt", "KDE", "Settings"]);
const xfceManager = entry("xfce4-settings-manager", ["xfce4-settings-manager"], ["X-XFCE", "Settings", "DesktopSettings"]);
const xfceDisplay = entry("xfce4-display-settings", ["xfce4-display-settings"], ["XFCE", "GTK", "Settings", "DesktopSettings", "X-XFCE-SettingsDialog", "X-XFCE-HardwareSettings"]);
const cinnamon = entry("cinnamon-settings", ["env", "WEBKIT_DISABLE_COMPOSITING_MODE=1", "cinnamon-settings"], ["Settings"]);
const pavucontrol = entry("org.pulseaudio.pavucontrol", ["pavucontrol"], ["AudioVideo", "Audio", "Mixer", "GTK", "Settings", "X-XFCE-SettingsDialog", "X-XFCE-HardwareSettings"]);
const nmEditor = entry("nm-connection-editor", ["nm-connection-editor"], ["GNOME", "GTK", "Settings", "X-GNOME-NetworkSettings", "X-GNOME-Utilities"]);
const blueman = entry("blueman-manager", ["blueman-manager"], ["GTK", "GNOME", "Settings", "HardwareSettings"]);
const nwgDisplays = entry("nwg-displays", ["nwg-displays"], ["Settings", "DesktopSettings"]);
const browser1 = entry("browser1", ["browser1"], ["Network", "WebBrowser"]);
const tideOnly = entry("tide-only", ["tide-only"], []);
const hyprOnly = entry("hypr-only", ["hypr-only"], []);
const desktopEntries = [gnomeSettings, kdeSettings, kdeElsewhere, plasma5Elsewhere, xfceManager, xfceDisplay, cinnamon,
    pavucontrol, nmEditor, blueman, nwgDisplays, browser1, tideOnly, hyprOnly];
const upstreamShowIn = parseShowIn([
    "@org.gnome.Settings.desktop", "|OnlyShowIn=GNOME;",
    "@systemsettings.desktop", "|OnlyShowIn=KDE;",
    "@kdesystemsettings.desktop", "|NotShowIn=KDE;",
    "@kdesystemsettings5.desktop", "|NotShowIn=KDE;",
    "@xfce4-settings-manager.desktop", "|OnlyShowIn=XFCE;",
    "@xfce4-display-settings.desktop", "|OnlyShowIn=XFCE;",
    "@cinnamon-settings.desktop", "|OnlyShowIn=X-Cinnamon;",
    "@org.pulseaudio.pavucontrol.desktop",
    "@nm-connection-editor.desktop",
    "@blueman-manager.desktop",
    "@nwg-displays.desktop",
    "@browser1.desktop",
    "@tide-only.desktop", "|OnlyShowIn=tide;",
    "@hypr-only.desktop", "|OnlyShowIn=Hyprland",
].join("\n"));
const appIds = (entries, desktop) => launcherItems(entries, desktop).map(i => i.id);

test("other desktops' settings apps have no row, and tide's own apps and Settings' tools do", () => {
    assert.deepEqual(appIds(desktopEntries, { names: desktopNames("tide:Hyprland"), showIn: upstreamShowIn }), [
        "org.pulseaudio.pavucontrol", "nm-connection-editor", "blueman-manager", "nwg-displays", "browser1", "tide-only", "hypr-only",
    ]);
});

test("a settings app that runs another desktop's settings has no row, whatever its OnlyShowIn", () => {
    // Before the first read, and for KDE's entries for other desktops.
    assert.deepEqual(appIds(desktopEntries), [
        "xfce4-display-settings", "org.pulseaudio.pavucontrol", "nm-connection-editor", "blueman-manager", "nwg-displays", "browser1", "tide-only", "hypr-only",
    ]);
    assert.equal(otherDesktopSettings(cinnamon), true);
    assert.equal(otherDesktopSettings(entry("kcm_mouse", ["/usr/bin/kcmshell6", "kcm_mouse"], ["Settings"])), true);
    assert.equal(otherDesktopSettings(entry("gnome-sound-panel", ["gnome-control-center", "sound"], ["Settings"])), true);
    // A launcher of one's own for it, outside Settings, stays.
    assert.equal(otherDesktopSettings(entry("my-kde", ["systemsettings"], ["Utility"])), false);
    assert.equal(otherDesktopSettings(entry("my-kde", ["systemsettings"], undefined)), false);
});

test("OnlyShowIn and NotShowIn go by the session's desktop names", () => {
    // In Xfce, its display settings would show.
    assert.equal(appIds(desktopEntries, { names: desktopNames("XFCE"), showIn: upstreamShowIn }).indexOf("xfce4-display-settings") >= 0, true);
    assert.deepEqual(desktopNames("tide:Hyprland"), ["tide", "Hyprland"]);
    assert.deepEqual(desktopNames(""), ["tide", "Hyprland"]);
    assert.deepEqual(desktopNames(undefined), ["tide", "Hyprland"]);
    assert.deepEqual(desktopNames(":"), ["tide", "Hyprland"]);
});

test("OnlyShowIn and NotShowIn follow the Desktop Entry spec", () => {
    const names = ["tide", "Hyprland"];
    const keys = (only, not = []) => ({ only, not });
    assert.equal(shownIn(null, names), true);
    assert.equal(shownIn(keys(null), names), true);
    assert.equal(shownIn(keys(["GNOME", "Unity"]), names), false);
    assert.equal(shownIn(keys(["Hyprland"]), names), true);
    assert.equal(shownIn(keys(null, ["tide"]), names), false);
    assert.equal(shownIn(keys(null, ["KDE", "GNOME"]), names), true);
    // The first of the session's names that either list holds decides.
    assert.equal(shownIn(keys(["Hyprland"], ["tide"]), names), false);
    assert.equal(shownIn(keys(["tide"], ["Hyprland"]), names), true);
    // An empty OnlyShowIn shows nowhere; names match case and all.
    assert.equal(shownIn(keys([]), names), false);
    assert.equal(shownIn(keys(["TIDE"]), names), false);
    // A hidden entry's desktop actions go with it.
    const chromeElsewhere = Object.assign({}, chrome, { id: "chrome-gnome" });
    assert.deepEqual(appIds([chromeElsewhere], { names, showIn: parseShowIn("@chrome-gnome.desktop\n|OnlyShowIn=GNOME;\n") }), []);
});

test("the OnlyShowIn and NotShowIn listing is read by desktop file ID, the first of each counting", () => {
    const showIn = parseShowIn([
        "@kde4/dolphin.desktop", "|OnlyShowIn = KDE ; GNOME ;", "|OnlyShowIn=XFCE;", "|NotShowIn=tide;",
        "@plain.desktop",
        "@plain.desktop", "|OnlyShowIn=GNOME;",
        "@kde4-dolphin.desktop", "|NotShowIn=KDE;",
        "stray line", "|NotShowIn=lost;",
    ].join("\n"));
    assert.deepEqual(Object.keys(showIn).sort(), ["kde4-dolphin", "plain"]);
    assert.deepEqual(showIn["kde4-dolphin"], { only: ["KDE", "GNOME"], not: ["tide"] });
    // A user's copy with neither key outranks the system's.
    assert.deepEqual(showIn.plain, { only: null, not: [] });
    assert.deepEqual(parseShowIn(""), {});
});

test("the OnlyShowIn and NotShowIn script reads the directories Quickshell scans, in its order", () => {
    const dir = mkdtempSync(join(tmpdir(), "tide-showin-"));
    const write = (path, text) => {
        mkdirSync(join(dir, path, ".."), { recursive: true });
        writeFileSync(join(dir, path), text);
    };
    write("home/applications/plain.desktop", "[Desktop Entry]\nType=Application\nName=Plain\nExec=plain\n");
    write("sys/applications/plain.desktop", "[Desktop Entry]\nName=Plain\nOnlyShowIn=GNOME;\n");
    write("sys/applications/kde4/dolphin.desktop", "[Desktop Entry]\nName=Dolphin\n  NotShowIn = GNOME;\r\n[Desktop Action x]\nOnlyShowIn=KDE;\n");
    write("sys/applications/actions.desktop", "[Desktop Action x]\nOnlyShowIn=KDE;\n[Desktop Entry]\nOnlyShowIn=XFCE;\n");
    write("sys/applications/notes.txt", "OnlyShowIn=KDE;\n");
    const run = spawnSync("sh", ["-c", SHOW_IN_SCRIPT], {
        env: { PATH: process.env.PATH, HOME: join(dir, "nohome"), XDG_DATA_HOME: join(dir, "home-data"), XDG_DATA_DIRS: `${join(dir, "missing")}:${join(dir, "sys")}/` },
        encoding: "utf8",
    });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stderr, "");
    // XDG_DATA_HOME here has no applications directory, so only sys counts.
    let showIn = parseShowIn(run.stdout);
    assert.deepEqual(showIn.plain, { only: ["GNOME"], not: [] });
    assert.deepEqual(showIn["kde4-dolphin"], { only: null, not: ["GNOME"] });
    assert.deepEqual(showIn.actions, { only: ["XFCE"], not: [] });
    assert.equal("notes" in showIn, false);
    // XDG_DATA_HOME comes first, and its copy has neither key.
    const home = spawnSync("sh", ["-c", SHOW_IN_SCRIPT], {
        env: { PATH: process.env.PATH, HOME: join(dir, "nohome"), XDG_DATA_HOME: join(dir, "home"), XDG_DATA_DIRS: join(dir, "sys") },
        encoding: "utf8",
    });
    assert.equal(home.status, 0, home.stderr);
    showIn = parseShowIn(home.stdout);
    assert.deepEqual(showIn.plain, { only: null, not: [] });
    assert.deepEqual(showIn["kde4-dolphin"], { only: null, not: ["GNOME"] });
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
    // The class the entry names, then the program's name; the desktop ID
    // differs from the class only in case, so it's listed once.
    assert.deepEqual(launchCommand(items[2]), [
        "tide", "launch", "--app", "Google-chrome", "--app", "google-chrome-stable", "--",
        "/usr/bin/google-chrome-stable", "--incognito",
    ]);
    // With no class named, the desktop ID and the program's name.
    assert.deepEqual(launchCommand(items[3]), ["tide", "launch", "--app", "kitty", "--", "kitty"]);
    assert.deepEqual(grantIds(items[5]), ["ssh", "ssh-app"]);
});

test("a wrapper's name isn't granted, since no window has it", () => {
    const flatpak = launcherItems([{
        id: "org.example.Editor", name: "Editor",
        command: ["/usr/bin/flatpak", "run", "--branch=stable", "org.example.Editor"], actions: [],
    }])[0];
    assert.deepEqual(grantIds(flatpak), ["org.example.Editor"]);
    const env = launcherItems([{ id: "tool", name: "Tool", command: ["env", "GDK_BACKEND=x11", "tool"], actions: [] }])[0];
    assert.deepEqual(grantIds(env), ["tool"]);
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

test("the quick actions are the screenshots, the session, settings, the toggles, clearing the clipboard and reload", () => {
    assert.deepEqual(quickActions({ notifications: true }).map(q => q.id), [
        "screenshot-window", "screenshot-screen", "screenshot-region",
        "lock", "logout", "suspend", "reboot", "poweroff",
        "settings",
        ...PAGES.map(p => `settings-${p.id}`),
        "dnd", "dark-style", "keep-awake", "presenter", "clear-clipboard", "reload",
    ]);
    // Every one has something to run.
    for (const q of quickActions({ notifications: true })) {
        assert.ok(quickCommand(q.id));
    }
    assert.throws(() => quickCommand("nope"));
});

test("Clear clipboard history wipes cliphist's history, notifying a failure", () => {
    assert.deepEqual(quickCommand("clear-clipboard"), { run: ["tide", "clipboard", "wipe", "--notify"], afterClose: false });
    assert.equal(search(quickActions(), "clear clip")[0].item.id, "clear-clipboard");
    assert.equal(search(quickActions(), "cliphist")[0].item.id, "clear-clipboard");
});

test("keep awake is the cup, as on the bar and the OSD, and coffee finds it", () => {
    assert.equal(byId(quickActions(), "icon")["keep-awake"], "keep-awake-symbolic.svg");
    assert.equal(search(quickActions(), "coffee")[0].item.id, "keep-awake");
});

test("a quick action shows the key that does the same", () => {
    const hints = byId(quickActions(), "hint");
    assert.equal(hints["screenshot-window"], "Alt+Print");
    assert.equal(hints.lock, "Super+L");
    assert.equal(hints["keep-awake"], "Super+S");
    assert.equal(hints.presenter, "Super+P");
    assert.equal(hints.reload, "");
});

test("the screenshot actions say what they take, and region doesn't promise a frozen screen", () => {
    // The frozen picker is post-MVP (SPEC.md §13); until then --region is a
    // live slurp selection.
    const sub = {};
    for (const q of quickActions()) {
        sub[q.id] = q.sub;
    }
    assert.equal(sub["screenshot-window"], "The window you were in");
    assert.equal(sub["screenshot-screen"], "The monitor you were on");
    assert.equal(sub["screenshot-region"], "Drag to select");
    assert.doesNotMatch(sub["screenshot-region"], /frozen/i);
});

test("Do not disturb is there only while the shell serves notifications", () => {
    // Under swaync it would hold nothing, so it's left out, as the bell is.
    assert.equal(quickActions({}).some(q => q.id === "dnd"), false);
    assert.equal(quickActions({ notifications: true }).some(q => q.id === "dnd"), true);
});

test("the toggles say whether they're on", () => {
    const sub = state => byId(quickActions(state), "sub");
    assert.equal(sub({ notifications: true, dnd: true }).dnd, "On");
    assert.equal(sub({ notifications: true }).dnd, "Off");
    assert.equal(sub({ keepAwake: true })["keep-awake"], "On");
    assert.equal(sub({ keepAwake: true, micHolds: true })["keep-awake"], "On while the mic is live");
    assert.equal(sub({ presenting: true }).presenter, "On");
    assert.equal(sub({}).presenter, "Off");
    // Dark style also says until when, unless it's fixed.
    assert.equal(sub({ dark: true, darkUntil: "07:00" })["dark-style"], "On until 07:00");
    assert.equal(sub({ dark: false, darkUntil: "19:00" })["dark-style"], "Off until 19:00");
    assert.equal(sub({ dark: true, darkUntil: "" })["dark-style"], "On");
});

test("settings is found by its name, and opens the panel on its first page", () => {
    for (const query of ["settings", "preferences", "control panel"]) {
        assert.equal(search(quickActions(), query)[0].item.id, "settings", query);
    }
    assert.deepEqual(quickCommand("settings"), { shell: "settings", page: "" });
});

// "mouse" and Enter found nothing to run, so did nothing: only Sound,
// Network and Bluetooth were among Settings' words, and it opened on Idle.
test("each settings page is found by its name and what it covers, and opens the panel on it", () => {
    const pages = {
        idle: ["idle", "idle settings"],
        sound: ["sound", "audio", "volume"],
        network: ["network", "wifi", "vpn"],
        bluetooth: ["bluetooth"],
        mouse: ["mouse", "mouse settings", "left-handed", "pointer"],
        touchpad: ["touchpad", "trackpad", "pointing stick", "tap to click"],
        keyboard: ["keyboard", "xkb", "repeat"],
        clocks: ["clocks", "time zone", "timezone"],
        keys: ["keys", "shortcuts", "bindings"],
        layouts: ["layouts", "tiling"],
        appearance: ["appearance", "wallpaper"],
        displays: ["displays", "monitors", "scale"],
        startup: ["start at login", "startup", "autostart"],
        notifications: ["notifications", "quiet hours", "muted apps"],
        clipboard: ["clipboard settings", "copy history", "paste history"],
        power: ["power settings", "battery", "power profile", "lid"],
        workspaces: ["workspaces settings", "home workspace", "name patterns"],
    };
    assert.deepEqual(Object.keys(pages), PAGES.map(p => p.id));
    for (const [id, queries] of Object.entries(pages)) {
        for (const query of queries) {
            const top = search(quickActions({ notifications: true }), query)[0]?.item;
            assert.equal(top?.id, `settings-${id}`, query);
            assert.deepEqual(quickCommand(top.id), { shell: "settings", page: id }, query);
        }
    }
    assert.equal(byId(quickActions(), "name")["settings-mouse"], "Mouse settings");
    assert.throws(() => quickCommand("settings-nope"));
});

test("the settings pages' rows wait for a query, so the empty one lists only Settings", () => {
    const ids = search(quickActions({ notifications: true }), "").map(r => r.item.id);
    assert.ok(ids.includes("settings"));
    assert.equal(ids.some(id => id.startsWith("settings-")), false);
});

test("dark style is found by theme, light and night", () => {
    for (const query of ["theme", "dark", "light", "night"]) {
        assert.equal(search(quickActions(), query)[0].item.id, "dark-style", query);
    }
});

test("screenshots wait for the launcher to go, the session runs through logind or uwsm", () => {
    assert.deepEqual(quickCommand("screenshot-window"), { run: ["screenshot", "--window"], afterClose: true });
    assert.deepEqual(quickCommand("screenshot-region"), { run: ["screenshot", "--region"], afterClose: true });
    // The monitor the launcher opened on, so closing it can't move the shot;
    // with none recorded, the script takes the focused one.
    assert.deepEqual(quickCommand("screenshot-screen", { output: "DP-2" }), { run: ["screenshot", "--output", "DP-2"], afterClose: true });
    assert.deepEqual(quickCommand("screenshot-screen"), { run: ["screenshot"], afterClose: true });
    assert.deepEqual(quickCommand("screenshot-screen", { output: "" }), { run: ["screenshot"], afterClose: true });
    assert.deepEqual(quickCommand("lock"), { run: ["loginctl", "lock-session"], afterClose: false, power: false });
    // A power action checks inhibitors, so it fails when something blocks it.
    assert.deepEqual(quickCommand("suspend"), { run: ["systemctl", "--check-inhibitors=yes", "suspend"], afterClose: false, power: true });
    assert.equal(quickCommand("logout").power, false);
    assert.deepEqual(quickCommand("dnd"), { shell: "dnd" });
    assert.deepEqual(quickCommand("dark-style"), { shell: "dark-style" });
    assert.deepEqual(quickCommand("presenter"), { shell: "presenter" });
});

test("presenter mode is found by what it's for, and keep awake and Do not disturb by their own names", () => {
    for (const query of ["presenter", "presentation", "slides", "projector"]) {
        assert.equal(search(quickActions({ notifications: true }), query)[0].item.id, "presenter", query);
    }
    assert.equal(search(quickActions({ notifications: true }), "keep awake")[0].item.id, "keep-awake");
    assert.equal(search(quickActions({ notifications: true }), "disturb")[0].item.id, "dnd");
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
    assert.equal(last(empty), "quick");
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

test("Screenshot window takes the recorded window by its stableId", () => {
    const clients = JSON.stringify([
        { address: "0x55aa01", at: [0, 0], size: [10, 10], stableId: "aa11bb22" },
        { address: "0x55AA02", at: [100, 40], size: [800, 600], stableId: "cc33dd44" },
    ]);
    // Matched however Hyprland and Quickshell write the address.
    const found = runWindowScreenshot("55aa02", clients);
    assert.deepEqual(found.args, ["--window-id", "cc33dd44"]);
    assert.equal(found.stderr, "");
    // quickCommand passes the recorded address through.
    assert.deepEqual(quickCommand("screenshot-window", { window: "55aa02" }).run.slice(0, 2), ["sh", "-c"]);
});

test("Screenshot window without a stableId takes the window where it is now", () => {
    const clients = JSON.stringify([
        { address: "0x55aa01", at: [0, 0], size: [10, 10], stableId: "aa11bb22" },
        { address: "0x55AA02", at: [100, 40], size: [800, 600] },
    ]);
    const found = runWindowScreenshot("55aa02", clients);
    assert.deepEqual(found.args, ["--geometry", "100,40 800x600"]);
    assert.equal(found.stderr, "");
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
    assert.equal(last(rows).section, "Actions");
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

test("Ctrl+Enter moves to a new workspace only for what opens a window", () => {
    assert.equal(opensWindow(items.find(i => i.kind === "app")), true);
    assert.equal(opensWindow(items.find(i => i.kind === "action")), true);
    assert.equal(opensWindow(quickActions()[0]), false);
    assert.equal(opensWindow(confirmRows("reboot")[0].item), false);
    assert.equal(opensWindow(undefined), false);
});

test("a launch asks for no workspace itself: the name prompt adds --workspace", () => {
    const app = items.find(i => i.kind === "app");
    const command = launchCommand(app);
    assert.deepEqual(command.slice(0, 2), ["tide", "launch"]);
    assert.ok(!command.includes("--new-workspace"));
    assert.ok(!command.includes("--workspace"));
});
