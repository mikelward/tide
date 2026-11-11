import QtQuick
import QtQuick.Effects
import "lib/appearance.mjs" as Appearance
import "lib/lock.mjs" as Lock

// The background of the lock, the greeter and the session's splash
// (SPEC.md §10, §11, §15): the face's gradient, and over it once loaded the
// wallpaper, drawn through a blur and darkened (lightened on the light
// face) so text reads on any picture; or a color wallpaper, darkened the
// same way. What goes on top are this item's children.
Rectangle {
    id: root

    property bool dark: true
    // The picture's path, or "" for none.
    property string wallpaper: ""
    // A color wallpaper, #rrggbb, or "".
    property string wallpaperColor: ""
    // How the picture is placed (Appearance.POSITIONS).
    property string wallpaperPosition: "fill"
    readonly property var placement: Appearance.wallpaperPlacement(wallpaperPosition)
    readonly property var palette: Lock.facePalette(root.dark)

    gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: root.palette.top }
        GradientStop { position: 1.0; color: root.palette.bottom }
    }

    // Decoded at the face's size, which the blur leaves no detail to spare.
    Image {
        id: picture

        anchors.fill: parent
        visible: false
        source: root.wallpaper === "" ? "" : Appearance.fileUrl(root.wallpaper)
        // Framed as Wallpaper.qml frames it; a picture fitted whole has the
        // gradient in its bars.
        fillMode: root.placement.stretch ? Image.Stretch : root.placement.fit ? Image.PreserveAspectFit : Image.PreserveAspectCrop
        horizontalAlignment: Image.AlignHCenter
        verticalAlignment: root.placement.vertical === "top" ? Image.AlignTop : root.placement.vertical === "bottom" ? Image.AlignBottom : Image.AlignVCenter
        asynchronous: true
        sourceSize.width: root.width
        sourceSize.height: root.height
        onStatusChanged: {
            if (status === Image.Error) {
                console.warn(`tide: wallpaper: couldn't load ${root.wallpaper}`);
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        visible: picture.status === Image.Ready
        source: picture
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        brightness: root.dark ? -Appearance.LOCK_DARKEN : Appearance.LOCK_DARKEN
    }

    // A color wallpaper: plain, with nothing to blur (Appearance.lockColor).
    Rectangle {
        anchors.fill: parent
        visible: root.wallpaperColor !== ""
        color: root.wallpaperColor === "" ? "transparent" : Appearance.lockColor(root.wallpaperColor, root.dark)
    }
}
