import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import "lib/launcher.mjs" as Search
import "lib/notifications.mjs" as Notes
import "lib/session.mjs" as Session
import "lib/workspaces.mjs" as Workspaces

// The launcher (SPEC.md §8): fuzzy search over the apps' desktop entries
// and their actions, centered near the top of the focused monitor over a
// dimmed backdrop. `Super+Space` (Hyprland's `tide:launcher` global
// shortcut) or `qs -c tide ipc call launcher toggle` opens and closes it;
// Escape or a click on the backdrop closes it. Its quick actions take
// screenshots, run the session actions, flip Do not disturb and keep awake,
// and reload the shell. Frecency, sections and Ctrl+Enter come later
// (TODO.md).
PanelWindow {
    id: root

    property string query: ""
    property int selected: -1
    // The selected row's key (Search.rowKey: kind and id), so a change of
    // state under an open launcher keeps it selected (Search.reselect), and
    // the opening, query and confirmation the rows were last built for.
    property var selectedKey: null
    property string shownFor: ""
    // A power action being checked against logind's inhibitors, and one
    // that something blocks, which asks before going ahead (§8), with what
    // blocks it.
    property bool checking: false
    // Counts openings, so a power check that finishes after the launcher
    // closed, or was opened again, leaves the new one alone.
    property int session: 0
    property string asking: ""
    property var blocked: []
    // Read when it opens rather than bound, so an app installed while it's
    // closed shows the next time, and one installed while it's open doesn't
    // reshuffle the list under the pointer.
    property var apps: []
    // The toggles' rows say whether they're on, so they follow the state.
    readonly property var items: root.apps.concat(Search.quickActions({
        notifications: NotificationData.enabled,
        dnd: NotificationData.dnd,
        keepAwake: KeepAwakeData.on,
        micHolds: MicData.live && !KeepAwakeData.asked
    }))
    readonly property var rows: root.asking !== "" ? Search.confirmRows(root.asking) : Search.search(root.items, root.query, LauncherData.frecency, root.openedAt)
    // Frecency is read as of the opening, so the order doesn't shift while
    // it's open.
    property real openedAt: 0
    // A screenshot waiting for the launcher to leave the screen, and the
    // window you were in when it opened, which "Screenshot window" takes
    // (§8): the address of Hyprland's focused window, which the launcher's
    // layer surface doesn't change. Only the address is kept; the window's
    // geometry is read when the screenshot runs (Search.windowScreenshot),
    // so a window that moved meanwhile is taken where it is.
    property string pending: ""
    property var windowAtOpen: null

    function open() {
        const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor);
        if (focused) {
            screen = focused;
        }
        // A screenshot still waiting would catch the launcher it's opening.
        screenshotDelay.stop();
        pending = "";
        windowAtOpen = Workspaces.normalizeAddress(Hyprland.activeToplevel?.address);
        session += 1;
        openedAt = Date.now();
        apps = Search.launcherItems(DesktopEntries.applications.values);
        checking = false;
        asking = "";
        blocked = [];
        selectedKey = null;
        query = "";
        field.text = "";
        // The rows rebuild above (with a new opening, so on the top hit);
        // say so here too, in case none of that changed them.
        selected = Search.reselect(null, rows, true);
        selectedKey = Search.rowKey(rows[selected]);
        visible = true;
        field.forceActiveFocus();
    }

    function close() {
        visible = false;
    }

    function toggle() {
        if (visible) {
            close();
        } else {
            open();
        }
    }

    function runRow(index) {
        const row = rows[index];
        if (!row || checking) {
            return;
        }
        if (row.item.kind === "confirm") {
            const id = asking;
            close();
            if (row.item.id === "anyway") {
                Launcher.run(Session.actionCommand(id, true), null);
            }
            return;
        }
        // Choosing it counts as using it, a blocked power action too: the
        // next opening lists it sooner either way.
        LauncherData.record(Search.rowKey(row));
        if (row.item.kind === "quick" && Search.quickCommand(row.item.id).power) {
            checkPower(row.item.id);
            return;
        }
        close();
        if (row.item.kind === "quick") {
            runQuick(row.item.id);
        } else {
            Launcher.start(Search.launchCommand(row.item), row.item.workingDirectory);
        }
    }

    // A power action stays open until logind says whether something blocks
    // it, then asks, naming what's in the way, as the session menu does.
    // One that fails for another reason closes; the failure is logged.
    function checkPower(id) {
        checking = true;
        const token = session;
        Launcher.run(Search.quickCommand(id).run, (ok, errors) => {
            if (token !== session || !visible) {
                return;
            }
            checking = false;
            const found = ok ? [] : Session.blockers(errors);
            if (found.length > 0) {
                blocked = found;
                asking = id;
            } else {
                close();
            }
        });
    }

    function runQuick(id) {
        const what = Search.quickCommand(id);
        if (what.shell === "dnd") {
            NotificationData.setDnd(!NotificationData.dnd);
        } else if (what.shell === "keep-awake") {
            KeepAwakeData.toggle();
        } else if (what.shell === "reload") {
            Quickshell.reload(false);
        } else if (what.afterClose) {
            pending = id;
            screenshotDelay.restart();
        } else {
            Launcher.run(what.run, null);
        }
    }

    // Long enough for the compositor to unmap the launcher and its backdrop,
    // so a screenshot doesn't catch them, and for focus to go back to the
    // window you were in, which "Screenshot window" takes.
    Timer {
        id: screenshotDelay

        interval: 300
        onTriggered: {
            const id = root.pending;
            root.pending = "";
            if (id === "") {
                return;
            }
            Launcher.run(Search.quickCommand(id, {
                window: root.windowAtOpen
            }).run, null);
        }
    }

    // A new query preselects its top hit, so a query and Enter runs it;
    // anything else that rebuilds the rows keeps the row you were on.
    onRowsChanged: {
        // Each opening counts as a new query too, so it starts on the top
        // hit whatever was selected when it last closed.
        const key = `${session}\n${asking}\n${query}`;
        const changed = key !== shownFor;
        shownFor = key;
        selected = Search.reselect(selectedKey, rows, changed);
        selectedKey = Search.rowKey(rows[selected]);
        if (changed) {
            list.positionViewAtBeginning();
        }
    }
    onSelectedChanged: selectedKey = Search.rowKey(rows[selected])

    visible: false
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive, so the window under the pointer can't take the keyboard
    // back while it's open (§14.2).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    // The mock's backdrop: black at 35%.
    color: Qt.rgba(0, 0, 0, 0.35)

    GlobalShortcut {
        appid: "tide"
        name: "launcher"
        description: "Open or close the launcher"
        onPressed: root.toggle()
    }

    IpcHandler {
        target: "launcher"

        function toggle(): void {
            root.toggle();
        }
        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
    }

    // A click on the backdrop closes it; the card takes its own clicks.
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
                    // The query stays put while a power action is checked or
                    // asks; Escape cancels it.
                    readOnly: root.checking || root.asking !== ""
                    onTextChanged: root.query = text

                    Keys.onEscapePressed: root.close()
                    Keys.onReturnPressed: root.runRow(root.selected)
                    Keys.onEnterPressed: root.runRow(root.selected)
                    Keys.onUpPressed: root.selected = Search.moved(root.selected, -1, root.rows.length)
                    Keys.onDownPressed: root.selected = Search.moved(root.selected, 1, root.rows.length)
                    Keys.onPressed: event => {
                        // Tab and Shift+Tab step through the sections; the
                        // field keeps focus rather than passing it on.
                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            root.selected = Search.nextSection(root.rows, root.selected, event.key === Qt.Key_Backtab ? -1 : 1);
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
                        text: "Search apps and actions"
                        color: Theme.fgFaint
                        font: field.font
                    }
                }

                Text {
                    id: count

                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.query.trim() !== "" && root.asking === ""
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

            // What blocks a power action, above its Anyway and Cancel rows.
            Text {
                visible: root.asking !== ""
                width: parent.width
                leftPadding: 10
                rightPadding: 10
                bottomPadding: 4
                wrapMode: Text.WordWrap
                text: Search.blockedHeading(root.asking)
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 13
                font.weight: Font.Bold
            }

            Repeater {
                model: root.asking !== "" ? root.blocked : []

                Text {
                    required property string modelData

                    width: column.width
                    leftPadding: 10
                    rightPadding: 10
                    bottomPadding: 4
                    wrapMode: Text.WordWrap
                    // Inhibitor names come from other programs: never markup.
                    textFormat: Text.PlainText
                    text: modelData
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 12.5
                }
            }

            ListView {
                id: list

                width: parent.width
                // About seven rows, as in the mock; more scroll.
                height: Math.min(contentHeight, 8 * 48)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.rows
                currentIndex: root.selected
                highlightMoveDuration: 0

                delegate: Item {
                    id: slot

                    required property var modelData
                    required property int index
                    // The first row of a section carries its heading.
                    readonly property bool heading: Search.startsSection(root.rows, index)

                    width: list.width
                    height: (heading ? 28 : 0) + 48

                    Text {
                        visible: slot.heading
                        height: 28
                        leftPadding: 10
                        topPadding: 12
                        textFormat: Text.PlainText
                        text: (slot.modelData.section ?? "").toUpperCase()
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        font.letterSpacing: 0.6
                    }

                    Rectangle {
                        id: row

                        readonly property var modelData: slot.modelData
                        readonly property int index: slot.index
                        readonly property bool current: index === root.selected

                        y: slot.heading ? 28 : 0
                        width: slot.width
                        height: 48
                        radius: 10
                        color: current ? Theme.accentBg : hover.hovered ? Theme.surface2 : "transparent"

                        HoverHandler {
                            id: hover
                        }

                        TapHandler {
                            onTapped: root.runRow(row.index)
                        }

                        // The key that does the same, so the launcher teaches
                        // the bindings.
                        Rectangle {
                            id: hint

                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            visible: (row.modelData.item.hint ?? "") !== ""
                            width: hintText.implicitWidth + 12
                            height: 20
                            radius: 5
                            color: row.current ? Qt.rgba(1, 1, 1, 0.16) : Theme.surface2

                            Text {
                                id: hintText

                                anchors.centerIn: parent
                                textFormat: Text.PlainText
                                text: row.modelData.item.hint ?? ""
                                color: row.current ? Qt.rgba(1, 1, 1, 0.82) : Theme.fgDim
                                font.family: Theme.font
                                font.pixelSize: 11
                            }
                        }

                        // A quick action's (or a confirmation's) symbolic icon,
                        // colored like the bar's;
                        // an app's own icon goes in the same place.
                        SymbolicIcon {
                            anchors.centerIn: icon
                            visible: row.modelData.item.kind === "quick" || row.modelData.item.kind === "confirm"
                            implicitWidth: 22
                            implicitHeight: 22
                            name: visible ? row.modelData.item.icon : ""
                            color: row.current ? "#ffffff" : Theme.fg
                        }

                        IconImage {
                            id: icon

                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            implicitSize: 32
                            // Empty for a quick action, whose box still lays the
                            // row out.
                            // An entry may name its icon by path rather than by theme name.
                            source: row.modelData.item.kind === "quick" || row.modelData.item.kind === "confirm" ? "" : Notes.iconFile(row.modelData.item.icon) ?? Quickshell.iconPath(row.modelData.item.icon, "application-x-executable")
                        }

                        Column {
                            anchors.left: icon.right
                            anchors.leftMargin: 12
                            anchors.right: hint.visible ? hint.left : parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                // Built by Search.highlighted, which escapes the
                                // name: desktop entries are never markup.
                                textFormat: Text.StyledText
                                text: Search.highlighted(row.modelData.item.name, row.modelData.positions, row.current ? "#ffffff" : Theme.accent)
                                color: row.current ? "#ffffff" : Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                            }

                            Text {
                                width: parent.width
                                visible: text !== ""
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                                text: row.modelData.item.sub
                                color: row.current ? Qt.rgba(1, 1, 1, 0.82) : Theme.fgDim
                                font.family: Theme.font
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }

            Text {
                visible: root.rows.length === 0
                width: parent.width
                topPadding: 12
                bottomPadding: 12
                horizontalAlignment: Text.AlignHCenter
                text: "No matches"
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 13
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
                    model: [["↑↓", "select"], ["↵", "run"], ["Tab", "next section"], ["Esc", "close"]]

                    Text {
                        required property var modelData

                        textFormat: Text.PlainText
                        text: `${modelData[0]}  ${modelData[1]}`
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 11.5
                    }
                }
            }
        }
    }
}
