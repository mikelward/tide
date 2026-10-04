import QtQuick
import Quickshell
import Quickshell.Io
import "lib/launch.mjs" as Run
import "lib/session.mjs" as Session

// The session menu (SPEC.md §7.4): lock, log out, suspend, restart and
// shut down, hanging from the session icon. A power action that something
// inhibits asks first, naming what's in the way, and goes ahead only on
// "Anyway".
PopupWindow {
    id: root

    required property Item icon

    // The action being run, and once systemctl says it's blocked, why.
    property string action: ""
    property var blocked: []
    // The run's signals, through shell/lib/launch.mjs, which says when it's
    // done: its exit code and stderr are both in, or it couldn't start.
    property var runState: Run.initial()

    function toggle() {
        blocked = [];
        visible = !visible;
    }

    function run(id, force) {
        // One at a time, so a result always belongs to the action shown.
        if (runner.running) {
            return;
        }
        action = id;
        blocked = [];
        runState = Run.initial();
        runner.command = Session.actionCommand(id, force);
        runner.running = true;
        if (!Session.isPower(id) || force) {
            visible = false;
        }
    }

    function handle(event) {
        if (runState.done) {
            return;
        }
        runState = Run.step(runState, event, runner.command);
        if (!runState.done) {
            return;
        }
        // Only a run that started and failed can be blocked.
        const found = runState.started && runState.code !== 0 && Session.isPower(action) ? Session.blockers(runState.errors) : [];
        if (found.length > 0) {
            blocked = found;
            return;
        }
        if (runState.report?.level === "warn") {
            console.warn(runState.report.message);
        }
        visible = false;
    }

    anchor.item: icon
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.bottom: -10
    grabFocus: true
    color: "transparent"
    implicitWidth: 240
    implicitHeight: card.implicitHeight

    Process {
        id: runner

        stderr: StdioCollector {
            onStreamFinished: root.handle({ type: "stderr", text: text })
        }
        onStarted: root.handle({ type: "started" })
        onRunningChanged: {
            if (!running) {
                root.handle({ type: "stopped" });
            }
        }
        onExited: (code, status) => root.handle({ type: "exited", code: code })
    }

    Rectangle {
        id: card

        anchors.fill: parent
        implicitHeight: list.implicitHeight + 12
        radius: 12
        color: Theme.surface
        border.color: Theme.edge

        Column {
            id: list

            anchors.fill: parent
            anchors.margins: 6
            spacing: 2

            Repeater {
                model: root.blocked.length > 0 ? [] : Session.ACTIONS

                MenuRow {
                    required property var modelData

                    width: list.width
                    enabled: !runner.running
                    icon: modelData.icon
                    label: modelData.label
                    onClicked: root.run(modelData.id, false)
                }
            }

            Text {
                visible: root.blocked.length > 0
                width: list.width
                leftPadding: 10
                rightPadding: 10
                topPadding: 6
                bottomPadding: 4
                wrapMode: Text.WordWrap
                text: `${Session.ACTIONS.find(a => a.id === root.action)?.label ?? ""} is blocked by:`
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: 12.5
                font.weight: Font.Bold
            }

            Repeater {
                model: root.blocked

                Text {
                    required property string modelData

                    width: list.width
                    leftPadding: 10
                    rightPadding: 10
                    wrapMode: Text.WordWrap
                    // Inhibitor names come from other programs: never markup.
                    textFormat: Text.PlainText
                    text: modelData
                    color: Theme.fgDim
                    font.family: Theme.font
                    font.pixelSize: 12
                }
            }

            MenuRow {
                visible: root.blocked.length > 0
                width: list.width
                enabled: !runner.running
                icon: "dialog-warning-symbolic"
                label: "Anyway"
                onClicked: root.run(root.action, true)
            }

            MenuRow {
                visible: root.blocked.length > 0
                width: list.width
                icon: "window-close-symbolic"
                label: "Cancel"
                onClicked: root.toggle()
            }
        }
    }
}
