import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import "theme.js" as Theme

// Vista grande de «En reproducción»: cabecera con volumen y utilidades y,
// debajo, una única columna vertical centrada en este orden:
//
//   portada → título/artista → LETRA → barra de progreso → controles
//
// La letra ocupa el hueco central (fillHeight) directamente sobre el fondo
// de la vista —sin tarjeta ni caja—, centrada con ancho de lectura acotado
// (`maxLyricsW`); la línea activa se centra en vertical desde LyricsView.
// Así en 2560x1440 la columna no se estira hasta el borde y en ~900x650
// nada se desborda: la portada se encoge con `coverCap` para garantizar la
// reserva de la letra y el resto lo absorbe el bloque relleno.
Rectangle {
    id: np

    property bool open: false
    property string title: ""
    property string artist: ""
    property string thumb: ""
    property bool playing: false
    property bool shuffle: false
    property bool repeat: false
    property real position: 0
    property real duration: 0

    property bool scrubbing: false
    property real scrubPos: 0

    // ---- medidas -------------------------------------------------------
    // Ancho máximo de la caja de contenido y de la columna de lectura.
    readonly property real maxContentW: 840
    readonly property real maxLyricsW: 820
    readonly property real minLyricsW: 320
    readonly property real contentW: Math.max(300, Math.min(maxContentW,
                                                            np.width - 64))
    // Portada: nunca más ancha que la caja ni más alta que un tercio de la
    // ventana (regla pedida: clamp `Math.min(maxW, height * 0.34)`).
    readonly property real coverRaw: Math.max(140, Math.min(contentW,
                                                            np.height * 0.34))
    // Alturas REALES de los bloques que acompañan a la portada (título a 1
    // o 2 líneas, progreso, transporte + los 4 espaciados de la columna).
    readonly property real otherBlocksH: titleCol.height + progressCol.height
        + transportRow.height + bodyCol.spacing * 4
    // Reserva mínima del hueco de letra cuando está visible.
    readonly property real lyricsReserve: lyricsVisible ? 175 : 0
    // Techo calculado de la portada: cuerpo − resto de bloques − letra.
    // En ventana baja la portada se encoge (sin bajar de 96 px) para que
    // la letra conserve su reserva y nada se desborde ni se recorte.
    readonly property real coverCap: Math.max(96, npBody.height - otherBlocksH
                                              - lyricsReserve)
    readonly property real coverSize: Math.min(coverRaw, coverCap)

    // El resplandor superior de la vista (Sys.surface → Sys.bg) se corta
    // POR ENCIMA del hueco de la letra: a partir de ahí el fondo es Sys.bg
    // plano y los difuminados de LyricsView funden sin costura de color.
    readonly property real lyricsTopY: npBody.y + coverWrap.height
        + titleCol.height + progressCol.height + bodyCol.spacing * 3
    readonly property real glowH: Math.max(190, lyricsTopY - 14)

    // ---- letra visible -------------------------------------------------
    // Se lee al arrancar y se persiste en appcfg ("npLyrics", 1 = visible).
    property bool lyricsVisible: (typeof appcfg !== "undefined")
        ? String(appcfg.get("npLyrics") || "1") !== "0" : true
    // Si Main.qml conecta `fullscreenRequested` puede poner esto a false para
    // que el botón no haga nada por su cuenta; por defecto sí actúa.
    property bool fullscreenFallback: true

    // ---- volumen (leído del reproductor; Main.qml no lo conecta) --------
    readonly property var ply: (typeof player !== "undefined") ? player : null
    readonly property int volume: ply ? Number(ply.volume || 0) : 70
    property int lastVolume: 70

    signal closeRequested()
    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal shuffleToggled()
    signal repeatToggled()
    signal seekRequested(real seconds)
    signal fullscreenRequested()

    color: Sys.bg
    opacity: open ? 1 : 0
    visible: open || opacity > 0
    Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

    function applyVolume(v) {
        const clamped = Math.max(0, Math.min(150, Math.round(v)))
        if (ply && typeof ply.setVolume === "function")
            ply.setVolume(clamped)
    }

    function toggleMute() {
        if (volume > 0) {
            lastVolume = volume
            applyVolume(0)
        } else {
            applyVolume(lastVolume > 0 ? lastVolume : 70)
        }
    }

    function toggleLyrics() {
        lyricsVisible = !lyricsVisible
        if (typeof appcfg !== "undefined") {
            appcfg.set("npLyrics", lyricsVisible ? "1" : "0")
            appcfg.save()
        }
        console.log("[np] letra visible=" + lyricsVisible)
    }

    // Botón de pantalla completa. Emite la señal (por si Main.qml la conecta
    // más adelante) y, si `fullscreenFallback` sigue activo, alterna la
    // ventana con la misma función que usa Main.qml para que su estado interno
    // (`root.fullscreen`) no se desincronice.
    function doFullscreen() {
        np.fullscreenRequested()
        if (!np.fullscreenFallback)
            return
        const w = np.Window.window
        if (!w)
            return
        if (typeof w.toggleFullscreen === "function")
            w.toggleFullscreen()
        else
            w.visibility = (w.visibility === Window.FullScreen)
                ? Window.Windowed : Window.FullScreen
    }

    // Registro de geometría: permite comprobar por log que no hay desbordes.
    function logGeometry() {
        // Ignora el disparo inicial, antes de que la ventana tenga tamaño.
        if (np.width < 100 || np.height < 100)
            return
        const fixed = coverWrap.height + titleCol.height + progressCol.height
                      + transportRow.height + bodyCol.spacing * 4
        const letra = lyricsSlot.visible ? lyricsSlot.height : 0
        const total = fixed + letra
        console.log("[np] geom", "win=" + np.width + "x" + np.height,
                    "contentW=" + Math.round(contentW),
                    "cover=" + Math.round(coverWrap.height),
                    "fijo=" + Math.round(fixed),
                    "disponible=" + Math.round(npBody.height),
                    "letra=" + Math.round(letra),
                    "letraW=" + Math.round(lyricsSlot.width),
                    "letraTop=" + Math.round(lyricsTopY),
                    "resplandor=" + Math.round(glowH),
                    total <= npBody.height + 1 ? "OK" : "DESBORDE")
    }

    // subtle top glow
    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: np.glowH
        gradient: Gradient {
            GradientStop { position: 0.0; color: Sys.surface }
            GradientStop { position: 1.0; color: Sys.bg }
        }
    }

    // ---- cortafuegos de clicks ----------------------------------------
    // Esta vista es un overlay a pantalla completa (z:65) que, en sus zonas
    // vacías, NO acepta el ratón: sin este área los clicks "atraviesan" la
    // vista y caen en el PlayerBar, la cola o la barra lateral que quedan
    // DEBAJO, disparando sus botones (de ahí que un click en la letra o en
    // el fondo saltara de pista). Se traga todo lo que no consuman los
    // hijos declarados después (cabecera, progreso, letra, controles).
    MouseArea {
        id: shieldMa
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    }

    // ---- header --------------------------------------------------------
    RowLayout {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.s6
        anchors.rightMargin: Theme.s6
        anchors.topMargin: Theme.s5
        height: 40
        spacing: Theme.s3

        Glyph {
            Layout.alignment: Qt.AlignVCenter
            width: 17
            height: 17
            kind: "expand"
            color: Sys.accent
        }
        Text {
            Layout.alignment: Qt.AlignVCenter
            text: "EN REPRODUCCIÓN"
            color: Sys.textDim
            font.pixelSize: Theme.tSm
            font.weight: Font.DemiBold
            font.letterSpacing: 1.2
        }
        Item { Layout.fillWidth: true }

        // ---- volumen: mute + barra + porcentaje ------------------------
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 34
            height: 34
            radius: Theme.rMd
            color: muteMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 17
                height: 17
                kind: np.volume > 0 ? "volume" : "volume-x"
                color: np.volume > 0 ? Sys.textDim : Sys.accent
            }
            MouseArea {
                id: muteMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: np.toggleMute()
            }
        }

        Rectangle {
            id: volTrack
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 110
            height: 16
            color: "transparent"
            visible: np.width >= 760

            readonly property real max: 150          // player.volume: 0..150
            readonly property real ratio: Math.min(1, np.volume / max)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: Theme.mix(Sys.surface, Sys.text, 0.16)
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * volTrack.ratio
                height: 4
                radius: 2
                color: Sys.accent
            }
            Rectangle {
                x: parent.width * volTrack.ratio - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 11
                height: 11
                radius: 5.5
                color: Sys.accent
                scale: volMa.containsMouse ? 1.15 : 0.9
                Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
            }
            MouseArea {
                id: volMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                function setAt(mouse) {
                    const r = Math.max(0, Math.min(1, mouse.x / width))
                    np.applyVolume(r * volTrack.max)
                }
                onPressed: (mouse) => setAt(mouse)
                onPositionChanged: (mouse) => { if (pressed) setAt(mouse) }
            }
        }

        Text {
            Layout.alignment: Qt.AlignVCenter
            visible: np.width >= 760
            text: Math.round(np.volume / 1.5) + "%"
            color: Sys.textDim
            font.pixelSize: Theme.tSm
        }

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 1
            height: 22
            color: Sys.borderSubtle
            visible: np.width >= 760
        }

        // ---- mostrar/ocultar letra -------------------------------------
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 36
            height: 36
            radius: Theme.rMd
            color: (!np.lyricsVisible || lyricsMa.containsMouse)
                   ? Theme.hover(Sys.bg) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            border.width: np.lyricsVisible ? 0 : 1
            border.color: Sys.accent
            Glyph {
                anchors.centerIn: parent
                width: 16
                height: 16
                kind: "lyrics"
                color: (np.lyricsVisible || lyricsMa.containsMouse)
                       ? Sys.accent : Sys.textDim
            }
            MouseArea {
                id: lyricsMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: np.toggleLyrics()
            }
        }

        // ---- pantalla completa -----------------------------------------
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 36
            height: 36
            radius: Theme.rMd
            color: fsMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 16
                height: 16
                kind: "expand"
                color: fsMa.containsMouse ? Sys.accent : Sys.textDim
            }
            MouseArea {
                id: fsMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: np.doFullscreen()
            }
        }

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 36
            height: 36
            radius: Theme.rMd
            color: closeMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 16
                height: 16
                kind: "chevron-down"
                color: closeMa.containsMouse ? Sys.accent : Sys.textDim
            }
            MouseArea {
                id: closeMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: np.closeRequested()
            }
        }
    }

    // ---- body ----------------------------------------------------------
    Item {
        id: npBody
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: Theme.s4
        anchors.leftMargin: Theme.s6
        anchors.rightMargin: Theme.s6
        anchors.bottomMargin: Theme.s5

        // Caja central: ancho `contentW`, centrada horizontalmente. Dentro,
        // cada bloque se centra con Layout.alignment.
        ColumnLayout {
            id: bodyCol
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: np.contentW
            spacing: Theme.s3

            // ---- 1) portada --------------------------------------------
            Item {
                id: coverWrap
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: np.coverSize
                Layout.preferredHeight: np.coverSize
                // Techo explícito: la portada nunca invade el hueco de la
                // letra (np.coverCap ya descuenta el resto de bloques).
                Layout.maximumWidth: np.contentW
                Layout.maximumHeight: np.coverCap
                Layout.minimumHeight: 96
                scale: np.open ? 1 : 0.94
                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.slowMs
                        easing.type: Easing.OutCubic
                    }
                }

                Rectangle {
                    id: bigCover
                    anchors.fill: parent
                    radius: Theme.rXl
                    color: Sys.surfaceAlt
                    clip: true
                    Image {
                        id: bigCoverImg
                        anchors.fill: parent
                        source: np.thumb
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                    }
                    LotusMark {
                        anchors.centerIn: parent
                        width: 96
                        height: 90
                        petalColor: Sys.accent
                        visible: bigCoverImg.status !== Image.Ready
                    }
                }
            }

            // ---- 2) título / artista -----------------------------------
            ColumnLayout {
                id: titleCol
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.s1
                Text {
                    Layout.fillWidth: true
                    text: np.title.length ? np.title : "—"
                    color: Sys.text
                    font.pixelSize: Theme.t2xl
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: np.artist.length ? np.artist : "—"
                    color: Sys.textDim
                    font.pixelSize: Theme.tMd
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }
            }

            // ---- 3) LETRA (hueco central, sin tarjeta) -------------------
            // Ocupa el espacio que sobra ENTRE título/artista y la barra de progreso.
            // Va directamente sobre el fondo de la vista: sin
            // caja, sin borde, sin fondo propio y sin cabecera. La anchura
            // se acota a `maxLyricsW` y LyricsView centra la línea activa
            // tanto horizontal como verticalmente dentro del hueco.
            Item {
                id: lyricsSlot
                visible: np.lyricsVisible
                Layout.fillHeight: true
                Layout.minimumHeight: 0
                Layout.preferredHeight: np.lyricsReserve
                Layout.preferredWidth: Math.min(np.maxLyricsW, np.contentW)
                Layout.alignment: Qt.AlignHCenter

                LyricsView {
                    anchors.fill: parent
                    lineSize: 19
                    maxLineWidth: np.maxLyricsW
                    // El resplandor superior termina justo encima de este
                    // bloque, así que a este altura el fondo es Sys.bg plano.
                    edgeColor: Sys.bg
                }

            }

            // Si la letra está oculta, este bloque absorbe el hueco que le
            // tocaría a lyricsSlot; solo uno de los dos es visible nunca.
            Item {
                id: lyricSpacer
                visible: !np.lyricsVisible
                Layout.fillHeight: true
                Layout.minimumHeight: 0
            }

            // ---- 5) progreso (bajo la letra, estilo Sonora) --------------
            ColumnLayout {
                id: progressCol
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.s2

                Rectangle {
                    id: npTrack
                    Layout.fillWidth: true
                    height: 16
                    color: "transparent"

                    readonly property real ratio: np.duration > 0
                        ? Math.min(1, (np.scrubbing ? np.scrubPos : np.position)
                                     / np.duration) : 0

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 4
                        radius: 2
                        color: Theme.mix(Sys.surface, Sys.text, 0.16)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * npTrack.ratio
                        height: 4
                        radius: 2
                        color: Sys.accent
                    }
                    Rectangle {
                        x: parent.width * npTrack.ratio - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12
                        height: 12
                        radius: 6
                        color: Sys.accent
                        scale: npSeek.containsMouse || np.scrubbing ? 1.2 : 0.9
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    }
                    MouseArea {
                        id: npSeek
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        function posAt(mouse) {
                            return Math.max(0, Math.min(1, mouse.x / width))
                                   * np.duration
                        }
                        onPressed: (mouse) => {
                            np.scrubbing = true
                            np.scrubPos = posAt(mouse)
                        }
                        onPositionChanged: (mouse) => {
                            if (np.scrubbing)
                                np.scrubPos = posAt(mouse)
                        }
                        onReleased: (mouse) => {
                            np.scrubbing = false
                            if (np.duration > 0)
                                np.seekRequested(posAt(mouse))
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: Theme.mmss(np.scrubbing ? np.scrubPos : np.position)
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: Theme.mmss(np.duration)
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                    }
                }
            }

            // ---- 6) transporte -----------------------------------------
            RowLayout {
                id: transportRow
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.s3

                Rectangle {
                    width: 40
                    height: 40
                    radius: width / 2
                    color: np.shuffle ? Sys.accentDim
                           : (shuffleMaN.containsMouse ? Theme.hover(Sys.bg) : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 18
                        height: 18
                        kind: "shuffle"
                        color: np.shuffle ? Sys.accent
                               : (shuffleMaN.containsMouse ? Sys.accent : Sys.textDim)
                    }
                    MouseArea {
                        id: shuffleMaN
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: np.shuffleToggled()
                    }
                }
                Rectangle {
                    width: 44
                    height: 44
                    radius: width / 2
                    color: prevMaN.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        kind: "prev"
                        color: Sys.text
                    }
                    MouseArea {
                        id: prevMaN
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: np.prevRequested()
                    }
                }
                Rectangle {
                    width: 60
                    height: 60
                    radius: width / 2
                    color: playMaN.containsMouse ? Qt.lighter(Sys.accent, 1.12)
                           : Sys.accent
                    scale: playMaN.pressed ? 0.94
                           : (playMaN.containsMouse ? 1.04 : 1)
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 24
                        height: 24
                        kind: np.playing ? "pause" : "play"
                        color: Sys.onAccent
                    }
                    MouseArea {
                        id: playMaN
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: np.toggleRequested()
                    }
                }
                Rectangle {
                    width: 44
                    height: 44
                    radius: width / 2
                    color: nextMaN.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        kind: "next"
                        color: Sys.text
                    }
                    MouseArea {
                        id: nextMaN
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: np.nextRequested()
                    }
                }
                Rectangle {
                    width: 40
                    height: 40
                    radius: width / 2
                    color: np.repeat ? Sys.accentDim
                           : (repeatMaN.containsMouse ? Theme.hover(Sys.bg) : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 18
                        height: 18
                        kind: "repeat"
                        color: np.repeat ? Sys.accent
                               : (repeatMaN.containsMouse ? Sys.accent : Sys.textDim)
                    }
                    MouseArea {
                        id: repeatMaN
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: np.repeatToggled()
                    }
                }
            }

        }
    }

    onWidthChanged: Qt.callLater(logGeometry)
    onHeightChanged: Qt.callLater(logGeometry)
    onOpenChanged: if (open) Qt.callLater(logGeometry)
    Component.onCompleted: logGeometry()


}
