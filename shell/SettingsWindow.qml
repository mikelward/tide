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
        // Sets one of the Mouse or Touchpad pages' settings: `qs -c tide ipc
        // call settings setInput mouse leftHanded false`. Answers why not,
        // or "".
        function setInput(section: string, key: string, value: string): string {
            const parsed = value === "true" ? true : value === "false" ? false : value.trim() === "" ? NaN : Number(value);
            return InputData.set(section, key, parsed);
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

        MouseArea {
            anchors.fill: parent
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
                    }

                    // Mouse and Touchpad: each setting for that kind of
                    // device, which − and + step along input.mjs's ladders,
                    // or a click turns on or off. Until it's set, it shows
                    // what conf's config has.
                    Column {
                        id: device

                        readonly property string section: root.current.id === "mouse" || root.current.id === "touchpad" ? root.current.id : ""

                        visible: section !== ""
                        width: parent.width
                        topPadding: 6
                        spacing: 2

                        Repeater {
                            model: device.section === "" ? [] : Input.SECTIONS[device.section]

                            Item {
                                id: option

                                required property var modelData
                                readonly property var value: Input.shown(InputData.input, device.section, modelData.key)
                                readonly property bool toggle: modelData.kind === "toggle"

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
                                    visible: !option.toggle
                                    anchors.right: parent.right
                                    anchors.rightMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 4

                                    StepButton {
                                        name: "list-remove-symbolic"
                                        value: option.toggle ? 0 : option.value
                                        next: option.toggle ? 0 : Input.stepped(option.modelData.kind, option.value, -1)
                                        onActivated: root.report(InputData.set(device.section, option.modelData.key, next))
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
                                        onActivated: root.report(InputData.set(device.section, option.modelData.key, next))
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
                                        onTapped: root.report(InputData.set(device.section, option.modelData.key, option.value !== true))
                                    }
                                }
                            }
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
