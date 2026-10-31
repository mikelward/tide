// Tests for startup.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
    commandError,
    commandWords,
    editableStartup,
    editedStartup,
    launchCommand,
    loadStartup,
    movedCommand,
    parseStartupFile,
    runFailure,
    SESSION_COMMAND,
    STARTED,
    queueEnded,
    homeRuns,
    listRuns,
    queuePrinted,
    startQueue,
    sessionId,
    startupDue,
    withCommand,
    withoutCommand,
} from "./startup.mjs";

test("a command is a program and its arguments, split at spaces", () => {
    assert.deepEqual(commandWords("  chrome  --app=https://chat.google.com\t"), ["chrome", "--app=https://chat.google.com"]);
    assert.equal(commandError("google-calendar"), "");
    assert.equal(commandError("chrome --app=https://x.example/?a=1&b=2"), "", "no shell reads & or ?");
});

test("a command with shell syntax, a control character or nothing is refused, saying why", () => {
    assert.match(commandError("echo \"hi\""), /quote, backslash or \$.*put shell syntax in a script/);
    assert.match(commandError("echo 'hi'"), /quote/);
    assert.match(commandError("run $HOME/x"), /\$/);
    assert.match(commandError("a\\ b"), /backslash/);
    assert.match(commandError("a\nb"), /one line/);
    assert.match(commandError("   "), /needs a program/);
    assert.match(commandError("/opt/helpers/ --x"), /\/opt\/helpers\/ is a directory, not a program/, "its basename names nothing to run or match");
    assert.match(commandError(3), /is text/);
});

test("the local file's list replaces the shared one whole, and none is the default", () => {
    assert.deepEqual(loadStartup(null, null), { commands: [], errors: [] });
    assert.deepEqual(loadStartup('{"commands": ["a"]}', null).commands, ["a"]);
    assert.deepEqual(loadStartup('{"commands": ["a"]}', '{"commands": ["b", "c"]}').commands, ["b", "c"]);
    assert.deepEqual(loadStartup('{"commands": ["a"]}', '{}').commands, ["a"], "a local file without a list keeps the shared one");
    assert.deepEqual(loadStartup('{"commands": ["a"]}', '{"commands": []}').commands, [], "an empty local list runs nothing");
});

test("a bad entry is an error naming its file and place, and the rest still run", () => {
    const r = loadStartup(null, '{"commands": ["google-calendar", "echo $HOME", 7, "google-calendar", "google-chat"]}');
    assert.deepEqual(r.commands, ["google-calendar", "google-chat"]);
    assert.equal(r.errors.length, 3);
    assert.match(r.errors[0], /^startup\.local\.json: commands entry 2: echo \$HOME has a quote/);
    assert.match(r.errors[1], /^startup\.local\.json: commands entry 3: a command is text/);
    assert.match(r.errors[2], /^startup\.local\.json: commands entry 4: google-calendar is listed already/);
});

test("a file that doesn't parse runs nothing, naming the file and line", () => {
    const r = loadStartup('{"commands": ["a"]}', '{\n  "commands": ["b",\n}');
    assert.equal(r.commands, null);
    assert.match(r.errors[0], /^startup\.local\.json: line 3: /);
    assert.match(loadStartup('["a"]', null).errors[0], /expected an object/);
    assert.match(loadStartup('{"commands": "a"}', null).errors[0], /commands must be a list/);
    assert.match(parseStartupFile('{"comands": []}').errors[0], /unknown setting "comands"/);
});

test("the page changes the local file, copying the shared list in first", () => {
    const shared = '{"commands": ["google-calendar"]}';
    assert.deepEqual(editableStartup(shared, null), { commands: ["google-calendar"], source: "startup.json" });
    const r = editedStartup(shared, null, c => withCommand(c, " google-chat "));
    assert.deepEqual(r.commands, ["google-calendar", "google-chat"]);
    assert.deepEqual(JSON.parse(r.text), { commands: ["google-calendar", "google-chat"] });
    assert.ok(r.text.endsWith("\n"));
});

test("a change keeps the local file's other keys, and never writes over one that doesn't parse", () => {
    const r = editedStartup(null, '{"commands": ["a"], "later": true}', c => withoutCommand(c, 0, "a"));
    assert.deepEqual(JSON.parse(r.text), { commands: [], later: true });
    assert.match(editedStartup(null, "{", c => ({ commands: c })).error, /^startup\.local\.json: /);
});

test("adding refuses a bad or repeated command", () => {
    assert.match(withCommand(["a"], "a").error, /a is listed already/);
    assert.match(withCommand(["a b"], "a   b").error, /listed already/, "compared by its words");
    assert.match(withCommand([], "x 'y'").error, /quote/);
});

test("moving stops at either end, and a change names its entry by place and text", () => {
    assert.deepEqual(movedCommand(["a", "b", "c"], 2, "c", -1).commands, ["a", "c", "b"]);
    assert.deepEqual(movedCommand(["a", "b"], 0, "a", -1).commands, ["a", "b"]);
    assert.deepEqual(movedCommand(["a", "b"], undefined, "a", 5).commands, ["b", "a"], "IPC names it by text alone");
    assert.match(movedCommand(["b", "a"], 0, "a", 1).error, /entry 1 isn't a/, "a hand edit moved it");
    assert.match(withoutCommand(["a"], undefined, "z").error, /z isn't listed/);
    assert.deepEqual(withoutCommand(["a", "b"], 1, "b").commands, ["a"]);
});

test("each runs through tide launch, in the background, unless it's running", () => {
    assert.deepEqual(launchCommand("chrome  --app=https://chat.google.com"),
        ["tide", "launch", "--background", "--unless-running", "--", "chrome", "--app=https://chat.google.com"]);
});

test("a failed run names the command and the last thing it said", () => {
    assert.equal(runFailure("a", true, "warning\n"), "");
    assert.equal(runFailure("google-chat", false, "tide launch: waiting\nchrome: no Linux Chrome installed\n"), "google-chat: chrome: no Linux Chrome installed");
    assert.equal(runFailure("x", false, ""), "x: it exited with a failure");
});

test("the list runs once a graphical session, not once a runtime directory", () => {
    const a = "0123456789abcdef0123456789abcdef";
    const b = "fedcba9876543210fedcba9876543210";
    assert.deepEqual(startupDue(null, a), { run: true, record: `${a}\n`, warn: "" });
    assert.deepEqual(startupDue(`${a}\n`, a), { run: false, record: null, warn: "" }, "a shell restart runs nothing");
    // The runtime directory outlived a logout (an SSH login, lingering):
    // the next login's session is another, so it runs again.
    assert.deepEqual(startupDue(`${a}\n`, b), { run: true, record: `${b}\n`, warn: "" });
    assert.equal(startupDue("", b).run, true, "an old empty record runs it");
});

test("a session that can't be read runs the list only with no record, saying why", () => {
    const first = startupDue(null, "");
    assert.equal(first.run, true);
    assert.match(first.warn, /couldn't read the graphical session's ID/);
    const again = startupDue(first.record, "");
    assert.equal(again.run, false);
    assert.match(again.warn, /not running Start at login's commands again/);
});

test("the session's ID is graphical-session.target's invocation ID, or none", () => {
    assert.deepEqual(SESSION_COMMAND, ["systemctl", "--user", "show", "-p", "InvocationID", "--value", "graphical-session.target"]);
    assert.equal(sessionId("0123456789abcdef0123456789abcdef\n"), "0123456789abcdef0123456789abcdef");
    assert.equal(sessionId("\n"), "", "a target that isn't active has none");
    assert.equal(sessionId("Failed to connect to bus"), "");
});

test("each command starts once the one before it has started, in the list's order", () => {
    let r = startQueue(["a", "b", "c"]);
    assert.deepEqual(r.start, { index: 0, command: "a" });
    r = queuePrinted(r.state, 0, "some output of a's");
    assert.equal(r.start, null, "only the marker counts");
    r = queuePrinted(r.state, 0, STARTED);
    assert.deepEqual(r.start, { index: 1, command: "b" });
    const afterB = queuePrinted(r.state, 0, STARTED);
    assert.equal(afterB.start, null, "a second marker from a starts nothing more");
    assert.equal(queueEnded(r.state, 0).start, null, "nor does a ending later, as Chrome does at logout");
    r = queueEnded(r.state, 1);
    assert.deepEqual(r.start, { index: 2, command: "c" }, "b skipped or failed: c starts");
    assert.equal(queuePrinted(r.state, 1, STARTED).start, null, "b can't advance twice");
    r = queuePrinted(r.state, 2, STARTED);
    assert.equal(r.start, null, "nothing after the last");
    assert.equal(queueEnded(r.state, 2).start, null);
});

test("an empty list starts nothing", () => {
    assert.equal(startQueue([]).start, null);
});

test("the line the shell waits for before the next command is the one tide launch prints", () => {
    const tide = readFileSync(new URL("../../bin/tide", import.meta.url), "utf8");
    assert.ok(tide.includes(`echo "${STARTED}"\n    exec uwsm app -- "$@"`), "printed just before it starts the command");
});

// Regression: home's apps were only a window rule, so nothing opened on
// home at login unless Start at login listed it too (SPEC.md §6.5).
test("home's apps start as a list of their own, and the list skips them", () => {
    const home = [
        { name: "gmail", argv: ["tide", "launch", "--background", "--unless-running", "--", "gmail"], program: "gmail" },
        { name: "https://music.youtube.com", argv: ["tide", "launch", "--background", "--", "tide", "web-app", "https://music.youtube.com"], program: null },
    ];
    assert.deepEqual(homeRuns(home), [
        { name: "gmail", argv: home[0].argv },
        { name: "https://music.youtube.com", argv: home[1].argv },
    ]);
    assert.deepEqual(listRuns(home, ["gmail", "slack --x"]), [{ name: "slack --x", argv: launchCommand("slack --x") }]);
    assert.deepEqual(listRuns([], ["a"]), [{ name: "a", argv: launchCommand("a") }]);
    assert.deepEqual(homeRuns([]), []);
});
