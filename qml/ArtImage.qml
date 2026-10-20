import QtQuick
import "theme.js" as Theme

// Arte de portada con cascada de resolución.
//
// La API de YouTube Music responde a menudo con miniaturas cuadradas de
// 120 px para las canciones; en huecos grandes (la portada del cine) esos
// píxeles se ven de sobra. Si hay ID de vídeo de por medio, este componente
// prueba además las variantes mayores del mismo arte (maxres → hq) y se
// queda con la más grande que exista; si no hay ID o ninguna respuesta, la
// base. El decodificado se limita al tamaño físico real del hueco, así no
// se cargan 1280 px para un cuadro de 60.
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
    // Ancho de decodificado; 0 = auto: tamaño del hueco × dpr (tope 1280).
    property int decodeWidth: 0

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

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: art.fillA }
            GradientStop { position: 1.0; color: art.fillB }
        }
    }

    Image {
        id: baseImg
        anchors.fill: parent
        source: art.src
        visible: status === Image.Ready
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: art.dw
        sourceSize.height: art.dw
    }
    Image {
        id: hqImg
        anchors.fill: parent
        source: art.vid ? "https://i.ytimg.com/vi/" + art.vid + "/hq2.jpg" : ""
        visible: status === Image.Ready && !hiImg.visible
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: art.dw
        sourceSize.height: art.dw
    }
    Image {
        id: hiImg
        anchors.fill: parent
        source: art.vid ? "https://i.ytimg.com/vi/" + art.vid
                        + "/maxresdefault.jpg" : ""
        visible: status === Image.Ready
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: art.dw
        sourceSize.height: art.dw
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
