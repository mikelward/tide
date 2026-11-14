// Tests for configerrors.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
    NOTHING, SHOWN, ICON, OUTDATED, replyErrors, keyOf, newsOf, warns, outdatedOf, loaded, versioned, unversioned, unreadable, sent, pending, retry,
    summary, body, notifyCommand, parts, listed, advice, asksForErrors, hyprlandErrors, compositorName,
} from "./configerrors.mjs";

const A = "/home/me/.config/tidewm/config:12: no setting is called bindcode";
const B = "/home/me/.config/tidewm/tide-keys.conf:3: bindsym needs keys and a command";

function reply(fields) {
    return JSON.stringify(Object.assign({ config: "", included_configs: [], path: "/home/me/.config/tidewm/config" }, fields));
}

test("GET_CONFIG's errors are read as tidewm worded them", () => {
    assert.deepEqual(replyErrors(reply({ errors: [A, B] })), { errors: [A, B] });
    assert.deepEqual(replyErrors(reply({ errors: [] })), { errors: [] });
});

test("a reply that doesn't say isn't taken for one with no errors, or with some", () => {
    for (const text of ["", "  \n", "not json", "null", "[]", "3", reply({}), reply({ errors: null }),
        reply({ errors: "bad" }), reply({ errors: [A, 3] }), reply({ errors: { a: 1 } }), undefined, null]) {
        const read = replyErrors(text);
        assert.equal(read.errors, undefined, String(text));
        assert.equal(typeof read.why, "string", String(text));
        assert.notEqual(read.why, "", String(text));
    }
    assert.match(replyErrors(reply({})).why, /older tidewm/);
});

test("a set of errors is the same set in any order", () => {
    assert.equal(keyOf([]), "");
    assert.equal(keyOf([A, B]), keyOf([B, A, A]));
    assert.notEqual(keyOf([A]), keyOf([A, B]));
});

test("new errors are notified once, however often they're reported", () => {
    let r = loaded(NOTHING, [A, B]);
    assert.equal(r.notify, true);
    assert.deepEqual(r.state.errors, [A, B]);
    // The same again while the notification is on its way.
    r = loaded(r.state, [A, B]);
    assert.equal(r.notify, false);
    const told = sent(r.state, keyOf([A, B]), true);
    assert.equal(pending(told), false);
    // A reconnect, or a reload, with the same errors in another order.
    assert.equal(loaded(told, [B, A]).notify, false);
    assert.deepEqual(loaded(told, [B, A]).state.errors, [B, A]);
});

test("a different set is notified", () => {
    const told = sent(loaded(NOTHING, [A, B]).state, keyOf([A, B]), true);
    assert.equal(loaded(told, [A]).notify, true);
});

test("a load with no errors shows none, and the same mistake made again is news", () => {
    const told = sent(loaded(NOTHING, [A]).state, keyOf([A]), true);
    const fixed = loaded(told, []);
    assert.equal(fixed.notify, false);
    assert.deepEqual(fixed.state.errors, []);
    assert.equal(loaded(fixed.state, [A]).notify, true);
});

test("errors that can't be read show nothing, and are no news when they're back", () => {
    const told = sent(loaded(NOTHING, [A]).state, keyOf([A]), true);
    const lost = unreadable(told);
    assert.deepEqual(lost.errors, []);
    assert.equal(pending(lost), false);
    assert.equal(loaded(lost, [A]).notify, false);
});

test("a notification that wasn't delivered is sent again", () => {
    const first = loaded(NOTHING, [A]);
    assert.equal(pending(first.state), false, "it's on its way");
    const failed = sent(first.state, keyOf([A]), false);
    assert.equal(pending(failed), true);
    const again = retry(failed);
    assert.equal(again.notify, true);
    assert.equal(retry(again.state).notify, false);
    assert.equal(pending(sent(again.state, keyOf([A]), true)), false);
});

test("a notification for errors since replaced doesn't count for the new ones", () => {
    const first = loaded(NOTHING, [A]);
    const second = loaded(first.state, [B]);
    assert.equal(second.notify, true);
    const done = sent(sent(second.state, keyOf([A]), true), keyOf([B]), false);
    assert.equal(pending(done), true);
});

test("the summary counts the errors in plain words", () => {
    assert.equal(summary([]), "");
    assert.equal(summary([A]), "tidewm's config has 1 error");
    assert.equal(summary([A, B]), "tidewm's config has 2 errors");
});

test("the notification is critical, from tide, and says where to see them", () => {
    assert.deepEqual(notifyCommand([A, B]), ["notify-send", "--app-name=tide", "--urgency=critical",
        `--icon=${ICON}`, "tidewm's config has 2 errors",
        "Click the warning in the bar to see them, or run tide doctor."]);
    assert.equal(body([A]), "Click the warning in the bar to see it, or run tide doctor.");
});

test("an error splits into where and what, with home as ~", () => {
    assert.deepEqual(parts(A, "/home/me"), { where: "~/.config/tidewm/config:12", what: "no setting is called bindcode" });
    assert.deepEqual(parts(A), { where: "/home/me/.config/tidewm/config:12", what: "no setting is called bindcode" });
    // One with no line, as a file that isn't there, or an output's.
    assert.deepEqual(parts("/home/me/.config/tidewm/config: there's no such file", "/home/me"),
        { where: "~/.config/tidewm/config", what: "there's no such file" });
    // Another home that starts the same isn't this one.
    assert.equal(parts("/home/meg/config:1: x", "/home/me").where, "/home/meg/config:1");
    // What isn't in that shape is shown whole.
    assert.deepEqual(parts("something else: went wrong", "/home/me"), { where: "", what: "something else: went wrong" });
});

test("a long list is cut short, saying how many more there are", () => {
    const many = [];
    for (let i = 1; i <= SHOWN + 3; i++) {
        many.push(`/c:${i}: no setting is called s${i}`);
    }
    const all = listed(many.slice(0, SHOWN));
    assert.equal(all.rows.length, SHOWN);
    assert.equal(all.more, "");
    const cut = listed(many);
    assert.equal(cut.rows.length, SHOWN);
    assert.deepEqual(cut.rows[0], { where: "/c:1", what: "no setting is called s1" });
    assert.equal(cut.more, "and 3 more: tide doctor lists them all");
    assert.deepEqual(listed([]), { rows: [], more: "" });
});

test("the advice counts too", () => {
    assert.equal(advice([A]), "Fix it, then reload tidewm's config.");
    assert.equal(advice([A, B]), "Fix them, then reload tidewm's config.");
});

test("the errors are asked for as the listener connects and when a key reloads the config", () => {
    assert.equal(asksForErrors("tick", { first: true, payload: "" }), true);
    assert.equal(asksForErrors("tick", JSON.stringify({ first: true, payload: "" })), true);
    assert.equal(asksForErrors("tick", { first: false, payload: "x" }), false);
    const binding = command => ({ change: "run", binding: { command, input_type: "keyboard" } });
    assert.equal(asksForErrors("binding", binding("reload")), true);
    assert.equal(asksForErrors("binding", JSON.stringify(binding("exec notify-send hi; reload "))), true);
    assert.equal(asksForErrors("binding", binding("exec tide reload")), false);
    assert.equal(asksForErrors("binding", binding('exec echo "a; reload"')), false);
    assert.equal(asksForErrors("binding", binding("floating toggle")), false);
    assert.equal(asksForErrors("binding", { change: "run" }), false);
    assert.equal(asksForErrors("window", { change: "new" }), false);
    assert.equal(asksForErrors("binding", "not json"), false);
    assert.equal(asksForErrors("tick", undefined), false);
    // tidewm's reload event, from any reload, as i3 and sway send it.
    assert.equal(asksForErrors("workspace", { change: "reload", current: null, old: null }), true);
    assert.equal(asksForErrors("workspace", JSON.stringify({ change: "focus" })), false);
});

test("Hyprland's errors are hyprctl configerrors' lines, and its words name Hyprland", () => {
    assert.deepEqual(hyprlandErrors(""), { errors: [] });
    assert.deepEqual(hyprlandErrors("\n"), { errors: [] });
    assert.deepEqual(hyprlandErrors("Config error in file /c/hyprland.lua at line 3: x\n  second  \n"),
        { errors: ["Config error in file /c/hyprland.lua at line 3: x", "second"] });
    // hyprctl that failed, as with no Hyprland to ask, says nothing is known.
    assert.equal(hyprlandErrors("", false).errors, undefined);
    assert.equal(compositorName(false), "Hyprland");
    assert.equal(compositorName(true), "tidewm");
    assert.equal(summary(["x"], "Hyprland"), "Hyprland's config has 1 error");
    assert.equal(advice(["x", "y"], "Hyprland"), "Fix them, then reload Hyprland's config.");
    assert.equal(notifyCommand(["x"], "Hyprland")[4], "Hyprland's config has 1 error");
});

test("tide-msg --outdated's exit status says whether tidewm was updated, or nothing", () => {
    assert.equal(outdatedOf(0), true);
    assert.equal(outdatedOf(1), false);
    // An older tide-msg's usage error, or no tidewm to ask.
    assert.equal(outdatedOf(2), undefined);
    assert.equal(outdatedOf(127), undefined);
});

test("a tidewm that was updated warns with no errors, and is notified once", () => {
    assert.equal(warns(NOTHING), false);
    let r = versioned(NOTHING, true);
    assert.equal(r.notify, true);
    assert.equal(warns(r.state), true);
    assert.deepEqual(r.state.errors, []);
    // Asked again on a reconnect, while the notification is on its way.
    assert.equal(versioned(r.state, true).notify, false);
    const told = sent(r.state, newsOf(r.state), true);
    assert.equal(pending(told), false);
    assert.equal(versioned(told, true).notify, false);
});

test("after an update, errors coming and going aren't more news", () => {
    const told = sent(versioned(NOTHING, true).state, OUTDATED, true);
    let r = loaded(told, [A, B]);
    assert.equal(r.notify, false, "the old tidewm's errors");
    assert.deepEqual(r.state.errors, [A, B]);
    assert.equal(r.state.outdated, true);
    r = loaded(r.state, []);
    assert.equal(r.notify, false);
    assert.equal(warns(r.state), true, "still to log out");
    assert.equal(unreadable(r.state).outdated, true);
});

test("an update found after its errors were notified is said once more", () => {
    const told = sent(loaded(NOTHING, [A]).state, keyOf([A]), true);
    const r = versioned(told, true);
    assert.equal(r.notify, true);
    assert.equal(retry(sent(r.state, OUTDATED, false)).notify, true, "and again if it didn't arrive");
});

test("a tidewm that's the one installed warns only of errors", () => {
    assert.equal(versioned(NOTHING, false).notify, false);
    assert.equal(warns(versioned(NOTHING, false).state), false);
    const r = versioned(loaded(NOTHING, [A]).state, false);
    assert.equal(warns(r.state), true);
    assert.equal(newsOf(r.state), keyOf([A]));
});

test("an update says to log out and back in, not to fix errors and reload", () => {
    assert.equal(summary([], "tidewm", true), "tidewm was updated");
    assert.equal(summary([A, B], "tidewm", true), "tidewm was updated");
    assert.equal(body([A, B], true), "Log out and back in to use it.");
    assert.equal(advice([], "tidewm", true), "Log out and back in to use it.");
    assert.match(advice([A, B], "tidewm", true), /^Log out and back in/);
    assert.doesNotMatch(advice([A, B], "tidewm", true), /reload/);
    const command = notifyCommand([A, B], "tidewm", true);
    assert.deepEqual(command.slice(-2), ["tidewm was updated", "Log out and back in to use it."]);
});

test("an update already told of isn't news again, whichever answers first after a shell reload", () => {
    // The shell starts over with what it told of kept, and the errors and
    // the version are asked side by side.
    const kept = sent(NOTHING, OUTDATED, true);
    let r = loaded(kept, []);
    assert.equal(r.state.told, OUTDATED);
    assert.equal(versioned(r.state, true).notify, false, "the errors first");
    r = versioned(kept, true);
    assert.equal(r.notify, false);
    assert.equal(loaded(r.state, [A]).notify, false, "the version first");
    // And errors told of aren't forgotten by a version that says nothing new.
    const errors = sent(NOTHING, keyOf([A]), true);
    assert.equal(loaded(versioned(errors, false).state, [A]).notify, false);
});

test("an update that's over is forgotten, so the next one is news", () => {
    const told = sent(versioned(NOTHING, true).state, OUTDATED, true);
    const over = versioned(told, false);
    assert.equal(over.state.told, "");
    assert.equal(warns(over.state), false);
    assert.equal(versioned(over.state, true).notify, true);
});

// A shell that reloads remembers it told of the update, and asks for the
// errors and the version again. The errors answering first, unchanged,
// aren't news, and nor is the update after them.
test("a reloaded shell says neither the update nor its errors again", () => {
    const remembered = sent(NOTHING, OUTDATED, true);
    const errors = ["tide.conf:177: bindsym has no flag --desc"];
    const first = loaded(remembered, errors);
    assert.equal(first.notify, false, "the errors, before the version is in");
    assert.equal(pending(first.state), false, "and none is owed meanwhile");
    assert.deepEqual(first.state.errors, errors, "though the bar lists them");
    const second = versioned(first.state, true);
    assert.equal(second.notify, false, "nor the update, told of already");
    assert.equal(second.state.told, OUTDATED);
    assert.equal(loaded(second.state, errors).notify, false, "nor the errors at a later load");
});

test("errors that waited on the version are said once it's not an update, or can't be told", () => {
    const remembered = sent(NOTHING, OUTDATED, true);
    const errors = ["tide.conf:3: unknown command"];
    const waiting = loaded(remembered, errors).state;
    const current = versioned(waiting, false);
    assert.equal(current.notify, true, "tidewm is the one installed after all");
    assert.equal(current.state.sending, keyOf(errors));
    const unknown = unversioned(waiting);
    assert.equal(unknown.notify, true, "it couldn't be told");
    assert.equal(unknown.state.sending, keyOf(errors));
    assert.equal(unversioned(loaded(remembered, []).state).notify, false, "with no errors there's nothing to say");
});
