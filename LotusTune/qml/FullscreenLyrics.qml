import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Cinema (pantalla completa): la distribucion de la referencia.
//
//   +----------------------------------+---------------------------+
//   | portada                          |                           |
//   | titulo + corazon                 |        letra              |
//   | artista                          |  (voz principal izquierda, |
//   | ---- progreso ---- 5:30    8:00  |   segunda voz a la derecha)|
//   | aleatorio < > play > ↻  volumen  |                           |
//   +----------------------------------+---------------------------+
//
// El bloque de la izquierda es `CinemaLeft.qml` (se usa tambien, apilado,
// en el movil, donde no caben dos columnas). El transporte vive DENTRO de
// la vista (el cinema tapa la barra: `bottomInset` = 0 en Main.qml), asi
// que la pantalla se basta sola. Cerrar va arriba a la derecha, con la
// cola a su izquierda.
//
// La letra es `LyricsView` - el mismo motor que el panel y Now Playing -
// con `duetSides: true`: cuando la fuente marca dos voces, las frases de
// la segunda salen desde el lado derecho, como en Sonora.
Rectangle {
    id: fl
    anchors.fill: parent
    // Geometry: Main lowers the overlay by `bottomInset` so the normal
    // floating PlayerBar pokes into the window UNTOUCHED (it keeps being
    // the one true transport: nothing here is re-hardcoded).
    anchors.bottomMargin: fl.bottomInset
    color: "transparent"
    visible: opacity > 0.01
    // Al bajar con el dedo la vista se desvanece un poco: el movimiento y
    // la transparencia cuentan la misma historia.
    opacity: (open ? 1 : 0) * pullFade
    z: 72

    property bool open: false
    property string title: ""
    property string artist: ""
    property string thumb: ""
    // YouTube ID of the current track: the big artwork needs it to
    // ask for the sharp variants of the art (the API thumbnails come at
    // 120 px).
    property string videoId: ""
    property bool playing: false
    property real position: 0
    property real duration: 0
    // Kept for API compatibility even though the transport lives in the
    // (reused) PlayerBar now; Main still binds them.
    property bool shuffleOn: false
    property int repeatVal: 0
    property bool liked: false
    // Volumen del reproductor (0..130, el mismo rango que la barra). El
    // cinema no tenia control de volumen: habia que salir a la barra.
    property int volume: 70
    // Height the overlay must lift to leave the real playback bar visible
    // below (Main: bar height +, on the phone, tab bar + gap + margin).
    property real bottomInset: 0

    signal closeRequested()
    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)
    signal shuffleRequested()
    signal repeatRequested()
    signal likeRequested()
    // Volumen pedido desde el cinema (0..130).
    signal volumeWanted(int value)
    // La cola ya no vive en la barra: se abre desde aqui (arriba a la
    // derecha, simetrica con el boton de cerrar).
    signal queueRequested()
    // Right click on the artwork: the same track menu as in the lists
    // (radio, queue, library...). Click on the artist: open their page.
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)
    // Swipe-down on the artwork: closes the overlay (same as the back
    // button on the phone).
    signal swipeDown()

    // The properties (title/artist/thumb/videoId/…) are bound from
    // Main.qml to the current values, so the cinema keeps them fresh
    // while it is open: bindings update themselves (an imperative copy
    // here would kill the binding and freeze the cover and the title).
    Behavior on opacity {
        NumberAnimation { duration: Theme.slowMs; easing.type: Easing.OutCubic }
    }
    // Entra subiendo desde abajo (donde estaba la barra): el gesto de
    // arrastre y la vista completa son el mismo movimiento. Es un
    // translate (se resuelve en el compositor), no un relayout, asi que
    // va a la frecuencia de la pantalla (120 Hz si el movil la tiene).
    property real revealOffset: fl.open ? 0 : fl.height * 0.14
    Behavior on revealOffset {
        NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
    }

    // ---- arrastrar hacia abajo: cerrar ------------------------------
    // El gesto de entrada, al reves: la vista baja con el dedo y, si se
    // pasa del umbral, se cierra sola. Vale en la portada, el titulo, el
    // fondo y (por el rebote de la letra) tambien sobre la letra. Las
    // animaciones son transform/opacity: van a la frecuencia de pantalla.
    property real pullDown: 0
    readonly property real pullLimit: fl.height * 0.45
    readonly property real pullFade: 1 - Math.min(0.85, fl.pullDown / (fl.height * 0.6))
    NumberAnimation {
        id: pullBack
        target: fl
        property: "pullDown"
        to: 0
        duration: 200
        easing.type: Easing.OutCubic
    }
    // Soltar pasado el umbral: la vista SIGUE bajando mientras se funde.
    // Antes, al cerrar se ponia pullDown a 0 de golpe y la vista subia de
    // vuelta para luego desaparecer: ese era el salto que se veia.
    NumberAnimation {
        id: closeOut
        target: fl
        property: "pullDown"
        to: fl.height * 0.55
        duration: 240
        easing.type: Easing.OutCubic
        onStopped: fl.pullDown = 0
    }
    onOpenChanged: {
        if (fl.open) {
            closeOut.stop()
            fl.pullDown = 0
        } else if (!closeOut.running) {
            fl.pullDown = 0
        }
    }


    transform: Translate { y: fl.revealOffset + fl.pullDown }

    readonly property bool isPhone: Qt.platform.os === "android"

    // Same veil the wash uses under the lyrics: the edge washes must sit
    // on the colour the eye sees. It was a hard coded deep blue (#1b2a44),
    // which is exactly why the cinema mode did not match the desktop
    // palette: now it is the palette accent mixed over the background.
    readonly property color veilColor: Theme.sAccent(Sys.bg, Sys.accent, 0.10)

    // ---- artwork wash -----------------------------------------------------
    // The cinema mode is an overlay on top of the app: it needs its own
    // opaque background, otherwise the page behind shows through while
    // the wash is being recomputed (when the track changes).
    Rectangle {
        anchors.fill: parent
        color: Sys.bg
    }
    // REAL blur done in the backend (CPU): a soft veil that, stretched over
    // the whole screen, comes out without blocks but still lets you
    // recognise the artwork.
    Image {
        id: washImg
        anchors.fill: parent
        // Same wash the app menu uses: "image://wash/<serial>" tracks the
        // current artwork. Here it follows the cinema's OWN thumb property
        // (bound from Main.qml): referencing ids of another file (`root`)
        // does not resolve reliably in QML. The wash content is refreshed
        // by the backend on every track change, whatever the "dynamic
        // background" setting of the main view is.
        source: fl.open && fl.thumb ? "image://wash/" + wash.serial : ""
        // STRETCHED, not cropped: the veil adapts to the window so the
        // artwork covers the 100 % of it (cropped, a tall window only showed
        // the middle of the art with dark edges on the sides).
        fillMode: Image.Stretch
        smooth: true
        asynchronous: true
        cache: false
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.slowMs } }
    }
    // Veil: the app background mixed with a deep blue so the cinema mode is
    // colder and crisper than the other windows.
    Rectangle {
        anchors.fill: parent
        color: fl.veilColor
        opacity: 0.66
    }
    // Click eater: the cinema mode has no colour of its own, so clicks on
    // any gap without a control or lyrics went through the window and
    // landed on the playlist behind. This one keeps whatever nobody else
    // wants. It ends where the real playback bar begins (the bar is OUTSIDE
    // this overlay, it must keep its clicks).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        z: -1
    }
    // Accent aura at the bottom, very faint: it fades just above the hole
    // where the floating bar shows through.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(240, parent.height * 0.32)
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.alpha(Sys.accent, 0.10) }
        }
    }

    // ---- fondo arrastrable (bajar = cerrar) -------------------------------
    // Detras del contenido: los botones y la letra reciben el toque primero,
    // asi que este MouseArea solo actua en el fondo. Antes habia un
    // DragHandler global que se quedaba con el gesto y dejaba botones como
    // "siguiente" sin respuesta.
    Item {
        id: sheetDrag
        anchors.fill: parent
        z: -1
        property real startY: 0
        property bool active: false
        property real translation: 0

        MouseArea {
            anchors.fill: parent
            function sceneY(m) { return mapToItem(null, m.x, m.y).y }
            onPressed: (m) => {
                sheetDrag.startY = sceneY(m)
                sheetDrag.active = false
                sheetDrag.translation = 0
            }
            onPositionChanged: (m) => {
                if (!pressed)
                    return
                const dy = sceneY(m) - sheetDrag.startY
                if (!sheetDrag.active && dy > 12)
                    sheetDrag.active = true
                if (sheetDrag.active) {
                    sheetDrag.translation = dy
                    fl.pullDown = Math.max(0, Math.min(fl.pullLimit, dy))
                }
            }
            onReleased: {
                if (sheetDrag.active && fl.pullDown > 110) {
                    if (typeof sfx !== "undefined")
                        sfx.play("tap")
                    closeOut.start()
                    fl.closeRequested()
                } else if (fl.pullDown > 0) {
                    pullBack.start()
                }
                sheetDrag.active = false
                sheetDrag.translation = 0
            }
            onCanceled: {
                if (fl.pullDown > 0)
                    pullBack.start()
                sheetDrag.active = false
                sheetDrag.translation = 0
            }
        }
    }

    // ---- contenido: info a la IZQUIERDA, letra a la DERECHA ---------------
    // La distribucion de la referencia: la portada con el titulo, el
    // artista, el progreso y los controles debajo, en una columna; la
    // letra ocupa la otra mitad, mas ancha. En el movil no caben dos
    // columnas: el panel se apila arriba y la letra debajo.
    Item {
        id: content
        anchors.fill: parent
        anchors.leftMargin: Theme.panelMargin + Theme.s4
        anchors.rightMargin: Theme.panelMargin + Theme.s4
        anchors.topMargin: fl.isPhone ? Theme.s5 : Theme.s4
        anchors.bottomMargin: fl.isPhone ? Theme.s5 + Theme.s3 : Theme.s5

        readonly property bool wide: width >= 720
        readonly property real leftW: Math.min(420, Math.round(width * 0.36))
        readonly property real coverSize: Math.round(
            Theme.clamp(Math.min(leftW - Theme.s2, height * 0.46), 120, 360))

        // ---- ESCRITORIO: dos columnas ----------------------------------
        RowLayout {
            anchors.fill: parent
            visible: content.wide
            spacing: Math.max(24, Math.round(content.width * 0.05))

            CinemaLeft {
                id: left
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: content.leftW

                title: fl.title
                artist: fl.artist
                thumb: fl.thumb
                videoId: fl.videoId
                playing: fl.playing
                position: fl.position
                duration: fl.duration
                shuffleOn: fl.shuffleOn
                repeatVal: fl.repeatVal
                liked: fl.liked
                volume: fl.volume
                coverSize: content.coverSize
                centered: false

                onToggleRequested: fl.toggleRequested()
                onNextRequested: fl.nextRequested()
                onPrevRequested: fl.prevRequested()
                onSeekRequested: (secs) => fl.seekRequested(secs)
                onShuffleRequested: fl.shuffleRequested()
                onRepeatRequested: fl.repeatRequested()
                onLikeRequested: fl.likeRequested()
                onVolumeWanted: (v) => fl.volumeWanted(v)
                onTrackMenuRequested: (x, y) => fl.trackMenuRequested(x, y)
                onArtistRequested: (name) => fl.artistRequested(name)
            }

            // Letra: la columna de la derecha, alineada a la izquierda y
            // con las voces a los lados cuando la fuente marca dueto.
            LyricsView {
                id: lyric
                Layout.fillWidth: true
                Layout.fillHeight: true
                lineSize: Math.max(20, Math.min(30, Math.round(content.height / 32)))
                activeBoost: Math.round(lineSize * 0.20)
                maxLineWidth: 860
                edgeColor: fl.veilColor
                leftAlign: true
                duetSides: true
                pinFrac: 0.36
                pillTop: true
                syncAdjustAllowed: false
                pillShown: false
            }
        }

        // ---- MOVIL: una columna ----------------------------------------
        ColumnLayout {
            anchors.fill: parent
            visible: !content.wide
            spacing: Theme.s3

            CinemaLeft {
                id: leftPhone
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter

                title: fl.title
                artist: fl.artist
                thumb: fl.thumb
                videoId: fl.videoId
                playing: fl.playing
                position: fl.position
                duration: fl.duration
                shuffleOn: fl.shuffleOn
                repeatVal: fl.repeatVal
                liked: fl.liked
                volume: fl.volume
                coverSize: Math.min(168, Math.round(content.width * 0.46))
                centered: true

                onToggleRequested: fl.toggleRequested()
                onNextRequested: fl.nextRequested()
                onPrevRequested: fl.prevRequested()
                onSeekRequested: (secs) => fl.seekRequested(secs)
                onShuffleRequested: fl.shuffleRequested()
                onRepeatRequested: fl.repeatRequested()
                onLikeRequested: fl.likeRequested()
                onVolumeWanted: (v) => fl.volumeWanted(v)
                onTrackMenuRequested: (x, y) => fl.trackMenuRequested(x, y)
                onArtistRequested: (name) => fl.artistRequested(name)
            }

            LyricsView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                lineSize: Math.max(20, Math.min(28, Math.round(content.height / 34)))
                activeBoost: Math.round(lineSize * 0.20)
                maxLineWidth: Math.min(content.width * 0.86, 720)
                edgeColor: fl.veilColor
                leftAlign: false
                duetSides: true
                pinFrac: 0.34
                pillTop: true
                syncAdjustAllowed: false
                pillShown: false
            }
        }
    }

    // ---- cerrar (arriba a la DERECHA) + cola -------------------------------
    // La referencia pone el boton de cerrar en la esquina superior derecha;
    // la cola queda a su izquierda, como una pareja de acciones de la
    // ventana. Back/Esc sigue cerrando tambien (goBack de Main).
    Rectangle {
        id: closeBtn
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: Theme.s5
        anchors.topMargin: Theme.s4
        width: 38
        height: 38
        radius: Theme.rMd
        color: exitMa.containsMouse ? Theme.sAccentHi(Sys.bg, Sys.accent)
                                    : Theme.alpha(Sys.text, 0.08)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        scale: exitMa.pressed ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
        Glyph {
            anchors.centerIn: parent
            width: 16
            height: 16
            kind: "x"
            color: Sys.text
            weight: 1.9
        }
        MouseArea {
            id: exitMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined")
                    sfx.play("tap")
                fl.closeRequested()
            }
        }
    }

    Rectangle {
        id: queueBtn
        anchors.right: closeBtn.left
        anchors.top: parent.top
        anchors.rightMargin: Theme.s2
        anchors.topMargin: Theme.s4
        width: 38
        height: 38
        radius: Theme.rMd
        color: queueMa.containsMouse ? Theme.sAccentHi(Sys.bg, Sys.accent)
                                     : Theme.alpha(Sys.text, 0.08)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        scale: queueMa.pressed ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
        Glyph {
            anchors.centerIn: parent
            width: 19
            height: 19
            kind: "queue"
            color: Sys.text
            weight: 1.8
        }
        MouseArea {
            id: queueMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined")
                    sfx.play("tap")
                fl.queueRequested()
            }
        }
    }
}
