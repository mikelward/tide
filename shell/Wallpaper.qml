import QtQuick
import Quickshell
import Quickshell.Wayland
import "lib/appearance.mjs" as Appearance

// The wallpaper on one monitor (SPEC.md §15): on the background layer,
// under everything, a picture placed as the mode's position says (filling
// the monitor as swaybg's fill mode does, keeping its top or bottom,
// fitted whole, or stretched to fill), or a color filling it plainly. With no wallpaper there's
// no window at all.
PanelWindow {
    id: root

    required property var modelData

    screen: modelData
    visible: WallpaperData.path !== "" || WallpaperData.color !== ""
    WlrLayershell.namespace: "tide-wallpaper"
    WlrLayershell.layer: WlrLayer.Background
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    readonly property var placement: Appearance.wallpaperPlacement(WallpaperData.position)

    // A color wallpaper, or under an image that hasn't loaded, or couldn't,
    // or the bars beside one fitted whole.
    color: WallpaperData.color !== "" ? WallpaperData.color : Theme.barBg

    // A right-click on bare desktop opens Appearance (SPEC.md §15), as a
    // right-click on the bar opens its item's page. Other clicks do
    // nothing: the window takes no keyboard focus, so a window keeps it.
    Item {
        anchors.fill: parent

        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: SettingsData.open("appearance")
        }
    }

    Image {
        anchors.fill: parent
        source: WallpaperData.path === "" ? "" : Appearance.fileUrl(WallpaperData.path)
        // Qt crops from the side away from the alignment, so this is
        // Appearance.wallpaperFrame's framing.
        fillMode: root.placement.stretch ? Image.Stretch : root.placement.fit ? Image.PreserveAspectFit : Image.PreserveAspectCrop
        horizontalAlignment: Image.AlignHCenter
        verticalAlignment: root.placement.vertical === "top" ? Image.AlignTop : root.placement.vertical === "bottom" ? Image.AlignBottom : Image.AlignVCenter
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
