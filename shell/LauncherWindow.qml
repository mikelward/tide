import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import "lib/launcher.mjs" as Search
import "lib/notifications.mjs" as Notes

// The launcher (SPEC.md §8): fuzzy search over the apps' desktop entries
// and their actions, centered near the top of the focused monitor over a
// dimmed backdrop. `Super+Space` (Hyprland's `tide:launcher` global
// shortcut) or `qs -c tide ipc call launcher toggle` opens and closes it;
// Escape or a click on the backdrop closes it. Quick actions, frecency,
// sections and Ctrl+Enter come later (TODO.md).
PanelWindow {
    id: root

    property string query: ""
    property int selected: -1
    // Read when it opens rather than bound, so an app installed while it's
    // closed shows the next time, and one installed while it's open doesn't
    // reshuffle the list under the pointer.
    property var items: []
    readonly property var rows: Search.search(root.items, root.query)

    function open() {
        const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor);
        if (focused) {
            screen = focused;
        }
        items = Search.launcherItems(DesktopEntries.applications.values);
        query = "";
        field.text = "";
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
        if (!row) {
            return;
        }
        close();
        Launcher.start(Search.launchCommand(row.item), row.item.workingDirectory);
    }

    // The top hit is preselected, so a query and Enter runs it.
    onRowsChanged: {
        selected = rows.length > 0 ? 0 : -1;
        list.positionViewAtBeginning();
    }

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
                    onTextChanged: root.query = text

                    Keys.onEscapePressed: root.close()
                    Keys.onReturnPressed: root.runRow(root.selected)
                    Keys.onEnterPressed: root.runRow(root.selected)
                    Keys.onUpPressed: root.selected = Search.moved(root.selected, -1, root.rows.length)
                    Keys.onDownPressed: root.selected = Search.moved(root.selected, 1, root.rows.length)
                    Keys.onPressed: event => {
                        if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_N) {
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

            ListView {
                id: list

                width: parent.width
                // Seven rows, as in the mock; more scroll.
                height: Math.min(contentHeight, 7 * 48)
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

                    width: list.width
                    height: 48
                    radius: 10
                    color: current ? Theme.accentBg : hover.hovered ? Theme.surface2 : "transparent"

                    HoverHandler {
                        id: hover
                    }

                    TapHandler {
                        onTapped: root.runRow(row.index)
                    }

                    IconImage {
                        id: icon

                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 32
                        // An entry may name its icon by path rather than by theme name.
                        source: Notes.iconFile(row.modelData.item.icon) ?? Quickshell.iconPath(row.modelData.item.icon, "application-x-executable")
                    }

                    Column {
                        anchors.left: icon.right
                        anchors.leftMargin: 12
                        anchors.right: parent.right
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
                    model: [["↑↓", "select"], ["↵", "run"], ["Esc", "close"]]

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
