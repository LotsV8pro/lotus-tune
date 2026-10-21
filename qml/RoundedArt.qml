import QtQuick

// Portada redondeada.
//
// El recorte (al centro) y las esquinas redondeadas los hace el servidor
// de imágenes en C++ («rart»): la foto se baja una vez, se recorta al
// tamaño exacto del hueco y se le aplica la máscara de esquinas, así que
// llega ya lista. Hace falta porque el `clip` de un Rectangle ignora el
// `radius` (las esquinas salían cuadradas) y porque el recorte con Canvas
// dependía de la caché de imágenes por URL (si otra parte de la app pedía
// la misma foto en otro tamaño, la portada salía descentrada o vacía).
Item {
    id: art

    property string source: ""
    // «circle» = círculo perfecto; número = píxeles de radio (en el hueco).
    property var radiusSpec: 16

    readonly property bool ready: img.status === Image.Ready

    // Radio en píxeles lógicos. El círculo se resuelve en el C++, que lo
    // recorta a media vida.
    readonly property int radius: radiusSpec === "circle" ? 10000 : radiusSpec

    // La URL del proveedor (lleva la versión, para que al reprocesar se
    // vuelva a pedir y se repinte).
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

    // Cuando el C++ termina de recortar, se vuelve a pedir la URL (ya
    // tiene versión nueva) y la portada aparece.
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
        // La imagen ya viene recortada al hueco y con el alfa de las
        // esquinas: sólo se estira.
        fillMode: Image.Stretch
        asynchronous: true
        cache: true
        smooth: true
    }
}
