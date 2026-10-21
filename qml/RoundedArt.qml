import QtQuick

// Rounded artwork.
//
// The centre crop and the rounded corners are done by the C++ image server
// ("rart"): the picture is fetched once, cropped to the exact size of the
// slot and given the corner mask, so it arrives ready. This is needed
// because a Rectangle's `clip` ignores its `radius` (the corners came out
// square) and because cropping with a Canvas depended on the image cache
// keyed by URL (when another part of the app asked for the same photo at
// another size, the artwork came out off-centre or empty).
Item {
    id: art

    property string source: ""
    // "circle" = perfect circle; a number = corner radius in slot pixels.
    property var radiusSpec: 16

    readonly property bool ready: img.status === Image.Ready

    // Radius in logical pixels. The circle is resolved on the C++ side,
    // which clamps it to half the side.
    readonly property int radius: radiusSpec === "circle" ? 10000 : radiusSpec

    // Provider URL (it carries the version, so a reprocessed image is
    // requested again and repainted).
    property string artUrl: ""

    function refresh() {
        const w = Math.round(art.width)
        const h = Math.round(art.height)
        if (!art.source || art.source.length === 0 || w <= 0 || h <= 0) {
            art.artUrl = ""
            return
        }
        art.artUrl = rart.url([art.source], w, h, art.radius,
                              Screen.devicePixelRatio)
    }

    onSourceChanged: refresh()
    onWidthChanged: refresh()
    onHeightChanged: refresh()
    onRadiusChanged: refresh()

    Component.onCompleted: refresh()

    // When the C++ side finishes cropping, the URL is requested again (it
    // already has the new version) and the artwork shows up.
    Connections {
        target: rart
        function onReady(key) {
            if (key === rart.key([art.source], Math.round(art.width),
                                 Math.round(art.height), art.radius,
                                 Screen.devicePixelRatio))
                art.refresh()
        }
    }

    Image {
        id: img
        anchors.fill: parent
        source: art.artUrl
        // The image already comes cropped to the slot and with the corner
        // alpha: it only gets stretched.
        fillMode: Image.Stretch
        asynchronous: true
        cache: true
        smooth: true
    }
}
