import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import "lib/launcher.mjs" as Search
import "lib/overview.mjs" as Ov
import "lib/sharepicker.mjs" as Picker
import "lib/workspaces.mjs" as Ws

// The overview (SPEC.md §8.7): every workspace's windows as cards, grouped
// by workspace, the current one first, full screen on the focused monitor.
// `qs -c tide ipc call overview toggle` opens and closes it, as Esc or a
// click on empty space does; it has no key yet. A click on a card, or
// the arrows and Enter, goes to that window; a click on a group's name
// goes to that workspace; typing filters the cards.
//
// Each card shows the window's picture, taken once as it opens: on
// Hyprland with ScreencopyView, as the share picker's are; on tidewm with
// `grim -T` into $XDG_RUNTIME_DIR/tide/overview. Without one, its icon.
PanelWindow {
    id: root

    property bool shown: false
    // Bumped at each open, so each card takes its picture again.
    property int session: 0
    property int selected: 0
    property string focusedAtOpen: ""
    // The open whose pictures tidewm's grim has taken; until then, icons.
    property int shotsFor: 0

    readonly property string shotDir: {
        const run = Quickshell.env("XDG_RUNTIME_DIR");
        return run ? `${run}/tide/overview` : "";
    }
    readonly property var all: root.shown ? Ov.groups({
        workspaces: Compositor.workspaces,
        standing: WorkspacesData.standing,
        windows: Compositor.windows,
        current: Compositor.monitors.find(m => m.name === Compositor.focusedMonitorName)?.workspace ?? null,
        monitors: Quickshell.screens.map(s => s.name)
    }) : []
    readonly property var groups: Ov.filtered(root.all, field.text, app => DesktopEntries.heuristicLookup(app)?.name ?? "")
    readonly property var cards: Ov.cards(root.groups)

    function open() {
        const focused = Compositor.focusedScreen;
        if (focused) {
            root.screen = focused;
        }
        root.focusedAtOpen = FocusData.focused?.address ?? "";
        field.text = "";
        root.session += 1;
        root.shown = true;
        root.takeShots();
        root.selected = Ov.startAt(root.groups, root.focusedAtOpen);
        field.forceActiveFocus();
    }

    // tidewm: every window's picture at once, as it opens. Here, not in
    // the cards, which typing rebuilds.
    function takeShots() {
        if (!Compositor.tidewm) {
            return;
        }
        const command = Ov.shotsCommand(root.shotDir, Compositor.windows.map(w => w.identifier));
        if (command === null) {
            return;
        }
        shots.takingFor = root.session;
        shots.command = command;
        shots.running = true;
    }

    Process {
        id: shots

        property int takingFor: 0

        onExited: (code, status) => {
            if (code !== 0) {
                console.warn(`tide: the overview's grim -T exited ${code}; some windows show their icon`);
            }
            root.shotsFor = shots.takingFor;
        }
    }

    function close() {
        root.shown = false;
    }

    function toggle() {
        if (root.shown) {
            root.close();
        } else {
            root.open();
        }
    }

    function choose(card) {
        const c = Ov.choice(card);
        root.close();
        if (c.restore !== undefined) {
            Compositor.moveWindowTo(c.restore, c.to);
        } else {
            Compositor.focusWindow(c.focus);
        }
    }

    function goTo(name) {
        root.close();
        Compositor.goToWorkspace(name);
    }

    // The selected card, kept in view once the positioners have placed it,
    // as the share picker's.
    property Item chosenCard: null
    onChosenCardChanged: Qt.callLater(root.reveal)

    function reveal() {
        if (!root.chosenCard || !root.shown) {
            return;
        }
        const top = root.chosenCard.mapToItem(column, 0, 0).y;
        scroller.contentY = Picker.revealY(scroller.contentY, scroller.height, scroller.contentHeight, top, root.chosenCard.height, 16);
    }

    onCardsChanged: root.selected = Math.min(root.selected, Math.max(0, root.cards.length - 1))

    IpcHandler {
        target: "overview"

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

    visible: root.shown
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "tide-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(Theme.barBg.r, Theme.barBg.g, Theme.barBg.b, 0.92)

    // A click on empty space closes it.
    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    TextInput {
        id: field

        x: 40
        y: 28
        width: parent.width - 80
        height: 28
        color: Theme.fg
        selectionColor: Theme.accentBg
        font.family: Theme.font
        font.pixelSize: 16
        clip: true
        maximumLength: 256
        onTextChanged: root.selected = 0

        Keys.onEscapePressed: root.close()
        Keys.onReturnPressed: root.enter()
        Keys.onEnterPressed: root.enter()
        Keys.onLeftPressed: event => root.step(event, -1)
        Keys.onRightPressed: event => root.step(event, 1)
        Keys.onUpPressed: event => root.step(event, -1)
        Keys.onDownPressed: event => root.step(event, 1)
        Keys.onTabPressed: event => root.step(event, 1)
        Keys.onBacktabPressed: event => root.step(event, -1)

        Text {
            visible: field.text === ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.all.length > 0 ? "Type to filter windows" : "No windows open"
            color: Theme.fgFaint
            font: field.font
        }
    }

    function step(event, by) {
        root.selected = Search.moved(root.selected, by, root.cards.length);
        event.accepted = true;
    }

    function enter() {
        const card = root.cards[root.selected];
        if (card) {
            root.choose(card);
        }
    }

    Flickable {
        id: scroller

        x: 40
        y: field.y + field.height + 16
        width: parent.width - 80
        height: parent.height - y - 24
        contentHeight: column.implicitHeight
        clip: true
        onHeightChanged: root.reveal()
        onContentHeightChanged: root.reveal()
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: column

            width: scroller.width
            spacing: 24

            Repeater {
                model: root.groups

                Column {
                    id: group

                    required property var modelData
                    required property int index
                    // The index of this group's first card among them all.
                    readonly property int first: Ov.cards(root.groups.slice(0, group.index)).length

                    width: column.width
                    spacing: 10

                    Text {
                        text: group.modelData.current ? `${group.modelData.name} · current` : group.modelData.name
                        textFormat: Text.PlainText
                        color: nameHover.hovered ? Theme.accent : Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 15
                        font.weight: Font.DemiBold

                        HoverHandler {
                            id: nameHover

                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            onTapped: root.goTo(group.modelData.name)
                        }
                    }

                    Flow {
                        width: parent.width
                        spacing: 14

                        Repeater {
                            model: group.modelData.windows

                            Rectangle {
                                id: card

                                required property var modelData
                                required property int index
                                readonly property bool chosen: group.first + card.index === root.selected
                                readonly property string iconSource: Quickshell.iconPath(
                                    DesktopEntries.heuristicLookup(card.modelData.app)?.icon ?? card.modelData.app,
                                    "application-x-executable")
                                // Hyprland's toplevel, for ScreencopyView.
                                readonly property var toplevel: root.shown && !Compositor.tidewm
                                    ? Hyprland.toplevels.values.find(t => Ws.normalizeAddress(t.address) === card.modelData.address)?.wayland ?? null
                                    : null
                                readonly property string shotFile: Compositor.tidewm ? (Ov.shotFile(root.shotDir, card.modelData.identifier) ?? "") : ""
                                // tidewm's, once this open's pictures are taken.
                                readonly property string shotSource: card.shotFile !== "" && root.shotsFor === root.session
                                    ? `file://${card.shotFile}?${root.session}` : ""

                                width: 260
                                height: thumb.height + label.height + 18
                                radius: 12
                                color: chosen ? Qt.tint(Theme.surface2, Qt.rgba(Theme.accentBg.r, Theme.accentBg.g, Theme.accentBg.b, 0.18)) : Theme.surface2
                                border.width: chosen ? 2 : 0
                                border.color: Theme.accentBg
                                opacity: card.modelData.minimized ? 0.75 : 1

                                onChosenChanged: {
                                    if (card.chosen) {
                                        root.chosenCard = card;
                                    }
                                }
                                Component.onCompleted: {
                                    if (card.chosen) {
                                        root.chosenCard = card;
                                    }
                                }
                                // The positioners place a card after it's made.
                                onYChanged: {
                                    if (card.chosen) {
                                        Qt.callLater(root.reveal);
                                    }
                                }

                                Rectangle {
                                    id: thumb

                                    x: 6
                                    y: 6
                                    width: parent.width - 12
                                    height: 146
                                    radius: 8
                                    color: Theme.barBg
                                    clip: true

                                    ScreencopyView {
                                        id: view

                                        anchors.centerIn: parent
                                        visible: !Compositor.tidewm
                                        captureSource: card.toplevel
                                        // One frame each: there may be many.
                                        live: false
                                        constraintSize: Qt.size(thumb.width, thumb.height)
                                    }

                                    Image {
                                        id: picture

                                        anchors.fill: parent
                                        visible: Compositor.tidewm && status === Image.Ready
                                        source: card.shotSource
                                        cache: false
                                        asynchronous: true
                                        fillMode: Image.PreserveAspectFit
                                        sourceSize: Qt.size(thumb.width * 2, thumb.height * 2)
                                    }

                                    IconImage {
                                        visible: Compositor.tidewm ? picture.status !== Image.Ready : !view.hasContent
                                        anchors.centerIn: parent
                                        implicitSize: 48
                                        source: card.iconSource
                                    }
                                }

                                Row {
                                    id: label

                                    x: 10
                                    anchors.top: thumb.bottom
                                    anchors.topMargin: 6
                                    width: parent.width - 20
                                    spacing: 6

                                    IconImage {
                                        anchors.verticalCenter: parent.verticalCenter
                                        implicitSize: 16
                                        source: card.iconSource
                                    }

                                    Text {
                                        width: parent.width - 22 - (mark.visible ? mark.implicitWidth + 6 : 0)
                                        elide: Text.ElideRight
                                        textFormat: Text.StyledText
                                        text: Search.highlighted(card.modelData.title || card.modelData.appName, card.modelData.title ? card.modelData.titleAt : card.modelData.appAt, Theme.accent)
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                    }

                                    Text {
                                        id: mark

                                        visible: card.modelData.minimized
                                        text: "minimized"
                                        color: Theme.fgDim
                                        font.family: Theme.font
                                        font.pixelSize: 11
                                    }
                                }

                                TapHandler {
                                    onTapped: root.choose(card.modelData)
                                }
                                HoverHandler {
                                    cursorShape: Qt.PointingHandCursor
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
