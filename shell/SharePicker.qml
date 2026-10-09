import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import "lib/sharepicker.mjs" as Picker
import "lib/workspaces.mjs" as Ws

// The screen-share picker (SPEC.md §12, docs/mocks/share-picker.png), for
// `tide-share-picker`, which xdph runs when an app asks to share. It
// offers each screen, each window xdph can share, and a 16:9 area of each
// monitor wider than that, centered on the focused monitor over a dimmed
// backdrop like the launcher. The arrow keys move through the options,
// Enter or a double-click shares the highlighted one, and Escape or Cancel
// says no. The answer goes back on the pipe the picker named.
PanelWindow {
    id: root

    // The pipe the open request's answer goes to; empty while closed.
    property string reply: ""
    property var opts: []
    property int selected: -1
    property bool reuse: false
    // The last choice made and when, so the next request within
    // Picker.REPEAT_MS opens on it.
    property var last: null
    readonly property var option: selected >= 0 && selected < opts.length ? opts[selected] : null
    // The highlighted option's tile, kept in view as it moves and as the
    // list lays out.
    property Item chosenTile: null

    onChosenTileChanged: Qt.callLater(root.reveal)

    function screenInfo(s) {
        return {
            name: s.name,
            width: s.width,
            height: s.height
        };
    }

    function workspaceOf(address) {
        const t = Hyprland.toplevels.values.find(w => Ws.normalizeAddress(w.address) === address);
        return t?.workspace?.id ?? null;
    }

    function show(replyPath, allowToken, list) {
        // A request while one is open answers the old one first: no.
        if (root.reply !== "") {
            root.answer("");
        }
        const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor) ?? null;
        if (focused) {
            screen = focused;
        }
        const opts = Picker.options(Quickshell.screens.map(screenInfo), Picker.parseWindows(list), workspaceOf, Hyprland.focusedMonitor?.activeWorkspace?.id ?? null);
        root.opts = opts;
        root.reuse = allowToken;
        root.selected = Picker.preselect(opts, {
            screen: focused ? screenInfo(focused) : null,
            address: Ws.normalizeAddress(Hyprland.activeToplevel?.address)
        }, root.last, Date.now());
        root.reply = replyPath;
        visible = true;
        keys.forceActiveFocus();
    }

    // Writes `line` to the open request's pipe, empty for no, and closes.
    // `kind` is what it shares, if anything, and `label` names it, which
    // ShareData hears only once the picker has the answer: a choice that
    // never reached xdph has no stream to pair with (§12). A pipe that's
    // gone means the picker gave up, and the write fails.
    function answer(line, kind, label) {
        if (root.reply === "") {
            return;
        }
        writer.createObject(root, {
            command: Picker.answerCommand(line, root.reply),
            kind: kind ?? "",
            label: label ?? ""
        });
        root.close();
    }

    // Closes with no answer, for a picker that has stopped waiting.
    function close() {
        root.reply = "";
        root.opts = [];
        visible = false;
    }

    function share() {
        if (!root.option) {
            return;
        }
        root.last = {
            key: root.option.key,
            time: Date.now()
        };
        root.answer(Picker.selectionLine(root.option, root.reuse), root.option.kind, root.option.label);
    }

    function reveal() {
        if (!root.chosenTile) {
            return;
        }
        const top = root.chosenTile.mapToItem(column, 0, 0).y;
        scroller.contentY = Picker.revealY(scroller.contentY, scroller.height, scroller.contentHeight, top, root.chosenTile.height, 16);
    }

    function move(step) {
        if (root.opts.length > 0) {
            root.selected = Math.max(0, Math.min(root.opts.length - 1, root.selected + step));
        }
    }

    visible: false
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-share-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive, so the window under the pointer can't take the keyboard
    // while you choose (§14.2).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.45)

    // `qs -c tide ipc call sharepicker pick REPLY ALLOW LIST` opens it for
    // tide-share-picker, which waits on REPLY; `... cancel REPLY` closes it
    // with no, if REPLY is still the open request's.
    IpcHandler {
        target: "sharepicker"

        function pick(reply: string, allowToken: string, windows: string): string {
            if (!Picker.validReply(reply, Quickshell.env("XDG_RUNTIME_DIR"))) {
                return `refused: ${reply} isn't a tide-share-picker pipe`;
            }
            root.show(reply, allowToken === "true", windows);
            return "shown";
        }

        function cancel(reply: string): void {
            // tide-share-picker has stopped reading, so nothing is written.
            if (reply === root.reply) {
                root.close();
            }
        }
    }

    // One write of an answer, reported if it fails, then gone.
    Component {
        id: writer

        Process {
            id: write

            // What the answer shares, for ShareData once it's written.
            property string kind: ""
            property string label: ""

            Component.onCompleted: running = true
            stderr: SplitParser {
                onRead: line => console.warn(`share picker: answering tide-share-picker: ${line}`)
            }
            onExited: (code, status) => {
                const outcome = Picker.answerOutcome(code, write.kind);
                // For the stream that follows, so a window share holds no
                // popups and the Sharing pill can say what's shared.
                if (outcome.chose) {
                    ShareData.chose(outcome.chose, write.label);
                }
                if (outcome.warning) {
                    console.warn(`share picker: ${outcome.warning}`);
                }
                write.destroy();
            }
        }
    }

    Item {
        id: keys

        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.answer("");
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.share();
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                root.move(-1);
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                root.move(1);
            } else {
                return;
            }
            event.accepted = true;
        }
    }

    // The backdrop takes clicks, so nothing under it does, but they do
    // nothing here: a stray click shouldn't answer for you.
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        id: card

        x: Math.round((parent.width - width) / 2)
        y: 70
        width: Math.min(960, parent.width - 40)
        height: Math.min(column.implicitHeight + 40, parent.height - 100)
        radius: 12
        color: Theme.surface
        border.color: Theme.edge
        clip: true

        Flickable {
            id: scroller

            anchors.fill: parent
            anchors.margins: 20
            contentHeight: column.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            onHeightChanged: root.reveal()
            onContentHeightChanged: root.reveal()

            Column {
                id: column

                width: parent.width
                spacing: 16

                Row {
                    spacing: 12

                    SymbolicIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        implicitWidth: 28
                        implicitHeight: 28
                        name: "video-display-symbolic"
                        color: Theme.accent
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            text: "Share your screen"
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 18
                            font.weight: Font.Bold
                        }

                        Text {
                            text: "An app asked to share. Pick what it gets."
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }
                }

                Repeater {
                    model: [{
                            kind: "screen",
                            title: "Screens",
                            note: ""
                        }, {
                            kind: "window",
                            title: "Windows",
                            note: "on every workspace, current one first"
                        }, {
                            kind: "region",
                            title: "Area",
                            note: ""
                        }]

                    Column {
                        id: section

                        required property var modelData
                        readonly property var entries: root.opts.map((o, i) => ({
                                    option: o,
                                    index: i
                                })).filter(e => e.option.kind === section.modelData.kind)

                        visible: entries.length > 0
                        width: column.width
                        spacing: 8

                        Row {
                            spacing: 8

                            Text {
                                text: section.modelData.title.toUpperCase()
                                color: Theme.fgFaint
                                font.family: Theme.font
                                font.pixelSize: 11
                                font.weight: Font.Bold
                                font.letterSpacing: 0.6
                            }

                            Text {
                                text: section.modelData.note
                                color: Theme.fgFaint
                                font.family: Theme.font
                                font.pixelSize: 11
                            }
                        }

                        Flow {
                            width: parent.width
                            spacing: 12

                            Repeater {
                                model: section.entries

                                Rectangle {
                                    id: tile

                                    required property var modelData
                                    readonly property var option: modelData.option
                                    readonly property bool chosen: modelData.index === root.selected
                                    readonly property var shot: root.visible ? (option.kind === "window" ? Hyprland.toplevels.values.find(t => Ws.normalizeAddress(t.address) === option.address)?.wayland ?? null : Quickshell.screens.find(s => s.name === option.screen) ?? null) : null

                                    width: (option.kind === "window" ? 196 : 250) + 12
                                    height: thumb.height + label.height + 18
                                    radius: 12
                                    color: chosen ? Qt.tint(Theme.surface2, Qt.rgba(Theme.accentBg.r, Theme.accentBg.g, Theme.accentBg.b, 0.18)) : Theme.surface2
                                    border.width: chosen ? 2 : 0
                                    border.color: Theme.accentBg

                                    onChosenChanged: {
                                        if (tile.chosen) {
                                            root.chosenTile = tile;
                                        }
                                    }
                                    Component.onCompleted: {
                                        if (tile.chosen) {
                                            root.chosenTile = tile;
                                        }
                                    }

                                    Rectangle {
                                        id: thumb

                                        x: 6
                                        y: 6
                                        width: parent.width - 12
                                        height: option.kind === "window" ? 110 : 105
                                        radius: 7
                                        color: Theme.barBg
                                        clip: true

                                        ScreencopyView {
                                            id: view

                                            anchors.centerIn: parent
                                            // Screens stay live while it's open; a window's thumbnail
                                            // is one frame, since there may be many.
                                            captureSource: tile.shot
                                            live: tile.option.kind !== "window" && root.visible
                                            constraintSize: Qt.size(thumb.width, thumb.height)
                                        }

                                        // The area's outline over its monitor.
                                        Rectangle {
                                            readonly property real k: view.width / Math.max(1, Quickshell.screens.find(s => s.name === tile.option.screen)?.width ?? 1)

                                            visible: tile.option.kind === "region" && view.hasContent && view.sourceSize.width > 0
                                            x: view.x + (tile.option.area?.x ?? 0) * k
                                            y: view.y + (tile.option.area?.y ?? 0) * k
                                            width: (tile.option.area?.w ?? 0) * k
                                            height: (tile.option.area?.h ?? 0) * k
                                            color: "transparent"
                                            border.width: 2
                                            border.color: Theme.accent
                                        }

                                        IconImage {
                                            visible: !view.hasContent && tile.option.kind === "window"
                                            anchors.centerIn: parent
                                            implicitSize: 40
                                            source: Quickshell.iconPath(DesktopEntries.heuristicLookup(tile.option.cls)?.icon ?? tile.option.cls, "application-x-executable")
                                        }
                                    }

                                    Row {
                                        id: label

                                        x: 10
                                        anchors.top: thumb.bottom
                                        anchors.topMargin: 6
                                        width: parent.width - 20
                                        spacing: 6

                                        Text {
                                            width: parent.width - detail.implicitWidth - 6
                                            elide: Text.ElideRight
                                            textFormat: Text.PlainText
                                            text: tile.option.label
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 12
                                            font.weight: Font.DemiBold
                                        }

                                        Text {
                                            id: detail

                                            text: tile.option.detail
                                            color: Theme.fgDim
                                            font.family: Theme.font
                                            font.pixelSize: 12
                                        }
                                    }

                                    TapHandler {
                                        onTapped: root.selected = tile.modelData.index
                                        onDoubleTapped: {
                                            root.selected = tile.modelData.index;
                                            root.share();
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Item {
                    width: column.width
                    height: 34

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18
                            height: 18
                            radius: 5
                            color: root.reuse ? Theme.accentBg : "transparent"
                            border.color: root.reuse ? "transparent" : Theme.edge

                            SymbolicIcon {
                                visible: root.reuse
                                anchors.centerIn: parent
                                implicitWidth: 14
                                implicitHeight: 14
                                name: "object-select-symbolic"
                                color: Theme.accentFg
                            }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Let this app reuse this choice"
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 13
                        }

                        TapHandler {
                            onTapped: root.reuse = !root.reuse
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Repeater {
                            model: [{
                                    label: "Cancel",
                                    primary: false
                                }, {
                                    label: Picker.shareLabel(root.option),
                                    primary: true
                                }]

                            Rectangle {
                                required property var modelData

                                width: buttonLabel.implicitWidth + 28
                                height: 32
                                radius: 8
                                color: modelData.primary ? Theme.accentBg : hover.hovered ? Theme.surface2 : "transparent"
                                border.color: modelData.primary ? "transparent" : Theme.edge
                                opacity: modelData.primary && !root.option ? 0.5 : 1

                                HoverHandler {
                                    id: hover
                                }

                                TapHandler {
                                    onTapped: parent.modelData.primary ? root.share() : root.answer("")
                                }

                                Text {
                                    id: buttonLabel

                                    anchors.centerIn: parent
                                    text: parent.modelData.label
                                    color: parent.modelData.primary ? Theme.accentFg : Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
