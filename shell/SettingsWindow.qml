import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Wayland
import "lib/audio.mjs" as Audio
import "lib/idle.mjs" as Idle
import "lib/input.mjs" as Input
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
