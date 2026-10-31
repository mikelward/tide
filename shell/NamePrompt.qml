import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "lib/launcher.mjs" as Search
import "lib/workspacenames.mjs" as Names
import "lib/workspaces.mjs" as Ws

// The name prompt (SPEC.md §6.5): names the workspace a window goes to, or
// a launch opens on. It's drawn like the launcher, centered near the top of
// the focused monitor, and holds the keyboard the same way. PromptData
// says what it's for; this shows the first request waiting.
//   - The text starts as the window's short name, selected, so typing
//     replaces it, and follows the window's title until you type.
//   - The rows are the typed name, when it's new, then the workspaces that
//     match it. Home is offered only to one of home's apps.
//   - Enter goes to the selected row's workspace, made if it's new; Esc is
//     PromptData.cancel's.
PanelWindow {
    id: root

    readonly property var request: PromptData.current
    readonly property bool asking: root.request !== null
    // The request the text was last set for, so a new one starts afresh and
    // the same one keeps what you typed.
    property int shownFor: 0
    // Whether you've typed since it opened: until then the text follows
    // the window's title.
    property bool edited: false
    property bool settingText: false
    property int selected: 0

    readonly property var window: root.request && root.request.address !== undefined
        ? Hyprland.toplevels.values.find(t => Ws.normalizeAddress(t.address) === root.request.address) ?? null
        : null
    readonly property string windowClass: root.window ? (root.window.lastIpcObject?.class || root.window.wayland?.appId || "") : ""
    readonly property string suggested: root.window
        ? Names.shortName(root.window.title, DesktopEntries.heuristicLookup(root.windowClass)?.name ?? "", PromptData.patterns)
        : ""
    readonly property var names: Ws.workspaceOrder(Hyprland.workspaces.values.map(w => ({
        id: w.id,
        name: w.name
    })), WorkspacesData.standing).map(w => w.name)
    readonly property var rows: Names.promptRows({
        names: root.names,
        typed: field.text,
        home: PromptData.home,
        allowHome: root.request?.allowHome ?? false
    })
    readonly property string refusal: root.rows.length > 0 ? "" : Names.promptChoice({
        rows: root.rows,
        selected: root.selected,
        typed: field.text,
        home: PromptData.home,
        allowHome: root.request?.allowHome ?? false
    }).error ?? ""

    function setText(text) {
        root.settingText = true;
        field.text = text;
        field.selectAll();
        root.settingText = false;
    }

    function enter() {
        const choice = Names.promptChoice({
            rows: root.rows,
            selected: root.selected,
            typed: field.text,
            home: PromptData.home,
            allowHome: root.request?.allowHome ?? false
        });
        if (choice.name !== undefined) {
            PromptData.answer(choice.name);
        }
    }

    onRequestChanged: {
        if (root.request === null || root.request.id === root.shownFor) {
            return;
        }
        root.shownFor = root.request.id;
        root.edited = false;
        root.selected = 0;
        const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor);
        if (focused) {
            root.screen = focused;
        }
        root.setText(root.suggested);
        field.forceActiveFocus();
    }
    onSuggestedChanged: {
        if (root.asking && !root.edited) {
            root.setText(root.suggested);
        }
    }
    onRowsChanged: root.selected = Math.min(root.selected, Math.max(0, root.rows.length - 1))

    visible: root.asking
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-name-prompt"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.35)

    // A click on the backdrop does nothing: Esc says what's to become of
    // the window or the launch, and a stray click shouldn't close a window.
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        x: Math.round((parent.width - width) / 2)
        y: 56
        width: 480
        height: column.implicitHeight + 20
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Column {
            id: column

            x: 10
            y: 10
            width: parent.width - 20
            spacing: 8

            Text {
                width: parent.width
                leftPadding: 4
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.request?.kind === "launch" ? "Open on the workspace named"
                    : root.request?.kind === "move" ? "Move this window to the workspace named"
                    : "This window goes to the workspace named"
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }

            Rectangle {
                width: parent.width
                height: 42
                radius: 10
                color: Theme.surface2

                TextInput {
                    id: field

                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.fg
                    selectionColor: Theme.accentBg
                    font.family: Theme.font
                    font.pixelSize: 16
                    clip: true
                    maximumLength: 256
                    // What a name can't hold (Names.UNSAFE) can't be typed.
                    // Qt matches it as PCRE, which has no \u escape, so the
                    // control characters are \x: with \u, nothing could be.
                    validator: RegularExpressionValidator {
                        regularExpression: /[^"'`\\\x00-\x1f\x7f]*/
                    }
                    onTextChanged: {
                        if (!root.settingText) {
                            root.edited = true;
                            root.selected = 0;
                        }
                    }

                    Keys.onEscapePressed: PromptData.cancel()
                    Keys.onReturnPressed: root.enter()
                    Keys.onEnterPressed: root.enter()
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
                        text: "Name a workspace"
                        color: Theme.fgFaint
                        font: field.font
                    }
                }
            }

            Text {
                visible: root.refusal !== "" && field.text.trim() !== ""
                width: parent.width
                leftPadding: 4
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.refusal
                color: Theme.urgent
                font.family: Theme.font
                font.pixelSize: 12
            }

            Repeater {
                model: root.rows

                Rectangle {
                    id: row

                    required property var modelData
                    required property int index
                    readonly property bool current: index === root.selected

                    width: column.width
                    height: 36
                    radius: 8
                    color: current ? Theme.accentBg : hover.hovered ? Theme.surface2 : "transparent"

                    HoverHandler {
                        id: hover
                    }

                    TapHandler {
                        onTapped: {
                            root.selected = row.index;
                            root.enter();
                        }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        textFormat: Text.StyledText
                        text: row.modelData.isNew
                            ? `New workspace <b>${Search.highlighted(row.modelData.name, [], row.current ? "#ffffff" : Theme.accent)}</b>`
                            : Search.highlighted(row.modelData.name, row.modelData.positions, row.current ? "#ffffff" : Theme.accent)
                        color: row.current ? "#ffffff" : Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 14
                    }
                }
            }
        }
    }
}
