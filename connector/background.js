// The tide connector's service worker: on Linux, it keeps tide's switcher
// told of this browser's tabs (bridge.js, SPEC.md §8.3). Anywhere else it
// does nothing, and its popup says so.
import { TabsBridge } from "./bridge.js";

const bridge = new TabsBridge(chrome);
// Asked once per worker: the platform can't change under it.
const linux = chrome.runtime.getPlatformInfo().then(
  ({ os }) => os === "linux",
  (e) => {
    console.error("tide connector: couldn't tell which platform this is, so it stays off:", e);
    return false;
  },
);
const onLinux = (what, f) => () =>
  linux.then((yes) => (yes ? f() : undefined)).catch((e) => console.error(`tide connector: couldn't ${what}:`, e));

const start = onLinux("start", () => bridge.start());
const changed = onLinux("send the tabs", () => bridge.changed());

// Listeners go on at the worker's first run, as Manifest V3 requires.
chrome.runtime.onStartup.addListener(start);
chrome.runtime.onInstalled.addListener(start);
for (const e of ["onCreated", "onRemoved", "onFocusChanged"]) chrome.windows[e].addListener(changed);
for (const e of ["onActivated", "onCreated", "onRemoved", "onMoved", "onAttached", "onDetached", "onReplaced"]) chrome.tabs[e].addListener(changed);
chrome.tabs.onUpdated.addListener((tabId, info) => {
  if ("title" in info || "url" in info) changed();
});
start();
