import QtQuick
import "theme.js" as Theme

// Arte de portada con cascada de resolución Y recorte redondeado en CPU.
//
// La API de YouTube Music responde a menudo con miniaturas cuadradas de
// 120 px para las canciones; en huecos grandes (la portada del cine) esos
// píxeles se ven de sobra. Si hay ID de vídeo de por medio, este componente
// prueba además las variantes mayores del mismo arte (maxres → hq) y se
// queda con la más grande que exista; si no hay ID o ninguna respuesta, la
// base. El decodificado se limita al tamaño físico real del hueco, así no
// se cargan 1280 px para un cuadro de 60.
//
// Las tres Image son sólo descargadores (van ocultas): lo que se ve es el
// Canvas que vuelca la mejor cargada con la máscara de esquinas redondeadas
// (el `clip` de un Rectangle no respetaba el radio y la portada salía
// cuadrada). Se pinta una vez por carga, no por frame.
Item {
    id: art

    property string src: ""
    // ID de YouTube explícito (el de la pista). Si viene vacío se intenta
    // extraer del propio `src` (URLs «watch?v=…» o «/vi_webp/…»).
    property string videoId: ""
    property string iconKind: "music"
    // ¿Icono de respaldo cuando no hay arte alguno?
    property bool showIconWhenEmpty: true
    // Degradado de fondo (se ve mientras carga o si no hay nada).
    property color fillA: "#232a33"
    property color fillB: "#12151a"
    // Forma del recorte: «circle» o píxeles de radio.
    property var radiusSpec: 0
    // Ancho de decodificado; 0 = auto: tamaño del hueco × dpr (tope 1280).
    property int decodeWidth: 0

    // La mejor imagen cargada (mayor resolución primero). Las Image van
    // ocultas (descargadores puros), así que la elección va por estado.
    readonly property Image current: hiImg.status === Image.Ready ? hiImg
                                     : (hqImg.status === Image.Ready ? hqImg : baseImg)
    readonly property bool ready: baseImg.status === Image.Ready
                                  || hqImg.status === Image.Ready
                                  || hiImg.status === Image.Ready

    readonly property string vid: {
        var v = String(art.videoId || "")
        if (v.length >= 11 && v.length <= 13)
            return v
        var m = /v=([\w-]{11,13})/.exec(art.src)
        if (!m)
            m = /\/vi(?:_webp)?\/([\w-]{11,13})\//.exec(art.src)
        return m ? m[1] : ""
    }
    readonly property int dw: decodeWidth > 0
                              ? decodeWidth
                              : Math.min(1280, Math.max(64, Math.round(
                                    width * Screen.devicePixelRatio)))

    // Cambios de forma/tamaño o llegada de otra imagen → repintar.
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    onRadiusSpecChanged: canvas.requestPaint()
    onCurrentChanged: canvas.requestPaint()

    // Como en RoundedArt: el pixmap puede llegar después del primer
    // pintado, y como el lienzo se limpia en cada repintado, sin insistir
    // la portada se queda en blanco. Se reintenta hasta que se pinte.
    property int attempts: 0
    Timer {
        id: retry
        interval: 150
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
    Component.onCompleted: retry.start()

    Rectangle {
        anchors.fill: parent
        visible: !art.ready
        gradient: Gradient {
            GradientStop { position: 0.0; color: art.fillA }
            GradientStop { position: 1.0; color: art.fillB }
        }
    }

    // Descargadores (ocultos; el Canvas pinta lo que traigan).
    Image {
        id: baseImg
        visible: false
        source: art.src
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // Sólo el ancho: el alto sale del aspecto real de la imagen y así
        // el tamaño implícito coincide con el pixmap (si se fijan los dos
        // lados, Qt toma sourceSize como tamaño del item aunque la imagen
        // sea menor, y el recorte se sale del pixmap).
        sourceSize.width: art.dw
        onStatusChanged: { art.attempts = 0; retry.start(); canvas.requestPaint() }
    }
    Image {
        id: hqImg
        visible: false
        source: art.vid ? "https://i.ytimg.com/vi/" + art.vid + "/hq2.jpg" : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // Sólo el ancho: el alto sale del aspecto real de la imagen y así
        // el tamaño implícito coincide con el pixmap (si se fijan los dos
        // lados, Qt toma sourceSize como tamaño del item aunque la imagen
        // sea menor, y el recorte se sale del pixmap).
        sourceSize.width: art.dw
        onStatusChanged: { art.attempts = 0; retry.start(); canvas.requestPaint() }
    }
    Image {
        id: hiImg
        visible: false
        source: art.vid ? "https://i.ytimg.com/vi/" + art.vid
                        + "/maxresdefault.jpg" : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // Sólo el ancho: el alto sale del aspecto real de la imagen y así
        // el tamaño implícito coincide con el pixmap (si se fijan los dos
        // lados, Qt toma sourceSize como tamaño del item aunque la imagen
        // sea menor, y el recorte se sale del pixmap).
        sourceSize.width: art.dw
        onStatusChanged: { art.attempts = 0; retry.start(); canvas.requestPaint() }
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Immediate

        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const img = art.current
            if (!art.ready || !img || width <= 0 || height <= 0)
                return
            const iw = img.width, ih = img.height
            if (iw <= 0 || ih <= 0)
                return
            // PreserveAspectCrop al centro sobre el hueco.
            const s = Math.max(width / iw, height / ih)
            const sw = width / s, sh = height / s
            const sx = (iw - sw) / 2, sy = (ih - sh) / 2
            const r = art.radiusSpec === "circle"
                      ? Math.min(width, height) / 2
                      : Math.min(art.radiusSpec, Math.min(width, height) / 2)
            if (r <= 0) {
                // Sin forma pedida: vuelco directo, sin máscara.
                ctx.drawImage(img, sx, sy, sw, sh, 0, 0, width, height)
                return
            }
            ctx.save()
            ctx.beginPath()
            ctx.moveTo(r, 0)
            ctx.arcTo(width, 0, width, height, r)
            ctx.arcTo(width, height, 0, height, r)
            ctx.arcTo(0, height, 0, 0, r)
            ctx.arcTo(0, 0, width, 0, r)
            ctx.closePath()
            ctx.clip()
            ctx.drawImage(img, sx, sy, sw, sh, 0, 0, width, height)
            ctx.restore()
        }
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
