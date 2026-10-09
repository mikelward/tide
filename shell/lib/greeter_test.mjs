// Tests for greeter.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { INITIAL, next } from "./lock.mjs";
import {
    LISTING_SCRIPT, SHELL_ID, SHELL_SESSION, authFailureEvent, canPickUser, execCommand, fileId, greetdError, parseDesktopEntry,
    parseListing, parseRemembered, parseUsers, pickSession, pickUser, serializeRemembered,
    inConversation, sessionFromEntry, takes, sessionList, statusText, uidRange,
} from "./greeter.mjs";

// What greeter.qml's listing script prints for these files, in order.
function listing(...files) {
    return files.map(([ok, path, text]) => `@${ok ? 1 : 0} ${path}\n${text.split("\n").map((l) => "|" + l).join("\n")}\n`).join("");
}

const TIDE = "[Desktop Entry]\nName=tide\nComment=Hyprland with the tide shell, managed by uwsm\n"
    + "Exec=uwsm start -e -D tide:Hyprland -N tide -- tide-hyprland\nTryExec=uwsm\nType=Application\nDesktopNames=tide;Hyprland\n";
const PLASMA = "[Desktop Entry]\nExec=/usr/lib/plasma-dbus-run-session-if-needed startplasma-wayland\nName=Plasma (Wayland)\nName[de]=Plasma (Wayland) DE\nDesktopNames=KDE\n";
const HYPR = "[Desktop Entry]\nName=Hyprland\nExec=Hyprland\nType=Application\n";

test("the listing gives each file's path, TryExec verdict and text", () => {
    const records = parseListing(listing(
        [true, "/usr/share/wayland-sessions/tide.desktop", "[Desktop Entry]\nName=tide"],
        [false, "/usr/share/wayland-sessions/a b.desktop", "|odd\n@not a header"],
    ));
    assert.deepEqual(records, [
        { path: "/usr/share/wayland-sessions/tide.desktop", ok: true, text: "[Desktop Entry]\nName=tide" },
        { path: "/usr/share/wayland-sessions/a b.desktop", ok: false, text: "|odd\n@not a header" },
    ]);
});

test("a file with no final newline doesn't run into the next header", () => {
    // The script ends each file with an extra newline for this.
    const out = "@1 /a/x.desktop\n|[Desktop Entry]\n|Name=X\n@1 /a/y.desktop\n|[Desktop Entry]\n";
    assert.deepEqual(parseListing(out).map((r) => r.path), ["/a/x.desktop", "/a/y.desktop"]);
    assert.deepEqual(parseListing(""), []);
});

test("a desktop entry's keys are its main group's, unlocalized and unescaped", () => {
    const entry = parseDesktopEntry("# a comment\n[Desktop Entry]\nName = Plain\nName[fr]=Simple\n"
        + "Exec=run\\sthis\nComment=a\\\\b\\nc\nName=Second\n[Desktop Action x]\nExec=other\n");
    assert.equal(entry.Name, "Plain");
    assert.equal(entry.Exec, "run this");
    assert.equal(entry.Comment, "a\\b\nc");
    assert.equal(parseDesktopEntry("[Other]\nName=x\n"), null);
    assert.equal(parseDesktopEntry(""), null);
});

test("an Exec line loses its field codes, and %% is a percent", () => {
    assert.equal(execCommand("startx %f --pct=50%% %U"), "startx  --pct=50%");
    assert.equal(execCommand("  sway  "), "sway");
    assert.equal(execCommand(undefined), "");
});

test("a session file becomes a session with the environment pam_systemd reads", () => {
    const s = sessionFromEntry("tide", parseDesktopEntry(TIDE));
    assert.equal(s.name, "tide");
    assert.equal(s.command, "uwsm start -e -D tide:Hyprland -N tide -- tide-hyprland");
    assert.deepEqual(s.env, ["XDG_SESSION_TYPE=wayland", "XDG_SESSION_DESKTOP=tide", "XDG_CURRENT_DESKTOP=tide:Hyprland"]);
    assert.deepEqual(sessionFromEntry("hyprland", parseDesktopEntry(HYPR)).env,
        ["XDG_SESSION_TYPE=wayland", "XDG_SESSION_DESKTOP=hyprland"]);
});

test("a hidden, undisplayed, nameless or commandless file offers no session", () => {
    for (const text of [HYPR + "Hidden=true\n", HYPR + "NoDisplay=true\n", "[Desktop Entry]\nExec=x\n",
        "[Desktop Entry]\nName=x\nExec=%f\n", "[Desktop Entry]\nName=x\nExec=x\nType=Link\n"]) {
        assert.equal(sessionFromEntry("x", parseDesktopEntry(text)), null, text);
    }
    assert.equal(sessionFromEntry("x", null), null);
    assert.notEqual(sessionFromEntry("x", parseDesktopEntry(HYPR + "Hidden=false\n")), null);
});

test("a file's ID is its name without .desktop", () => {
    assert.equal(fileId("/usr/share/wayland-sessions/plasma.desktop"), "plasma");
    assert.equal(fileId("tide.desktop"), "tide");
});

test("tide leads, the rest follow by name, and the shell comes last", () => {
    const sessions = sessionList(parseListing(listing(
        [true, "/usr/share/wayland-sessions/plasma.desktop", PLASMA],
        [true, "/usr/share/wayland-sessions/hyprland.desktop", HYPR],
        [true, "/usr/local/share/wayland-sessions/tide.desktop", TIDE],
    )));
    assert.deepEqual(sessions.map((s) => s.name), ["tide", "Hyprland", "Plasma (Wayland)", "Shell"]);
    assert.equal(sessions[sessions.length - 1], SHELL_SESSION);
});

test("the first file with an ID counts, even when it hides or can't run", () => {
    const sessions = sessionList(parseListing(listing(
        [true, "/usr/local/share/wayland-sessions/hyprland.desktop", HYPR + "Hidden=true\n"],
        [true, "/usr/share/wayland-sessions/hyprland.desktop", HYPR],
        [false, "/usr/local/share/wayland-sessions/tide.desktop", TIDE],
        [true, "/usr/share/wayland-sessions/tide.desktop", TIDE],
        [true, "/usr/share/wayland-sessions/README", "not a session"],
    )));
    assert.deepEqual(sessions.map((s) => s.id), [SHELL_ID]);
});

test("the shell runs the user's login shell on a text session", () => {
    assert.equal(SHELL_SESSION.command, '"${SHELL:-/bin/sh}" -l');
    assert.deepEqual(SHELL_SESSION.env, ["XDG_SESSION_TYPE=tty"]);
    // No desktop file ID can be it: they're file names.
    assert.ok(SHELL_ID.includes("/"));
});

test("login.defs sets the range of people's UIDs, with its own defaults", () => {
    assert.deepEqual(uidRange(""), { min: 1000, max: 60000 });
    assert.deepEqual(uidRange("# UID_MIN 5\nUID_MIN\t\t 500\nUID_MAX 1999\nSYS_UID_MIN 100\n"), { min: 500, max: 1999 });
});

test("the users are people who can log in, by UID, with their names", () => {
    const passwd = [
        "root:x:0:0:root:/root:/bin/bash",
        "user2:x:1001:1001::/home/user2:/usr/bin/zsh",
        "user1:x:1000:1000:User One,,,:/home/user1:/bin/bash",
        "svc:x:1002:1002:Service:/var/svc:/usr/sbin/nologin",
        "off:x:1003:1003::/home/off:/bin/false",
        "nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin",
        "#user9:x:1009:1009::/home/user9:/bin/sh",
        "broken:x:abc:1::/:/bin/sh",
        "",
    ].join("\n");
    assert.deepEqual(parseUsers(passwd, uidRange("")), [
        { name: "user1", label: "User One" },
        { name: "user2", label: "user2" },
    ]);
});

test("the remembered user and session round-trip, and junk is nothing", () => {
    assert.deepEqual(parseRemembered(serializeRemembered("user1", "tide")), { user: "user1", session: "tide" });
    assert.deepEqual(parseRemembered("not json"), { user: "", session: "" });
    assert.deepEqual(parseRemembered('{"user": 3}'), { user: "", session: "" });
    assert.deepEqual(parseRemembered("null"), { user: "", session: "" });
});

test("the remembered user and session are preselected while they're still there", () => {
    const users = [{ name: "user1", label: "One" }, { name: "user2", label: "Two" }];
    assert.equal(pickUser(users, "user2"), "user2");
    assert.equal(pickUser(users, "gone"), "user1");
    assert.equal(pickUser([], "user2"), "");
    const sessions = sessionList(parseListing(listing(
        [true, "/s/hyprland.desktop", HYPR], [true, "/s/tide.desktop", TIDE])));
    assert.equal(pickSession(sessions, "hyprland"), "hyprland");
    assert.equal(pickSession(sessions, SHELL_ID), SHELL_ID);
    assert.equal(pickSession(sessions, "gone"), "tide");
    assert.equal(pickSession([], "tide"), "");
});

test("greetd's failures read as the lock's, and anything else is named", () => {
    assert.deepEqual(authFailureEvent("pam_authenticate: AUTH_ERR"), { type: "done", result: "failed" });
    assert.deepEqual(authFailureEvent("pam_authenticate: MAXTRIES"), { type: "done", result: "maxtries" });
    assert.deepEqual(authFailureEvent(""), { type: "done", result: "failed" });
    assert.deepEqual(authFailureEvent("pam_acct_mgmt: ACCT_EXPIRED"), { type: "failed", detail: "pam_acct_mgmt: ACCT_EXPIRED" });
    // Through the lock's state: a wrong password clears the field and says so.
    let state = next(INITIAL, { type: "key", text: "x" }).state;
    state = next(state, { type: "submit" }).state;
    state = next(state, authFailureEvent("pam_authenticate: AUTH_ERR")).state;
    assert.equal(state.message, "Wrong password. Try again.");
    assert.equal(state.checking, false);
});

test("a greetd error after the password was taken asks for it again", () => {
    let state = next(INITIAL, { type: "key", text: "x" }).state;
    state = next(state, { type: "submit" }).state;
    state = next(state, { type: "done", result: "success" }).state;
    assert.equal(statusText(state, "tide", ""), "Starting tide");
    const after = greetdError(state, "a session is already running", "tide");
    assert.equal(after.unlocked, false);
    assert.equal(after.checking, false);
    assert.equal(after.error, true);
    assert.equal(after.message, "Couldn't start tide: a session is already running.");
    assert.equal(statusText(after, "tide", after.message), after.message);
});

test("a greetd error while checking keeps what was typed since", () => {
    let state = next(INITIAL, { type: "key", text: "x" }).state;
    state = next(state, { type: "submit" }).state;
    state = next(state, { type: "key", text: "y" }).state;
    const after = greetdError(state, "", "tide");
    assert.equal(after.input, "y");
    assert.equal(after.message, "Couldn't log in: greetd failed.");
    assert.equal(Object.isFrozen(after), true);
});

test("the listing script reads every data dir's sessions, in order, and checks TryExec", () => {
    const root = mkdtempSync(join(tmpdir(), "greeter-"));
    try {
        const local = join(root, "local share");
        const usr = join(root, "usr");
        const bin = join(root, "bin");
        for (const d of [join(local, "wayland-sessions"), join(usr, "wayland-sessions"), bin]) {
            mkdirSync(d, { recursive: true });
        }
        writeFileSync(join(bin, "uwsm"), "#!/bin/sh\n");
        chmodSync(join(bin, "uwsm"), 0o755);
        writeFileSync(join(local, "wayland-sessions", "tide.desktop"), TIDE);
        // No final newline, and a TryExec that isn't installed.
        writeFileSync(join(usr, "wayland-sessions", "hyprland.desktop"), HYPR + "TryExec=no-such-hyprland");
        writeFileSync(join(usr, "wayland-sessions", "plasma.desktop"), PLASMA);
        writeFileSync(join(usr, "wayland-sessions", "notes.txt"), "not a session\n");
        const out = execFileSync("sh", ["-c", LISTING_SCRIPT], {
            env: { PATH: `${bin}:/usr/bin:/bin`, XDG_DATA_DIRS: `${local}:${join(root, "missing")}:${usr}` },
            encoding: "utf8",
        });
        const records = parseListing(out);
        assert.deepEqual(records.map((r) => [r.path, r.ok]), [
            [join(local, "wayland-sessions", "tide.desktop"), true],
            [join(usr, "wayland-sessions", "hyprland.desktop"), false],
            [join(usr, "wayland-sessions", "plasma.desktop"), true],
        ]);
        assert.equal(records[0].text.trimEnd(), TIDE.trimEnd());
        assert.deepEqual(sessionList(records).map((s) => s.id), ["tide", "plasma", SHELL_ID]);
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});

test("the listing script says which file it couldn't read, and exits 1", (t) => {
    if (process.getuid && process.getuid() === 0) {
        t.skip("root reads any file");
        return;
    }
    const root = mkdtempSync(join(tmpdir(), "greeter-"));
    try {
        mkdirSync(join(root, "wayland-sessions"));
        const locked = join(root, "wayland-sessions", "locked.desktop");
        writeFileSync(locked, HYPR);
        chmodSync(locked, 0o000);
        const r = spawnSync("sh", ["-c", LISTING_SCRIPT], { env: { PATH: "/usr/bin:/bin", XDG_DATA_DIRS: root }, encoding: "utf8" });
        assert.equal(r.status, 1);
        assert.match(r.stderr, /locked\.desktop/);
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});

test("without XDG_DATA_DIRS the listing reads the standard dirs", () => {
    assert.match(LISTING_SCRIPT, /\$\{XDG_DATA_DIRS:-\/usr\/local\/share:\/usr\/share\}/);
});

test("greetd's replies count only between Enter and its answer", () => {
    assert.equal(inConversation(INITIAL), false);
    let state = next(INITIAL, { type: "key", text: "x" }).state;
    assert.equal(inConversation(state), false);
    state = next(state, { type: "submit" }).state;
    assert.equal(inConversation(state), true);
    // A second prompt, for a one-time code: still in the conversation.
    state = next(state, { type: "pam", text: "Password: ", isError: false, responseRequired: true }).state;
    state = next(state, { type: "pam", text: "Code: ", isError: false, responseRequired: true }).state;
    assert.equal(state.awaiting, true);
    assert.equal(inConversation(state), true);
});

test("an Enter while greetd checks isn't held, but the keys typed are kept", () => {
    let state = next(INITIAL, { type: "key", text: "x" }).state;
    assert.equal(takes(state, { type: "submit" }), true);
    state = next(state, { type: "submit" }).state;
    assert.equal(takes(state, { type: "key", text: "y" }), true);
    assert.equal(takes(state, { type: "submit" }), false);
    assert.equal(takes(state, { type: "clear" }), true);
    state = next(state, { type: "key", text: "y" }).state;
    state = next(state, { type: "done", result: "failed" }).state;
    assert.equal(state.input, "y");
    assert.equal(takes(state, { type: "submit" }), true);
});

test("another user can be picked mid-login, but not once the session is starting", () => {
    assert.equal(canPickUser(INITIAL), true);
    let state = next(INITIAL, { type: "key", text: "x" }).state;
    assert.equal(canPickUser(state), true);
    state = next(state, { type: "submit" }).state;
    assert.equal(state.checking, true);
    assert.equal(canPickUser(state), true);
    state = next(state, { type: "pam", text: "Password: ", isError: false, responseRequired: true }).state;
    state = next(state, { type: "pam", text: "Code: ", isError: false, responseRequired: true }).state;
    assert.equal(state.awaiting, true);
    assert.equal(canPickUser(state), true);
    state = next(state, { type: "done", result: "failed" }).state;
    assert.equal(canPickUser(state), true);
    state = next(next(state, { type: "submit" }).state, { type: "done", result: "success" }).state;
    assert.equal(state.unlocked, true);
    assert.equal(canPickUser(state), false);
});
