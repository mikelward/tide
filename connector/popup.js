// The popup: whether this browser's tabs reach tide's switcher, and what to
// do if they don't.
import { STATUS_KEY, statusText } from "./bridge.js";

const show = ({ state, detail }) => {
  document.getElementById("state").textContent = state;
  document.getElementById("detail").textContent = detail;
};

async function refresh() {
  const [{ os }, stored] = await Promise.all([chrome.runtime.getPlatformInfo(), chrome.storage.session.get(STATUS_KEY)]);
  show(statusText(os, stored[STATUS_KEY]));
}

const failed = (e) => {
  console.error("tide connector: couldn't show its status:", e);
  show({ state: "Couldn't read the status", detail: String(e?.message ?? e) });
};
chrome.storage.session.onChanged.addListener((changes) => {
  if (STATUS_KEY in changes) refresh().catch(failed);
});
refresh().catch(failed);
