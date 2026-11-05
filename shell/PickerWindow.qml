import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "lib/dispatch.mjs" as Dispatch
import "lib/launch.mjs" as Run
import "lib/launcher.mjs" as Search
import "lib/picker.mjs" as Picker

// The picker on Super+V (SPEC.md §8.4), and on Super+Shift+V on its Fill
// tab, which types a snippet or a Bitwarden login's field: a Clipboard tab, the history
// tide-clipboard.service keeps with cliphist, and a Characters tab, emoji
// and symbols from shell/chars/chars.tsv found by name. Drawn like the
// switcher, near the top of the focused monitor over a dimmed backdrop.
// `qs -c tide ipc call picker toggle clipboard` (conf's Super+V) opens
// it, and the same again closes it; Tab and Shift+Tab move between the
// tabs; Enter copies the selection, closes, and pastes it into the window
// the picker opened over; Shift+Delete forgets the
// selected clipboard entry; Esc or a click on the backdrop closes it.
PanelWindow {
    id: root

    property string tab: "clipboard"
    property string query: ""
    property int selected: -1

    // The history as last listed, newest first, and why it couldn't be
    // listed, if it couldn't. Listed afresh at each opening.
    property var history: []
    property string historyError: ""
    property bool historyLoading: false
    // Counts listings, so one that finishes after a newer one started is
    // dropped.
    property int listing: 0

    // The snippets and logins `tide fill list` printed, listed afresh each
    // time the Fill tab shows: names only, never a secret.
    property var fillEntries: []
    property string fillError: ""
    property bool fillLoading: false
    // Counts Fill listings, as `listing` counts the history's.
    property int fillListing: 0

    // The character list, read once, the first time the tab shows.
    property var chars: []
    property string charsError: ""
    property bool charsRead: false

    // The window focused when the picker opened, {address, class}, which
    // Enter pastes into; null with none, as on an empty workspace
    // (FocusData.qml).
    property var pasteInto: null

    readonly property var rows: root.tab === "clipboard" ? Picker.historyRows(root.history, root.query)
        : root.tab === "fill" ? Picker.fillRows(root.fillEntries, root.query)
        : Picker.characterRows(root.chars, root.query)
    readonly property string emptyText: Picker.emptyText(root.tab, root.query, {
        loading: root.tab === "fill" ? root.fillLoading : root.historyLoading,
        error: root.tab === "clipboard" ? root.historyError : root.tab === "fill" ? root.fillError : root.charsError
    })

    onRowsChanged: {
        selected = rows.length > 0 ? 0 : -1;
        list.positionViewAtBeginning();
    }

    function open(tab) {
        showTab(tab ?? "clipboard");
        if (visible) {
            return;
        }
        // The paste is Hyprland's sendshortcut, which tidewm has no
        // counterpart to yet, so on tidewm a choice is only copied.
        pasteInto = Compositor.tidewm ? null
            : Picker.pasteTarget(FocusData.focused ? { address: FocusData.focused.address, class: FocusData.focused.app } : null);
        const focused = Compositor.focusedScreen;
        if (focused) {
            screen = focused;
        }
        query = "";
        field.text = "";
        listHistory();
        if (root.tab === "fill") {
            listFill();
        }
        visible = true;
        field.forceActiveFocus();
    }

    function close() {
        visible = false;
    }

    function toggle(tab) {
        const next = Picker.toggled(visible, root.tab, tab ?? "clipboard");
        if (next.visible) {
            open(next.tab);
        } else {
            close();
        }
    }

    function showTab(tab) {
        if (tab === "characters" && !root.charsRead) {
            root.charsRead = true;
            // Blocks until onLoaded or onLoadFailed has run.
            charsFile.text();
        }
        if (tab === root.tab) {
            return;
        }
        root.tab = tab;
        root.query = "";
        field.text = "";
        if (tab === "fill" && visible) {
            listFill();
        }
    }

    function listHistory() {
        root.listing += 1;
        root.historyLoading = true;
        lister.createObject(root, { token: root.listing }).running = true;
    }

    function listFill() {
        root.fillListing += 1;
        root.fillLoading = true;
        lister.createObject(root, { token: root.fillListing, what: "fill" }).running = true;
    }

    // Enter: the selection onto the clipboard, the picker away, and, once
    // the copy has worked, Ctrl+V (Ctrl+Shift+V in a terminal) sent to the
    // window it opened over. With no window, or a failed copy, it doesn't
    // paste. A failure is logged (Launcher.run).
    function choose(index) {
        const row = rows[index];
        if (!row) {
            return;
        }
        const into = root.pasteInto;
        close();
        // Fill types into the window that has the keyboard once the picker's
        // surface is gone, through wtype (bin/tide-fill): nothing goes on
        // the clipboard, so no history keeps a password. Unlock asks rbw
        // for the master password, then opens the tab again.
        if (root.tab === "fill") {
            const command = Picker.fillCommand(row.item);
            Launcher.run(command, ok => {
                if (ok && row.item.kind === "unlock") {
                    root.open("fill");
                }
            });
            return;
        }
        const paste = ok => {
            if (!ok || !into) {
                return;
            }
            const keys = Picker.pasteShortcut(into.class);
            Hyprland.dispatch(Dispatch.sendShortcut(keys.mods, keys.key, into.address, Hyprland.usingLua));
        };
        if (root.tab === "clipboard") {
            Launcher.run(["tide", "clipboard", "copy", row.item.id], paste);
        } else {
            Launcher.run(["tide", "clipboard", "put", row.item.char], paste);
        }
    }

    // Shift+Delete: forget the selected clipboard entry. It goes from the
    // list at once; the history is listed again once cliphist is done, so
    // a delete that failed shows the entry back.
    function forget(index) {
        const row = rows[index];
        if (root.tab !== "clipboard" || !row) {
            return;
        }
        const id = row.item.id;
        root.history = root.history.filter(e => e.id !== id);
        Launcher.run(["tide", "clipboard", "delete", id], () => {
            if (root.visible) {
                root.listHistory();
            }
        });
    }

    visible: false
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive, as the switcher's, so the window under the pointer can't
    // take the keyboard back while it's open (§14.2).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.35)

    // `qs -c tide ipc call picker toggle clipboard`: conf's Super+V. A tab
    // it doesn't have is refused, and says so.
    IpcHandler {
        target: "picker"

        function toggle(tab: string): string {
            if (!Picker.TABS.includes(tab)) {
                return `no ${tab} tab; the tabs are ${Picker.TABS.join(", ")}`;
            }
            root.toggle(tab);
            return "ok";
        }
        function open(tab: string): string {
            if (!Picker.TABS.includes(tab)) {
                return `no ${tab} tab; the tabs are ${Picker.TABS.join(", ")}`;
            }
            root.open(tab);
            return "ok";
        }
        function close(): void {
            root.close();
        }
    }

    // `tide clipboard list`, read once both its streams end, as KeysData
    // reads hyprctl's.
    Component {
        id: lister

        Process {
            id: run

            property int token: 0
            // "clipboard" or "fill": which list it reads.
            property string what: "clipboard"
            property var state: Run.initial()
            property string out: ""
            property bool outRead: false
            property string errors: ""
            property bool errorsRead: false

            command: ["tide", what, "list"]

            function streamed() {
                if (outRead && errorsRead) {
                    handle({ type: "stderr", text: errors });
                }
            }

            function handle(event) {
                if (state.done) {
                    return;
                }
                state = Run.step(state, event, command);
                if (!state.done) {
                    return;
                }
                const fill = what === "fill";
                const failed = state.report?.level === "warn";
                const r = fill ? Picker.listedFill(failed, out, errors) : Picker.listedHistory(failed, out, errors);
                if (r.error !== "") {
                    console.warn(`tide: the picker's ${fill ? "snippets and logins" : "clipboard history"}: ${r.error}`);
                }
                for (const w of r.warnings) {
                    console.warn(`tide: tide ${what} list: ${w}`);
                }
                const target = Picker.listingTarget(what, token, { clipboard: root.listing, fill: root.fillListing });
                if (target === "fill") {
                    root.fillEntries = r.entries;
                    root.fillError = r.error;
                    root.fillLoading = false;
                } else if (target === "clipboard") {
                    root.history = r.entries;
                    root.historyError = r.error;
                    root.historyLoading = false;
                }
                destroy();
            }

            stdout: StdioCollector {
                onStreamFinished: {
                    run.out = text;
                    run.outRead = true;
                    run.streamed();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    run.errors = text;
                    run.errorsRead = true;
                    run.streamed();
                }
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (code, status) => handle({ type: "exited", code: code })
        }
    }

    // The character list, beside the shell's files.
    FileView {
        id: charsFile

        path: decodeURIComponent(Qt.resolvedUrl("chars/chars.tsv").toString().replace(/^file:\/\//, ""))
        printErrors: false
        // Read only when the tab first shows (root.showTab), and then
        // before it draws, so what's typed next searches the whole list.
        // It's about 130 KB.
        preload: false
        blockLoading: true
        onLoaded: {
            const r = Picker.parseChars(text());
            for (const error of r.errors) {
                console.warn(`tide: ${path}: ${error}`);
            }
            root.chars = r.chars;
            root.charsError = r.chars.length === 0 ? `No characters in ${path}` : "";
        }
        onLoadFailed: error => {
            root.charsError = `Couldn't read the character list: ${FileViewError.toString(error)}`;
            console.warn(`tide: ${path}: ${FileViewError.toString(error)}`);
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    Rectangle {
        id: card

        x: Math.round((parent.width - width) / 2)
        y: 56
        width: 560
        height: column.implicitHeight + 20
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        MouseArea {
            anchors.fill: parent
        }

        Column {
            id: column

            x: 10
            y: 10
            width: parent.width - 20

            Row {
                spacing: 4
                bottomPadding: 8

                Repeater {
                    model: Picker.TABS

                    Rectangle {
                        id: tabChip

                        required property string modelData
                        readonly property bool shown: modelData === root.tab

                        width: tabLabel.implicitWidth + 20
                        height: 26
                        radius: 8
                        color: shown ? Theme.accentBg : "transparent"

                        Text {
                            id: tabLabel

                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: Picker.TAB_NAMES[tabChip.modelData]
                            color: tabChip.shown ? "#ffffff" : Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }

                        TapHandler {
                            onTapped: {
                                root.showTab(tabChip.modelData);
                                field.forceActiveFocus();
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 46
                radius: 12
                color: Theme.surface2

                SymbolicIcon {
                    id: glass

                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: 20
                    implicitHeight: 20
                    name: "system-search-symbolic"
                    color: Theme.fgDim
                }

                TextInput {
                    id: field

                    anchors.left: glass.right
                    anchors.leftMargin: 10
                    anchors.right: count.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.fg
                    selectionColor: Theme.accentBg
                    font.family: Theme.font
                    font.pixelSize: 16
                    clip: true
                    onTextChanged: root.query = text

                    Keys.onEscapePressed: root.close()
                    Keys.onReturnPressed: root.choose(root.selected)
                    Keys.onEnterPressed: root.choose(root.selected)
                    Keys.onUpPressed: root.selected = Search.moved(root.selected, -1, root.rows.length)
                    Keys.onDownPressed: root.selected = Search.moved(root.selected, 1, root.rows.length)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            root.showTab(Picker.movedTab(root.tab, event.key === Qt.Key_Backtab ? -1 : 1));
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Delete && event.modifiers & Qt.ShiftModifier) {
                            root.forget(root.selected);
                            event.accepted = true;
                        } else if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_N) {
                            root.selected = Search.moved(root.selected, 1, root.rows.length);
                            event.accepted = true;
                        } else if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_P) {
                            root.selected = Search.moved(root.selected, -1, root.rows.length);
                            event.accepted = true;
                        }
                    }

                    Text {
                        visible: field.text === ""
                        anchors.verticalCenter: parent.verticalCenter
                        text: Picker.PLACEHOLDERS[root.tab]
                        color: Theme.fgFaint
                        font: field.font
                    }
                }

                Text {
                    id: count

                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.query.trim() !== ""
                    text: root.rows.length === 1 ? "1 result" : `${root.rows.length} results`
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }
            }

            Item {
                width: 1
                height: 8
            }

            // A tab with no rows says why: nothing copied, cliphist missing.
            Text {
                visible: root.rows.length === 0 && text !== ""
                width: parent.width
                leftPadding: 10
                rightPadding: 10
                topPadding: 6
                bottomPadding: 6
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.emptyText
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 13
            }

            ListView {
                id: list

                width: parent.width
                height: Math.min(contentHeight, 8 * 48)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.rows
                currentIndex: root.selected
                highlightMoveDuration: 0

                delegate: Rectangle {
                    id: row

                    required property var modelData
                    required property int index
                    readonly property bool current: index === root.selected
                    readonly property bool character: root.tab === "characters"

                    width: list.width
                    height: 48
                    radius: 10
                    color: current ? Theme.accentBg : hover.hovered ? Theme.surface2 : "transparent"

                    HoverHandler {
                        id: hover
                    }

                    TapHandler {
                        onTapped: root.choose(row.index)
                    }

                    Rectangle {
                        id: glyph

                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        height: 32
                        radius: 8
                        color: row.current ? Qt.rgba(1, 1, 1, 0.16) : Theme.surface2

                        Text {
                            anchors.centerIn: parent
                            visible: row.character
                            textFormat: Text.PlainText
                            text: row.character ? row.modelData.item.char : ""
                            color: row.current ? "#ffffff" : Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 20
                        }

                        SymbolicIcon {
                            anchors.centerIn: parent
                            visible: !row.character
                            implicitWidth: 18
                            implicitHeight: 18
                            name: row.character ? "" : root.tab === "fill" ? Picker.fillIcon(row.modelData.item) : row.modelData.item.kind === "image" ? "image-x-generic-symbolic" : row.modelData.item.kind === "link" ? "insert-link-symbolic" : "text-x-generic-symbolic"
                            color: row.current ? "#ffffff" : Theme.fgDim
                        }
                    }

                    Column {
                        anchors.left: glyph.right
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            // Built by Search.highlighted, which escapes it:
                            // what you copied is never markup.
                            textFormat: Text.StyledText
                            text: Search.highlighted(row.modelData.item.name, row.modelData.positions, row.current ? "#ffffff" : Theme.accent)
                            color: row.current ? "#ffffff" : Theme.fg
                            font.family: row.character ? Theme.font : Theme.monoFont
                            font.pixelSize: 14
                            font.weight: row.character ? Font.DemiBold : Font.Normal
                        }

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: row.character ? Picker.characterSub(row.modelData.item) : row.modelData.item.sub
                            color: row.current ? Qt.rgba(1, 1, 1, 0.82) : Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.edge
            }

            Row {
                topPadding: 10
                leftPadding: 10
                spacing: 16

                Repeater {
                    model: root.tab === "clipboard"
                        ? [["↑↓", "select"], ["↵", "paste"], ["Shift+Del", "forget"], ["Tab", "characters"], ["Esc", "close"]]
                        : root.tab === "characters"
                        ? [["↑↓", "select"], ["↵", "paste"], ["Tab", "fill"], ["Esc", "close"]]
                        : [["↑↓", "select"], ["↵", "type"], ["Tab", "clipboard"], ["Esc", "close"]]

                    Text {
                        required property var modelData

                        textFormat: Text.PlainText
                        text: `${modelData[0]}  ${modelData[1]}`
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
            }
        }
    }
}
