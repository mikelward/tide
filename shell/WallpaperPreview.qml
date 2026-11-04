import QtQuick
import "lib/appearance.mjs" as Appearance

// One monitor's preview of a wallpaper picture on the Appearance page
// (SPEC.md §16): the whole picture, scaled to fit, with the monitor's
// frame over it and what the monitor trims dimmed, and a line under it
// with the numbers. Appearance.previewLayout works out the geometry; this
// only draws it.
//
// Its own Image, not Wallpaper.qml's: that one decodes at the monitor's
// size, and this needs the file's own, which an Image with no sourceSize
// reports as its implicit size once loaded.
Column {
    id: preview

    // The file, or "" for none.
    property string path: ""
    // The monitor or monitors (names joined), and their size in pixels.
    property string screenName: ""
    property int screenWidth: 0
    property int screenHeight: 0
    property string position: "fill"
    // What fills the monitor where the picture doesn't (fit).
    property color barColor: Theme.barBg
    property int maxWidth: 240
    property int maxHeight: 160

    readonly property var image: picture.status === Image.Ready ? { width: picture.implicitWidth, height: picture.implicitHeight } : null
    readonly property var layout: image === null ? null : Appearance.previewLayout(image, { width: screenWidth, height: screenHeight }, position, maxWidth, maxHeight)
    readonly property bool ready: layout !== null

    // The picture couldn't be loaded, so the page can try the next.
    signal failed(string path)

    spacing: 4
    width: maxWidth

    Item {
        width: preview.ready ? preview.layout.width : 0
        height: preview.ready ? preview.layout.height : 0

        // The monitor, under the picture: seen only where the picture
        // doesn't reach.
        Rectangle {
            visible: preview.ready
            x: preview.ready ? preview.layout.frame.x : 0
            y: preview.ready ? preview.layout.frame.y : 0
            width: preview.ready ? preview.layout.frame.width : 0
            height: preview.ready ? preview.layout.frame.height : 0
            color: preview.barColor
        }

        Image {
            id: picture

            visible: preview.ready
            x: preview.ready ? preview.layout.image.x : 0
            y: preview.ready ? preview.layout.image.y : 0
            width: preview.ready ? preview.layout.image.width : 0
            height: preview.ready ? preview.layout.image.height : 0
            source: preview.path === "" ? "" : Appearance.fileUrl(preview.path)
            fillMode: Image.Stretch
            asynchronous: true
            smooth: true
            mipmap: true
            onStatusChanged: {
                if (status === Image.Error) {
                    preview.failed(preview.path);
                }
            }
        }

        // What the monitor trims.
        Repeater {
            model: preview.ready ? preview.layout.dims : []

            Rectangle {
                required property var modelData

                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height
                color: Qt.rgba(0, 0, 0, 0.6)
            }
        }

        Rectangle {
            visible: preview.ready
            x: preview.ready ? preview.layout.frame.x : 0
            y: preview.ready ? preview.layout.frame.y : 0
            width: preview.ready ? preview.layout.frame.width : 0
            height: preview.ready ? preview.layout.frame.height : 0
            color: "transparent"
            border.width: 2
            border.color: Theme.accent
        }
    }

    Text {
        visible: preview.ready
        width: preview.maxWidth
        wrapMode: Text.Wrap
        text: preview.ready ? Appearance.framingCaption(preview.screenName, preview.image, { width: preview.screenWidth, height: preview.screenHeight }, preview.position) : ""
        color: Theme.fgDim
        font.family: Theme.font
        font.pixelSize: 11
        font.features: ({ "tnum": 1 })
    }
}
