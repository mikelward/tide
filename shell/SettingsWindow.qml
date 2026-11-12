import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Wayland
import "lib/appearance.mjs" as Appearance
import "lib/audio.mjs" as Audio
import "lib/cities.mjs" as Cities
import "lib/barside.mjs" as BarSide
import "lib/baricons.mjs" as BarIcons
import "lib/clipboard.mjs" as Clip
import "lib/dnd.mjs" as Dnd
import "lib/floating.mjs" as FloatRules
import "lib/idle.mjs" as Idle
import "lib/input.mjs" as Input
import "lib/keymaps.mjs" as KeyPresets
import "lib/keys.mjs" as Shortcuts
import "lib/launch.mjs" as Run
import "lib/layouts.mjs" as Layouts
import "lib/outputs.mjs" as Outputs
import "lib/power.mjs" as Power
import "lib/settings.mjs" as Settings
import "lib/status.mjs" as Status
import "lib/workspacenames.mjs" as Names
import "lib/workspacepage.mjs" as WsPage

// The settings panel (SPEC.md §16), centered on the focused monitor over a
// dimmed backdrop, as the launcher is: the pages down the side, the one
// chosen beside them, and at its foot the app that does the rest, if any.
// The pages are grouped under headings, which can't be chosen.
// The launcher's Settings action or `qs -c tide ipc call settings toggle`
// opens and closes it; Escape or a click on the backdrop closes it. The
// field over the sidebar keeps the pages a search finds, and has the
// keyboard: Up and Down change the page, past the headings and the pages
// it dropped, Escape empties it first, and Enter, with it empty, opens the
// page's app.
PanelWindow {
    id: root

    property int page: 0
    readonly property var current: Settings.PAGES[page]
    readonly property var advancedLink: Settings.advancedFor(current, Compositor.tidewm, Quickshell.env("HOME") ?? "", Quickshell.env("XDG_CONFIG_HOME") ?? "")
    // The section of the page to scroll to, by its id (settings.mjs's
    // SECTIONS, or floating-add for the Floating page's fields), or "": set
    // as one opens, and cleared by another page or a flick.
    property string section: ""
    // What's typed in the sidebar's search field, the rows it keeps, and
    // their pages (settings.mjs's searchedSidebar).
    property string query: ""
    readonly property var rows: Settings.searchedSidebar(query)
    readonly property var kept: Settings.keptPages(rows)

    // Another page starts at its top.
    onPageChanged: {
        wallpaperColors.close();
        wallpaperGrid.close();
        cityPicker.close();
        section = "";
        pageFlick.contentY = 0;
    }
    onSectionChanged: pageFlick.scrolled()

    // A search that drops the page showing shows the first it keeps, and
    // one that finds a page by a section only scrolls there. Finding
    // nothing, or nothing typed, leaves the page as it is.
    onQueryChanged: {
        const pages = Settings.keptPages(Settings.searchedSidebar(query));
        if (pages.length > 0 && pages.indexOf(page) < 0) {
            page = pages[0];
        }
        const found = Settings.searchedSection(page, query);
        if (found !== "") {
            section = found;
        }
    }

    // Shows the page at `index`, at the section the search found it by.
    function show(index) {
        page = index;
        const found = Settings.searchedSection(index, query);
        if (found !== "") {
            section = found;
        }
    }

    // Opens on page `id`, or at section `id`, or on the first page with
    // none (settings.mjs's); one already open moves there. Answers why
    // not, or "".
    function open(id) {
        const to = id ? Settings.opened(id) : { index: 0, section: "" };
        if (to === null) {
            return `no ${id} page; the pages are ${[...Settings.PAGES, ...Settings.SECTIONS].map(p => p.id).join(", ")}`;
        }
        // Each opening starts with every page.
        keys.text = "";
        if (visible) {
            if (id) {
                page = to.index;
                section = to.section;
            }
            return "";
        }
        const focused = Compositor.focusedScreen;
        if (focused) {
            screen = focused;
        }
        page = to.index;
        section = to.section;
        visible = true;
        keys.forceActiveFocus();
        return "";
    }

    function close() {
        KeysData.stop();
        wallpaperColors.close();
        wallpaperGrid.close();
        cityPicker.close();
        visible = false;
    }

    function toggle() {
        if (visible) {
            close();
        } else {
            open();
        }
    }

    // A change a page asked for and was refused, which the log has.
    function report(error) {
        if (error !== "") {
            console.warn(`tide: ${error}`);
        }
    }

    // The wallpaper chooser running, or null (pickWallpaper).
    property var picking: null

    // A wallpaper's choose button: the desktop portal's file chooser
    // (tide-pick), offering images, for setting `key`, `label`'s. The panel
    // closes first, so the chooser opens over the desktop, not under it,
    // and comes back on Appearance once it answers, with the file set.
    function pickWallpaper(key, label) {
        if (picking !== null) {
            return;
        }
        const command = Appearance.pickCommand(label, AppearanceData.settings[key] ?? "", Quickshell.env("HOME") ?? "");
        close();
        picking = picker.createObject(root, { key: key, command: command });
        picking.running = true;
    }

    // What tide-pick answered for `key`: the file chosen, nothing for a
    // cancel, or why it couldn't ask, shown as a refused change is.
    function picked(key, ok, errors, output) {
        picking = null;
        open("appearance");
        if (!ok) {
            appearance.refused = `couldn't open the file chooser: ${errors.trim() || "tide-pick didn't start"}`;
            return;
        }
        const value = Appearance.pickedWallpaper(output, Quickshell.env("HOME") ?? "");
        if (value !== "") {
            appearance.set(key, value);
        }
    }

    // Closes first, so the app opens over the desktop, not under the panel.
    function advanced() {
        if (advancedLink === null) {
            return;
        }
        const command = advancedLink.command;
        const dirs = advancedLink.dirs ?? [];
        close();
        if (dirs.length > 0) {
            // Launched either way: a failed mkdir is logged, and the app
            // says itself what it lacks
            Launcher.run(["mkdir", "-p", "--"].concat(dirs), () => Launcher.launch(command));
        } else {
            Launcher.launch(command);
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
    WlrLayershell.namespace: "tide-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive, as the launcher's, so the window under the pointer can't
    // take the keyboard back while it's open (§14.2).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    color: Qt.rgba(0, 0, 0, 0.35)

    IpcHandler {
        target: "settings"

        function toggle(): void {
            root.toggle();
        }
        function open(): void {
            root.open("");
        }
        // Opens on one page, as the launcher's "Mouse settings" does: `qs
        // -c tide ipc call settings openPage mouse`, or at a section of
        // one, as `openPage keys` opens Keyboard at its shortcuts. Answers
        // why not, or "".
        function openPage(page: string): string {
            return root.open(page);
        }
        // The page showing, by its id, or "" while closed.
        function shownPage(): string {
            return root.visible ? root.current.id : "";
        }
        function close(): void {
            root.close();
        }
        // Sets one of the Idle page's steps, as − and + do: `qs -c tide
        // ipc call settings setIdle lock 600`. Answers why not, or "".
        function setIdle(key: string, seconds: int): string {
            return IdleData.set(key, seconds);
        }
        // Turns the Idle page's Suspend on AC on or off, as a click does:
        // `qs -c tide ipc call settings setSuspendOnAC true`.
        function setSuspendOnAC(on: bool): string {
            return IdleData.set("suspendOnAC", on);
        }
        // Sets one of the Mouse, Touchpad or Keyboard pages' settings: `qs
        // -c tide ipc call settings setInput mouse leftHanded false`.
        // Answers why not, or "".
        function setInput(section: string, key: string, value: string): string {
            return InputData.set(section, key, Input.parseValue(section, key, value));
        }
        // Sets one mouse's, touchpad's or keyboard's own setting, by its
        // name in `hyprctl devices`, as those pages do with that device
        // chosen: `qs -c tide ipc call settings setDevice trackball speed
        // 0.5`.
        function setDevice(name: string, key: string, value: string): string {
            return InputData.setDevice(name, key, Input.parseValue(Input.deviceSection(name, key), key, value));
        }
        // Clears every setting of that device's own, as Reset does on each
        // page it's on.
        function clearDevice(name: string): string {
            return InputData.clearDevice(name);
        }
        // Add, move (a step to the right on the bar), relabel or take out
        // one of the Clocks page's clocks, by its zone, as that page does:
        // `qs -c tide ipc call settings addClock Asia/Kolkata`. Each
        // answers why not, or "".
        function addClock(zone: string): string {
            return ClockData.add(zone);
        }
        function moveClock(zone: string, step: int): string {
            return ClockData.move(undefined, zone, step);
        }
        function setClockLabel(zone: string, label: string): string {
            return ClockData.relabel(undefined, zone, label);
        }
        function removeClock(zone: string): string {
            return ClockData.remove(undefined, zone);
        }
        // Sets the system's time zone, as the Clocks page does: `qs -c tide
        // ipc call settings setSystemZone Europe/London`. Answers why it
        // didn't start, or ""; it may ask for a password, and a failure
        // after that is logged.
        function setSystemZone(zone: string): string {
            return ClockData.setSystemZone(zone);
        }
        // Turns one of the Clocks page's switches, hour24 or dedupeLocal,
        // on or off: `qs -c tide ipc call settings setClockSwitch hour24
        // false`. Answers why not, or "".
        function setClockSwitch(key: string, on: bool): string {
            return ClockData.setSwitch(key, on);
        }
        // Sets one of the Layouts page's settings, by its path, as that
        // page does: `qs -c tide ipc call settings setLayout
        // modes.tile.mfact 0.6`, a mode for defaultMode.normal or
        // defaultMode.ultrawide, or end, top, next or master for
        // newWindow. Answers why not, or "".
        function setLayout(path: string, value: string): string {
            return LayoutsData.set(path, path.startsWith("defaultMode.") || path === "newWindow" ? value : Number(value));
        }
        // Sets one of the Appearance page's settings, as it does: `qs -c
        // tide ipc call settings setAppearance mode dark`, a time
        // ("07:15"), a latitude or longitude, a dimStrength (0.1), or a
        // lightWallpaper or darkWallpaper, a file or a color such as
        // "#1a1d2e" ("" for the default), or a lightWallpaperPosition or
        // darkWallpaperPosition (fill, fill-top, fill-bottom, fit or
        // stretch), or barPosition (top or bottom). Answers why not, or
        // "".
        function setAppearance(key: string, value: string): string {
            if (key === "latitude" || key === "longitude") {
                const c = Appearance.parseCoordinate(key, value);
                return c.error ? `${c.error}; not changing ${key}` : AppearanceData.set(key, c.value);
            }
            return AppearanceData.set(key, key === "dimStrength" ? Number(value) : value);
        }
        // Sets one monitor's scale or position, by its description, as the
        // Displays page does: `qs -c tide ipc call settings setDisplay
        // "Dell Inc. DELL U2720Q 1234ABC" scale 1.5`; a scale of auto
        // clears this machine's, leaving outputs.json's or else Hyprland's
        // own, and a position of auto is set. Answers why not, or "".
        function setDisplay(description: string, key: string, value: string): string {
            if (key === "scale" && value === "auto") {
                return OutputsData.set(description, key, undefined);
            }
            return OutputsData.set(description, key, key === "scale" ? Number(value) : value);
        }

        // Clears a monitor's settings in outputs.local.json, as Reset does.
        function resetDisplay(description: string): string {
            return OutputsData.reset(description);
        }

        // Adds, moves (a step later) or takes out one of Start at login's
        // commands, by its text, as that page does: `qs -c tide ipc call
        // settings addStartup google-calendar`. Each answers why not, or "".
        function addStartup(command: string): string {
            return StartupData.add(command);
        }
        function moveStartup(command: string, step: int): string {
            return StartupData.move(undefined, command, step);
        }
        function removeStartup(command: string): string {
            return StartupData.remove(undefined, command);
        }

        // Sets one of the Notifications page's settings, as it does: `qs
        // -c tide ipc call settings setNotifications dndFrom 21:30`, a
        // switch as true or false, and dndDays as `mon,tue` ("" for none).
        // Answers why not, or "".
        function setNotifications(key: string, value: string): string {
            if (key === "dndDays") {
                return NotificationSettingsData.set(key, value === "" ? [] : value.split(","));
            }
            return NotificationSettingsData.set(key, value === "true" ? true : value === "false" ? false : value);
        }
        // Mutes or unmutes an app ID or site:HOST, as the Notifications
        // page's list does. Each answers why not, or "".
        function addMuted(entry: string): string {
            return WorkspacesData.addMuted(entry);
        }
        function removeMuted(entry: string): string {
            return WorkspacesData.removeMuted(undefined, entry);
        }

        // Sets one of the Clipboard page's settings, as it does: `qs -c
        // tide ipc call settings setClipboard maxItems 500`, maxAgeDays 30,
        // or history true or false. Answers why not, or "".
        function setClipboard(key: string, value: string): string {
            return ClipboardSettingsData.set(key, key === "maxItems" || key === "maxAgeDays" ? Number(value) : value === "true" ? true : value === "false" ? false : value);
        }
        // Clears the clipboard history, as the page's Clear history does.
        function clearClipboard(): void {
            ClipboardSettingsData.clear();
        }
        // Sets what closing the lid does, as the Power page does: `qs -c
        // tide ipc call settings setPower lidClose lock`. Answers why not,
        // or "".
        function setPower(key: string, value: string): string {
            return PowerData.set(key, value);
        }
        // Adds, moves (a step later) or takes out an entry of one of the
        // Workspaces page's lists, standing, inApps or namePatterns, as it
        // does: `qs -c tide ipc call settings addWorkspaceItem standing
        // docs`. Each answers why not, or "".
        function addWorkspaceItem(key: string, item: string): string {
            return WorkspacesData.addItem(key, item);
        }
        function moveWorkspaceItem(key: string, item: string, step: int): string {
            return WorkspacesData.moveItem(key, undefined, item, step);
        }
        function removeWorkspaceItem(key: string, item: string): string {
            return WorkspacesData.removeItem(key, undefined, item);
        }
        // One workspace's own settings, as the Workspaces page sets them:
        // `qs -c tide ipc call settings setWorkspaceAskForName re true`,
        // and `... addPinnedApp in gmail` or `... removePinnedApp in
        // gmail`. Each answers why not, or "".
        function setWorkspaceAskForName(name: string, on: bool): string {
            return WorkspacesData.setAskForName(name, on);
        }
        function addPinnedApp(name: string, item: string): string {
            return WorkspacesData.addPinned(name, item);
        }
        function removePinnedApp(name: string, item: string): string {
            return WorkspacesData.removePinned(name, undefined, item);
        }
        // Adds, moves (a step later) or takes out one of the Floating page's
        // rules, by its class and title pattern ("" for none), as it does:
        // `qs -c tide ipc call settings addFloating org.gnome.Calculator ""`.
        // Each answers why not, or "".
        function addFloating(cls: string, title: string): string {
            return FloatingData.add(cls, title);
        }
        function moveFloating(cls: string, title: string, step: int): string {
            return FloatingData.move(undefined, { class: cls, title: title }, step);
        }
        function removeFloating(cls: string, title: string): string {
            return FloatingData.remove(undefined, { class: cls, title: title });
        }
    }

    Connections {
        target: SettingsData

        function onOpenRequested(page) {
            root.report(root.open(page));
        }
    }

    // The Sound page's levels are only live on bound nodes; only while it shows.
    PwObjectTracker {
        objects: root.visible && root.current.id === "sound" ? [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource].filter(n => n) : []
    }

    component Heading: Text {
        leftPadding: 10
        topPadding: 8
        bottomPadding: 2
        color: Theme.fgDim
        font.family: Theme.font
        font.pixelSize: 11
        font.weight: Font.Bold
        font.letterSpacing: 0.5
    }

    // A small button with a word on it, as Reset is on the device pages.
    component PillButton: Rectangle {
        id: pill

        property string text
        // Shown as the one chosen.
        property bool selected: false

        signal activated

        anchors.verticalCenter: parent.verticalCenter
        width: pillText.implicitWidth + 24
        height: 24
        radius: 12
        color: pill.selected ? Theme.accentBg : pillHover.hovered ? Theme.edge : Theme.surface2

        Text {
            id: pillText

            anchors.centerIn: parent
            text: pill.text
            color: pill.selected ? Theme.accentFg : Theme.fg
            font.family: Theme.font
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }

        HoverHandler {
            id: pillHover
        }

        TapHandler {
            onTapped: pill.activated()
        }
    }

    // A page's − or +: dimmed when it wouldn't move `value`, and a click
    // asks to move it to `next`.
    component StepButton: Rectangle {
        id: button

        property string name
        property real value
        property real next
        readonly property bool moves: next !== value

        signal activated

        anchors.verticalCenter: parent.verticalCenter
        width: 26
        height: 26
        radius: 7
        color: hover.hovered && moves ? Theme.surface2 : "transparent"
        opacity: moves ? 1 : 0.4

        SymbolicIcon {
            anchors.centerIn: parent
            name: button.name
        }

        HoverHandler {
            id: hover
        }

        TapHandler {
            enabled: button.moves
            onTapped: button.activated()
        }
    }

    // The wallpaper grid's listing (galleryCommand), tracked as every
    // command the shell runs is, waiting for its stdout too.
    Component {
        id: gallery

        Process {
            id: list

            property var tracker: null

            function handle(event) {
                if (tracker.on(event)) {
                    destroy();
                }
            }

            Component.onCompleted: tracker = Run.track(command, (ok, errors, output) => wallpaperGrid.listed(ok, errors, output), {
                warn: m => console.warn(m),
                log: m => console.log(m)
            }, true)
            stdout: StdioCollector {
                onStreamFinished: list.handle({ type: "stdout", text: text })
            }
            stderr: StdioCollector {
                onStreamFinished: list.handle({ type: "stderr", text: text })
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (exitCode, status) => handle({ type: "exited", code: exitCode })
        }
    }

    // tide-pick, tracked as every command the shell runs is
    // (shell/lib/launch.mjs), waiting for its stdout too.
    Component {
        id: picker

        Process {
            id: pick

            property string key
            property var tracker: null

            function handle(event) {
                if (tracker.on(event)) {
                    destroy();
                }
            }

            Component.onCompleted: tracker = Run.track(command, (ok, errors, output) => root.picked(pick.key, ok, errors, output), {
                warn: m => console.warn(m),
                log: m => console.log(m)
            }, true)
            stdout: StdioCollector {
                onStreamFinished: pick.handle({ type: "stdout", text: text })
            }
            stderr: StdioCollector {
                onStreamFinished: pick.handle({ type: "stderr", text: text })
            }
            onStarted: handle({ type: "started" })
            onRunningChanged: {
                if (!running) {
                    handle({ type: "stopped" });
                }
            }
            onExited: (exitCode, status) => handle({ type: "exited", code: exitCode })
        }
    }

    // A click on the backdrop closes it; the card takes its own clicks.
    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    Rectangle {
        id: card

        // The sidebar at its tallest, with every page and heading, so the
        // card doesn't shrink as a search drops some.
        property real tallest: 0

        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 3)
        width: 640
        height: Math.max(440, tallest + 12)
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        // Takes every press on the card, under its buttons too, whose tap
        // handlers grab only passively, so a click anywhere but a field
        // takes the keyboard back from one being typed in.
        MouseArea {
            anchors.fill: parent
            onPressed: keys.forceActiveFocus()
        }

        Column {
            id: sidebar

            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 6
            width: 180
            spacing: 2
            onImplicitHeightChanged: card.tallest = Math.max(card.tallest, implicitHeight)

            Rectangle {
                width: sidebar.width
                height: 32
                radius: 7
                color: Theme.surface2

                SymbolicIcon {
                    id: glass

                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: 16
                    implicitHeight: 16
                    name: "system-search-symbolic"
                    color: Theme.fgDim
                }

                // The search field, which holds the keyboard while the
                // panel's open: a page's field hands it back when done.
                TextInput {
                    id: keys

                    anchors.left: glass.right
                    anchors.leftMargin: 10
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    focus: true
                    clip: true
                    color: Theme.fg
                    selectionColor: Theme.accentBg
                    font.family: Theme.font
                    font.pixelSize: 13
                    onTextChanged: root.query = text

                    Keys.onEscapePressed: {
                        if (text !== "") {
                            text = "";
                        } else {
                            root.close();
                        }
                    }
                    Keys.onUpPressed: root.show(Settings.movedPage(root.page, -1, root.kept))
                    Keys.onDownPressed: root.show(Settings.movedPage(root.page, 1, root.kept))
                    // Enter mid-search would open an app the query never
                    // named, so only an empty field opens the page's.
                    Keys.onReturnPressed: {
                        if (text === "") {
                            root.advanced();
                        }
                    }
                    Keys.onEnterPressed: {
                        if (text === "") {
                            root.advanced();
                        }
                    }

                    Text {
                        visible: keys.text === ""
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Search settings"
                        color: Theme.fgFaint
                        font: keys.font
                    }
                }
            }

            Text {
                visible: root.rows.length === 0
                width: sidebar.width
                leftPadding: 10
                topPadding: 6
                text: "No settings match"
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 13
            }

            // Each group's heading, then its pages, as the search keeps them.
            Repeater {
                model: root.rows

                Item {
                    id: sideRow

                    required property var modelData

                    width: sidebar.width
                    implicitHeight: modelData.heading !== "" ? groupHeading.implicitHeight : pageRow.implicitHeight

                    Heading {
                        id: groupHeading

                        visible: sideRow.modelData.heading !== ""
                        text: sideRow.modelData.heading.toUpperCase()
                    }

                    MenuRow {
                        id: pageRow

                        visible: sideRow.modelData.heading === ""
                        width: sidebar.width
                        icon: sideRow.modelData.page >= 0 ? Settings.PAGES[sideRow.modelData.page].icon : ""
                        label: sideRow.modelData.page >= 0 ? Settings.PAGES[sideRow.modelData.page].label : ""
                        highlighted: sideRow.modelData.page === root.page
                        onClicked: root.show(sideRow.modelData.page)
                    }
                }
            }
        }

        Rectangle {
            id: divider

            anchors.left: sidebar.right
            anchors.leftMargin: 6
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: Theme.edge
        }

        Item {
            anchors.left: divider.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: 6

            Text {
                id: title

                width: parent.width
                leftPadding: 10
                topPadding: 6
                bottomPadding: 6
                text: root.current.label
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 20
                font.weight: Font.Bold
            }

            Flickable {
                id: pageFlick

                // At root.section's top, once it's laid out and as it
                // grows, as far as the page scrolls.
                function scrolled() {
                    if (root.section === "keys" && keyList.visible) {
                        contentY = Math.max(0, Math.min(keyList.y, contentHeight - height));
                    }
                    // The Floating page's fields, filled in by Always float
                    // or Super+Alt+F, kept in view below the rules.
                    if (root.section === "floating-add" && floatingPage.visible) {
                        const bottom = floatingPage.y + floatAddRow.y + floatAddRow.height + 40;
                        contentY = Math.max(0, Math.min(bottom - height, contentHeight - height));
                    }
                }

                onContentHeightChanged: scrolled()
                onHeightChanged: scrolled()
                onMovementStarted: root.section = ""

                anchors.top: title.bottom
                anchors.bottom: advancedRow.top
                anchors.bottomMargin: 6
                width: parent.width
                contentHeight: pageColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: pageColumn

                    width: parent.width
                    spacing: 2

                    Text {
                        visible: root.current.about !== ""
                        width: parent.width
                        leftPadding: 10
                        rightPadding: 10
                        wrapMode: Text.WordWrap
                        text: root.current.about
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 13
                    }

                    // Idle: each step's time since the last input, which −
                    // and + move along idle.mjs's ladder (SPEC.md §10).
                    Column {
                        id: idle

                        visible: root.current.id === "idle"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Repeater {
                            model: Idle.STEPS

                            Item {
                                id: step

                                required property var modelData
                                readonly property int seconds: IdleData.idle[modelData.key]

                                width: idle.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: step.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "list-remove-symbolic"
                                        value: step.seconds
                                        next: Idle.stepped(step.seconds, -1)
                                        onActivated: root.report(IdleData.set(step.modelData.key, next))
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 92
                                        horizontalAlignment: Text.AlignHCenter
                                        text: Idle.formatDuration(step.seconds)
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        font.features: ({ "tnum": 1 })
                                    }

                                    StepButton {
                                        name: "list-add-symbolic"
                                        value: step.seconds
                                        next: Idle.stepped(step.seconds, 1)
                                        onActivated: root.report(IdleData.set(step.modelData.key, next))
                                    }
                                }
                            }
                        }

                        // Suspend on AC, which a click turns on or off.
                        Repeater {
                            model: Idle.SWITCHES

                            Item {
                                id: idleSwitch

                                required property var modelData
                                readonly property bool on: IdleData.idle[modelData.key] === true

                                width: idle.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: idleSwitch.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                // On or off, in the accent color while on,
                                // as the Mouse page's switches.
                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 56
                                    height: 26
                                    radius: 13
                                    color: idleSwitch.on ? Theme.accentBg : Theme.surface2

                                    Text {
                                        anchors.centerIn: parent
                                        text: idleSwitch.on ? "On" : "Off"
                                        color: idleSwitch.on ? Theme.accentFg : Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                    }

                                    TapHandler {
                                        onTapped: root.report(IdleData.set(idleSwitch.modelData.key, !idleSwitch.on))
                                    }
                                }
                            }
                        }
                    }

                    // Mouse, Touchpad and Keyboard: each setting for that
                    // kind of device, which − and + step along input.mjs's
                    // ladders, a click turns on or off, or is typed and set
                    // with Enter. Until it's set, it shows what conf's
                    // config has.
                    Column {
                        id: device

                        readonly property string section: ["mouse", "touchpad", "keyboard"].includes(root.current.id) ? root.current.id : ""
                        // Every device of the kind (""), then each one by
                        // name, which ‹ and › step through.
                        readonly property var targets: section !== "" ? Input.targets(InputData.input, InputData.connected, section) : [""]
                        // The one the settings below are for: "" for every
                        // device of the kind, or one by name.
                        property string name: ""
                        readonly property int at: Math.max(0, targets.indexOf(name))
                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""

                        function set(key, value) {
                            refused = name === "" ? InputData.set(section, key, value) : InputData.setDevice(name, key, value);
                            root.report(refused);
                        }

                        function shown(key) {
                            return name === "" ? Input.shown(InputData.input, section, key) : Input.deviceShown(InputData.input, name, key);
                        }

                        onSectionChanged: {
                            refused = "";
                            name = "";
                            if (section !== "") {
                                InputData.listDevices();
                            }
                        }
                        // One unplugged with nothing of its own, or just
                        // reset, has gone from the list.
                        onTargetsChanged: {
                            if (!targets.includes(name)) {
                                name = "";
                            }
                        }

                        visible: section !== ""
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        // Which the settings are for, once there's a
                        // device to choose; a device with settings of its
                        // own can go back to its kind's.
                        Item {
                            visible: device.targets.length > 1
                            width: device.width
                            implicitHeight: 32

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StepButton {
                                    name: "go-previous-symbolic"
                                    value: device.at
                                    next: Math.max(0, device.at - 1)
                                    onActivated: device.name = device.targets[next]
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 300
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideMiddle
                                    // Device names come from the hardware:
                                    // never markup.
                                    textFormat: Text.PlainText
                                    text: Input.targetLabel(device.section, device.name)
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }

                                StepButton {
                                    name: "go-next-symbolic"
                                    value: device.at
                                    next: Math.min(device.targets.length - 1, device.at + 1)
                                    onActivated: device.name = device.targets[next]
                                }
                            }

                            Rectangle {
                                visible: device.name !== "" && Input.hasOwn(InputData.input, device.name, device.section)
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: 56
                                height: 26
                                radius: 13
                                color: Theme.surface2

                                Text {
                                    anchors.centerIn: parent
                                    text: "Reset"
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                }

                                TapHandler {
                                    onTapped: {
                                        device.refused = InputData.clearDevice(device.name, device.section);
                                        root.report(device.refused);
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: device.section === "" ? [] : Input.SECTIONS[device.section]

                            Item {
                                id: option

                                required property var modelData
                                readonly property var value: device.shown(modelData.key)
                                readonly property bool toggle: modelData.kind === "toggle"
                                readonly property bool typed: Input.isText(modelData.kind)

                                width: device.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: option.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Row {
                                    visible: !option.toggle && !option.typed
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "list-remove-symbolic"
                                        value: option.toggle ? 0 : option.value
                                        next: option.toggle ? 0 : Input.stepped(option.modelData.kind, option.value, -1)
                                        onActivated: device.set(option.modelData.key, next)
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 92
                                        horizontalAlignment: Text.AlignHCenter
                                        text: option.toggle ? "" : Input.formatValue(option.modelData.kind, option.value)
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        font.features: ({ "tnum": 1 })
                                    }

                                    StepButton {
                                        name: "list-add-symbolic"
                                        value: option.toggle ? 0 : option.value
                                        next: option.toggle ? 0 : Input.stepped(option.modelData.kind, option.value, 1)
                                        onActivated: device.set(option.modelData.key, next)
                                    }
                                }

                                // On or off, in the accent color while on.
                                Rectangle {
                                    visible: option.toggle
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 56
                                    height: 26
                                    radius: 13
                                    color: option.value === true ? Theme.accentBg : Theme.surface2

                                    Text {
                                        anchors.centerIn: parent
                                        text: Input.formatValue("toggle", option.value === true)
                                        color: option.value === true ? Theme.accentFg : Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                    }

                                    TapHandler {
                                        enabled: option.toggle
                                        onTapped: device.set(option.modelData.key, option.value !== true)
                                    }
                                }

                                // A name, typed: Enter sets it, and Escape
                                // or a click elsewhere puts back what's set.
                                Rectangle {
                                    visible: option.typed
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 148
                                    height: 26
                                    radius: 6
                                    color: Theme.surface2
                                    border.width: field.activeFocus ? 1 : 0
                                    border.color: Theme.accent

                                    TextInput {
                                        id: field

                                        function shown() {
                                            return option.typed ? String(option.value) : "";
                                        }

                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        verticalAlignment: TextInput.AlignVCenter
                                        enabled: option.typed
                                        clip: true
                                        text: shown()
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        onAccepted: {
                                            device.set(option.modelData.key, text);
                                            keys.forceActiveFocus();
                                        }
                                        Keys.onEscapePressed: keys.forceActiveFocus()
                                        // Typing may have left it saying
                                        // something that isn't set.
                                        onActiveFocusChanged: {
                                            if (!activeFocus) {
                                                text = Qt.binding(() => field.shown());
                                            }
                                        }

                                        // No variant shows as none, not a
                                        // blank field.
                                        Text {
                                            visible: field.text === "" && !field.activeFocus
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "none"
                                            color: Theme.fgFaint
                                            font: field.font
                                        }
                                    }
                                }
                            }
                        }

                        // A typed name that isn't one, say.
                        Text {
                            visible: device.refused !== ""
                            x: 10
                            width: device.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: device.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Clocks: the bar's zones in its order, each with its
                    // label, typed and set with Enter; the arrows move one
                    // and the bin takes it out, and a zone typed at the
                    // foot is added before local (SPEC.md §7.3).
                    Column {
                        id: clocks

                        readonly property string localZone: ClockData.table ? ClockData.table.localZone : ""
                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""

                        function changed(error) {
                            refused = error;
                            root.report(error);
                        }

                        onVisibleChanged: refused = ""
                        visible: root.current.id === "clocks"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        // The system's time zone, local's: its ID, typed and
                        // set with Enter, as a clock's label is. Setting it
                        // may ask for a password.
                        Item {
                            width: clocks.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Time zone"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: 220
                                height: 26
                                radius: 6
                                color: Theme.surface2
                                border.width: systemZone.activeFocus ? 1 : 0
                                border.color: Theme.accent

                                TextInput {
                                    id: systemZone

                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    text: clocks.localZone
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    onAccepted: {
                                        clocks.changed(ClockData.setSystemZone(text.trim()));
                                        keys.forceActiveFocus();
                                    }
                                    Keys.onEscapePressed: keys.forceActiveFocus()
                                    onActiveFocusChanged: {
                                        if (!activeFocus) {
                                            text = Qt.binding(() => clocks.localZone);
                                        }
                                    }

                                    Text {
                                        visible: systemZone.text === "" && !systemZone.activeFocus
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "such as Europe/London"
                                        color: Theme.fgFaint
                                        font: systemZone.font
                                    }
                                }
                            }
                        }

                        // How setting it went, and why the bar may not
                        // follow: a session with $TZ set keeps that zone.
                        Text {
                            readonly property string sessionZone: Quickshell.env("TZ") || ""

                            visible: text !== ""
                            x: 10
                            width: clocks.width - 20
                            bottomPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: ClockData.settingSystemZone ? "Setting the time zone…" : ClockData.systemZoneFailure !== "" ? ClockData.systemZoneFailure : sessionZone !== "" ? `The TZ environment variable is ${sessionZone}, so the bar uses that zone.` : ""
                            color: ClockData.systemZoneFailure !== "" && !ClockData.settingSystemZone ? Theme.danger : Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 12
                        }

                        Repeater {
                            model: ClockData.listed

                            Item {
                                id: clock

                                required property var modelData
                                required property int index

                                width: clocks.width
                                implicitHeight: 32

                                // As the Keyboard page's names: Escape or a
                                // click elsewhere puts back what's set.
                                Rectangle {
                                    id: labelBox

                                    anchors.left: parent.left
                                    anchors.leftMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 96
                                    height: 26
                                    radius: 6
                                    color: Theme.surface2
                                    border.width: labelField.activeFocus ? 1 : 0
                                    border.color: Theme.accent

                                    TextInput {
                                        id: labelField

                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        verticalAlignment: TextInput.AlignVCenter
                                        clip: true
                                        text: clock.modelData.label
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        onAccepted: {
                                            clocks.changed(ClockData.relabel(clock.index, clock.modelData.zone, text));
                                            keys.forceActiveFocus();
                                        }
                                        Keys.onEscapePressed: keys.forceActiveFocus()
                                        onActiveFocusChanged: {
                                            if (!activeFocus) {
                                                text = Qt.binding(() => clock.modelData.label);
                                            }
                                        }

                                        // No label shows as none, not a
                                        // blank field.
                                        Text {
                                            visible: labelField.text === "" && !labelField.activeFocus
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "none"
                                            color: Theme.fgFaint
                                            font: labelField.font
                                        }
                                    }
                                }

                                Text {
                                    anchors.left: labelBox.right
                                    anchors.leftMargin: 10
                                    anchors.right: clockButtons.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: clock.modelData.zone !== clocks.localZone ? clock.modelData.zone : ClockData.switches.dedupeLocal ? `${clock.modelData.zone} · local, hidden` : `${clock.modelData.zone} · local`
                                    color: Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Row {
                                    id: clockButtons

                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    // In the bar, or only in the popover.
                                    Rectangle {
                                        readonly property bool on: clock.modelData.bar !== false

                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 44
                                        height: 26
                                        radius: 13
                                        color: on ? Theme.accentBg : Theme.surface2

                                        Text {
                                            anchors.centerIn: parent
                                            text: "Bar"
                                            color: parent.on ? Theme.accentFg : Theme.fgDim
                                            font.family: Theme.font
                                            font.pixelSize: 12
                                            font.weight: Font.DemiBold
                                        }

                                        TapHandler {
                                            onTapped: clocks.changed(ClockData.setBar(clock.index, clock.modelData.zone, !parent.on))
                                        }
                                    }

                                    StepButton {
                                        name: "go-up-symbolic"
                                        value: clock.index
                                        next: Math.max(0, clock.index - 1)
                                        onActivated: clocks.changed(ClockData.move(clock.index, clock.modelData.zone, -1))
                                    }

                                    StepButton {
                                        name: "go-down-symbolic"
                                        value: clock.index
                                        next: Math.min(ClockData.listed.length - 1, clock.index + 1)
                                        onActivated: clocks.changed(ClockData.move(clock.index, clock.modelData.zone, 1))
                                    }

                                    StepButton {
                                        name: "edit-delete-symbolic"
                                        value: 0
                                        next: 1
                                        onActivated: clocks.changed(ClockData.remove(clock.index, clock.modelData.zone))
                                    }
                                }
                            }
                        }

                        // A zone to add, typed as its ID: Enter adds it, and
                        // one refused stays to be fixed.
                        Item {
                            width: clocks.width
                            implicitHeight: 32

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                height: 26
                                radius: 6
                                color: Theme.surface2
                                border.width: newZone.activeFocus ? 1 : 0
                                border.color: Theme.accent

                                TextInput {
                                    id: newZone

                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    onAccepted: {
                                        const error = ClockData.add(text.trim());
                                        clocks.changed(error);
                                        if (error === "") {
                                            text = "";
                                            keys.forceActiveFocus();
                                        }
                                    }
                                    Keys.onEscapePressed: {
                                        text = "";
                                        keys.forceActiveFocus();
                                    }

                                    Text {
                                        visible: newZone.text === "" && !newZone.activeFocus
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Add a zone, such as Asia/Kolkata"
                                        color: Theme.fgFaint
                                        font: newZone.font
                                    }
                                }
                            }
                        }

                        // 24-hour time and hiding the local zone's clock,
                        // which a click turns on or off, as Idle's switches.
                        Repeater {
                            model: ClockData.switchRows

                            Item {
                                id: clockSwitch

                                required property var modelData
                                readonly property bool on: ClockData.switches[modelData.key] === true

                                width: clocks.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: clockSwitch.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 56
                                    height: 26
                                    radius: 13
                                    color: clockSwitch.on ? Theme.accentBg : Theme.surface2

                                    Text {
                                        anchors.centerIn: parent
                                        text: clockSwitch.on ? "On" : "Off"
                                        color: clockSwitch.on ? Theme.accentFg : Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                    }

                                    TapHandler {
                                        onTapped: clocks.changed(ClockData.setSwitch(clockSwitch.modelData.key, !clockSwitch.on))
                                    }
                                }
                            }
                        }

                        // A zone that isn't one, say.
                        Text {
                            visible: clocks.refused !== ""
                            x: 10
                            width: clocks.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: clocks.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Keyboard's shortcuts: each binding's keys and what it
                    // does, below the keyboard's settings, listed again as
                    // they show. conf's named ones come first, and a click
                    // on one's keys records new ones (SPEC.md §16).
                    Column {
                        id: keyList

                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""
                        // The preset asked about, when starting from it
                        // would drop keys of your own, or "".
                        property string asking: ""

                        function startFrom(preset) {
                            asking = "";
                            refused = KeysData.startFrom(preset);
                            root.report(refused);
                        }

                        onVisibleChanged: {
                            refused = "";
                            asking = "";
                            if (visible) {
                                KeysData.list();
                                pageFlick.scrolled();
                            } else {
                                KeysData.stop();
                            }
                        }
                        onYChanged: pageFlick.scrolled()
                        visible: root.current.id === "keyboard"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Heading {
                            text: "SHORTCUTS"
                        }

                        Text {
                            visible: text !== ""
                            width: keyList.width
                            leftPadding: 10
                            rightPadding: 10
                            bottomPadding: 4
                            wrapMode: Text.WordWrap
                            text: KeysData.editable ? "Click a shortcut's keys to change them." : Settings.section("keys").about
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 13
                        }

                        // Other tiling window managers' keys, to start from.
                        Item {
                            visible: KeysData.editable
                            width: keyList.width
                            implicitHeight: 32

                            Text {
                                id: startLabel

                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Start from"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.left: startLabel.right
                                anchors.leftMargin: 10
                                height: parent.height
                                spacing: 4

                                Repeater {
                                    model: KeyPresets.PRESET_NAMES

                                    PillButton {
                                        required property string modelData

                                        text: KeyPresets.PRESETS[modelData].label
                                        selected: KeysData.yours.preset === modelData
                                        onActivated: {
                                            if (Object.keys(KeysData.yours.keys).length > 0) {
                                                keyList.asking = modelData;
                                            } else {
                                                keyList.startFrom(modelData);
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Starting from a preset drops your own keys: ask.
                        Item {
                            visible: keyList.asking !== ""
                            width: keyList.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.right: askButtons.left
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: keyList.asking === "" ? "" : `Your own keys go. Start from ${KeyPresets.PRESETS[keyList.asking].label}?`
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                id: askButtons

                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                height: parent.height
                                spacing: 4

                                PillButton {
                                    text: "Start over"
                                    onActivated: keyList.startFrom(keyList.asking)
                                }

                                PillButton {
                                    text: "Cancel"
                                    onActivated: keyList.asking = ""
                                }
                            }
                        }

                        // Takes the keys pressed while one is recording.
                        // Hyprland's other bindings are off then, and Esc
                        // leaves its submap, which ends the recording; Esc
                        // here is for when that didn't start.
                        Item {
                            id: recorder

                            // The shortcut recording: a click on another's
                            // keys while one records moves the card's focus,
                            // so each new one takes it back.
                            readonly property string name: KeysData.recording

                            onNameChanged: {
                                if (name !== "") {
                                    forceActiveFocus();
                                } else if (activeFocus) {
                                    keys.forceActiveFocus();
                                }
                            }
                            width: 0
                            height: 0
                            Keys.onPressed: event => {
                                event.accepted = true;
                                if (event.key === Qt.Key_Escape) {
                                    KeysData.stop();
                                    return;
                                }
                                keyList.refused = KeysData.pressed(event.key, event.modifiers);
                                root.report(keyList.refused);
                            }
                        }

                        Repeater {
                            model: KeysData.editable ? KeysData.rows.named : []

                            Rectangle {
                                id: named

                                required property var modelData
                                readonly property bool recording: KeysData.recording === named.modelData.name

                                width: keyList.width
                                implicitHeight: 28
                                radius: 6
                                color: namedHover.hovered || named.recording ? Theme.surface2 : "transparent"

                                HoverHandler {
                                    id: namedHover
                                }

                                Text {
                                    id: namedKeys

                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 170
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: named.recording ? "Press keys…" : named.modelData.label
                                    color: named.recording ? Theme.accent : named.modelData.keys.length === 0 ? Theme.fgFaint : Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold

                                    TapHandler {
                                        onTapped: {
                                            keyList.refused = "";
                                            if (named.recording) {
                                                KeysData.stop();
                                            } else {
                                                KeysData.record(named.modelData.name);
                                            }
                                        }
                                    }
                                }

                                Text {
                                    anchors.left: namedKeys.right
                                    anchors.leftMargin: 10
                                    anchors.right: namedButtons.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: named.modelData.does
                                    color: Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Row {
                                    id: namedButtons

                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: parent.height
                                    spacing: 4

                                    PillButton {
                                        visible: named.modelData.keys.length > 0 && (namedHover.hovered || named.recording)
                                        text: "Off"
                                        onActivated: {
                                            KeysData.stop();
                                            keyList.refused = KeysData.off(named.modelData.name);
                                            root.report(keyList.refused);
                                        }
                                    }

                                    PillButton {
                                        visible: named.modelData.changed
                                        text: "Reset"
                                        onActivated: {
                                            KeysData.stop();
                                            keyList.refused = KeysData.reset(named.modelData.name);
                                            root.report(keyList.refused);
                                        }
                                    }
                                }
                            }
                        }

                        // Keys another shortcut has: swap them, or not.
                        Item {
                            visible: KeysData.pending !== null
                            width: keyList.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.right: clashButtons.left
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                                text: KeysData.pending === null ? "" : `${Shortcuts.keysId(KeysData.pending.keys)} is ${KeysData.pending.clash.does}. Swap them?`
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                id: clashButtons

                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                height: parent.height
                                spacing: 4

                                PillButton {
                                    text: "Swap"
                                    onActivated: {
                                        keyList.refused = KeysData.swap();
                                        root.report(keyList.refused);
                                    }
                                }

                                PillButton {
                                    text: "Cancel"
                                    onActivated: KeysData.pending = null
                                }
                            }
                        }

                        Repeater {
                            model: KeysData.rows.fixed

                            Item {
                                id: binding

                                required property var modelData

                                width: keyList.width
                                implicitHeight: 26

                                Text {
                                    id: bindingKeys

                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 170
                                    elide: Text.ElideRight
                                    // From the config: never markup.
                                    textFormat: Text.PlainText
                                    text: binding.modelData.submap === "" ? binding.modelData.keys : `${binding.modelData.submap}: ${binding.modelData.keys}`
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }

                                Text {
                                    anchors.left: bindingKeys.right
                                    anchors.leftMargin: 10
                                    anchors.right: parent.right
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: binding.modelData.does === "" ? "no description" : binding.modelData.does
                                    color: binding.modelData.does === "" ? Theme.fgFaint : Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }
                            }
                        }

                        // Why there are none, if they couldn't be listed,
                        // why a change was refused, or why yours aren't in
                        // effect.
                        Repeater {
                            model: [KeysData.error, keyList.refused, KeysData.failure].filter(t => t !== "")

                            Text {
                                required property string modelData

                                x: 10
                                width: keyList.width - 20
                                topPadding: 4
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                                text: modelData
                                color: Theme.danger
                                font.family: Theme.font
                                font.pixelSize: 12
                            }
                        }
                    }

                    // Layouts: how a new workspace starts and each layout's
                    // master width and count, which − and + step, and the
                    // modes, which ‹ and › step through (SPEC.md §6).
                    Column {
                        id: layouts

                        readonly property var effective: LayoutsData.effective
                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""

                        function set(path, value) {
                            refused = LayoutsData.set(path, value);
                            root.report(refused);
                        }

                        onVisibleChanged: refused = ""
                        visible: root.current.id === "layouts"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Repeater {
                            model: Layouts.layoutRows(layouts.effective)

                            Item {
                                id: layoutRow

                                required property var modelData
                                readonly property string kind: modelData.kind
                                // A number row's value, or a lone window's width.
                                readonly property real number: kind === "number" ? Layouts.shownLayout(LayoutsData.layouts, modelData.path) : kind === "single" ? layouts.effective.single[modelData.index].width : 0
                                // A choice row's options, and which is in effect.
                                readonly property var choices: kind === "choice" ? Layouts.layoutChoices(modelData.path) : []
                                readonly property int choiceAt: kind === "choice" ? Math.max(0, choices.findIndex(c => c.value === Layouts.shownLayout(LayoutsData.layouts, modelData.path))) : 0

                                function step(steps) {
                                    if (kind === "single") {
                                        layouts.set("single", Layouts.steppedSingle(layouts.effective.single, modelData.index, steps));
                                    } else {
                                        layouts.set(modelData.path, Layouts.steppedLayout(modelData.path, number, steps));
                                    }
                                }

                                function stepped(steps) {
                                    return Layouts.steppedLayout(kind === "single" ? "single.width" : modelData.path, number, steps);
                                }

                                width: layouts.width
                                implicitHeight: kind === "heading" ? heading.implicitHeight : 32

                                Heading {
                                    id: heading

                                    visible: layoutRow.kind === "heading"
                                    text: layoutRow.kind === "heading" ? layoutRow.modelData.label : ""
                                }

                                Text {
                                    visible: layoutRow.kind !== "heading"
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: layoutRow.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                // A number, or a lone window's width.
                                Row {
                                    visible: layoutRow.kind === "number" || layoutRow.kind === "single"
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "list-remove-symbolic"
                                        value: layoutRow.number
                                        next: layoutRow.kind === "heading" || layoutRow.kind === "choice" ? layoutRow.number : layoutRow.stepped(-1)
                                        onActivated: layoutRow.step(-1)
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 92
                                        horizontalAlignment: Text.AlignHCenter
                                        text: layoutRow.kind === "number" ? Layouts.formatLayout(layoutRow.modelData.path, layoutRow.number) : layoutRow.kind === "single" ? Layouts.formatLayout("single.width", layoutRow.number) : ""
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        font.features: ({ "tnum": 1 })
                                    }

                                    StepButton {
                                        name: "list-add-symbolic"
                                        value: layoutRow.number
                                        next: layoutRow.kind === "heading" || layoutRow.kind === "choice" ? layoutRow.number : layoutRow.stepped(1)
                                        onActivated: layoutRow.step(1)
                                    }
                                }

                                // A mode, or where a new window goes, which ‹
                                // and › step through.
                                Row {
                                    visible: layoutRow.kind === "choice"
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "go-previous-symbolic"
                                        value: layoutRow.choiceAt
                                        next: Math.max(0, layoutRow.choiceAt - 1)
                                        onActivated: layouts.set(layoutRow.modelData.path, layoutRow.choices[next].value)
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 120
                                        horizontalAlignment: Text.AlignHCenter
                                        text: layoutRow.kind === "choice" ? layoutRow.choices[layoutRow.choiceAt].label : ""
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }

                                    StepButton {
                                        name: "go-next-symbolic"
                                        value: layoutRow.choiceAt
                                        next: Math.min(layoutRow.choices.length - 1, layoutRow.choiceAt + 1)
                                        onActivated: layouts.set(layoutRow.modelData.path, layoutRow.choices[next].value)
                                    }
                                }
                            }
                        }

                        // A setting that isn't one, say.
                        Text {
                            visible: layouts.refused !== ""
                            x: 10
                            width: layouts.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: layouts.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Appearance: light or dark now, with a switch until
                    // the next change; the mode, which ‹ and › step
                    // through; the times, which − and + move a quarter hour;
                    // and the location, typed and set with Enter (SPEC.md
                    // §15).
                    Column {
                        id: appearance

                        readonly property var settings: AppearanceData.settings
                        // The time zone's place, which sunrise and sunset
                        // use with no location set (§15).
                        readonly property var place: AppearanceData.place
                        readonly property int modeAt: Math.max(0, Appearance.MODE_CHOICES.findIndex(c => c.mode === settings.mode))
                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""

                        function set(key, value) {
                            refused = AppearanceData.set(key, value);
                            root.report(refused);
                        }

                        onVisibleChanged: refused = ""
                        visible: root.current.id === "appearance"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Item {
                            width: appearance.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: (AppearanceData.dark ? "Dark" : "Light") + (AppearanceData.until === "" ? "" : ` until ${AppearanceData.until}`)
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                                font.features: ({ "tnum": 1 })
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: 92
                                height: 26
                                radius: 13
                                color: Theme.surface2

                                Text {
                                    anchors.centerIn: parent
                                    text: AppearanceData.dark ? "Light now" : "Dark now"
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                }

                                TapHandler {
                                    onTapped: AppearanceData.flip()
                                }
                            }
                        }

                        Item {
                            width: appearance.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Mode"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StepButton {
                                    name: "go-previous-symbolic"
                                    value: appearance.modeAt
                                    next: Appearance.steppedModeAt(appearance.settings, appearance.modeAt, -1, appearance.place)
                                    onActivated: appearance.set("mode", Appearance.MODE_CHOICES[next].mode)
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 140
                                    horizontalAlignment: Text.AlignHCenter
                                    text: Appearance.MODE_CHOICES[appearance.modeAt].label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                StepButton {
                                    name: "go-next-symbolic"
                                    value: appearance.modeAt
                                    next: Appearance.steppedModeAt(appearance.settings, appearance.modeAt, 1, appearance.place)
                                    onActivated: appearance.set("mode", Appearance.MODE_CHOICES[next].mode)
                                }
                            }
                        }

                        // Light from and dark from, by the clock.
                        Repeater {
                            model: appearance.settings.mode === "schedule" ? [{ key: "light", label: "Light from" }, { key: "dark", label: "Dark from" }] : []

                            Item {
                                id: time

                                required property var modelData
                                readonly property string value: appearance.settings[modelData.key]

                                // Past the other time, so the two can cross.
                                function stepped(steps) {
                                    return Appearance.steppedTimePast(value, steps, appearance.settings[modelData.key === "light" ? "dark" : "light"]);
                                }

                                width: appearance.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: time.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "list-remove-symbolic"
                                        value: 0
                                        next: time.stepped(-1) === time.value ? 0 : 1
                                        onActivated: appearance.set(time.modelData.key, time.stepped(-1))
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 92
                                        horizontalAlignment: Text.AlignHCenter
                                        text: time.value
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        font.features: ({ "tnum": 1 })
                                    }

                                    StepButton {
                                        name: "list-add-symbolic"
                                        value: 0
                                        next: time.stepped(1) === time.value ? 0 : 1
                                        onActivated: appearance.set(time.modelData.key, time.stepped(1))
                                    }
                                }
                            }
                        }

                        // Where sunrise and sunset are for, and Change,
                        // which opens the city picker under it.
                        Item {
                            id: location

                            readonly property var row: Appearance.locationRow(appearance.settings, appearance.place)

                            visible: row.shown
                            width: appearance.width
                            implicitHeight: 32

                            Text {
                                id: locationLabel

                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: location.row.label
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Text {
                                anchors.left: locationLabel.right
                                anchors.leftMargin: 12
                                anchors.right: change.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                                text: location.row.value
                                color: Theme.fgDim
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Rectangle {
                                id: change

                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: 76
                                height: 26
                                radius: 13
                                color: Theme.surface2
                                Accessible.name: "Change location"

                                Text {
                                    anchors.centerIn: parent
                                    text: "Change"
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                }

                                TapHandler {
                                    onTapped: cityPicker.show(change)
                                }
                            }
                        }

                        // The inactive dim's strength (§6.2), which − and +
                        // step a point at a time.
                        Item {
                            width: appearance.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Dim inactive windows"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StepButton {
                                    name: "list-remove-symbolic"
                                    value: AppearanceData.dimStrength
                                    next: Appearance.steppedDim(AppearanceData.dimStrength, -1)
                                    onActivated: appearance.set("dimStrength", next)
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 92
                                    horizontalAlignment: Text.AlignHCenter
                                    text: Appearance.formatDim(AppearanceData.dimStrength)
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    font.features: ({ "tnum": 1 })
                                }

                                StepButton {
                                    name: "list-add-symbolic"
                                    value: AppearanceData.dimStrength
                                    next: Appearance.steppedDim(AppearanceData.dimStrength, 1)
                                    onActivated: appearance.set("dimStrength", next)
                                }
                            }
                        }

                        // The wallpapers, light and dark (§15): a file's
                        // path, chosen in the desktop's file chooser, or a
                        // color, chosen from the swatch's; either can be
                        // typed and set with Enter as the location is.
                        // Empty is the default, conf's images.
                        Repeater {
                            model: [{ key: "lightWallpaper", label: "Light wallpaper" }, { key: "darkWallpaper", label: "Dark wallpaper" }]

                            Column {
                                id: wallpaper

                                required property var modelData
                                readonly property bool dark: modelData.key === "darkWallpaper"
                                // The pictures to preview, in order, and
                                // how many couldn't load.
                                readonly property var candidates: Appearance.previewCandidates(appearance.settings, dark, AppearanceData.dark, WallpaperData.path, Quickshell.env("HOME") ?? "", Quickshell.env("TIDE_WALLPAPER") ?? "")
                                property int tried: 0
                                // Only while the page shows: the preview
                                // holds the picture at its own size.
                                readonly property string previewPath: root.visible && appearance.visible ? (candidates[tried] ?? "") : ""

                                function shown() {
                                    return appearance.settings[modelData.key] ?? "";
                                }

                                onCandidatesChanged: tried = 0
                                width: appearance.width

                                Item {
                                    width: wallpaper.width
                                    implicitHeight: 32

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: wallpaper.modelData.label
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }

                                    // Opens the wallpaper colors: the color set,
                                    // or a neutral icon for an image or the
                                    // default.
                                    Rectangle {
                                        id: swatch

                                        readonly property string shows: Appearance.wallpaperColor(wallpaper.shown())

                                        anchors.right: gridButton.left
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 26
                                        height: 26
                                        radius: 7
                                        color: swatchHover.hovered || wallpaperColors.key === wallpaper.modelData.key ? Theme.surface2 : "transparent"

                                        Rectangle {
                                            anchors.centerIn: parent
                                            visible: swatch.shows !== ""
                                            width: 16
                                            height: 16
                                            radius: 4
                                            color: swatch.shows === "" ? "transparent" : swatch.shows
                                            border.color: Theme.edge
                                        }

                                        SymbolicIcon {
                                            anchors.centerIn: parent
                                            visible: swatch.shows === ""
                                            name: "color-select-symbolic"
                                        }

                                        HoverHandler {
                                            id: swatchHover
                                        }

                                        TapHandler {
                                            onTapped: wallpaperColors.show(wallpaper.modelData.key, wallpaper.modelData.label, swatch)
                                        }
                                    }

                                    // Opens the wallpaper grid, the
                                    // installed pictures and yours.
                                    Rectangle {
                                        id: gridButton

                                        anchors.right: chooseButton.left
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 26
                                        height: 26
                                        radius: 7
                                        color: gridHover.hovered || wallpaperGrid.key === wallpaper.modelData.key ? Theme.surface2 : "transparent"
                                        Accessible.name: "Wallpapers"

                                        SymbolicIcon {
                                            anchors.centerIn: parent
                                            name: "view-grid-symbolic"
                                        }

                                        HoverHandler {
                                            id: gridHover
                                        }

                                        TapHandler {
                                            onTapped: {
                                                wallpaperColors.close();
                                                wallpaperGrid.show(wallpaper.modelData.key, wallpaper.modelData.label);
                                            }
                                        }
                                    }

                                    // Opens the file chooser, for an image.
                                    Rectangle {
                                        id: chooseButton

                                        anchors.right: wallpaperField.left
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 26
                                        height: 26
                                        radius: 7
                                        color: chooseHover.hovered ? Theme.surface2 : "transparent"

                                        SymbolicIcon {
                                            anchors.centerIn: parent
                                            name: "document-open-symbolic"
                                        }

                                        HoverHandler {
                                            id: chooseHover
                                        }

                                        TapHandler {
                                            onTapped: root.pickWallpaper(wallpaper.modelData.key, wallpaper.modelData.label)
                                        }
                                    }

                                    Rectangle {
                                        id: wallpaperField

                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 220
                                        height: 26
                                        radius: 6
                                        color: Theme.surface2
                                        border.width: file.activeFocus ? 1 : 0
                                        border.color: Theme.accent

                                        TextInput {
                                            id: file

                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter
                                            clip: true
                                            text: wallpaper.shown()
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 13
                                            onAccepted: {
                                                appearance.set(wallpaper.modelData.key, text.trim());
                                                keys.forceActiveFocus();
                                            }
                                            Keys.onEscapePressed: keys.forceActiveFocus()
                                            onActiveFocusChanged: {
                                                if (!activeFocus) {
                                                    text = Qt.binding(() => wallpaper.shown());
                                                }
                                            }

                                            Text {
                                                visible: file.text === "" && !file.activeFocus
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: "default"
                                                color: Theme.fgFaint
                                                font: file.font
                                            }
                                        }
                                    }
                                }

                                // How this mode's picture is placed (§15),
                                // which ‹ and › step through. A color has
                                // nothing to place.
                                Item {
                                    id: positionRow

                                    readonly property string key: wallpaper.dark ? "darkWallpaperPosition" : "lightWallpaperPosition"
                                    readonly property int at: Appearance.positionAt(appearance.settings, wallpaper.dark)

                                    visible: Appearance.wallpaperColor(wallpaper.shown()) === ""
                                    width: wallpaper.width
                                    implicitHeight: 32

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: `${wallpaper.modelData.label} position`
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }

                                    Row {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 4

                                        StepButton {
                                            name: "go-previous-symbolic"
                                            value: positionRow.at
                                            next: Appearance.steppedPositionAt(positionRow.at, -1)
                                            onActivated: appearance.set(positionRow.key, Appearance.POSITION_CHOICES[next].position)
                                        }

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 140
                                            horizontalAlignment: Text.AlignHCenter
                                            text: Appearance.POSITION_CHOICES[positionRow.at].label
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 13
                                        }

                                        StepButton {
                                            name: "go-next-symbolic"
                                            value: positionRow.at
                                            next: Appearance.steppedPositionAt(positionRow.at, 1)
                                            onActivated: appearance.set(positionRow.key, Appearance.POSITION_CHOICES[next].position)
                                        }
                                    }
                                }

                                // What each monitor shows of the picture
                                // (§16): one preview per size of monitor.
                                Flow {
                                    x: 10
                                    width: wallpaper.width - 16
                                    visible: wallpaper.previewPath !== ""
                                    spacing: 12
                                    bottomPadding: 6

                                    Repeater {
                                        model: wallpaper.previewPath === "" ? [] : Appearance.previewScreens(Quickshell.screens)

                                        WallpaperPreview {
                                            required property var modelData

                                            path: wallpaper.previewPath
                                            screenName: modelData.name
                                            screenWidth: modelData.width
                                            screenHeight: modelData.height
                                            position: Appearance.wallpaperPosition(appearance.settings, wallpaper.dark)
                                            onFailed: failedPath => {
                                                if (failedPath === wallpaper.previewPath) {
                                                    wallpaper.tried++;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // A time or a location that isn't one, say.
                        Text {
                            visible: appearance.refused !== ""
                            x: 10
                            width: appearance.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: appearance.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Bar: where it runs, top or bottom, and which status
                    // icons it shows, in what order (SPEC.md §16).
                    Column {
                        id: barPage

                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""
                        // The Icons list, made whole (lib/baricons.mjs).
                        readonly property var icons: BarIcons.iconList(AppearanceData.settings.barIcons)

                        function set(key, value) {
                            refused = AppearanceData.set(key, value);
                            root.report(refused);
                        }

                        onVisibleChanged: refused = ""
                        visible: root.current.id === "bar"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        // Which edge the bar runs along (§7.1), which ‹
                        // and › step between. It moves at once. It's
                        // appearance.json's barPosition (§15).
                        Item {
                            id: barRow

                            readonly property int at: BarSide.barChoiceAt(AppearanceData.settings)

                            width: barPage.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Position"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StepButton {
                                    name: "go-previous-symbolic"
                                    value: barRow.at
                                    next: BarSide.steppedBarChoice(barRow.at, -1)
                                    onActivated: barPage.set("barPosition", Appearance.BAR_CHOICES[next].position)
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 92
                                    horizontalAlignment: Text.AlignHCenter
                                    text: Appearance.BAR_CHOICES[barRow.at].label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                StepButton {
                                    name: "go-next-symbolic"
                                    value: barRow.at
                                    next: BarSide.steppedBarChoice(barRow.at, 1)
                                    onActivated: barPage.set("barPosition", Appearance.BAR_CHOICES[next].position)
                                }
                            }
                        }

                        Heading {
                            text: "ICONS"
                        }

                        // Each status icon in the bar's order (§7.4): the
                        // arrows move it, and a click on its switch shows
                        // or hides it. The bar follows at once. It's
                        // appearance.json's barIcons (§15).
                        Repeater {
                            model: barPage.icons

                            Item {
                                id: barIcon

                                required property var modelData
                                required property int index

                                width: barPage.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: barIcon.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "go-up-symbolic"
                                        value: barIcon.index
                                        next: barIcon.index > 0 ? barIcon.index - 1 : barIcon.index
                                        onActivated: barPage.set("barIcons", BarIcons.moved(barPage.icons, barIcon.index, -1))
                                    }

                                    StepButton {
                                        name: "go-down-symbolic"
                                        value: barIcon.index
                                        next: barIcon.index < barPage.icons.length - 1 ? barIcon.index + 1 : barIcon.index
                                        onActivated: barPage.set("barIcons", BarIcons.moved(barPage.icons, barIcon.index, 1))
                                    }

                                    // On or off, in the accent color while
                                    // on, as the Idle page's switches.
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 56
                                        height: 26
                                        radius: 13
                                        color: barIcon.modelData.shown ? Theme.accentBg : Theme.surface2

                                        Text {
                                            anchors.centerIn: parent
                                            text: barIcon.modelData.shown ? "On" : "Off"
                                            color: barIcon.modelData.shown ? Theme.accentFg : Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 12
                                            font.weight: Font.DemiBold
                                        }

                                        TapHandler {
                                            onTapped: barPage.set("barIcons", BarIcons.switched(barPage.icons, barIcon.index, !barIcon.modelData.shown))
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: barPage.refused !== ""
                            x: 10
                            width: barPage.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: barPage.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Displays: each monitor's scale, which − and + step,
                    // and where it goes, which ‹ and › step through; Reset
                    // clears what this machine sets (SPEC.md §16).
                    Column {
                        id: displays

                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""

                        function set(description, key, value) {
                            refused = OutputsData.set(description, key, value);
                            root.report(refused);
                        }

                        onVisibleChanged: {
                            refused = "";
                            if (visible) {
                                OutputsData.listMonitors();
                            }
                        }
                        visible: root.current.id === "displays"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Repeater {
                            model: Outputs.shownMonitors(OutputsData.outputs, OutputsData.connected)

                            Column {
                                id: monitor

                                required property var modelData
                                readonly property var own: Outputs.monitorSettings(OutputsData.outputs, modelData.description)
                                readonly property real scale: own.scale !== undefined ? own.scale : (modelData.scale ?? 1)
                                readonly property int placeAt: Math.max(0, Outputs.POSITIONS.findIndex(p => p.position === (own.position ?? "auto")))

                                width: displays.width
                                spacing: 2

                                Item {
                                    width: monitor.width
                                    implicitHeight: monitorName.implicitHeight

                                    Heading {
                                        id: monitorName

                                        width: parent.width - (resetMonitor.visible ? resetMonitor.width + 12 : 0)
                                        elide: Text.ElideRight
                                        // From the monitor's EDID: never markup.
                                        textFormat: Text.PlainText
                                        text: monitor.modelData.name === "" ? `${monitor.modelData.description} (not connected)` : `${monitor.modelData.description} (${monitor.modelData.name})`
                                    }

                                    Rectangle {
                                        id: resetMonitor

                                        visible: Object.keys(Outputs.monitorSettings(OutputsData.localSettings, monitor.modelData.description)).length > 0
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.bottom: parent.bottom
                                        width: 56
                                        height: 22
                                        radius: 11
                                        color: Theme.surface2

                                        Text {
                                            anchors.centerIn: parent
                                            text: "Reset"
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 12
                                            font.weight: Font.DemiBold
                                        }

                                        TapHandler {
                                            onTapped: {
                                                displays.refused = OutputsData.reset(monitor.modelData.description);
                                                root.report(displays.refused);
                                            }
                                        }
                                    }
                                }

                                Item {
                                    width: monitor.width
                                    implicitHeight: 32

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Scale"
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }

                                    Row {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 4

                                        StepButton {
                                            name: "list-remove-symbolic"
                                            value: monitor.scale
                                            next: Outputs.steppedScale(monitor.scale, -1)
                                            onActivated: displays.set(monitor.modelData.description, "scale", next)
                                        }

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 120
                                            horizontalAlignment: Text.AlignHCenter
                                            text: Outputs.formatScale(monitor.own.scale, monitor.modelData.scale)
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 13
                                            font.features: ({ "tnum": 1 })
                                        }

                                        StepButton {
                                            name: "list-add-symbolic"
                                            value: monitor.scale
                                            next: Outputs.steppedScale(monitor.scale, 1)
                                            onActivated: displays.set(monitor.modelData.description, "scale", next)
                                        }
                                    }
                                }

                                Item {
                                    width: monitor.width
                                    implicitHeight: 32

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Place"
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }

                                    Row {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 4

                                        StepButton {
                                            name: "go-previous-symbolic"
                                            value: monitor.placeAt
                                            next: Math.max(0, monitor.placeAt - 1)
                                            onActivated: displays.set(monitor.modelData.description, "position", Outputs.POSITIONS[next].position)
                                        }

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 120
                                            horizontalAlignment: Text.AlignHCenter
                                            text: Outputs.POSITIONS[monitor.placeAt].label
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 13
                                        }

                                        StepButton {
                                            name: "go-next-symbolic"
                                            value: monitor.placeAt
                                            next: Math.min(Outputs.POSITIONS.length - 1, monitor.placeAt + 1)
                                            onActivated: displays.set(monitor.modelData.description, "position", Outputs.POSITIONS[next].position)
                                        }
                                    }
                                }
                            }
                        }

                        // A setting that isn't one, say.
                        Text {
                            visible: displays.refused !== ""
                            x: 10
                            width: displays.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: displays.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Start at login: each command, which the arrows move
                    // and the bin takes out, and one typed at the foot is
                    // added at the end (SPEC.md §16).
                    Column {
                        id: startup

                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""

                        function changed(error) {
                            refused = error;
                            root.report(error);
                        }

                        onVisibleChanged: refused = ""
                        visible: root.current.id === "startup"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Repeater {
                            model: StartupData.listed

                            Item {
                                id: entry

                                required property var modelData
                                required property int index

                                width: startup.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: entryButtons.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: entry.modelData
                                    color: Theme.fg
                                    font.family: Theme.monoFont
                                    font.pixelSize: 13
                                }

                                Row {
                                    id: entryButtons

                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "go-up-symbolic"
                                        value: entry.index
                                        next: Math.max(0, entry.index - 1)
                                        onActivated: startup.changed(StartupData.move(entry.index, entry.modelData, -1))
                                    }

                                    StepButton {
                                        name: "go-down-symbolic"
                                        value: entry.index
                                        next: Math.min(StartupData.listed.length - 1, entry.index + 1)
                                        onActivated: startup.changed(StartupData.move(entry.index, entry.modelData, 1))
                                    }

                                    StepButton {
                                        name: "edit-delete-symbolic"
                                        value: 0
                                        next: 1
                                        onActivated: startup.changed(StartupData.remove(entry.index, entry.modelData))
                                    }
                                }
                            }
                        }

                        // None yet, said, so the page isn't only a field.
                        Text {
                            visible: StartupData.listed.length === 0
                            x: 10
                            width: startup.width - 20
                            topPadding: 4
                            bottomPadding: 4
                            text: "Nothing starts at login."
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 13
                        }

                        // A command to add: Enter adds it, and one refused
                        // stays to be fixed.
                        Item {
                            width: startup.width
                            implicitHeight: 32

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                height: 26
                                radius: 6
                                color: Theme.surface2
                                border.width: newCommand.activeFocus ? 1 : 0
                                border.color: Theme.accent

                                TextInput {
                                    id: newCommand

                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    color: Theme.fg
                                    font.family: Theme.monoFont
                                    font.pixelSize: 13
                                    onAccepted: {
                                        const error = StartupData.add(text);
                                        startup.changed(error);
                                        if (error === "") {
                                            text = "";
                                            keys.forceActiveFocus();
                                        }
                                    }
                                    Keys.onEscapePressed: {
                                        text = "";
                                        keys.forceActiveFocus();
                                    }

                                    Text {
                                        visible: newCommand.text === "" && !newCommand.activeFocus
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Add a command, such as google-calendar"
                                        color: Theme.fgFaint
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }
                                }
                            }
                        }

                        // A command refused, or a file that can't be
                        // changed, say.
                        Text {
                            visible: startup.refused !== ""
                            x: 10
                            width: startup.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: startup.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Notifications: Do not disturb now and on a schedule,
                    // whether critical alerts break through, and the muted
                    // apps and sites (SPEC.md §9, §16).
                    Column {
                        id: notifications

                        readonly property var settings: NotificationSettingsData.settings
                        // Why the last change made here was refused, until
                        // the next one or another page.
                        property string refused: ""

                        function changed(error) {
                            refused = error;
                            root.report(error);
                        }

                        function set(key, value) {
                            changed(NotificationSettingsData.set(key, value));
                        }

                        onVisibleChanged: refused = ""
                        visible: root.current.id === "notifications"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        // Each a switch a click turns on or off, as Idle's.
                        Repeater {
                            model: [
                                { key: "now", label: "Do not disturb" },
                                { key: "dndScheduled", label: "On a schedule" },
                                { key: "criticalsBreakThrough", label: "Critical alerts break through" },
                            ]

                            Item {
                                id: notifySwitch

                                required property var modelData
                                readonly property bool on: modelData.key === "now" ? NotificationData.dnd : notifications.settings[modelData.key] === true

                                width: notifications.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: notifySwitch.modelData.key === "dndScheduled" ? `${notifySwitch.modelData.label}: ${Dnd.scheduleSummary(notifications.settings)}` : notifySwitch.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 56
                                    height: 26
                                    radius: 13
                                    color: notifySwitch.on ? Theme.accentBg : Theme.surface2

                                    Text {
                                        anchors.centerIn: parent
                                        text: notifySwitch.on ? "On" : "Off"
                                        color: notifySwitch.on ? Theme.accentFg : Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                    }

                                    TapHandler {
                                        onTapped: {
                                            if (notifySwitch.modelData.key === "now") {
                                                NotificationData.setDnd(!notifySwitch.on);
                                            } else {
                                                notifications.set(notifySwitch.modelData.key, !notifySwitch.on);
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // From and to, a quarter hour a step, past each
                        // other, as Appearance's times.
                        Repeater {
                            model: notifications.settings.dndScheduled ? [{ key: "dndFrom", label: "From", other: "dndTo" }, { key: "dndTo", label: "To", other: "dndFrom" }] : []

                            Item {
                                id: dndTime

                                required property var modelData
                                readonly property string value: notifications.settings[modelData.key]

                                function stepped(steps) {
                                    return Dnd.steppedDndTime(value, steps, notifications.settings[modelData.other]);
                                }

                                width: notifications.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: dndTime.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "list-remove-symbolic"
                                        value: 0
                                        next: dndTime.stepped(-1) === dndTime.value ? 0 : 1
                                        onActivated: notifications.set(dndTime.modelData.key, dndTime.stepped(-1))
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 92
                                        horizontalAlignment: Text.AlignHCenter
                                        text: dndTime.value
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        font.features: ({ "tnum": 1 })
                                    }

                                    StepButton {
                                        name: "list-add-symbolic"
                                        value: 0
                                        next: dndTime.stepped(1) === dndTime.value ? 0 : 1
                                        onActivated: notifications.set(dndTime.modelData.key, dndTime.stepped(1))
                                    }
                                }
                            }
                        }

                        // The days a window starts on, each turned on or off
                        // with a click.
                        Item {
                            visible: notifications.settings.dndScheduled
                            width: notifications.width
                            implicitHeight: visible ? 32 : 0

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Days"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                Repeater {
                                    model: Dnd.DAYS

                                    Rectangle {
                                        id: day

                                        required property string modelData
                                        required property int index
                                        readonly property bool on: notifications.settings.dndDays.includes(modelData)

                                        width: 26
                                        height: 26
                                        radius: 13
                                        color: day.on ? Theme.accentBg : Theme.surface2

                                        Text {
                                            anchors.centerIn: parent
                                            text: Dnd.DAY_LABELS[day.index]
                                            color: day.on ? Theme.accentFg : Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 12
                                            font.weight: Font.DemiBold
                                        }

                                        TapHandler {
                                            onTapped: notifications.changed(NotificationSettingsData.toggleDay(day.modelData))
                                        }
                                    }
                                }
                            }
                        }

                        Heading {
                            text: "MUTED"
                        }

                        Repeater {
                            model: WorkspacesData.muted

                            Item {
                                id: mutedEntry

                                required property var modelData
                                required property int index

                                width: notifications.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: unmute.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: mutedEntry.modelData
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                StepButton {
                                    id: unmute

                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    name: "edit-delete-symbolic"
                                    value: 0
                                    next: 1
                                    onActivated: notifications.changed(WorkspacesData.removeMuted(mutedEntry.index, mutedEntry.modelData))
                                }
                            }
                        }

                        // An entry to mute: Enter adds it, and one refused
                        // stays to be fixed.
                        Item {
                            width: notifications.width
                            implicitHeight: 32

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                height: 26
                                radius: 6
                                color: Theme.surface2
                                border.width: newMuted.activeFocus ? 1 : 0
                                border.color: Theme.accent

                                TextInput {
                                    id: newMuted

                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    onAccepted: {
                                        const error = WorkspacesData.addMuted(text);
                                        notifications.changed(error);
                                        if (error === "") {
                                            text = "";
                                            keys.forceActiveFocus();
                                        }
                                    }
                                    Keys.onEscapePressed: {
                                        text = "";
                                        keys.forceActiveFocus();
                                    }

                                    Text {
                                        visible: newMuted.text === "" && !newMuted.activeFocus
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Mute an app ID, such as org.gnome.Nautilus, or site:chat.google.com"
                                        color: Theme.fgFaint
                                        font: newMuted.font
                                    }
                                }
                            }
                        }

                        // A change refused, say.
                        Text {
                            visible: notifications.refused !== ""
                            x: 10
                            width: notifications.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: notifications.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Clipboard: whether the history keeps new copies, how
                    // many, and Clear history (SPEC.md §8.4, §16).
                    Column {
                        id: clipboard

                        readonly property var settings: ClipboardSettingsData.settings
                        property string refused: ""

                        function changed(error) {
                            refused = error;
                            root.report(error);
                        }

                        onVisibleChanged: {
                            refused = "";
                            if (ClipboardSettingsData.clearing !== "clearing") {
                                ClipboardSettingsData.clearing = "";
                            }
                        }
                        visible: root.current.id === "clipboard"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Item {
                            width: clipboard.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: `History: ${Clip.historySummary(clipboard.settings)}`
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: 56
                                height: 26
                                radius: 13
                                color: clipboard.settings.history ? Theme.accentBg : Theme.surface2

                                Text {
                                    anchors.centerIn: parent
                                    text: clipboard.settings.history ? "On" : "Off"
                                    color: clipboard.settings.history ? Theme.accentFg : Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                }

                                TapHandler {
                                    onTapped: clipboard.changed(ClipboardSettingsData.set("history", !clipboard.settings.history))
                                }
                            }
                        }

                        // How many to keep, a mark a step.
                        Item {
                            visible: clipboard.settings.history
                            width: clipboard.width
                            implicitHeight: visible ? 32 : 0

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Copies to keep"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StepButton {
                                    name: "list-remove-symbolic"
                                    value: clipboard.settings.maxItems
                                    next: Clip.steppedMax(clipboard.settings.maxItems, -1)
                                    onActivated: clipboard.changed(ClipboardSettingsData.set("maxItems", next))
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 92
                                    horizontalAlignment: Text.AlignHCenter
                                    text: String(clipboard.settings.maxItems)
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    font.features: ({ "tnum": 1 })
                                }

                                StepButton {
                                    name: "list-add-symbolic"
                                    value: clipboard.settings.maxItems
                                    next: Clip.steppedMax(clipboard.settings.maxItems, 1)
                                    onActivated: clipboard.changed(ClipboardSettingsData.set("maxItems", next))
                                }
                            }
                        }

                        Item {
                            visible: clipboard.settings.history
                            width: clipboard.width
                            implicitHeight: visible ? 32 : 0

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Days to keep"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StepButton {
                                    name: "list-remove-symbolic"
                                    value: clipboard.settings.maxAgeDays
                                    next: Clip.steppedAge(clipboard.settings.maxAgeDays, -1)
                                    onActivated: clipboard.changed(ClipboardSettingsData.set("maxAgeDays", next))
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 92
                                    horizontalAlignment: Text.AlignHCenter
                                    text: Clip.ageText(clipboard.settings.maxAgeDays)
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                    font.features: ({ "tnum": 1 })
                                }

                                StepButton {
                                    name: "list-add-symbolic"
                                    value: clipboard.settings.maxAgeDays
                                    next: Clip.steppedAge(clipboard.settings.maxAgeDays, 1)
                                    onActivated: clipboard.changed(ClipboardSettingsData.set("maxAgeDays", next))
                                }
                            }
                        }

                        MenuRow {
                            width: clipboard.width
                            icon: "edit-clear-all-symbolic"
                            label: "Clear history"
                            enabled: ClipboardSettingsData.clearing !== "clearing"
                            onClicked: ClipboardSettingsData.clear()
                        }

                        // How Clear history went, or a change refused.
                        Text {
                            readonly property string said: ClipboardSettingsData.clearing === "clearing" ? "Clearing…" : ClipboardSettingsData.clearing === "cleared" ? "The history is empty." : ClipboardSettingsData.clearing

                            visible: text !== ""
                            x: 10
                            width: clipboard.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: clipboard.refused !== "" ? clipboard.refused : said
                            color: clipboard.refused !== "" || !["", "clearing", "cleared"].includes(ClipboardSettingsData.clearing) ? Theme.danger : Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Power: the battery, the power profile when
                    // power-profiles-daemon is there, and what closing the
                    // lid does (SPEC.md §16).
                    Column {
                        id: power

                        readonly property var battery: UPower.displayDevice
                        readonly property int lidAt: Power.LID_CHOICES.findIndex(c => c.value === PowerData.settings.lidClose)
                        property string refused: ""

                        function changed(error) {
                            refused = error;
                            root.report(error);
                        }

                        onVisibleChanged: {
                            refused = "";
                            if (visible) {
                                PowerData.listProfiles();
                            }
                        }
                        visible: root.current.id === "power"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Text {
                            readonly property var view: Status.batteryView({
                                present: power.battery?.isPresent ?? false,
                                percentage: power.battery?.percentage,
                                state: power.battery?.state,
                            })

                            x: 10
                            width: power.width - 20
                            text: view.visible ? `Battery ${view.text} · ${Status.batteryStatus({ state: power.battery?.state, timeToEmpty: power.battery?.timeToEmpty, timeToFull: power.battery?.timeToFull })}` : "No battery"
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 13
                            font.features: ({ "tnum": 1 })
                        }

                        Heading {
                            text: "POWER PROFILE"
                        }

                        Repeater {
                            model: PowerData.profilesDaemon === true ? Status.profileChoices(PowerProfiles.hasPerformanceProfile) : []

                            MenuRow {
                                required property var modelData

                                width: power.width
                                icon: modelData.icon
                                label: modelData.label
                                selected: PowerProfiles.profile === modelData.profile
                                onClicked: PowerProfiles.profile = modelData.profile
                            }
                        }

                        Text {
                            visible: PowerData.profilesDaemon !== true
                            x: 10
                            width: power.width - 20
                            wrapMode: Text.Wrap
                            text: PowerData.profilesDaemon === false ? "power-profiles-daemon isn't installed or running, so there are no power profiles to choose." : "Looking for power-profiles-daemon…"
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 13
                        }

                        Heading {
                            text: "LID"
                        }

                        // Closing the lid with no other monitor: ‹ and ›
                        // step through Suspend, Lock and Do nothing.
                        Item {
                            width: power.width
                            implicitHeight: 32

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Closing the lid"
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 13
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                StepButton {
                                    name: "go-previous-symbolic"
                                    value: power.lidAt
                                    next: Math.max(0, power.lidAt - 1)
                                    onActivated: power.changed(PowerData.set("lidClose", Power.steppedLid(PowerData.settings.lidClose, -1)))
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 92
                                    horizontalAlignment: Text.AlignHCenter
                                    text: Power.lidLabel(PowerData.settings.lidClose)
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                StepButton {
                                    name: "go-next-symbolic"
                                    value: power.lidAt
                                    next: Math.min(Power.LID_CHOICES.length - 1, power.lidAt + 1)
                                    onActivated: power.changed(PowerData.set("lidClose", Power.steppedLid(PowerData.settings.lidClose, 1)))
                                }
                            }
                        }

                        Text {
                            visible: power.refused !== "" || PowerData.applyFailure !== ""
                            x: 10
                            width: power.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: power.refused !== "" ? power.refused : PowerData.applyFailure
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Workspaces: the standing workspaces, home's apps and
                    // the name patterns, each a list whose entries the bin
                    // takes out and, where order counts, the arrows move;
                    // one typed at the foot is added. Then each standing
                    // workspace's own settings: whether its new windows ask
                    // for a workspace, and its pinned apps, a list as home's
                    // apps are (SPEC.md §6.5, §16).
                    Column {
                        id: workspacesPage

                        property string refused: ""

                        function changed(error) {
                            refused = error;
                            root.report(error);
                        }

                        onVisibleChanged: refused = ""
                        visible: root.current.id === "workspaces"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Repeater {
                            model: WsPage.LISTS

                            Column {
                                id: wsList

                                required property var modelData
                                readonly property var items: WorkspacesData.settings[modelData.key] ?? []

                                width: workspacesPage.width
                                spacing: 2

                                Heading {
                                    text: wsList.modelData.heading
                                }

                                Repeater {
                                    model: wsList.items

                                    Item {
                                        id: wsItem

                                        required property var modelData
                                        required property int index

                                        width: wsList.width
                                        implicitHeight: 32

                                        Text {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 10
                                            anchors.right: wsButtons.left
                                            anchors.rightMargin: 6
                                            anchors.verticalCenter: parent.verticalCenter
                                            elide: Text.ElideRight
                                            textFormat: Text.PlainText
                                            readonly property string note: WsPage.itemNote(wsList.modelData.key, wsItem.index)
                                            text: note === "" ? wsItem.modelData : `${wsItem.modelData} · ${note}`
                                            color: Theme.fg
                                            font.family: wsList.modelData.key === "namePatterns" ? Theme.monoFont : Theme.font
                                            font.pixelSize: 13
                                        }

                                        Row {
                                            id: wsButtons

                                            anchors.right: parent.right
                                            anchors.rightMargin: 6
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 4

                                            StepButton {
                                                visible: wsList.modelData.ordered
                                                name: "go-up-symbolic"
                                                value: wsItem.index
                                                next: Math.max(0, wsItem.index - 1)
                                                onActivated: workspacesPage.changed(WorkspacesData.moveItem(wsList.modelData.key, wsItem.index, wsItem.modelData, -1))
                                            }

                                            StepButton {
                                                visible: wsList.modelData.ordered
                                                name: "go-down-symbolic"
                                                value: wsItem.index
                                                next: Math.min(wsList.items.length - 1, wsItem.index + 1)
                                                onActivated: workspacesPage.changed(WorkspacesData.moveItem(wsList.modelData.key, wsItem.index, wsItem.modelData, 1))
                                            }

                                            StepButton {
                                                name: "edit-delete-symbolic"
                                                value: 0
                                                next: 1
                                                onActivated: workspacesPage.changed(WorkspacesData.removeItem(wsList.modelData.key, wsItem.index, wsItem.modelData))
                                            }
                                        }
                                    }
                                }

                                Item {
                                    width: wsList.width
                                    implicitHeight: 32

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 6
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: 26
                                        radius: 6
                                        color: Theme.surface2
                                        border.width: newItem.activeFocus ? 1 : 0
                                        border.color: Theme.accent

                                        TextInput {
                                            id: newItem

                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter
                                            clip: true
                                            color: Theme.fg
                                            font.family: wsList.modelData.key === "namePatterns" ? Theme.monoFont : Theme.font
                                            font.pixelSize: 13
                                            onAccepted: {
                                                const error = WorkspacesData.addItem(wsList.modelData.key, text);
                                                workspacesPage.changed(error);
                                                if (error === "") {
                                                    text = "";
                                                    keys.forceActiveFocus();
                                                }
                                            }
                                            Keys.onEscapePressed: {
                                                text = "";
                                                keys.forceActiveFocus();
                                            }

                                            Text {
                                                visible: newItem.text === "" && !newItem.activeFocus
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: wsList.modelData.hint
                                                color: Theme.fgFaint
                                                font.family: Theme.font
                                                font.pixelSize: 13
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: WorkspacesData.standing

                            Column {
                                id: wsOwn

                                required property var modelData
                                required property int index
                                readonly property var setting: Names.workspaceSetting(WorkspacesData.settings, modelData)

                                width: workspacesPage.width
                                spacing: 2

                                Heading {
                                    text: WsPage.workspaceHeading(wsOwn.modelData, wsOwn.index).toUpperCase()
                                }

                                Item {
                                    width: wsOwn.width
                                    implicitHeight: 32

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: WsPage.ASK_LABEL
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }

                                    Rectangle {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 56
                                        height: 26
                                        radius: 13
                                        color: wsOwn.setting.askForName ? Theme.accentBg : Theme.surface2

                                        Text {
                                            anchors.centerIn: parent
                                            text: wsOwn.setting.askForName ? "On" : "Off"
                                            color: wsOwn.setting.askForName ? Theme.accentFg : Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 12
                                            font.weight: Font.DemiBold
                                        }

                                        TapHandler {
                                            onTapped: workspacesPage.changed(WorkspacesData.setAskForName(wsOwn.modelData, !wsOwn.setting.askForName))
                                        }
                                    }
                                }

                                Text {
                                    leftPadding: 10
                                    topPadding: 4
                                    text: WsPage.PINNED_LABEL
                                    color: Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                }

                                Repeater {
                                    model: wsOwn.setting.pinnedApps

                                    Item {
                                        id: pinnedItem

                                        required property var modelData
                                        required property int index

                                        width: wsOwn.width
                                        implicitHeight: 32

                                        Text {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 10
                                            anchors.right: pinnedBin.left
                                            anchors.rightMargin: 6
                                            anchors.verticalCenter: parent.verticalCenter
                                            elide: Text.ElideRight
                                            textFormat: Text.PlainText
                                            text: pinnedItem.modelData
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 13
                                        }

                                        Row {
                                            id: pinnedBin

                                            anchors.right: parent.right
                                            anchors.rightMargin: 6
                                            anchors.verticalCenter: parent.verticalCenter

                                            StepButton {
                                                name: "edit-delete-symbolic"
                                                value: 0
                                                next: 1
                                                onActivated: workspacesPage.changed(WorkspacesData.removePinned(wsOwn.modelData, pinnedItem.index, pinnedItem.modelData))
                                            }
                                        }
                                    }
                                }

                                Item {
                                    width: wsOwn.width
                                    implicitHeight: 32

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 6
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: 26
                                        radius: 6
                                        color: Theme.surface2
                                        border.width: newPinned.activeFocus ? 1 : 0
                                        border.color: Theme.accent

                                        TextInput {
                                            id: newPinned

                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter
                                            clip: true
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: 13
                                            onAccepted: {
                                                const error = WorkspacesData.addPinned(wsOwn.modelData, text);
                                                workspacesPage.changed(error);
                                                if (error === "") {
                                                    text = "";
                                                    keys.forceActiveFocus();
                                                }
                                            }
                                            Keys.onEscapePressed: {
                                                text = "";
                                                keys.forceActiveFocus();
                                            }

                                            Text {
                                                visible: newPinned.text === "" && !newPinned.activeFocus
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: WsPage.PINNED_HINT
                                                color: Theme.fgFaint
                                                font.family: Theme.font
                                                font.pixelSize: 13
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: workspacesPage.refused !== ""
                            x: 10
                            width: workspacesPage.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: workspacesPage.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Floating: the rules, each a class and maybe a title
                    // pattern, which the arrows move and the bin takes out,
                    // one typed at the foot added; then the floating
                    // windows no rule covers, each with Always float
                    // (SPEC.md §6.4, §16).
                    Column {
                        id: floatingPage

                        property string refused: ""
                        // Which rule covers the window the fields were
                        // filled for already, or "".
                        property string note: ""
                        // What else the window filled in for has
                        // (Rules.windowDetails), or none.
                        property var details: []

                        function changed(error) {
                            refused = error;
                            root.report(error);
                        }

                        function addTyped() {
                            const error = FloatingData.add(newFloatClass.text, newFloatTitle.text);
                            floatingPage.changed(error);
                            if (error === "") {
                                floatingPage.clearTyped();
                            }
                        }

                        function clearTyped() {
                            newFloatClass.text = "";
                            newFloatTitle.text = "";
                            note = "";
                            details = [];
                            keys.forceActiveFocus();
                        }

                        // Always float and Super+Alt+F fill the fields, and
                        // the title, selected, takes the keys, to trim or
                        // clear; Enter adds the rule. After the panel has
                        // opened, which takes the keys itself.
                        Connections {
                            target: FloatingData

                            function onPrefillChanged() {
                                const p = FloatingData.prefill;
                                if (!p) {
                                    return;
                                }
                                newFloatClass.text = p.class;
                                newFloatTitle.text = p.title;
                                floatingPage.note = p.note;
                                floatingPage.details = p.details ?? [];
                                floatingPage.refused = "";
                                Qt.callLater(() => {
                                    root.section = "floating-add";
                                    pageFlick.scrolled();
                                    newFloatTitle.forceActiveFocus();
                                    newFloatTitle.selectAll();
                                });
                            }
                        }

                        onVisibleChanged: {
                            refused = "";
                            if (visible && !Compositor.tidewm) {
                                // The client list's floating flags, fresh.
                                Hyprland.refreshToplevels();
                            }
                        }
                        visible: root.current.id === "floating"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Heading {
                            text: "ALWAYS FLOAT"
                        }

                        Repeater {
                            model: FloatingData.rules

                            Item {
                                id: floatRule

                                required property var modelData
                                required property int index

                                width: floatingPage.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: floatButtons.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: FloatRules.describe(floatRule.modelData)
                                    color: Theme.fg
                                    font.family: Theme.monoFont
                                    font.pixelSize: 13
                                }

                                Row {
                                    id: floatButtons

                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "go-up-symbolic"
                                        value: floatRule.index
                                        next: Math.max(0, floatRule.index - 1)
                                        onActivated: floatingPage.changed(FloatingData.move(floatRule.index, floatRule.modelData, -1))
                                    }

                                    StepButton {
                                        name: "go-down-symbolic"
                                        value: floatRule.index
                                        next: Math.min(FloatingData.rules.length - 1, floatRule.index + 1)
                                        onActivated: floatingPage.changed(FloatingData.move(floatRule.index, floatRule.modelData, 1))
                                    }

                                    StepButton {
                                        name: "edit-delete-symbolic"
                                        value: 0
                                        next: 1
                                        onActivated: floatingPage.changed(FloatingData.remove(floatRule.index, floatRule.modelData))
                                    }
                                }
                            }
                        }

                        Text {
                            x: 10
                            width: floatingPage.width - 20
                            topPadding: 4
                            bottomPadding: 4
                            text: "Dialogs always float."
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 13
                        }

                        // A class and, optionally, a title pattern: Enter
                        // in either adds the rule, and one refused stays to
                        // be fixed.
                        Item {
                            id: floatAddRow

                            onYChanged: pageFlick.scrolled()
                            width: floatingPage.width
                            implicitHeight: 32

                            Rectangle {
                                id: floatClassField

                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: (parent.width - addFloat.width - 24) / 2
                                height: 26
                                radius: 6
                                color: Theme.surface2
                                border.width: newFloatClass.activeFocus ? 1 : 0
                                border.color: Theme.accent

                                TextInput {
                                    id: newFloatClass

                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    color: Theme.fg
                                    font.family: Theme.monoFont
                                    font.pixelSize: 13
                                    onAccepted: floatingPage.addTyped()
                                    KeyNavigation.tab: newFloatTitle
                                    Keys.onEscapePressed: floatingPage.clearTyped()

                                    Text {
                                        visible: newFloatClass.text === "" && !newFloatClass.activeFocus
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "App ID, such as org.gnome.Calculator"
                                        color: Theme.fgFaint
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }
                                }
                            }

                            Rectangle {
                                anchors.left: floatClassField.right
                                anchors.leftMargin: 6
                                anchors.right: addFloat.left
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                height: 26
                                radius: 6
                                color: Theme.surface2
                                border.width: newFloatTitle.activeFocus ? 1 : 0
                                border.color: Theme.accent

                                TextInput {
                                    id: newFloatTitle

                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    color: Theme.fg
                                    font.family: Theme.monoFont
                                    font.pixelSize: 13
                                    onAccepted: floatingPage.addTyped()
                                    Keys.onEscapePressed: floatingPage.clearTyped()

                                    Text {
                                        visible: newFloatTitle.text === "" && !newFloatTitle.activeFocus
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Title (optional), such as ^Library$"
                                        color: Theme.fgFaint
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                    }
                                }
                            }

                            Rectangle {
                                id: addFloat

                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: addFloatLabel.implicitWidth + 16
                                height: 26
                                radius: 7
                                color: addFloatHover.hovered ? Theme.surface2 : "transparent"
                                border.width: 1
                                border.color: Theme.surface2

                                Text {
                                    id: addFloatLabel

                                    anchors.centerIn: parent
                                    text: "Add"
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                }

                                HoverHandler {
                                    id: addFloatHover
                                }

                                TapHandler {
                                    onTapped: floatingPage.addTyped()
                                }
                            }
                        }

                        // Which rule already covers the window filled in.
                        Text {
                            visible: floatingPage.note !== ""
                            x: 10
                            width: floatingPage.width - 20
                            topPadding: 2
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: floatingPage.note
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 12
                        }

                        // More about this window: what else Hyprland says
                        // of the window filled in for, read-only, closed
                        // until opened, as it was left for the session.
                        Item {
                            visible: floatingPage.details.length > 0
                            width: floatingPage.width
                            implicitHeight: 28

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                SymbolicIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: FloatingData.detailsOpen ? "pan-down-symbolic" : "pan-end-symbolic"
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "More about this window"
                                    color: Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                }
                            }

                            TapHandler {
                                onTapped: FloatingData.detailsOpen = !FloatingData.detailsOpen
                            }
                        }

                        Repeater {
                            model: FloatingData.detailsOpen ? floatingPage.details : []

                            Item {
                                id: detailRow

                                required property var modelData

                                width: floatingPage.width
                                implicitHeight: 22

                                Text {
                                    id: detailLabel

                                    x: 32
                                    width: 130
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    text: detailRow.modelData.label
                                    color: Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                }

                                Text {
                                    anchors.left: detailLabel.right
                                    anchors.leftMargin: 8
                                    anchors.right: parent.right
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: detailRow.modelData.value
                                    color: Theme.fg
                                    font.family: Theme.monoFont
                                    font.pixelSize: 12
                                }
                            }
                        }

                        Heading {
                            text: "FLOATING NOW"
                        }

                        Repeater {
                            model: FloatingData.unruled

                            Item {
                                id: floatingWindow

                                required property var modelData

                                width: floatingPage.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: alwaysFloat.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: floatingWindow.modelData.title === "" ? floatingWindow.modelData.class : `${floatingWindow.modelData.class} · ${floatingWindow.modelData.title}`
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Rectangle {
                                    id: alwaysFloat

                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: alwaysFloatLabel.implicitWidth + 16
                                    height: 26
                                    radius: 7
                                    color: alwaysFloatHover.hovered ? Theme.surface2 : "transparent"
                                    border.width: 1
                                    border.color: Theme.surface2

                                    Text {
                                        id: alwaysFloatLabel

                                        anchors.centerIn: parent
                                        text: "Always float"
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 12
                                    }

                                    HoverHandler {
                                        id: alwaysFloatHover
                                    }

                                    TapHandler {
                                        onTapped: floatingPage.changed(FloatingData.prefillFor(floatingWindow.modelData))
                                    }
                                }
                            }
                        }

                        Text {
                            visible: FloatingData.unruled.length === 0
                            x: 10
                            width: floatingPage.width - 20
                            topPadding: 4
                            bottomPadding: 4
                            wrapMode: Text.Wrap
                            text: "None. Super+Shift+F floats a window."
                            color: Theme.fgDim
                            font.family: Theme.font
                            font.pixelSize: 13
                        }

                        // Also floating: the floating windows a rule covers
                        // already, dialogs among them, so their class and
                        // title can be looked up: Details fills the fields
                        // and More about this window from one.
                        Heading {
                            visible: FloatingData.covered.length > 0
                            text: "ALSO FLOATING"
                        }

                        Repeater {
                            model: FloatingData.covered

                            Item {
                                id: coveredWindow

                                required property var modelData

                                width: floatingPage.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: coveredBy.left
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: coveredWindow.modelData.title === "" ? coveredWindow.modelData.class : `${coveredWindow.modelData.class} · ${coveredWindow.modelData.title}`
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                Text {
                                    id: coveredBy

                                    anchors.right: details.left
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: coveredWindow.modelData.builtIn ? "Built in" : "Your rule"
                                    color: Theme.fgDim
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                }

                                Rectangle {
                                    id: details

                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: detailsLabel.implicitWidth + 16
                                    height: 26
                                    radius: 7
                                    color: detailsHover.hovered ? Theme.surface2 : "transparent"
                                    border.width: 1
                                    border.color: Theme.surface2

                                    Text {
                                        id: detailsLabel

                                        anchors.centerIn: parent
                                        text: "Details"
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 12
                                    }

                                    HoverHandler {
                                        id: detailsHover
                                    }

                                    TapHandler {
                                        onTapped: {
                                            FloatingData.detailsOpen = true;
                                            floatingPage.changed(FloatingData.prefillFor(coveredWindow.modelData));
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: floatingPage.refused !== ""
                            x: 10
                            width: floatingPage.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: floatingPage.refused
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }

                    // Sound: the output and input devices, as the volume
                    // popover lists them, with the level and mute of each
                    // one in use.
                    Column {
                        id: sound

                        readonly property var lists: Audio.audioLists(Pipewire.nodes.values, {
                            sink: PwNodeType.AudioSink,
                            source: PwNodeType.AudioSource,
                            outStream: PwNodeType.AudioOutStream,
                        })

                        visible: root.current.id === "sound"
                        width: parent.width
                        spacing: 2

                        Heading {
                            text: "OUTPUT"
                        }

                        VolumeControl {
                            width: sound.width
                            visible: Pipewire.defaultAudioSink !== null
                            node: Pipewire.defaultAudioSink
                        }

                        Repeater {
                            model: sound.lists.outputs

                            MenuRow {
                                required property var modelData

                                width: sound.width
                                icon: "audio-speakers-symbolic"
                                label: Audio.deviceLabel(modelData)
                                selected: Pipewire.defaultAudioSink === modelData
                                onClicked: Pipewire.preferredDefaultAudioSink = modelData
                            }
                        }

                        Heading {
                            visible: sound.lists.inputs.length > 0
                            text: "INPUT"
                        }

                        VolumeControl {
                            width: sound.width
                            visible: Pipewire.defaultAudioSource !== null
                            node: Pipewire.defaultAudioSource
                        }

                        Repeater {
                            model: sound.lists.inputs

                            MenuRow {
                                required property var modelData

                                width: sound.width
                                icon: "audio-input-microphone-symbolic"
                                label: Audio.deviceLabel(modelData)
                                selected: Pipewire.defaultAudioSource === modelData
                                onClicked: Pipewire.preferredDefaultAudioSource = modelData
                            }
                        }
                    }
                }
            }

            MenuRow {
                id: advancedRow

                anchors.bottom: parent.bottom
                width: parent.width
                visible: root.advancedLink !== null
                // Taking no room when hidden, so the page runs to the foot.
                height: visible ? implicitHeight : 0
                icon: "window-new-symbolic"
                label: root.advancedLink?.label ?? ""
                onClicked: root.advanced()
            }
        }

        // Over the card while the wallpaper colors are open: a press
        // anywhere else closes them, and goes no further.
        MouseArea {
            anchors.fill: parent
            visible: wallpaperColors.visible || wallpaperGrid.visible || cityPicker.visible
            onPressed: {
                wallpaperColors.close();
                wallpaperGrid.close();
                cityPicker.close();
                keys.forceActiveFocus();
            }
        }

        // The city picker (§16), under the Location row's Change: a search
        // of shell/cities/cities.tsv as you type, best and nearest first,
        // or with nothing typed the nearest cities; and above them, once a
        // city is chosen, the time zone's city again.
        // ↑ and ↓ move through them, Enter or a click chooses one, and
        // Escape, or a click anywhere else, closes it with nothing set.
        Rectangle {
            id: cityPicker

            property bool open: false
            property var cities: []
            property string failed: ""
            property bool read: false
            property int current: 0
            // Find's answer ({latitude, longitude, accuracyKm}) once it's
            // in, whether it's asking, and why it couldn't, for this opening.
            property var found: null
            property bool finding: false
            property string findFailed: ""
            property var request: null
            readonly property var place: AppearanceData.place
            // What the results favor: where Find says this machine is, else
            // where sunrise and sunset are for now, the location set or the
            // time zone's city; null for none.
            readonly property var near: {
                if (found) {
                    return { latitude: found.latitude, longitude: found.longitude };
                }
                const where = Appearance.placed(AppearanceData.settings, place);
                return where.latitude !== undefined && where.longitude !== undefined ? { latitude: where.latitude, longitude: where.longitude } : null;
            }
            // With nothing typed, the cities nearest it.
            readonly property var rows: {
                const typed = search.text.trim() !== "";
                const cities = typed ? Cities.searchCities(cityPicker.cities, search.text, 8, near)
                    : near ? Cities.nearestCities(cityPicker.cities, near, 8) : [];
                const listed = cities.map(c => ({ label: c.label, city: c }));
                const reset = search.text.trim() === "" && !cityPicker.found ? Appearance.resetLocation(AppearanceData.settings, AppearanceData.sharedSettings, place) : null;
                const back = reset ? [{ label: reset, city: null }] : [];
                return back.concat(listed);
            }

            // Opens under `button`, or over it with no room below, reading
            // the list the first time: about 440 KB, so not before.
            function show(button) {
                if (!read) {
                    read = true;
                    // Blocks until onLoaded or onLoadFailed has run.
                    citiesFile.text();
                }
                const at = button.mapToItem(card, 0, 0);
                x = Math.max(6, Math.min(at.x + button.width - width, card.width - width - 6));
                y = at.y + button.height + 4 + height <= card.height - 6 ? at.y + button.height + 4 : Math.max(6, at.y - 4 - height);
                search.text = "";
                current = 0;
                found = null;
                findFailed = "";
                open = true;
                search.forceActiveFocus();
            }

            function close() {
                open = false;
                if (request) {
                    request.abort();
                    request = null;
                }
                finding = false;
                findTimeout.stop();
            }

            // Asks beacondb.net where this machine's IP address is, then
            // lists the cities nearest that, for one to be chosen.
            function find() {
                if (finding) {
                    return;
                }
                finding = true;
                findFailed = "";
                const xhr = new XMLHttpRequest();
                request = xhr;
                xhr.onreadystatechange = () => {
                    if (xhr.readyState !== XMLHttpRequest.DONE || request !== xhr) {
                        return;
                    }
                    request = null;
                    finding = false;
                    findTimeout.stop();
                    const r = Cities.parseGeolocation(xhr.status, xhr.responseText);
                    if (r.error) {
                        findFailed = `Couldn't find your location: ${r.error}`;
                        console.warn(`tide: city picker: ${r.error}`);
                        return;
                    }
                    console.log(`tide: city picker: found a location to within ${r.accuracyKm ?? "?"} km`);
                    found = r;
                    search.text = "";
                    current = 0;
                    search.forceActiveFocus();
                };
                xhr.open("POST", Cities.GEOLOCATE_URL);
                xhr.setRequestHeader("Content-Type", "application/json");
                xhr.send(Cities.GEOLOCATE_BODY);
                findTimeout.restart();
            }

            function choose(row) {
                close();
                keys.forceActiveFocus();
                const city = row.city === null ? null : { label: row.city.label, latitude: row.city.latitude, longitude: row.city.longitude };
                appearance.refused = AppearanceData.setLocation(city);
                root.report(appearance.refused);
            }

            visible: open
            width: 360
            height: pickerColumn.implicitHeight + 24
            radius: 12
            color: Theme.surface
            border.color: Theme.edge

            // Takes its own presses, so they don't close it.
            MouseArea {
                anchors.fill: parent
            }

            FileView {
                id: citiesFile

                path: decodeURIComponent(Qt.resolvedUrl("cities/cities.tsv").toString().replace(/^file:\/\//, ""))
                printErrors: false
                preload: false
                blockLoading: true
                onLoaded: {
                    const r = Cities.parseCities(text());
                    for (const error of r.errors) {
                        console.warn(`tide: ${path}: ${error}`);
                    }
                    cityPicker.cities = r.cities;
                    cityPicker.failed = r.cities.length === 0 ? `No cities in ${path}` : "";
                }
                onLoadFailed: error => {
                    cityPicker.failed = `Couldn't read the city list: ${FileViewError.toString(error)}`;
                    console.warn(`tide: ${path}: ${FileViewError.toString(error)}`);
                }
            }

            // A Find with no answer in ten seconds gives up.
            Timer {
                id: findTimeout

                interval: 10 * 1000
                onTriggered: {
                    if (cityPicker.request) {
                        const xhr = cityPicker.request;
                        cityPicker.request = null;
                        xhr.abort();
                    }
                    cityPicker.finding = false;
                    cityPicker.findFailed = "Couldn't find your location: beacondb.net didn't answer";
                    console.warn("tide: city picker: beacondb.net didn't answer in 10 seconds");
                }
            }

            Column {
                id: pickerColumn

                x: 12
                y: 12
                width: cityPicker.width - 24
                spacing: 4

                Item {
                    width: parent.width
                    height: 28

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: findButton.left
                        anchors.rightMargin: 6
                        height: 28
                        radius: 6
                        color: Theme.surface2
                        border.width: search.activeFocus ? 1 : 0
                        border.color: Theme.accent

                        TextInput {
                            id: search

                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 13
                            onTextChanged: cityPicker.current = 0
                            onAccepted: {
                                if (cityPicker.rows.length > 0) {
                                    cityPicker.choose(cityPicker.rows[Math.min(cityPicker.current, cityPicker.rows.length - 1)]);
                                }
                            }
                            Keys.onUpPressed: cityPicker.current = Math.max(0, cityPicker.current - 1)
                            Keys.onDownPressed: cityPicker.current = Math.min(cityPicker.rows.length - 1, cityPicker.current + 1)
                            Keys.onEscapePressed: {
                                cityPicker.close();
                                keys.forceActiveFocus();
                            }

                            Text {
                                visible: search.text === ""
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Search cities"
                                color: Theme.fgFaint
                                font: search.font
                            }
                        }
                    }

                    // Find: where this machine is, by its IP address.
                    Rectangle {
                        id: findButton

                        anchors.right: parent.right
                        width: 64
                        height: 28
                        radius: 14
                        color: Theme.surface2
                        opacity: cityPicker.finding ? 0.5 : 1
                        Accessible.name: "Find my location"

                        Text {
                            anchors.centerIn: parent
                            text: cityPicker.finding ? "Finding" : "Find"
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }

                        TapHandler {
                            onTapped: cityPicker.find()
                        }
                    }
                }

                Repeater {
                    model: cityPicker.rows

                    Rectangle {
                        id: cityRow

                        required property var modelData
                        required property int index

                        width: pickerColumn.width
                        height: 28
                        radius: 6
                        color: index === cityPicker.current ? Theme.surface2 : "transparent"

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: cityRow.modelData.label
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: 13
                        }

                        HoverHandler {
                            onHoveredChanged: {
                                if (hovered) {
                                    cityPicker.current = cityRow.index;
                                }
                            }
                        }

                        TapHandler {
                            onTapped: cityPicker.choose(cityRow.modelData)
                        }
                    }
                }

                // Why there's nothing to choose, or where Find's answer is from.
                Text {
                    visible: text !== ""
                    width: pickerColumn.width
                    leftPadding: 8
                    topPadding: 4
                    bottomPadding: 4
                    wrapMode: Text.Wrap
                    text: cityPicker.failed !== "" ? cityPicker.failed
                        : cityPicker.findFailed !== "" ? cityPicker.findFailed
                        : search.text.trim() !== "" && cityPicker.rows.length === 0 ? "No cities match"
                        : cityPicker.found && search.text.trim() === "" ? `${Cities.foundText(cityPicker.found)}. ${Cities.GEOLOCATE_CREDIT}.` : ""
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 12
                }
            }
        }

        // A wallpaper's colors (§16), under its swatch: tide's palette's
        // backgrounds, dark then light, and a field for any #rrggbb, set
        // with Enter. Choosing one sets it as the row's field would, and
        // closes them; Escape closes them with nothing set.
        Rectangle {
            id: wallpaperColors

            // The setting, lightWallpaper or darkWallpaper, or "" when shut.
            property string key: ""
            property string label: ""
            readonly property string current: Appearance.wallpaperColor(AppearanceData.settings[key] ?? "")
            // The color under the pointer, by its label.
            property string hovered: ""

            // Opens under `swatch`, or over it with no room below.
            function show(key, label, swatch) {
                const at = swatch.mapToItem(card, 0, 0);
                wallpaperColors.key = key;
                wallpaperColors.label = label;
                x = Math.max(6, Math.min(at.x, card.width - width - 6));
                y = at.y + swatch.height + 4 + height <= card.height - 6 ? at.y + swatch.height + 4 : Math.max(6, at.y - 4 - height);
                hex.text = current;
                hex.forceActiveFocus();
            }

            function close() {
                key = "";
                modeMenu.visible = false;
                hovered = "";
            }

            function choose(value) {
                const key = wallpaperColors.key;
                close();
                keys.forceActiveFocus();
                appearance.set(key, value);
            }

            visible: key !== ""
            width: colorColumn.implicitWidth + 24
            height: colorColumn.implicitHeight + 24
            radius: 12
            color: Theme.surface
            border.color: Theme.edge

            // Takes its own presses, so they don't close it.
            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: colorColumn

                x: 12
                y: 12
                spacing: 8

                Text {
                    width: colorGrid.width
                    elide: Text.ElideRight
                    text: wallpaperColors.hovered !== "" ? wallpaperColors.hovered : wallpaperColors.label
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 12
                }

                Grid {
                    id: colorGrid

                    columns: 4
                    spacing: 6

                    Repeater {
                        model: Appearance.WALLPAPER_COLORS

                        Rectangle {
                            id: choice

                            required property var modelData
                            readonly property bool chosen: modelData.color === wallpaperColors.current

                            width: 32
                            height: 32
                            radius: 7
                            color: modelData.color
                            border.width: chosen || choiceHover.hovered ? 2 : 1
                            border.color: chosen || choiceHover.hovered ? Theme.accent : Theme.edge
                            Accessible.name: modelData.label

                            HoverHandler {
                                id: choiceHover

                                onHoveredChanged: wallpaperColors.hovered = hovered ? choice.modelData.label : ""
                            }

                            TapHandler {
                                onTapped: wallpaperColors.choose(choice.modelData.color)
                            }
                        }
                    }
                }

                // Any color, as #rrggbb or #rgb; one that isn't is refused
                // as the row's field's is.
                Rectangle {
                    width: colorGrid.width
                    height: 26
                    radius: 6
                    color: Theme.surface2
                    border.width: hex.activeFocus ? 1 : 0
                    border.color: Theme.accent

                    TextInput {
                        id: hex

                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: 13
                        font.features: ({ "tnum": 1 })
                        onAccepted: {
                            if (text.trim() !== "") {
                                wallpaperColors.choose(text.trim());
                            }
                        }
                        Keys.onEscapePressed: {
                            wallpaperColors.close();
                            keys.forceActiveFocus();
                        }

                        Text {
                            visible: hex.text === ""
                            anchors.verticalCenter: parent.verticalCenter
                            text: "#rrggbb"
                            color: Theme.fgFaint
                            font: hex.font
                        }
                    }
                }
            }
        }

        // The wallpaper grid (§16): every picture installed in the distro's
        // collections and in ~/Pictures/wallpapers, as thumbnails over the
        // page. Choosing one sets it as the file chooser would, and closes
        // it; Escape, or a click anywhere else, closes it with nothing set.
        Rectangle {
            id: wallpaperGrid

            // The setting, lightWallpaper or darkWallpaper, or "" when shut.
            property string key: ""
            property string label: ""
            // The pictures, galleryImages's, and whether the listing is
            // still running or what it said went wrong.
            property var images: []
            // The filters: light, dark or any (GALLERY_MODES), opening on
            // the setting's; and a collection's chip, "" for all.
            property string mode: "any"
            property string collection: ""
            readonly property var collections: Appearance.galleryCollections(images)
            readonly property var shown: Appearance.galleryFiltered(images, mode, collection)
            // Each size of monitor connected, previewScreens's, whose
            // shape the grid puts first.
            readonly property var screens: Appearance.previewScreens(Quickshell.screens)
            readonly property int columns: 4
            readonly property var rows: Appearance.galleryRows(shown, screens, columns)
            property bool listing: false
            property string failed: ""
            // The picture under the pointer, by its name.
            property string hovered: ""
            readonly property string current: Appearance.expandHome(AppearanceData.settings[key] ?? "", Quickshell.env("HOME") ?? "")

            // Lists the pictures afresh each time, so a download shows.
            function show(key, label) {
                wallpaperGrid.key = key;
                wallpaperGrid.label = label;
                mode = Appearance.galleryModeFor(key);
                collection = "";
                modeMenu.visible = false;
                images = [];
                failed = "";
                if (!listing) {
                    listing = true;
                    const run = gallery.createObject(root, { command: Appearance.galleryCommand(Appearance.galleryFolders(Quickshell.env("HOME") ?? "")) });
                    run.running = true;
                }
                thumbs.forceActiveFocus();
            }

            // Shows what was listed even when some of it couldn't be, with
            // why over the grid (Run.track has logged it).
            function listed(ok, errors, output) {
                listing = false;
                if (key === "") {
                    return;
                }
                images = Appearance.galleryImages(output, Quickshell.env("HOME") ?? "", Appearance.distroName(osRelease.text()));
                if (!ok) {
                    failed = `couldn't list every wallpaper: ${errors.trim().split("\n")[0] || "find didn't start"}`;
                }
            }

            function close() {
                key = "";
                modeMenu.visible = false;
                hovered = "";
                images = [];
            }

            function choose(path) {
                const key = wallpaperGrid.key;
                close();
                keys.forceActiveFocus();
                appearance.set(key, Appearance.pickedWallpaper(path, Quickshell.env("HOME") ?? ""));
            }

            visible: key !== ""
            x: 12
            y: 12
            width: card.width - 24
            height: card.height - 24
            radius: 12
            color: Theme.surface
            border.color: Theme.edge

            // Takes its own presses, so they don't close it.
            MouseArea {
                anchors.fill: parent
            }

            Text {
                id: gridTitle

                x: 12
                y: 12
                width: findMore.x - 24
                elide: Text.ElideRight
                text: wallpaperGrid.hovered !== "" ? wallpaperGrid.hovered : wallpaperGrid.failed !== "" && thumbs.count > 0 ? wallpaperGrid.failed : wallpaperGrid.label
                color: wallpaperGrid.hovered === "" && wallpaperGrid.failed !== "" && thumbs.count > 0 ? Theme.danger : Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 12
            }

            // Find more wallpapers on Unsplash (free ones) or Wallhaven (your
            // widest monitor's size and shape) in the browser, closing the
            // panel first so the browser isn't under it. Save one to
            // ~/Pictures/wallpapers and it shows here.
            Row {
                id: findMore

                x: parent.width - width - 12
                y: 8
                spacing: 4

                Repeater {
                    model: Appearance.moreWallpapers(wallpaperGrid.screens)

                    delegate: Rectangle {
                        id: site

                        required property var modelData

                        width: siteText.implicitWidth + 16
                        height: 24
                        radius: 6
                        color: siteHover.hovered ? Theme.surface2 : "transparent"
                        Accessible.name: `Find more on ${modelData.site}`

                        Text {
                            id: siteText

                            anchors.centerIn: parent
                            text: site.modelData.site
                            color: Theme.accent
                            font.family: Theme.font
                            font.pixelSize: 12
                        }

                        HoverHandler {
                            id: siteHover
                        }

                        TapHandler {
                            onTapped: {
                                root.close();
                                Launcher.launch(Appearance.openCommand(site.modelData.url));
                            }
                        }
                    }
                }
            }

            // The distro's name, for the chip of the pictures it installs
            // loose in /usr/share/backgrounds, as Ubuntu does.
            FileView {
                id: osRelease

                path: "/etc/os-release"
                blockLoading: true
                printErrors: false
                onLoadFailed: error => console.log(`tide: wallpaper grid: no distro name from ${path}: ${FileViewError.toString(error)}`)
            }

            // Light, dark or both, opening on the setting's: a picture that
            // isn't one of a light and dark pair shows for either.
            Rectangle {
                id: modeButton

                readonly property var labels: ({
                        light: "Light",
                        dark: "Dark",
                        any: "Light and dark"
                    })

                x: 12
                y: gridTitle.y + gridTitle.height + 8
                width: modeText.implicitWidth + 28
                height: 24
                radius: 6
                color: modeHover.hovered || modeMenu.visible ? Theme.surface2 : "transparent"
                border.color: Theme.edge
                Accessible.name: `Show ${modeText.text}`

                Text {
                    id: modeText

                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: modeButton.labels[wallpaperGrid.mode]
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: 12
                }

                Text {
                    x: parent.width - width - 7
                    anchors.verticalCenter: parent.verticalCenter
                    text: "▾"
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 10
                }

                HoverHandler {
                    id: modeHover
                }

                TapHandler {
                    onTapped: modeMenu.visible = !modeMenu.visible
                }
            }

            // A chip for each collection, when there's more than one.
            Flickable {
                id: chips

                x: modeButton.x + modeButton.width + 8
                y: modeButton.y
                width: parent.width - x - 12
                height: modeButton.height
                clip: true
                contentWidth: chipRow.implicitWidth
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                visible: wallpaperGrid.collections.length > 0

                Row {
                    id: chipRow

                    spacing: 6

                    Repeater {
                        model: [""].concat(wallpaperGrid.collections)

                        delegate: Rectangle {
                            id: chip

                            required property string modelData
                            readonly property bool chosen: wallpaperGrid.collection === modelData

                            width: chipText.implicitWidth + 20
                            height: chips.height
                            radius: height / 2
                            color: chosen ? Theme.accent : chipHover.hovered ? Theme.surface2 : "transparent"
                            border.color: chosen ? Theme.accent : Theme.edge
                            Accessible.name: chipText.text

                            Text {
                                id: chipText

                                anchors.centerIn: parent
                                text: chip.modelData === "" ? "All" : chip.modelData
                                color: chip.chosen ? Theme.accentFg : Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 12
                            }

                            HoverHandler {
                                id: chipHover
                            }

                            TapHandler {
                                onTapped: wallpaperGrid.collection = chip.modelData
                            }
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: thumbs
                width: thumbs.width - 24
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                visible: thumbs.count === 0
                text: wallpaperGrid.failed !== "" ? wallpaperGrid.failed
                    : wallpaperGrid.listing ? "Finding wallpapers…"
                    : wallpaperGrid.images.length > 0 ? "No wallpapers match these filters."
                    : "No wallpapers found. Add some to ~/Pictures/wallpapers."
                color: Theme.fgDim
                font.family: Theme.font
                font.pixelSize: 13
            }

            // A row of pictures at a time, so a few hundred stay cheap and
            // the sections can have headings: your monitors' shape first,
            // cropped as a monitor would; then the rest, whole, so their
            // shape shows.
            ListView {
                id: thumbs

                readonly property real cellWidth: Math.floor(width / wallpaperGrid.columns)
                readonly property real cellHeight: Math.round(cellWidth * 10 / 16)

                x: 12
                y: modeButton.y + modeButton.height + 8
                width: parent.width - 24
                height: parent.height - y - 12
                clip: true
                model: wallpaperGrid.rows
                boundsBehavior: Flickable.StopAtBounds
                Keys.onEscapePressed: {
                    wallpaperGrid.close();
                    keys.forceActiveFocus();
                }

                delegate: Column {
                    id: row

                    required property var modelData
                    required property int index

                    // The section's heading, on its first row.
                    Text {
                        width: thumbs.width
                        visible: row.modelData.heading !== ""
                        leftPadding: 3
                        topPadding: row.index === 0 ? 0 : 8
                        bottomPadding: 4
                        text: row.modelData.heading
                        color: Theme.fgDim
                        font.family: Theme.font
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }

                    Row {
                        Repeater {
                            model: row.modelData.images

                            delegate: Item {
                                id: thumb

                                required property var modelData
                                readonly property bool chosen: modelData.path === wallpaperGrid.current

                                width: thumbs.cellWidth
                                height: thumbs.cellHeight

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    radius: 7
                                    color: Theme.surface2
                                    clip: true

                                    // Decoded small and off the UI thread, so a
                                    // few hundred 4K pictures don't stall the
                                    // panel.
                                    Image {
                                        id: thumbImage

                                        anchors.fill: parent
                                        source: Appearance.fileUrl(thumb.modelData.path)
                                        sourceSize.width: 320
                                        sourceSize.height: 200
                                        fillMode: row.modelData.section === "fits" ? Image.PreserveAspectCrop : Image.PreserveAspectFit
                                        asynchronous: true
                                        smooth: true
                                    }

                                    // One Qt can't decode, JPEG XL without
                                    // kimageformats say, shows its name instead.
                                    Text {
                                        anchors.fill: parent
                                        anchors.margins: 6
                                        visible: thumbImage.status === Image.Error
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                        text: thumb.modelData.name
                                        color: Theme.fgDim
                                        font.family: Theme.font
                                        font.pixelSize: 11
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 7
                                        color: "transparent"
                                        border.width: thumb.chosen || thumbHover.hovered ? 2 : 1
                                        border.color: thumb.chosen || thumbHover.hovered ? Theme.accent : Theme.edge
                                    }
                                }

                                Accessible.name: modelData.name

                                HoverHandler {
                                    id: thumbHover

                                    onHoveredChanged: wallpaperGrid.hovered = hovered ? thumb.modelData.name : ""
                                }

                                TapHandler {
                                    onTapped: wallpaperGrid.choose(thumb.modelData.path)
                                }
                            }
                        }
                    }
                }
            }

            // The light and dark filter's choices, over the grid.
            Rectangle {
                id: modeMenu

                visible: false
                x: modeButton.x
                y: modeButton.y + modeButton.height + 4
                width: modeColumn.implicitWidth + 8
                height: modeColumn.implicitHeight + 8
                radius: 8
                color: Theme.surface
                border.color: Theme.edge

                Column {
                    id: modeColumn

                    x: 4
                    y: 4

                    Repeater {
                        model: Appearance.GALLERY_MODES

                        delegate: Rectangle {
                            id: modeItem

                            required property string modelData

                            width: Math.max(140, modeItemText.implicitWidth + 24)
                            height: 26
                            radius: 6
                            color: modeItemHover.hovered ? Theme.surface2 : "transparent"
                            Accessible.name: modeItemText.text

                            Text {
                                id: modeItemText

                                x: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: modeButton.labels[modeItem.modelData]
                                color: wallpaperGrid.mode === modeItem.modelData ? Theme.accent : Theme.fg
                                font.family: Theme.font
                                font.pixelSize: 12
                            }

                            HoverHandler {
                                id: modeItemHover
                            }

                            TapHandler {
                                onTapped: {
                                    wallpaperGrid.mode = modeItem.modelData;
                                    modeMenu.visible = false;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
