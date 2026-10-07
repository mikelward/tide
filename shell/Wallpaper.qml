import QtQuick
import Quickshell
import Quickshell.Wayland
import "lib/appearance.mjs" as Appearance

// The wallpaper on one monitor (SPEC.md §15): on the background layer,
// under everything, filling the monitor as swaybg's fill mode does. With no
// wallpaper there's no window at all.
PanelWindow {
    id: root

    required property var modelData

    screen: modelData
    visible: WallpaperData.path !== ""
    WlrLayershell.namespace: "tide-wallpaper"
    WlrLayershell.layer: WlrLayer.Background
    exclusionMode: ExclusionMode.Ignore
    // Click-through, as swaybg's is: a click on bare desktop isn't the
    // shell's.
    mask: Region {}
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    // Under an image that hasn't loaded, or couldn't.
    color: Theme.barBg

    Image {
        anchors.fill: parent
        source: WallpaperData.path === "" ? "" : Appearance.fileUrl(WallpaperData.path)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Decoded at the monitor's size rather than the file's: its pixels,
        // which are the window's size times its scale.
        sourceSize.width: root.width * root.devicePixelRatio
        sourceSize.height: root.height * root.devicePixelRatio
        onStatusChanged: {
            if (status === Image.Error) {
                console.warn(`tide: wallpaper: couldn't load ${WallpaperData.path}; trying the next`);
                WallpaperData.cantDraw(WallpaperData.path);
            }
        }
    }
}
