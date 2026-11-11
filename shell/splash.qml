import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "lib/lock.mjs" as Lock
import "lib/splash.mjs" as Splash

// The session's splash (SPEC.md §5.3): from the moment Hyprland starts
// until tide's shell is ready, every monitor shows your wallpaper, blurred
// as on the lock, with the hostname and "Starting tide", in place of
// Hyprland's empty background. It goes when tide.service is ready or has
// failed (the fallback's terminal then shows), and after
// Splash.GIVE_UP_AFTER_MS whatever happens. Each of those, and a slow
// start, is logged with how long it took.
ShellRoot {
    id: root

    property var state: Splash.initial(Date.now())
    property string hostnameText: ""
    readonly property string user: Quickshell.env("USER") || ""

    function answer(status) {
        const r = Splash.next(root.state, status, Date.now());
        root.state = r.state;
        if (r.log !== null) {
            console.info(`tide-splash: ${r.log}`);
        }
        if (r.quit) {
            Qt.quit();
        }
    }

    Component.onCompleted: console.info("tide-splash: showing until the shell is ready")

    // Your look, as the greeter shows it (LookData.qml).
    LookData {
        id: lookData
        user: root.user
        name: "tide-splash"
    }

    FileView {
        path: "/proc/sys/kernel/hostname"
        onLoaded: root.hostnameText = text()
    }

    // tide.service's state, asked again each second. Quickshell reports a
    // command that can't start only by stopping without `started`
    // (shell/lib/launch.mjs); that counts as no answer.
    Process {
        id: poll

        property bool started: false

        command: ["systemctl", "--user", "is-active", "tide.service"]
        stdout: StdioCollector {
            onStreamFinished: root.answer(text.trim())
        }
        onStarted: started = true
        onRunningChanged: {
            if (!running && !started) {
                console.warn("tide-splash: couldn't run systemctl to ask after the shell");
                root.answer("");
            }
        }
    }

    Timer {
        interval: Splash.POLL_MS
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!poll.running) {
                poll.started = false;
                poll.running = true;
            }
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData

            screen: modelData
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "tide-splash"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            color: "#000000"

            Backdrop {
                id: backdrop

                readonly property var palette: Lock.facePalette(dark)

                anchors.fill: parent
                dark: lookData.shown?.dark ?? true
                wallpaper: lookData.shown?.path ?? ""
                wallpaperColor: lookData.shown?.color ?? ""
                wallpaperPosition: lookData.shown?.position ?? "fill"

                Column {
                    anchors.centerIn: parent
                    spacing: 12

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Lock.shortHostname(root.hostnameText, root.user)
                        color: backdrop.palette.text
                        font.family: "Inter"
                        font.pixelSize: 32
                        font.weight: Font.Bold
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Splash.text(root.state)
                        color: backdrop.palette.text
                        opacity: 0.7
                        font.family: "Inter"
                        font.pixelSize: 13
                    }

                    // A dot sliding across a track: it's working.
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 120
                        height: 3
                        radius: 1.5
                        color: Qt.rgba(backdrop.palette.ink, backdrop.palette.ink, backdrop.palette.ink, 0.15)

                        Rectangle {
                            width: 30
                            height: parent.height
                            radius: parent.radius
                            color: backdrop.palette.accent

                            SequentialAnimation on x {
                                loops: Animation.Infinite
                                NumberAnimation { from: 0; to: 90; duration: 700; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 90; to: 0; duration: 700; easing.type: Easing.InOutSine }
                            }
                        }
                    }
                }
            }
        }
    }
}
