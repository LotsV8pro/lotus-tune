import QtQuick

// Portada redondeada para el backend de software (sin shaders).
//
// El `clip` de un Rectangle sólo recorta por el cuadro envolvente e
// IGNORA el `radius`: por eso los degradados de respaldo se veían
// redondeados pero las portadas con imagen real salían cuadradas. Aquí la
// imagen se pinta dentro de un Canvas con una trayectoria de esquinas
// redondeadas — recorte en CPU, compatible con la ejecución sin GPU.
//
// La imagen se carga con `asynchronous`, así que su pixmap puede llegar
// DESPUÉS del primer pintado: como el lienzo se limpia en cada repintado,
// un repintado puede llegar con la imagen todavía ausente y la portada se
// queda en blanco para siempre. Por eso se insiste con un temporizador
// hasta que la imagen se pinte de verdad (y entonces se para). Coste: un
// repintado cada 120 ms, sólo durante la carga.
Item {
    id: art

    property string source: ""
    // «circle» = círculo perfecto; número = píxeles de radio.
    property var radiusSpec: 16
    // Tope de decodificado; 0 = auto (tamaño del hueco × DPR).
    property int decodeWidth: 0

    readonly property bool ready: artImg.status === Image.Ready

    // Intentos de repintado mientras la imagen aún no se ve.
    property int attempts: 0

    onRadiusSpecChanged: canvas.requestPaint()
    onSourceChanged: { art.attempts = 0; retry.start(); canvas.requestPaint() }

    Component.onCompleted: { retry.start(); canvas.requestPaint() }

    Image {
        id: artImg
        source: art.source
        visible: false
        asynchronous: true
        cache: true
        // Sólo el ancho: así el alto sale del propio aspecto de la imagen y
        // el tamaño implícito coincide con el pixmap (si se fijan los dos
        // lados, Qt toma sourceSize como tamaño del item aunque la imagen
        // sea menor y el recorte se sale del pixmap).
        sourceSize.width: art.decodeWidth > 0
                          ? art.decodeWidth
                          : Math.max(64, Math.round(art.width * Screen.devicePixelRatio))
        onStatusChanged: { art.attempts = 0; retry.start(); canvas.requestPaint() }
    }

    // Insiste hasta que la imagen se pinte de verdad.
    Timer {
        id: retry
        interval: 120
        repeat: true
        onTriggered: {
            if (art.attempts > 40) {
                retry.stop()
                return
            }
            art.attempts++
            canvas.requestPaint()
        }
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Immediate

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (artImg.status !== Image.Ready || width <= 0 || height <= 0)
                return
            // La Image oculta se queda con su tamaño natural: ese es el
            // lienzo de origen del que recortamos (PreserveAspectCrop al
            // centro, como hacían los Image con fillMode antes).
            const iw = artImg.width, ih = artImg.height
            if (iw <= 0 || ih <= 0)
                return
            const s = Math.max(width / iw, height / ih)
            const sw = width / s, sh = height / s
            const sx = (iw - sw) / 2, sy = (ih - sh) / 2
            const r = art.radiusSpec === "circle"
                      ? Math.min(width, height) / 2
                      : Math.min(art.radiusSpec, Math.min(width, height) / 2)
            ctx.save()
            ctx.beginPath()
            ctx.moveTo(r, 0)
            ctx.arcTo(width, 0, width, height, r)
            ctx.arcTo(width, height, 0, height, r)
            ctx.arcTo(0, height, 0, 0, r)
            ctx.arcTo(0, 0, width, 0, r)
            ctx.closePath()
            ctx.clip()
            ctx.drawImage(artImg, sx, sy, sw, sh, 0, 0, width, height)
            ctx.restore()
        }
    }
}
