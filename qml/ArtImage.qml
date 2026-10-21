import QtQuick
import "theme.js" as Theme

// Cover art with a resolution cascade AND rounded corners.
//
// YouTube Music's API often answers with 120 px square thumbnails for
// songs; in big slots (the cinema artwork) those pixels are plainly
// insufficient. When a video ID is known, this component also offers the
// bigger variants of the same art (maxres -> hq) and the image server
// ("rart") keeps the first one that works; without an ID, or if none of
// them answers, the base one.
//
// The centre crop and the rounded corners are done in C++ (so a
// Rectangle's `clip` cannot leave the corners square and the crop can
// never come out off-centre). It is painted once per load, not per frame.
Item {
    id: art

    property string src: ""
    // Explicit YouTube ID (the track's). If empty it is extracted from
    // `src` itself ("watch?v=..." or "/vi_webp/..." URLs).
    property string videoId: ""
    property string iconKind: "music"
    // Fallback icon when there is no artwork at all?
    property bool showIconWhenEmpty: true
    // Background gradient (visible while loading or when there is
    // nothing).
    property color fillA: "#232a33"
    property color fillB: "#12151a"
    // Crop shape: "circle" or a radius in pixels.
    property var radiusSpec: 0

    readonly property bool ready: img.status === Image.Ready

    readonly property string vid: {
        var v = String(art.videoId || "")
        if (v.length >= 11 && v.length <= 13)
            return v
        var m = /v=([\w-]{11,13})/.exec(art.src)
        if (!m)
            m = /\/vi(?:_webp)?\/([\w-]{11,13})\//.exec(art.src)
        return m ? m[1] : ""
    }

    // The candidates, largest first: the C++ side tries them in order and
    // keeps the first one that downloads fine.
    readonly property var candidates: {
        var list = []
        if (art.vid) {
            list.push("https://i.ytimg.com/vi/" + art.vid + "/maxresdefault.jpg")
            list.push("https://i.ytimg.com/vi/" + art.vid + "/hq2.jpg")
        }
        if (art.src)
            list.push(art.src)
        return list
    }

    // Radius in logical pixels (the circle is resolved on the C++ side).
    readonly property int radius: radiusSpec === "circle" ? 10000 : radiusSpec

    property string artUrl: ""

    function refresh() {
        const w = Math.round(art.width)
        const h = Math.round(art.height)
        if (art.candidates.length === 0 || w <= 0 || h <= 0) {
            art.artUrl = ""
            return
        }
        art.artUrl = rart.url(art.candidates, w, h, art.radius,
                              Screen.devicePixelRatio)
    }

    onSrcChanged: refresh()
    onVideoIdChanged: refresh()
    onWidthChanged: refresh()
    onHeightChanged: refresh()
    onRadiusChanged: refresh()

    Component.onCompleted: refresh()

    Connections {
        target: rart
        function onReady(key) {
            if (key === rart.key(art.candidates, Math.round(art.width),
                                 Math.round(art.height), art.radius,
                                 Screen.devicePixelRatio))
                art.refresh()
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: !art.ready
        gradient: Gradient {
            GradientStop { position: 0.0; color: art.fillA }
            GradientStop { position: 1.0; color: art.fillB }
        }
    }

    Image {
        id: img
        anchors.fill: parent
        source: art.artUrl
        // It already comes cropped to the slot with rounded corners.
        fillMode: Image.Stretch
        asynchronous: true
        cache: true
        smooth: true
    }

    Glyph {
        anchors.centerIn: parent
        width: Math.round(Math.min(parent.width, parent.height) * 0.32)
        height: width
        kind: art.iconKind
        color: Theme.alpha(Sys.text, 0.45)
        visible: art.showIconWhenEmpty && art.src.length === 0
                 && !art.ready
    }
}
