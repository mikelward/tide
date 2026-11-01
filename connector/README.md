# tide connector

A browser extension that lists your Chrome or Brave tabs in tide's window
switcher, and brings a tab up when you pick it there. It does nothing off
Linux. SPEC.md §8.3 is the design.

## Trying it unpacked

1. Run `setup` (mikelward/scripts), which installs `tide-tabs`'s host
   manifest for each browser. It doesn't allow the connector's ID yet
   (TODO.md); until it does, add `chrome-extension://ID/` to the manifest's
   `allowed_origins` by hand, with the ID `chrome://extensions` shows.
2. At `chrome://extensions` (or `brave://extensions`), turn on developer
   mode, **Load unpacked**, and pick this directory.
3. Its toolbar popup says whether it's connected.

## Tests

`node --test connector/bridge_test.js`, which `make test` runs too.

## Publishing

Only if tileco can't keep its Linux tab list in the store.

`make connector-zip` builds `build/tide-connector.zip`. Upload it at the
[Chrome Web Store developer dashboard](https://chrome.google.com/webstore/devconsole)
as a new item, then fill in:

- **Summary** (the manifest's `description`): "Lists your browser tabs in
  the window switcher of tide, a Linux desktop, so you can find and switch
  to any tab."
- **Description**:

  > tide is a desktop for Linux. Its window switcher lists your windows;
  > with this extension it lists each browser tab too, under its window, so
  > you can find any tab by its title or site and switch to it. It needs
  > tide and its `tide-tabs` helper on the same computer, and does nothing
  > on other systems.

- **Category**: Tools.
- **Single purpose**: "Lists this browser's tabs in tide's window switcher
  on Linux, and switches to the tab you pick there."
- **Permission justifications**:
  - `tabs`: each tab's title and address, which the switcher shows and
    searches.
  - `nativeMessaging`: handing the tab list to tide's `tide-tabs` helper on
    the same computer, and hearing which tab to bring up.
  - `storage`: the connection's status, which the popup shows.
- **Remote code**: no.
- **Data use**: none collected. The tabs go only to `tide-tabs` on the same
  computer; nothing goes to the developer or anyone else.

Once the store gives the item its ID, add it to `setup`'s host manifest
(mikelward/scripts), so the store's copy may connect too.
