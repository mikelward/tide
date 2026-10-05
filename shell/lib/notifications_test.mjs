// Tests for notifications.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { timeoutFor, MAX_SHOWN, stackHeight, withDraft, replyDraft, shown, syncKey, arrive, leave, grantId, clearsMarks, defaultAction, buttons, bodyStyled, iconFile, themedImageName, countdown, held, hold, release, restarted, due, nextDeadline, passesDnd, heldByDnd, ORIGIN_HINT, isChrome, originText, siteOf, siteFrom, siteWindowClasses, browserOf, targetApps, originLabel, joinLabel, rest, wake, unkept, isLive, arriveResting } from "./notifications.mjs";

// Quickshell's NotificationUrgency values.
const URGENCY = { Low: 0, Normal: 1, Critical: 2 };

test("low lasts 4 s, normal 6 s, and critical until dismissed", () => {
    assert.equal(timeoutFor(URGENCY.Low, URGENCY), 4000);
    assert.equal(timeoutFor(URGENCY.Normal, URGENCY), 6000);
    assert.equal(timeoutFor(URGENCY.Critical, URGENCY), 0);
});

test("three show, newest on top, and the rest wait their turn", () => {
    const queue = ["a", "b", "c", "d"];
    assert.equal(MAX_SHOWN, 3);
    assert.deepEqual(shown(queue), ["c", "b", "a"]);
    assert.deepEqual(shown(leave(queue, "b")), ["d", "c", "a"]);
    assert.deepEqual(shown([]), []);
});

test("a notification joins the end of the queue, once", () => {
    const a = { appName: "mail", hints: {} };
    const b = { appName: "chat", hints: {} };
    let { queue, replaced } = arrive([], a);
    ({ queue, replaced } = arrive(queue, b));
    assert.deepEqual(queue, [a, b]);
    assert.equal(replaced, null);
    assert.deepEqual(arrive(queue, a), { queue, replaced: null });
});

test("a synchronous key from the same app replaces in place", () => {
    const first = { appName: "volume", hints: { "x-canonical-private-synchronous": "volume" } };
    const other = { appName: "mail", hints: {} };
    const second = { appName: "volume", hints: { "x-canonical-private-synchronous": "volume" } };
    const { queue, replaced } = arrive([first, other], second);
    assert.deepEqual(queue, [second, other]);
    assert.equal(replaced, first);
});

test("the same key from another app doesn't replace", () => {
    const first = { appName: "a", hints: { "x-canonical-private-synchronous": "k" } };
    const second = { appName: "b", hints: { "x-canonical-private-synchronous": "k" } };
    assert.deepEqual(arrive([first], second), { queue: [first, second], replaced: null });
});

test("only a nonempty string is a synchronous key", () => {
    assert.equal(syncKey({ "x-canonical-private-synchronous": "brightness" }), "brightness");
    assert.equal(syncKey({ "x-canonical-private-synchronous": "" }), null);
    assert.equal(syncKey({ "x-canonical-private-synchronous": 3 }), null);
    assert.equal(syncKey(undefined), null);
});

test("a click grants the desktop entry, else the app name", () => {
    assert.equal(grantId({ desktopEntry: "google-chrome", appName: "Google Chrome" }), "google-chrome");
    assert.equal(grantId({ desktopEntry: " ", appName: "Thunderbird" }), "Thunderbird");
    assert.equal(grantId({ desktopEntry: "", appName: "" }), null);
});

test("the default action is the click, and the rest are buttons", () => {
    const actions = [
        { identifier: "default", text: "Open" },
        { identifier: "reply", text: "Reply" },
        { identifier: "blank", text: "" },
    ];
    assert.equal(defaultAction(actions), actions[0]);
    assert.deepEqual(buttons(actions), [actions[1]]);
    assert.equal(defaultAction([]), null);
});

test("body markup keeps bold, italic and underline, and drops links' targets and images", () => {
    assert.equal(bodyStyled("<b>Ann</b>: <i>hi</i> <u>there</u>"), "<b>Ann</b>: <i>hi</i> <u>there</u>");
    assert.equal(bodyStyled('see <a href="https://example.com/x">this</a>'), "see this");
    assert.equal(bodyStyled('<img src="https://example.com/t.png" alt="pic"/>done'), "done");
});

test("anything else in a body is text, not markup", () => {
    assert.equal(bodyStyled("<script>x</script> 1 < 2 & 3"), "&lt;script&gt;x&lt;/script&gt; 1 &lt; 2 &amp; 3");
    assert.equal(bodyStyled('<font color="red">hot</font>'), '&lt;font color="red"&gt;hot&lt;/font&gt;');
});

test("a body keeps its line breaks and the entities it already escaped", () => {
    assert.equal(bodyStyled("one\ntwo<br/>three"), "one<br>two<br>three");
    assert.equal(bodyStyled("Tom &amp; Jerry &lt;3"), "Tom &amp; Jerry &lt;3");
});

test("an app icon is a themed name, or a path or file URL to an image", () => {
    assert.equal(iconFile("mail-unread"), null);
    assert.equal(iconFile("/usr/share/pixmaps/app.png"), "file:///usr/share/pixmaps/app.png");
    assert.equal(iconFile("file:///tmp/a.png"), "file:///tmp/a.png");
});

test("an image that names a theme icon gives the name, so a missing one can be dropped", () => {
    assert.equal(themedImageName("image://icon/firefox"), "firefox");
    assert.equal(themedImageName("image://icon/firefox?path=/opt/icons"), "firefox");
    assert.equal(themedImageName("file:///tmp/avatar.png"), null);
    assert.equal(themedImageName("image://qsimage/42"), null);
    assert.equal(themedImageName(""), null);
    assert.equal(themedImageName(undefined), null);
});

test("a countdown runs out at its deadline", () => {
    const c = countdown(6000, 1000);
    assert.equal(due(c, 6999), false);
    assert.equal(due(c, 7000), true);
});

test("holding keeps the time left, and letting go resumes it", () => {
    let c = countdown(6000, 0);
    c = hold(c, "popup", 5900);
    assert.equal(due(c, 100000), false);
    c = release(c, "popup", 20000);
    assert.equal(due(c, 20099), false);
    assert.equal(due(c, 20100), true);
});

test("holding twice or letting go twice changes nothing", () => {
    const h = hold(countdown(4000, 0), "popup", 1000);
    assert.equal(hold(h, "popup", 3000), h);
    const running = countdown(4000, 0);
    assert.equal(release(running, "popup", 3000), running);
});

test("a click's hold ends with its grant, and the time runs again", () => {
    // A resident notification stays after its action; the click mustn't
    // keep it up for good.
    let c = hold(countdown(6000, 0), "click", 1000);
    assert.equal(due(c, 60000), false);
    c = release(c, "click", 2000);
    assert.equal(held(c), false);
    assert.equal(due(c, 6999), false);
    assert.equal(due(c, 7000), true);
});

test("it runs again only once every hold has let go", () => {
    let c = countdown(6000, 0);
    c = hold(c, "popup", 1000);
    c = hold(c, "click", 2000);
    c = release(c, "click", 3000);
    assert.equal(due(c, 60000), false);
    c = release(c, "popup", 10000);
    assert.equal(due(c, 14999), false);
    assert.equal(due(c, 15000), true);
});

test("an update in place starts over, still held", () => {
    const c = restarted(hold(countdown(6000, 0), "popup", 5000), 6000, 5500);
    assert.deepEqual(c.holders, ["popup"]);
    assert.equal(due(c, 1e9), false);
    assert.equal(due(release(c, "popup", 9000), 14999), false);
    assert.equal(due(release(c, "popup", 9000), 15000), true);
});

test("a critical popup's countdown never runs out", () => {
    let c = countdown(0, 0);
    assert.equal(due(c, 1e12), false);
    c = release(hold(c, "popup", 10), "popup", 20);
    assert.equal(due(c, 1e12), false);
    assert.equal(nextDeadline([c]), null);
});

test("the next deadline is the soonest running one", () => {
    const a = countdown(6000, 0);
    const b = countdown(4000, 1000);
    const h = hold(countdown(1000, 0), "popup", 500);
    assert.equal(nextDeadline([a, b, h]), 5000);
    assert.equal(nextDeadline([]), null);
});

test("a popup nobody can see yet keeps its whole time until it can be", () => {
    // No focused monitor at startup: held from the start, so it isn't
    // spent before the popup ever shows.
    let c = hold(countdown(4000, 0), "unseen", 0);
    assert.equal(due(c, 60000), false);
    c = release(c, "unseen", 60000);
    assert.equal(due(c, 63999), false);
    assert.equal(due(c, 64000), true);
});

test("the popup stack fits the output, and scrolls past it", () => {
    assert.equal(stackHeight(300, 720, 44, 12), 300, "fits");
    assert.equal(stackHeight(900, 720, 44, 12), 664, "capped to the room below the bar");
    assert.equal(stackHeight(900, 40, 44, 12), 0, "never negative");
});

test("a reply draft is kept by notification, and dropped once empty", () => {
    const a = withDraft({}, 7, "on my w");
    assert.deepEqual(a, { 7: "on my w" });
    const b = withDraft(a, 8, "ok");
    assert.deepEqual(b, { 7: "on my w", 8: "ok" });
    assert.deepEqual(a, { 7: "on my w" }, "the old map is untouched");
    assert.deepEqual(withDraft(b, 7, ""), { 8: "ok" });
    assert.deepEqual(withDraft(b, 9, ""), b);
});

test("an unsent reply holds the countdown after the pointer and a click let go", () => {
    let c = countdown(6000, 0);
    c = hold(c, "popup", 1000);
    c = hold(c, "draft", 2000);
    c = hold(c, "click", 3000);
    c = release(c, "click", 3500);
    c = release(c, "popup", 4000);
    assert.equal(held(c), true, "the draft still holds it");
    assert.equal(due(c, 100000), false);
    c = release(c, "draft", 10000);
    assert.equal(held(c), false);
    assert.equal(due(c, 14999), false);
    assert.equal(due(c, 15000), true, "the 5 s left when first held");
});

test("an update that takes the reply field away drops the draft", () => {
    const drafts = { 7: "on my w" };
    assert.equal(replyDraft(drafts, 7, true), "on my w");
    assert.equal(replyDraft(drafts, 7, false), "");
    assert.equal(replyDraft(drafts, 8, true), "");
});

test("a dismissal or the app's close clears a notification's marks, and expiring doesn't", () => {
    const reasons = { Expired: 1, Dismissed: 2, CloseRequested: 3 };
    assert.equal(clearsMarks(reasons.Dismissed, reasons), true);
    assert.equal(clearsMarks(reasons.CloseRequested, reasons), true);
    assert.equal(clearsMarks(reasons.Expired, reasons), false);
});

test("only a system sender's critical notification gets through Do not disturb", () => {
    const n = (appName, urgency, desktopEntry = "") => ({ appName, desktopEntry, urgency });
    assert.equal(passesDnd(n("tide", URGENCY.Critical), URGENCY), true);
    assert.equal(passesDnd(n("Tide ", URGENCY.Critical), URGENCY), true);
    assert.equal(passesDnd(n("", URGENCY.Critical, "polkit-gnome-authentication-agent-1"), URGENCY), true);
    assert.equal(passesDnd(n("PolicyKit1 polkit agent", URGENCY.Critical), URGENCY), true);
    // Not critical, even from the shell.
    assert.equal(passesDnd(n("tide", URGENCY.Normal), URGENCY), false);
    // Chrome marks requireInteraction notifications critical.
    assert.equal(passesDnd(n("Google Chrome", URGENCY.Critical, "google-chrome"), URGENCY), false);
    assert.equal(passesDnd(n("", URGENCY.Critical), URGENCY), false);
});

test("Do not disturb holds whatever in the queue doesn't pass, as it is now", () => {
    const shell = { appName: "tide", desktopEntry: "", urgency: URGENCY.Critical };
    const chat = { appName: "Chat", desktopEntry: "", urgency: URGENCY.Normal };
    assert.deepEqual(heldByDnd([shell, chat], false, URGENCY), []);
    assert.deepEqual(heldByDnd([shell, chat], true, URGENCY), [chat]);
    // A system critical updated to normal no longer passes.
    shell.urgency = URGENCY.Normal;
    assert.deepEqual(heldByDnd([shell, chat], true, URGENCY), [shell, chat]);
});

test("a popup that goes rests, still live, out of the queue", () => {
    const a = { id: 1 }, b = { id: 2 };
    assert.deepEqual(rest([a, b], [], a), { queue: [b], resting: [a] });
    // Resting twice keeps one.
    assert.deepEqual(rest([b], [a], a), { queue: [b], resting: [a] });
});

test("an update wakes a resting notification back into the queue", () => {
    const a = { id: 1, appName: "x", hints: {} }, b = { id: 2, appName: "x", hints: {} };
    assert.deepEqual(wake([b], [a], a), { queue: [b, a], resting: [], replaced: null });
    // Woken with a synchronous key, it replaces what holds that key.
    const s1 = { id: 3, appName: "vol", hints: { "x-canonical-private-synchronous": "v" } };
    const s2 = { id: 4, appName: "vol", hints: { "x-canonical-private-synchronous": "v" } };
    assert.deepEqual(wake([s1], [s2], s2), { queue: [s2], resting: [], replaced: s1 });
});

test("a resting notification goes once the center lets its entry go", () => {
    const a = { id: 1 }, b = { id: 2 };
    const keyOf = (id) => `k-${id}`;
    assert.deepEqual(unkept([a, b], ["k-1"], keyOf), [b]);
    assert.deepEqual(unkept([a, b], ["k-1", "k-2"], keyOf), []);
    assert.deepEqual(unkept([a], [], keyOf), [a]);
});

test("a resting notification is still live, so a click's grant runs its action", () => {
    const a = { id: 1 }, b = { id: 2 }, gone = { id: 3 };
    assert.equal(isLive([a], [], a), true);
    assert.equal(isLive([], [b], b), true);
    assert.equal(isLive([a], [b], gone), false);
});

test("a synchronous key replaces a resting notification too", () => {
    const sync = (id, app) => ({ id, appName: app, hints: { "x-canonical-private-synchronous": "v" } });
    const old = sync(1, "vol"), next = sync(2, "vol"), other = sync(3, "mail");
    // The resting one is replaced and leaves `resting`; the new one queues.
    assert.deepEqual(arriveResting([], [old], next), { queue: [next], resting: [], replaced: old });
    // One in the queue is matched first, as before.
    const queued = sync(4, "vol");
    assert.deepEqual(arriveResting([queued], [old], next), { queue: [next], resting: [old], replaced: queued });
    // Another app's key, or no key, replaces nothing.
    assert.deepEqual(arriveResting([], [other], next), { queue: [next], resting: [other], replaced: null });
    const plain = { id: 5, appName: "vol", hints: {} };
    assert.deepEqual(arriveResting([], [old], plain), { queue: [plain], resting: [old], replaced: null });
});

const chat = (origin) => ({ appName: "Google Chrome", desktopEntry: "google-chrome", hints: origin === undefined ? {} : { [ORIGIN_HINT]: origin } });

test("the origin hint gives the site, without a port", () => {
    assert.equal(ORIGIN_HINT, "x-kde-origin-name");
    assert.equal(siteOf(chat("chat.google.com")), "chat.google.com");
    assert.equal(siteOf(chat(" Example.COM:8080 ")), "example.com");
    assert.equal(siteFrom("localhost:3000"), "localhost");
});

test("a context message or no hint is no site", () => {
    assert.equal(siteOf(chat()), null);
    assert.equal(siteOf(chat("")), null);
    assert.equal(siteOf(chat("Example Extension")), null);
    assert.equal(siteOf(chat("example.com/path")), null);
    assert.equal(originText(chat("Example Extension")), "Example Extension");
    assert.equal(originText({}), "");
});

test("a site's --app window class is found by its host", () => {
    const windows = [
        { app: "google-chrome", focus: 0 },
        { app: "chrome-chat.google.com__-Default", focus: 3 },
        { app: "chrome-mail.google.com__mail_-Default", focus: 1 },
    ];
    assert.deepEqual(siteWindowClasses("chat.google.com", windows), ["chrome-chat.google.com__-Default"]);
    assert.deepEqual(siteWindowClasses("mail.google.com", windows), ["chrome-mail.google.com__mail_-Default"]);
    assert.deepEqual(siteWindowClasses("meet.google.com", windows), []);
    assert.deepEqual(siteWindowClasses(null, windows), []);
});

test("a site open in two profiles is both classes, the most recently focused first", () => {
    const windows = [
        { app: "chrome-calendar.google.com__-Default", focus: 4 },
        { app: "chrome-calendar.google.com__-Profile_1", focus: 2 },
        { app: "chrome-calendar.google.com__-Default", focus: 1 },
    ];
    assert.deepEqual(siteWindowClasses("calendar.google.com", windows),
        ["chrome-calendar.google.com__-Default", "chrome-calendar.google.com__-Profile_1"]);
});

test("a shortened site matches its subdomains", () => {
    const windows = [
        { app: "chrome-chat.example.co.uk__-Default", focus: 4 },
        { app: "chrome-mail.example.co.uk__-Profile_1", focus: 2 },
    ];
    assert.deepEqual(siteWindowClasses("example.co.uk", windows),
        ["chrome-mail.example.co.uk__-Profile_1", "chrome-chat.example.co.uk__-Default"]);
    assert.deepEqual(siteWindowClasses("ample.co.uk", windows), []);
});

test("an installed web app's class names no site, so it never matches", () => {
    const windows = [{ app: "chrome-abcdefghijklmnopabcdefghijklmnop-Default", focus: 0 }];
    assert.deepEqual(siteWindowClasses("abcdefghijklmnopabcdefghijklmnop", windows), []);
});

test("a window never focused (-1), or with no history, comes after one that was", () => {
    const windows = [
        { app: "chrome-chat.google.com__-Profile_1", focus: -1 },
        { app: "chrome-chat.google.com__-Profile_2" },
        { app: "chrome-chat.google.com__-Default", focus: 0 },
    ];
    assert.deepEqual(siteWindowClasses("chat.google.com", windows)[0], "chrome-chat.google.com__-Default");
});

test("Chrome's notification goes to Chrome's windows, Chromium's to Chromium's", () => {
    const windows = [
        { app: "chrome-chat.google.com__-Default", focus: 1 },
        { app: "chromium-chat.google.com__-Default", focus: 0 },
    ];
    assert.deepEqual(siteWindowClasses("chat.google.com", windows, "chrome"), ["chrome-chat.google.com__-Default"]);
    assert.deepEqual(siteWindowClasses("chat.google.com", windows, "chromium"), ["chromium-chat.google.com__-Default"]);
    assert.equal(browserOf("google-chrome"), "chrome");
    assert.equal(browserOf("org.chromium.Chromium"), "chromium");
    const from = entry => ({ appName: "", desktopEntry: entry, hints: { [ORIGIN_HINT]: "chat.google.com" } });
    assert.deepEqual(targetApps(from("google-chrome"), windows), ["chrome-chat.google.com__-Default"]);
    assert.deepEqual(targetApps(from("chromium"), windows), ["chromium-chat.google.com__-Default"]);
});

test("a web notification goes to its site's --app windows, else to Chrome", () => {
    const windows = [
        { app: "chrome-chat.google.com__-Default", focus: 0 },
        { app: "chrome-chat.google.com__-Profile_1", focus: 1 },
    ];
    assert.deepEqual(targetApps(chat("chat.google.com"), windows),
        ["chrome-chat.google.com__-Default", "chrome-chat.google.com__-Profile_1"]);
    assert.deepEqual(targetApps(chat("meet.google.com"), windows), ["google-chrome"]);
    assert.deepEqual(targetApps(chat(), windows), ["google-chrome"]);
    assert.equal(targetApps({ appName: "", desktopEntry: "", hints: {} }, windows), null);
});

test("only Chrome's origin hint routes to an --app window", () => {
    // Any app can send the hint; one naming a host stays its own app.
    const windows = [{ app: "chrome-chat.google.com__-Default", focus: 0 }];
    const other = { appName: "Mail", desktopEntry: "org.example.Mail", hints: { [ORIGIN_HINT]: "chat.google.com" } };
    assert.deepEqual(targetApps(other, windows), ["org.example.Mail"]);
    for (const entry of ["google-chrome", "google-chrome-beta", "chromium", "chromium-browser", "org.chromium.Chromium", "com.google.Chrome"]) {
        assert.equal(isChrome(entry), true, entry);
        if (!/chromium/i.test(entry)) {
            assert.deepEqual(targetApps({ appName: "", desktopEntry: entry, hints: { [ORIGIN_HINT]: "chat.google.com" } }, windows), ["chrome-chat.google.com__-Default"], entry);
        }
    }
    for (const id of ["org.example.Mail", "chrome-chat.google.com__-Default", "googlechrome", "", null]) {
        assert.equal(isChrome(id), false, String(id));
    }
});

test("the origin shows beside the name, cut short past 28 characters", () => {
    assert.equal(joinLabel("Google Chrome", originLabel("chat.google.com")), "Google Chrome · chat.google.com");
    assert.equal(joinLabel("Files", originLabel("")), "Files");
    assert.equal(joinLabel(originLabel(undefined), "2 min"), "2 min");
    assert.equal(originLabel("x".repeat(28)), "x".repeat(28));
    assert.equal(originLabel("x".repeat(29)), "x".repeat(27) + "…");
});

// The origin hint is the sender's text, so any Text showing it renders it
// as plain text: Qt's default would take HTML, and an <img> in it would
// make the shell fetch a URL.
test("every Text that shows the origin hint is plain text", () => {
    const shell = join(dirname(fileURLToPath(import.meta.url)), "..");
    let found = 0;
    for (const f of readdirSync(shell).filter(n => n.endsWith(".qml"))) {
        const text = readFileSync(join(shell, f), "utf8");
        for (let i = text.indexOf("Notes.originLabel("); i !== -1; i = text.indexOf("Notes.originLabel(", i + 1)) {
            found++;
            const start = text.lastIndexOf("Text {", i);
            assert.ok(start !== -1, `${f}: no Text around the origin label`);
            let depth = 0;
            let end = start;
            for (let j = text.indexOf("{", start); j < text.length; j++) {
                if (text[j] === "{") {
                    depth++;
                } else if (text[j] === "}" && --depth === 0) {
                    end = j;
                    break;
                }
            }
            assert.ok(end > i, `${f}: the origin label isn't inside the Text before it`);
            assert.match(text.slice(start, end), /\btextFormat:\s*Text\.PlainText\b/, f);
        }
    }
    assert.ok(found >= 2, `found the origin label ${found} times`);
});
