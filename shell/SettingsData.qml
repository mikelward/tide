pragma Singleton

import QtQuick
import Quickshell

// Opens the settings panel (SPEC.md §16) from elsewhere in the shell, such
// as the launcher's Settings action.
Singleton {
    signal openRequested

    function open() {
        openRequested();
    }
}
