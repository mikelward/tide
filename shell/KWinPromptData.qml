pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Super+Return's name prompt on KDE Plasma (SPEC.md §8.5): NamePrompt.qml
// asks for a workspace to go to, and Enter goes to KWin's desktop of that
// name, made if there's none (KWinData.goToNamed). Plasma's Meta+Return
// runs scripts' tide-go-to-workspace, which calls `prompt go` here. The
// other prompts, for a window or a launch, are tide's session's
// (PromptData).
Singleton {
    id: root

    // The request shown, {id, kind: "go"}, or null.
    property var current: null
    property int asked: 0

    function askGo() {
        // The desktops as they are now: one made or renamed in Plasma's
        // Pager since the last read is listed.
        KWinData.refresh();
        root.asked += 1;
        root.current = { id: root.asked, kind: "go" };
    }

    function answer(name) {
        root.current = null;
        KWinData.goToNamed(name);
    }

    function cancel() {
        root.current = null;
    }

    IpcHandler {
        target: "prompt"

        function go(): void {
            root.askGo();
        }
        // The kind of the prompt shown, or "" with none: for tests.
        function shown(): string {
            return root.current?.kind ?? "";
        }
    }
}
