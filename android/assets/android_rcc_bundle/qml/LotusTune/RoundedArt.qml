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
    // Alternative URLs, tried in order when `source` fails (a signed
    // YouTube cover expires with time; the stable /vi/ one of the first
    // track of a downloaded list does not).
    property var sources: []
    // "circle" = perfect circle; a number = corner radius in slot pixels.
    property var radiusSpec: 16

    // Desenfoque (0 = ninguno). Se hace en C++ con el pipeline del wash:
    // la app va con el backend software y un shader (MultiEffect) no
    // dibujaria nada. Se usa como fondo de la lista abierta.
    property int blur: 0

    readonly property bool ready: img.status === Image.Ready

    // Radius in logical pixels. The circle is resolved on the C++ side,
    // which clamps it to half the side.
    readonly property int radius: radiusSpec === "circle" ? 10000 : radiusSpec

    // Provider URL (it carries the version, so a reprocessed image is
    // requested again and repainted).
    property string artUrl: ""

    // Guard against re-entry: the C++ side no longer emits `ready` from
    // inside the url request, but a refresh running twice in the same
    // turn was the source of a "Maximum call stack size exceeded" loop.
    property bool _refreshing: false

    // Every non-empty candidate, without duplicates. The first one is
    // the preferred cover; the rest are the safety net (see `sources`).
    function candidates() {
        var out = []
        function add(u) {
            u = String(u || "")
            if (u.length > 0 && out.indexOf(u) < 0)
                out.push(u)
        }
        add(art.source)
        if (art.sources) {
            for (var i = 0; i < art.sources.length; ++i)
                add(art.sources[i])
        }
        return out
    }

    function refresh() {
        if (art._refreshing)
            return
        art._refreshing = true
        const w = Math.round(art.width)
        const h = Math.round(art.height)
        const list = art.candidates()
        if (list.length === 0 || w <= 0 || h <= 0) {
            art.artUrl = ""
            art._refreshing = false
            return
        }
        art.artUrl = rart.urlBlurred(list, w, h, art.radius,
                                     Screen.devicePixelRatio, art.blur)
        art._refreshing = false
    }

    onSourceChanged: refresh()
    onSourcesChanged: refresh()
    onWidthChanged: refresh()
    onHeightChanged: refresh()
    onRadiusChanged: refresh()
    onBlurChanged: refresh()

    Component.onCompleted: refresh()

    // When the C++ side finishes cropping, the URL is requested again (it
    // already has the new version) and the artwork shows up.
    //
    // Solo se reacciona mientras ESTA tarjeta espera su imagen. Antes se
    // comparaba la clave (un SHA1) en cada portada de la app por cada
    // "ready": con una lista en scroll eso son cientos de hashes por
    // segundo en el hilo de la GUI (tirones). Si ya hay URL no hay nada
    // que hacer: los cambios de tamano/radio llaman a refresh() ellos
    // mismos.
    Connections {
        target: rart
        function onReady(key) {
            if (art.artUrl.length === 0 && art.candidates().length > 0)
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
