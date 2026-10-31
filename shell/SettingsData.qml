pragma Singleton

import QtQuick
import Quickshell

// Opens the settings panel (SPEC.md §16) from elsewhere in the shell, such
// as the launcher's Settings action: on page `page` (settings.mjs's id, such
// as "mouse"), or on the first with none.
Singleton {
    signal openRequested(string page)

    function open(page) {
        openRequested(page ?? "");
    }
}
