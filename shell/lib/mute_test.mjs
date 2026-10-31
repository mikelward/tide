// Tests for mute.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { loadWorkspaceSettings, withMuted } from "./workspacenames.mjs";
import { appWindowSite, windowMuted, noteOf, noteMuted, windowEntry, noteEntry, toggledMuted, groupNote } from "./mute.mjs";

test("an app ID mutes windows as home's apps match them", () => {
    assert.equal(windowMuted("org.gnome.Nautilus", ["nautilus"]), true, "a bare name, the last part of a qualified one");
    assert.equal(windowMuted("Slack", ["slack.desktop"]), true, "ignoring case and .desktop");
    assert.equal(windowMuted("kitty", ["nautilus"]), false);
    assert.equal(windowMuted("", ["nautilus"]), false);
    assert.equal(windowMuted("kitty", []), false);
});

test("a site mutes its --app windows and its subdomains', not the browser", () => {
    assert.equal(appWindowSite("chrome-chat.google.com__-Default"), "chat.google.com");
    assert.equal(appWindowSite("google-chrome"), null);
    assert.equal(windowMuted("chrome-chat.google.com__-Default", ["site:chat.google.com"]), true);
    assert.equal(windowMuted("chromium-chat.google.com__-Profile_1", ["site:google.com"]), true, "a subdomain");
    assert.equal(windowMuted("chrome-mail.google.com__-Default", ["site:chat.google.com"]), false);
    assert.equal(windowMuted("google-chrome", ["site:chat.google.com"]), false);
    assert.equal(windowMuted("chrome-notchat.google.com.evil__-Default", ["site:chat.google.com"]), false);
});

test("a notification is muted by its app, or by the site Chrome named", () => {
    const chat = noteOf("google-chrome", "Google Chrome", "chat.google.com");
    assert.deepEqual(chat, { id: "google-chrome", site: "chat.google.com", system: false });
    assert.equal(noteMuted(chat, ["site:chat.google.com"]), true);
    assert.equal(noteMuted(chat, ["site:google.com"]), true);
    assert.equal(noteMuted(chat, ["site:mail.google.com"]), false);
    assert.equal(noteMuted(chat, ["google-chrome"]), true, "muting the browser mutes its sites too");
    const slack = noteOf("", "Slack", "");
    assert.equal(noteMuted(slack, ["slack"]), true, "the app name when there's no desktop entry");
    // Any app can send the hint, so only Chrome's or Chromium's site counts.
    const other = noteOf("org.example.Chat", "", "chat.google.com");
    assert.equal(other.site, null);
    assert.equal(noteMuted(other, ["site:chat.google.com"]), false);
});

test("a system sender is never muted, so its criticals still get through", () => {
    assert.equal(noteMuted(noteOf("tide", "tide", ""), ["tide"]), false);
    assert.equal(noteMuted(noteOf("", "polkit-gnome-authentication-agent-1", ""), ["polkit-gnome-authentication-agent-1"]), false);
    assert.equal(noteMuted(noteOf("tide", "tide", "chat.google.com"), ["site:chat.google.com"]), false);
});

test("muting a row adds an --app window's site, else its class", () => {
    assert.equal(windowEntry("chrome-chat.google.com__-Default"), "site:chat.google.com");
    assert.equal(windowEntry("org.gnome.Nautilus"), "org.gnome.Nautilus");
    assert.equal(noteEntry(noteOf("google-chrome", "", "chat.google.com")), "site:chat.google.com");
    assert.equal(noteEntry(noteOf("", "Slack", "")), "Slack");
});

test("toggling mutes, then unmutes, removing every entry that mutes it", () => {
    const isMuted = (list) => windowMuted("org.gnome.Nautilus", list);
    let r = toggledMuted(["slack"], isMuted, "org.gnome.Nautilus");
    assert.deepEqual(r, { list: ["slack", "org.gnome.Nautilus"], muted: true });
    r = toggledMuted(["slack", "nautilus", "org.gnome.Nautilus"], isMuted, "org.gnome.Nautilus");
    assert.deepEqual(r, { list: ["slack"], muted: false }, "a broad entry goes too, so the row is unmuted");
    assert.deepEqual(toggledMuted([], () => false, ""), { list: [], muted: false }, "nothing to mute it by");
});

test("a center group mutes its newest entry's site, else its app", () => {
    const group = { app: "Google Chrome", items: [
        { entry: "google-chrome", app: "Google Chrome", origin: "chat.google.com" },
        { entry: "google-chrome", app: "Google Chrome", origin: "mail.google.com" },
    ] };
    assert.equal(noteEntry(groupNote(group)), "site:chat.google.com");
    assert.equal(noteEntry(groupNote({ app: "Slack", items: [{ entry: "", app: "Slack", origin: "" }] })), "Slack");
});

test("a spaced app name, a notification's fallback with no desktop entry, stays muted after a reload", () => {
    const note = noteOf("", "Example App", "");
    const r = toggledMuted([], (list) => noteMuted(note, list), noteEntry(note));
    assert.deepEqual(r, { list: ["Example App"], muted: true });
    const text = withMuted(null, r.list).text;
    const { settings, warnings } = loadWorkspaceSettings(null, text);
    assert.deepEqual(warnings, []);
    assert.equal(noteMuted(note, settings.muted), true);
});

test("toggling never writes an entry the list would refuse", () => {
    assert.deepEqual(toggledMuted([], () => false, "site:"), { list: [], muted: false });
    assert.deepEqual(toggledMuted([], () => false, "bell\u0007"), { list: [], muted: false });
});

test("each mute surface matches the entry it writes, a .desktop-suffixed ID included", () => {
    // A window's row: Ctrl+M writes its class, which then mutes it.
    for (const cls of ["org.telegram.desktop", "org.gnome.Nautilus", "Example App", "chrome-chat.google.com__-Default"]) {
        const r = toggledMuted([], (list) => windowMuted(cls, list), windowEntry(cls));
        assert.equal(r.muted, true, cls);
        assert.equal(windowMuted(cls, r.list), true, `${cls} is muted by ${r.list}`);
        const back = toggledMuted(r.list, (list) => windowMuted(cls, list), windowEntry(cls));
        assert.deepEqual(back, { list: [], muted: false }, `${cls} unmutes`);
    }
    // A notification, from the center's group header or the switcher.
    for (const [entry, app, origin] of [["org.telegram.desktop", "Telegram", ""], ["", "Example App", ""], ["google-chrome", "", "chat.google.com"]]) {
        const note = noteOf(entry, app, origin);
        const r = toggledMuted([], (list) => noteMuted(note, list), noteEntry(note));
        assert.equal(r.muted, true, entry || app);
        assert.equal(noteMuted(note, r.list), true, `${entry || app} is muted by ${r.list}`);
    }
    // Telegram's window and its notifications are the same app, however
    // either spells it.
    assert.equal(windowMuted("org.telegram.desktop", ["org.telegram"]), true);
    assert.equal(noteMuted(noteOf("org.telegram.desktop", "", ""), ["org.telegram"]), true);
    assert.equal(noteMuted(noteOf("org.telegram", "", ""), ["org.telegram.desktop"]), true);
});
