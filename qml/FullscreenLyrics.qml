import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Letra a pantalla completa (modo cine). El reparto es el del reproductor de
// referencia: columna izquierda con la portada, el título y la artista, el
// progreso, el transporte y el volumen; a la derecha, la letra leída grande y
// alineada por la izquierda. Arriba a la izquierda el botón de recogida
// (flecha abajo) y arriba al centro la pastilla de compensación de tiempo.
// La columna izquierda es fija: no se esconde nunca (como en el repo base).
//
// La letra es `LyricsView` —el mismo motor que el panel y Now Playing— para
// que lo que ve el usuario aquí, en el panel y en los widgets del escritorio
// (que leen el estado que publica la app) sea literalmente la misma
// representación.
Rectangle {
    id: fl
    anchors.fill: parent
    color: "transparent"
    visible: opacity > 0.01
    opacity: open ? 1 : 0
    z: 72

    property bool open: false
    property string title: ""
    property string artist: ""
    property string thumb: ""
    // ID de YouTube de la pista actual: la portada grande del cine lo necesita
    // para pedir las variantes nítitas del arte (las miniaturas de la API van
    // a 120 px).
    property string videoId: ""
    property bool playing: false
    property real position: 0
    property real duration: 0
    // Estado real del reproductor para los conmutadores del transporte.
    property bool shuffleOn: false
    property int repeatVal: 0
    property bool liked: false

    signal closeRequested()
    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)
    signal shuffleRequested()
    signal repeatRequested()
    signal likeRequested()
    // Clic derecho sobre la columna de la pista: mismo menú de canción que en
    // las listas (radio, cola, biblioteca…). Clic en el artista: ir a su página.
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)

    Behavior on opacity {
        NumberAnimation { duration: Theme.slowMs; easing.type: Easing.OutCubic }
    }

    readonly property var ply: (typeof player !== "undefined") ? player : null

    // ---- lavado de portada ------------------------------------------------
    // Desenfoque REAL hecho en el backend (CPU): vela suave que, estirada a
    // toda la pantalla, sale sin bloques pero dejando reconocer la portada.
    Image {
        id: washImg
        anchors.fill: parent
        source: fl.open && fl.thumb ? "image://wash/" + wash.serial : ""
        fillMode: Image.PreserveAspectCrop
        smooth: true
        asynchronous: true
        cache: false
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.slowMs } }
    }
    // Velo: fondo de la app mezclado con un azul profundo para que el modo
    // cine sea más frío y nítido que el resto de ventanas. Bajo la letra, el
    // velo que exige el contraste; sobre la columna, la portada manda.
    Rectangle {
        anchors.fill: parent
        color: Theme.mix(Sys.bg, "#1b2a44", 0.28)
        opacity: 0.66
    }
    // Tocho anti-pasada: el cine no tiene color propio, así que los clics en
    // cualquier hueco sin mando ni letra atravesaban la ventana y acababan en
    // la playlist de detrás. Éste se queda los que nadie más quiera.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        z: -1
    }
    // Aura de acento en la parte baja, muy tenue.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(280, parent.height * 0.34)
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.alpha(Sys.accent, 0.10) }
        }
    }

    // Zona de clic derecho sobre la columna izquierda entera (portada, título
    // y artista): abre el menú de la pista. Sólo acepta el derecho, así que
    // no interfiere con botones ni con el arrastre de la letra.
    MouseArea {
        anchors.left: leftCol.left
        anchors.right: leftCol.right
        anchors.top: leftCol.top
        anchors.bottom: leftCol.bottom
        acceptedButtons: Qt.RightButton
        onClicked: {
            const p = mapToItem(null, mouse.x, mouse.y)
            fl.trackMenuRequested(p.x, p.y)
        }
    }

    // ---- letra ------------------------------------------------------------
    // Columna derecha, lectura por la izquierda y mucho más grande que en el
    // panel; la pastilla de sincronía sube al centro del encabezado y acompaña
    // siempre a la ventana (los mandos NO se esconden: como en el repo de
    // referencia, la columna izquierda es permanente).
    LyricsView {
        id: lyric
        objectName: "cine"
        anchors.left: leftCol.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.s6
        anchors.rightMargin: Theme.s4
        lineSize: Math.max(24, Math.min(36, Math.round(fl.width / 44)))
        activeBoost: Math.round(lineSize * 0.20)
        maxLineWidth: Math.min(fl.width * 0.52, 1180)
        edgeColor: Theme.mix(Sys.bg, "#1b2a44", 0.28)
        leftAlign: true
        pillTop: true
        pillShown: fl.open
    }

    // ---- columna izquierda: portada, datos y mandos ------------------------
    // Centrada en el borde izquierdo, con el ancho de la portada como regla.
    // Es PERMANENTE (como en el repo de referencia): no se esconde al mover el
    // ratón; la letra grande ya ocupa su propia columna a la derecha.
    ColumnLayout {
        id: leftCol
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Math.max(Theme.s5, Math.round(fl.width * 0.05))
        width: Math.round(Math.max(210, Math.min(fl.height * 0.40, fl.width * 0.30)))
        spacing: Theme.s4

        // Portada grande con el «me gusta» incrustado en la esquina inferior
        // izquierda (el puesto del «+» del repo de referencia). `ArtImage` se
        // encarga de la cascada de resolución (maxres → hq → miniatura) con el
        // ID REAL de la pista: las miniaturas de la API vienen a 120 px y aquí
        // la portada es enorme — sin cascada se pixelaba.
        Rectangle {
            id: coverBox
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: leftCol.width
            Layout.preferredHeight: leftCol.width
            radius: Theme.rXl
            color: Sys.surfaceAlt
            clip: true

            ArtImage {
                anchors.fill: parent
                src: fl.thumb
                videoId: fl.videoId
                // La portada del cine va con las esquinas redondeadas como
                // las tarjetas de Inicio.
                radiusSpec: Theme.rXl
                showIconWhenEmpty: false
            }
            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: Theme.s3
                width: 34
                height: 34
                radius: 17
                color: fl.liked ? Sys.accent : Theme.alpha(Sys.bg, 0.55)
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 17
                    height: 17
                    kind: fl.liked ? "heart" : "heart-outline"
                    color: fl.liked ? Sys.onAccent : Sys.text
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.likeRequested() }
                }
            }
        }

        // Pista y artista, centrados bajo la portada.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: fl.title.length ? fl.title : "—"
                color: Sys.text
                font.pixelSize: Theme.tLg
                font.weight: Font.Bold
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 6
                Glyph {
                    width: 12
                    height: 12
                    kind: "disc"
                    color: Sys.textDim
                    weight: 1.3
                }
                Text {
                    id: flArtist
                    property bool hot: flArtistHover.hovered
                    text: fl.artist.length ? fl.artist : "—"
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                    font.underline: flArtistHover.hovered
                    elide: Text.ElideRight
                    HoverHandler { id: flArtistHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("tap")
                            if (fl.artist.length)
                                fl.artistRequested(fl.artist)
                        }
                    }
                }
            }
        }

        // Progreso: tiempo · barra clicable · tiempo.
        Item {
            Layout.fillWidth: true
            Layout.topMargin: Theme.s2
            implicitHeight: 22
            height: 22

            Text {
                id: posLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Theme.mmss(track.scrubbing ? track.scrubSec : fl.position)
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                width: 38
            }
            Text {
                id: durLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: fl.duration > 0 ? Theme.mmss(fl.duration) : "0:00"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
            }
            Item {
                id: track
                anchors.left: posLabel.right
                anchors.right: durLabel.left
                anchors.leftMargin: Theme.s2
                anchors.rightMargin: Theme.s2
                anchors.verticalCenter: parent.verticalCenter
                height: 14
                // Arrastre con el botón pulsado: la barra, la bola y el reloj
                // siguen al cursor en vivo y el seek de verdad se pide al
                // soltar. Antes sólo había clic suelto y el «mantener y
                // deslizar» no hacía nada.
                property bool scrubbing: false
                property real scrubSec: 0
                readonly property real shown: scrubbing ? scrubSec : fl.position
                readonly property real frac: fl.duration > 0
                                             ? Theme.clamp(shown / fl.duration, 0, 1) : 0

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 4
                    radius: 2
                    color: Theme.alpha(Sys.text, 0.16)
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * parent.frac
                    height: 4
                    radius: 2
                    color: Sys.accent
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Math.max(0, parent.width * parent.frac - 5)
                    width: 10
                    height: 10
                    radius: 5
                    color: Sys.accent
                    visible: seekMa.pressed || seekMa.containsMouse
                }
                MouseArea {
                    id: seekMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    function secAt(mx) {
                        if (parent.width <= 0)
                            return 0
                        return Math.max(0, Math.min(1, mx / parent.width)) * fl.duration
                    }
                    onPressed: (mouse) => {
                        track.scrubbing = true
                        track.scrubSec = secAt(mouse.x)
                    }
                    onPositionChanged: (mouse) => {
                        if (track.scrubbing)
                            track.scrubSec = secAt(mouse.x)
                    }
                    onReleased: (mouse) => {
                        track.scrubbing = false
                        if (fl.duration > 0)
                            fl.seekRequested(secAt(mouse.x))
                    }
                    onCanceled: track.scrubbing = false
                }
            }
        }

        // Transporte: aleatorio · anterior · reproducir · siguiente · repetir.
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.s3

            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 18
                color: shMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    kind: "shuffle"
                    color: fl.shuffleOn ? Sys.accent : Sys.textDim
                }
                MouseArea {
                    id: shMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.shuffleRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 42
                Layout.preferredHeight: 42
                radius: 21
                color: prevMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    kind: "prev"
                    color: Sys.text
                }
                MouseArea {
                    id: prevMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.prevRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 52
                Layout.preferredHeight: 52
                radius: 26
                color: Sys.accent
                scale: playMa.containsMouse ? 1.05 : 1
                Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    kind: fl.playing ? "pause" : "play"
                    color: Sys.onAccent
                }
                MouseArea {
                    id: playMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.toggleRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 42
                Layout.preferredHeight: 42
                radius: 21
                color: nextMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    kind: "next"
                    color: Sys.text
                }
                MouseArea {
                    id: nextMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.nextRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 18
                color: rpMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    kind: fl.repeatVal === 2 ? "repeat-one" : "repeat"
                    color: fl.repeatVal > 0 ? Sys.accent : Sys.textDim
                }
                MouseArea {
                    id: rpMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.repeatRequested() }
                }
            }
        }

        // Volumen: altavoz y barra corta, centrados.
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.s1
            spacing: Theme.s2

            Glyph {
                width: 16
                height: 16
                kind: (fl.ply && fl.ply.volume > 0) ? "volume" : "volume-x"
                color: Sys.textDim
            }
            Item {
                Layout.preferredWidth: Math.round(leftCol.width * 0.46)
                Layout.preferredHeight: 16

                readonly property real frac: fl.ply ? Theme.clamp(fl.ply.volume / 100, 0, 1) : 0

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 3
                    radius: 2
                    color: Theme.alpha(Sys.text, 0.16)
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * parent.frac
                    height: 3
                    radius: 2
                    color: Sys.accent
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Math.max(0, parent.width * parent.frac - 4)
                    width: 8
                    height: 8
                    radius: 4
                    color: Sys.accent
                    visible: volMa.pressed || volMa.containsMouse
                }
                MouseArea {
                    id: volMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => {
                        if (fl.ply && parent.width > 0)
                            fl.ply.setVolume(Math.round(mouse.x / parent.width * 100))
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed && fl.ply && parent.width > 0)
                            fl.ply.setVolume(Math.round(Theme.clamp(mouse.x / parent.width, 0, 1) * 100))
                    }
                }
            }
        }
    }

    // ---- recogida (arriba a la izquierda, square suave) ---------------------
    // Flecha abajo en un cuadrado redondeado: deja el modo cine, en el mismo
    // puesto que en el repo de referencia.
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: Theme.s5
        anchors.topMargin: Theme.s4
        width: 38
        height: 38
        radius: Theme.rMd
        color: exitMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : Theme.alpha(Sys.text, 0.08)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        Glyph {
            anchors.centerIn: parent
            width: 20
            height: 20
            kind: "chevron-down"
            color: Sys.text
            weight: 1.8
        }
        MouseArea {
            id: exitMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.closeRequested() }
        }
    }

    // El modo cine ya no esconde los mandos: la columna izquierda es fija, la
    // letra y la portada conviven siempre (reparto del repo de referencia).
}
