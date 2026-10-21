import QtQuick
import "theme.js" as Theme

// Arte de portada con cascada de resolución Y recorte redondeado.
//
// La API de YouTube Music responde a menudo con miniaturas cuadradas de
// 120 px para las canciones; en huecos grandes (la portada del cine) esos
// píxeles se ven de sobra. Si hay ID de vídeo de por medio, este componente
// propone además las variantes mayores del mismo arte (maxres → hq) y el
// servidor de imágenes («rart») se queda con la primera que sirva; si no
// hay ID o ninguna responde, la base.
//
// El recorte al centro y las esquinas redondeadas los hace el C++ (así el
// `clip` de un Rectangle no puede dejar las esquinas cuadradas y el
// recorte nunca sale descentrado). Se pinta una vez por carga, no por
// frame.
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

    // Las candidatas, de mayor a menor: el C++ prueba en orden y se
    // queda con la primera que descargue bien.
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

    // Radio en píxeles lógicos (el círculo lo resuelve el C++).
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
        // Ya viene recortada al hueco y con las esquinas redondeadas.
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
