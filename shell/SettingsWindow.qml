import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import "lib/appearance.mjs" as Appearance
import "lib/audio.mjs" as Audio
import "lib/idle.mjs" as Idle
import "lib/input.mjs" as Input
import "lib/layouts.mjs" as Layouts
import "lib/outputs.mjs" as Outputs
import "lib/settings.mjs" as Settings

// The settings panel (SPEC.md §16), centered on the focused monitor over a
// dimmed backdrop, as the launcher is: the pages down the side, the one
// chosen beside them, and at its foot the app that does the rest, if any.
// The launcher's Settings action or `qs -c tide ipc call settings toggle`
// opens and closes it; Escape or a click on the backdrop closes it. Up and
// Down change the page, and Enter opens its app.
PanelWindow {
    id: root

    property int page: 0
    readonly property var current: Settings.PAGES[page]

    function open() {
        if (visible) {
            return;
        }
        const focused = Quickshell.screens.find(s => Hyprland.monitorFor(s) === Hyprland.focusedMonitor);
        if (focused) {
            screen = focused;
        }
        page = 0;
        visible = true;
        keys.forceActiveFocus();
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

    // A change a page asked for and was refused, which the log has.
    function report(error) {
        if (error !== "") {
            console.warn(`tide: ${error}`);
        }
    }

    // Closes first, so the app opens over the desktop, not under the panel.
    function advanced() {
        if (current.advanced === null) {
            return;
        }
        const command = current.advanced.command;
        close();
        Launcher.launch(command);
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
            root.open();
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
        // Sets one mouse's or touchpad's own setting, by its name in
        // `hyprctl devices`, as those pages do with that device chosen: `qs
        // -c tide ipc call settings setDevice trackball speed 0.5`.
        function setDevice(name: string, key: string, value: string): string {
            return InputData.setDevice(name, key, Input.parseValue(Input.deviceKind(name), key, value));
        }
        // Clears every setting of that device's own, as Reset does.
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
        // ("07:15"), a latitude or longitude, or a dimStrength (0.1).
        // Answers why not, or "".
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
    }

    Connections {
        target: SettingsData

        function onOpenRequested() {
            root.open();
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

    // A click on the backdrop closes it; the card takes its own clicks.
    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    Rectangle {
        id: card

        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 3)
        width: 640
        height: 440
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

        // Holds the keyboard while it's open.
        Item {
            id: keys

            focus: true
            Keys.onEscapePressed: root.close()
            Keys.onUpPressed: root.page = Settings.movedPage(root.page, -1)
            Keys.onDownPressed: root.page = Settings.movedPage(root.page, 1)
            Keys.onReturnPressed: root.advanced()
            Keys.onEnterPressed: root.advanced()
        }

        Column {
            id: sidebar

            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 6
            width: 180
            spacing: 2

            Repeater {
                model: Settings.PAGES

                MenuRow {
                    required property var modelData
                    required property int index

                    width: sidebar.width
                    icon: modelData.icon
                    label: modelData.label
                    highlighted: index === root.page
                    onClicked: root.page = index
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
                        readonly property bool pointer: section === "mouse" || section === "touchpad"
                        // Every device of the kind (""), then each one by
                        // name, which ‹ and › step through.
                        readonly property var targets: pointer ? Input.targets(InputData.input, InputData.connected, section) : [""]
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
                            if (pointer) {
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
                                visible: device.name !== "" && Input.hasOwn(InputData.input, device.name)
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
                                        device.refused = InputData.clearDevice(device.name);
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

                    // Keys: each binding's keys and what it does, listed
                    // again as the page shows.
                    Column {
                        id: keyList

                        onVisibleChanged: {
                            if (visible) {
                                KeysData.list();
                            }
                        }
                        visible: root.current.id === "keys"
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Repeater {
                            model: KeysData.binds

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

                        // Why there are none, if they couldn't be listed.
                        Text {
                            visible: KeysData.error !== ""
                            x: 10
                            width: keyList.width - 20
                            topPadding: 4
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: KeysData.error
                            color: Theme.danger
                            font.family: Theme.font
                            font.pixelSize: 12
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
                                    next: Appearance.steppedModeAt(appearance.settings, appearance.modeAt, -1)
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
                                    next: Appearance.steppedModeAt(appearance.settings, appearance.modeAt, 1)
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

                        // The location, for sunrise and sunset: shown in any
                        // mode, since sunrise and sunset can't be chosen
                        // until it's set.
                        Repeater {
                            model: [{ key: "latitude", label: "Latitude" }, { key: "longitude", label: "Longitude" }]

                            Item {
                                id: coordinate

                                required property var modelData

                                function shown() {
                                    const v = appearance.settings[modelData.key];
                                    return v === undefined ? "" : String(v);
                                }

                                width: appearance.width
                                implicitHeight: 32

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: coordinate.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: 13
                                }

                                // As the Keyboard page's names: Enter sets
                                // it, and Escape or a click elsewhere puts
                                // back what's set.
                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 148
                                    height: 26
                                    radius: 6
                                    color: Theme.surface2
                                    border.width: degrees.activeFocus ? 1 : 0
                                    border.color: Theme.accent

                                    TextInput {
                                        id: degrees

                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        verticalAlignment: TextInput.AlignVCenter
                                        clip: true
                                        text: coordinate.shown()
                                        color: Theme.fg
                                        font.family: Theme.font
                                        font.pixelSize: 13
                                        onAccepted: {
                                            const c = Appearance.parseCoordinate(coordinate.modelData.key, text);
                                            if (c.error) {
                                                appearance.refused = `${c.error}; not changing ${coordinate.modelData.key}`;
                                                root.report(appearance.refused);
                                            } else {
                                                appearance.set(coordinate.modelData.key, c.value);
                                            }
                                            keys.forceActiveFocus();
                                        }
                                        Keys.onEscapePressed: keys.forceActiveFocus()
                                        onActiveFocusChanged: {
                                            if (!activeFocus) {
                                                text = Qt.binding(() => coordinate.shown());
                                            }
                                        }

                                        Text {
                                            visible: degrees.text === "" && !degrees.activeFocus
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "none"
                                            color: Theme.fgFaint
                                            font: degrees.font
                                        }
                                    }
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
                visible: root.current.advanced !== null
                // Taking no room when hidden, so the page runs to the foot.
                height: visible ? implicitHeight : 0
                icon: "window-new-symbolic"
                label: root.current.advanced?.label ?? ""
                onClicked: root.advanced()
            }
        }
    }
}
