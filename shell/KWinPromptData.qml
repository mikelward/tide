pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The name prompts on KDE Plasma (SPEC.md §8.5): NamePrompt.qml asks for
// a workspace, and Enter goes to KWin's desktop of that name, made if
// there's none (KWinData.goToNamed), or moves the window you're in there
// and follows it (KWinData.moveToNamed). Plasma's Meta+Return and
// Meta+Shift+Return run scripts' tide-go-to-workspace and
// tide-move-to-workspace, which call `prompt go` and `prompt move` here.
// The prompts for a new window or a launch are tide's session's
// (PromptData).
Singleton {
    id: root

    // The request shown, {id, kind: "go" or "move"}, or null.
    property var current: null
    property int asked: 0

    function ask(kind) {
        // The desktops as they are now: one made or renamed in Plasma's
        // Pager since the last read is listed.
        KWinData.refresh();
        root.asked += 1;
        root.current = { id: root.asked, kind: kind };
    }

    function answer(name) {
        const kind = root.current?.kind;
        root.current = null;
        if (kind === "move") {
            KWinData.moveToNamed(name);
        } else {
            KWinData.goToNamed(name);
        }
    }

    function cancel() {
        root.current = null;
    }

    IpcHandler {
        target: "prompt"

        function go(): void {
            root.ask("go");
        }
        // The window you're in, which KWin keeps active under the prompt.
        function move(): void {
            root.ask("move");
        }
        // The kind of the prompt shown, or "" with none: for tests.
        function shown(): string {
            return root.current?.kind ?? "";
        }
    }
}
