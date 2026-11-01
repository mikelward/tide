// Tests for bridge.js: this browser's tabs, handed to tide's switcher.
import { test } from "node:test";
import assert from "node:assert/strict";
import { browserName, closedState, HOST, hostMessage, retrySeconds, STATUS_KEY, statusText, TabsBridge, tabsMessage } from "./bridge.js";

const WINDOWS = [
  {
    id: 1,
    type: "normal",
    focused: true,
    tabs: [
      { id: 11, title: "Inbox", url: "https://mail.example.com/", active: false, favIconUrl: "https://mail.example.com/i.png" },
      { id: 12, title: "Docs", url: "https://docs.example.com/", active: true },
    ],
  },
  { id: 2, type: "app", tabs: [{ id: 21, title: "Chat", url: "https://chat.example.com/", active: true }] },
  { id: 3, type: "normal", incognito: true, tabs: [{ id: 31, title: "Secret", url: "https://example.com/", active: true }] },
  { id: 4, type: "normal", tabs: [{ id: 41, active: true }] },
];

test("the tabs go as normal windows, each titled by its active tab", () => {
  assert.deepEqual(tabsMessage(WINDOWS, "Brave"), {
    type: "tabs",
    browser: "Brave",
    windows: [
      {
        id: 1,
        focused: true,
        title: "Docs",
        tabs: [
          { id: 11, title: "Inbox", url: "https://mail.example.com/", active: false },
          { id: 12, title: "Docs", url: "https://docs.example.com/", active: true },
        ],
      },
      // A tab still loading has no title or address yet.
      { id: 4, focused: false, title: "", tabs: [{ id: 41, title: "", url: "", active: true }] },
    ],
  });
});

test("the host's messages are checked", () => {
  assert.deepEqual(hostMessage({ type: "activate", tabId: 12, windowId: 1 }), { type: "activate", tabId: 12, windowId: 1 });
  assert.deepEqual(hostMessage({ type: "shell", connected: true }), { type: "shell", connected: true });
  assert.deepEqual(hostMessage({ type: "hello", version: 1 }), { type: "hello", version: 1 });
  assert.deepEqual(hostMessage({ type: "refresh" }), { type: "refresh" });
  assert.ok(hostMessage({ type: "activate", tabId: "12", windowId: 1 }).error);
  assert.ok(hostMessage({ type: "navigate", url: "https://example.com/" }).error);
  assert.ok(hostMessage(null).error);
});

test("a closed port says why", () => {
  assert.equal(closedState("Specified native messaging host not found."), "missing");
  assert.equal(closedState("Access to the specified native messaging host is forbidden."), "forbidden");
  assert.equal(closedState("Native host has exited."), "stopped");
  assert.deepEqual([0, 1, 2, 5, 6, 20].map(retrySeconds), [1, 2, 4, 32, 60, 60]);
});

test("the browser is named from its brands", () => {
  const nav = (...brands) => ({ userAgentData: { brands: brands.map((brand) => ({ brand })) } });
  assert.equal(browserName(nav("Not A Brand", "Chromium", "Brave")), "Brave");
  assert.equal(browserName(nav("Chromium", "Google Chrome")), "Google Chrome");
  assert.equal(browserName(nav("Chromium")), "Chromium");
  assert.equal(browserName({}), "Chrome");
});

// Timers that run only when a test says so.
class Timers {
  constructor() {
    this.due = new Map();
    this.next = 1;
  }
  setTimeout(f, ms) {
    const id = this.next++;
    this.due.set(id, { f, ms });
    return id;
  }
  clearTimeout(id) {
    this.due.delete(id);
  }
  // Runs what's due now, in the order it was set; returns their delays.
  async run() {
    const now = [...this.due.entries()];
    this.due.clear();
    for (const [, t] of now) t.f();
    await settle();
    return now.map(([, t]) => t.ms);
  }
}

const settle = async () => {
  for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r));
};

function event() {
  const fs = [];
  return { addListener: (f) => fs.push(f), fire: (...a) => fs.forEach((f) => f(...a)) };
}

// A chrome with a native host that can be there or not.
function fakeChrome({ host = true } = {}) {
  const c = {
    ports: [],
    session: {},
    updates: [],
    host,
    runtime: {
      lastError: undefined,
      connectNative(name) {
        assert.equal(name, HOST);
        const port = { sent: [], onMessage: event(), onDisconnect: event(), disconnected: false };
        port.postMessage = (m) => port.sent.push(m);
        port.disconnect = () => (port.disconnected = true);
        c.ports.push(port);
        // Chrome reports a missing host by closing the port soon after.
        if (!c.host) {
          queueMicrotask(() => {
            c.runtime.lastError = { message: "Specified native messaging host not found." };
            port.onDisconnect.fire(port);
            c.runtime.lastError = undefined;
          });
        }
        return port;
      },
    },
    storage: { session: { set: async (o) => Object.assign(c.session, o) } },
    windows: {
      getAll: async (opts) => {
        assert.deepEqual(opts, { populate: true, windowTypes: ["normal"] });
        return WINDOWS;
      },
      update: async (id, props) => c.updates.push(["window", id, props]),
    },
    tabs: { update: async (id, props) => c.updates.push(["tab", id, props]) },
  };
  return c;
}

test("it connects, and sends the tabs once per burst of changes", async () => {
  const chrome = fakeChrome();
  const timers = new Timers();
  const bridge = new TabsBridge(chrome, { browser: "Google Chrome", timers });
  await bridge.start();
  assert.equal(chrome.ports.length, 1);
  const port = chrome.ports[0];
  port.onMessage.fire({ type: "hello", version: 1 });
  port.onMessage.fire({ type: "shell", connected: true });
  await settle();
  assert.deepEqual(chrome.session[STATUS_KEY], { state: "connected", message: "" });
  bridge.changed();
  bridge.changed();
  await timers.run();
  assert.equal(port.sent.length, 1, "the start, the shell and two changes are one send");
  assert.deepEqual(port.sent[0], tabsMessage(WINDOWS, "Google Chrome"));
  // Starting again, as each tab event does, keeps the one port.
  await bridge.start();
  assert.equal(chrome.ports.length, 1);
});

test("the host asks, and the tab and its window come up", async () => {
  const chrome = fakeChrome();
  const bridge = new TabsBridge(chrome, { timers: new Timers() });
  await bridge.start();
  chrome.ports[0].onMessage.fire({ type: "activate", tabId: 11, windowId: 1 });
  // Nothing but activate may act.
  chrome.ports[0].onMessage.fire({ type: "close", tabId: 12 });
  await settle();
  assert.deepEqual(chrome.updates, [
    ["tab", 11, { active: true }],
    ["window", 1, { focused: true }],
  ]);
});

test("a missing host is said so, and tried again later, backing off", async () => {
  const chrome = fakeChrome({ host: false });
  const timers = new Timers();
  const bridge = new TabsBridge(chrome, { timers });
  await bridge.start();
  await settle();
  assert.equal(chrome.session[STATUS_KEY].state, "missing");
  // A tab event while it waits doesn't connect early.
  bridge.changed();
  await settle();
  assert.equal(chrome.ports.length, 1);
  assert.deepEqual(await timers.run(), [1000]);
  assert.equal(chrome.ports.length, 2);
  assert.deepEqual(await timers.run(), [2000]);
  // Installed now: the next try connects, and stays.
  chrome.host = true;
  await timers.run();
  assert.equal(chrome.ports.length, 4);
  chrome.ports[3].onMessage.fire({ type: "hello", version: 1 });
  await settle();
  assert.equal(chrome.session[STATUS_KEY].state, "waiting");
  // A host that stops later is reconnected from the shortest wait again.
  chrome.runtime.lastError = { message: "Native host has exited." };
  chrome.ports[3].onDisconnect.fire();
  chrome.runtime.lastError = undefined;
  await settle();
  assert.equal(chrome.session[STATUS_KEY].state, "stopped");
  assert.deepEqual([...timers.due.values()].map((t) => t.ms), [1000]);
});

test("the popup says what's missing", () => {
  assert.match(statusText("mac", { state: "connected" }).state, /Only for Linux/);
  assert.match(statusText("linux", { state: "connected" }).state, /Connected/);
  assert.match(statusText("linux", { state: "missing" }).state, /isn't installed/);
  assert.match(statusText("linux", { state: "waiting" }).detail, /tide session/);
  assert.match(statusText("linux", { state: "forbidden" }).detail, /setup again/);
  assert.match(statusText("linux", { state: "stopped", message: "Native host has exited." }).detail, /Native host has exited/);
  assert.match(statusText("linux", undefined).state, /Connecting/);
});
