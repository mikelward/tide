// The tide connector hands this browser's tabs to tide's switcher (SPEC.md
// §8.3). It talks to tide's `tide-tabs` native-messaging host, which Chrome
// starts and which relays to tide's shell, on this machine only. Each message
// is one JSON object; Chrome does the framing. Copied from tileco's
// src/tabsbridge.js (mikelward/tileco 97ae30c), which does the same on
// Linux.
//
// Extension to host:
//   {type: "tabs", browser, windows: [{id, focused, title, tabs: [{id, title, url, active}]}]}
//     every normal window and its tabs, sent whole on each change; a
//     window's title is its active tab's, which is how tide finds its window
// Host to extension:
//   {type: "hello", version}           the host started
//   {type: "shell", connected}         whether tide's shell is listening
//   {type: "refresh"}                  send the tabs again (a shell came up)
//   {type: "activate", tabId, windowId} bring that tab up, and its window

export const HOST = "io.github.mikelward.tide.tabs";
// What the popup shows, in storage.session: {state, message}.
export const STATUS_KEY = "status";
export const VERSION = 1;

// How long changes are gathered before the tabs are sent: a page load sends
// several updates in a row.
const GATHER_MS = 100;
const MAX_RETRY_S = 60;

// The message for `windows`, from chrome.windows.getAll({populate: true}).
// Only normal windows: an app window is a window of its own in tide's list
// already. Incognito windows stay out, whatever Chrome lets the connector see.
export function tabsMessage(windows, browser) {
  return {
    type: "tabs",
    browser,
    windows: windows
      .filter((w) => w.type === "normal" && !w.incognito)
      .map((w) => {
        const tabs = (w.tabs ?? []).map((t) => ({ id: t.id, title: t.title ?? "", url: t.url ?? "", active: Boolean(t.active) }));
        return { id: w.id, focused: Boolean(w.focused), title: tabs.find((t) => t.active)?.title ?? "", tabs };
      }),
  };
}

// A message from the host, checked: {type, ...} or {error}.
export function hostMessage(m) {
  if (!m || typeof m !== "object") return { error: "not an object" };
  switch (m.type) {
    case "hello":
      return { type: "hello", version: Number(m.version) || 0 };
    case "shell":
      return { type: "shell", connected: m.connected === true };
    case "refresh":
      return { type: "refresh" };
    case "activate":
      if (!Number.isInteger(m.tabId) || !Number.isInteger(m.windowId)) return { error: "activate without a tabId and windowId" };
      return { type: "activate", tabId: m.tabId, windowId: m.windowId };
    default:
      return { error: `unknown type ${JSON.stringify(m.type)}` };
  }
}

// The state a closed port leaves, from Chrome's lastError.message.
export function closedState(message) {
  if (/not found/i.test(message ?? "")) return "missing";
  if (/forbidden/i.test(message ?? "")) return "forbidden";
  return "stopped";
}

// Seconds before connecting again after `attempt` failures in a row.
export function retrySeconds(attempt) {
  return Math.min(2 ** attempt, MAX_RETRY_S);
}

// The browser's name, as tide shows it: Brave and Chrome load the same
// extension, and each has its own host manifest.
export function browserName(nav = globalThis.navigator) {
  const brands = (nav?.userAgentData?.brands ?? []).map((b) => b.brand);
  for (const name of ["Brave", "Microsoft Edge", "Opera", "Vivaldi", "Google Chrome"]) if (brands.includes(name)) return name;
  return brands.includes("Chromium") ? "Chromium" : "Chrome";
}

export class TabsBridge {
  // `api` is chrome; `timers` has setTimeout and clearTimeout.
  constructor(api, { browser = browserName(), timers = globalThis } = {}) {
    this.api = api;
    this.browser = browser;
    this.timers = timers;
    this.port = null;
    this.attempt = 0;
    this.retry = null;
    this.gather = null;
    this.status = null;
  }

  async setStatus(state, message = "") {
    this.status = { state, message };
    try {
      await this.api.storage.session.set({ [STATUS_KEY]: this.status });
    } catch (e) {
      console.error("tide connector: couldn't save its status for the popup:", e);
    }
  }

  // Connect, if it isn't connected already. Called at each worker start and
  // on every tab event, so a worker that slept with no port (the host
  // missing, say) tries again when there's news to send.
  start() {
    this.starting ??= this.connect().finally(() => {
      this.starting = null;
    });
    return this.starting;
  }

  async connect() {
    if (this.port || this.retry) return;
    await this.setStatus("connecting");
    let port;
    try {
      port = this.api.runtime.connectNative(HOST);
    } catch (e) {
      await this.closed(e?.message ?? String(e));
      return;
    }
    this.port = port;
    // Before any await, so a close that comes at once isn't missed.
    port.onMessage.addListener((m) => this.received(port, m));
    port.onDisconnect.addListener(() => {
      if (this.port !== port) return;
      this.port = null;
      this.closed(this.api.runtime.lastError?.message ?? "the host exited");
    });
    this.changed();
  }

  // The port closed or never opened. An open native port is what keeps an
  // MV3 worker running (Chrome 105+), so this retries while the worker
  // lives; a worker that stops meanwhile retries at its next start.
  async closed(message) {
    if (this.gather) this.timers.clearTimeout(this.gather);
    this.gather = null;
    const state = closedState(message);
    console.warn(`tide connector: tide's tab list (${HOST}) closed: ${message}`);
    await this.setStatus(state, message);
    const wait = retrySeconds(this.attempt++);
    this.retry = this.timers.setTimeout(() => {
      this.retry = null;
      this.start().catch((e) => console.error("tide connector: couldn't reconnect tide's tab list:", e));
    }, wait * 1000);
  }

  received(port, raw) {
    const m = hostMessage(raw);
    if (m.error) {
      console.warn(`tide connector: ignoring a message from tide's tab list: ${m.error}`);
      return;
    }
    if (m.type === "hello") {
      this.attempt = 0;
      this.setStatus("waiting");
    } else if (m.type === "shell") {
      this.setStatus(m.connected ? "connected" : "waiting");
      if (m.connected) this.changed();
    } else if (m.type === "refresh") {
      this.changed();
    } else if (m.type === "activate") {
      this.activate(m.tabId, m.windowId).catch((e) => console.warn(`tide connector: couldn't bring up tab ${m.tabId} for tide:`, e?.message ?? e));
    }
  }

  async activate(tabId, windowId) {
    await this.api.tabs.update(tabId, { active: true });
    await this.api.windows.update(windowId, { focused: true });
  }

  // Something about the tabs changed: send them all, once the burst is over.
  changed() {
    if (!this.port) {
      this.start().catch((e) => console.error("tide connector: couldn't connect tide's tab list:", e));
      return;
    }
    if (this.gather) return;
    this.gather = this.timers.setTimeout(() => {
      this.gather = null;
      this.send().catch((e) => console.error("tide connector: couldn't send the tabs to tide:", e));
    }, GATHER_MS);
  }

  async send() {
    const port = this.port;
    if (!port) return;
    const windows = await this.api.windows.getAll({ populate: true, windowTypes: ["normal"] });
    // The port can close while Chrome answers.
    if (this.port !== port) return;
    port.postMessage(tabsMessage(windows, this.browser));
  }
}

// What the popup says: {state, detail}. `status` is the worker's last
// STATUS_KEY, if any; `os` is chrome.runtime.getPlatformInfo()'s.
export function statusText(os, status) {
  if (os !== "linux") return { state: "Only for Linux", detail: "tide is a Linux desktop, so this does nothing here." };
  switch (status?.state) {
    case "connected":
      return { state: "Connected", detail: "This browser's tabs are in tide's switcher." };
    case "waiting":
      return { state: "Waiting for tide", detail: "tide-tabs is running, but tide's shell isn't listening. The tabs show once you're in a tide session." };
    case "missing":
      return { state: "tide-tabs isn't installed", detail: "Run tide's setup, which installs the helper for Chrome and Brave, then this connects by itself." };
    case "forbidden":
      return { state: "tide-tabs doesn't know this extension", detail: "Its manifest names another extension ID. Run setup again, so it names this one." };
    case "stopped":
      return { state: "Reconnecting", detail: `tide-tabs stopped (${status.message}); it's started again shortly.` };
    default:
      return { state: "Connecting", detail: "" };
  }
}
