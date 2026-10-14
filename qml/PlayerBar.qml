import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Barra de reproducción: tarjeta FLOTANTE ultra fina (Theme.playerBarH = 56)
// con 8 px de margen exterior. El item raíz vive en un ColumnLayout a ancho
// completo, así que el margen se dibuja DENTRO (la tarjeta es la que flota).
//
// Contenido: portada + título/artista, transporte compacto (acento solo en
// play), progreso fino de 2 px con tiempos discretos, dos botones callados
// (cola y letras) y volumen mínimo. Sin sombras ni capas extra.
Rectangle {
    id: bar

    property bool playing: false
    property real position: 0
    property real duration: 0
    property string title: ""
    property string artist: ""
    property string currentThumb: ""
    property int volume: 70
    property bool shuffle: false
    property bool repeat: false
    // videoId de la pista actual + estado de "me gusta" (YouTube Music).
    property string videoId: ""
    property bool liked: false
    // ¿Hay sesión de YT Music? (habilita like / añadir a lista)
    property bool canInteract: false

    signal toggle()
    signal nextRequested()
    signal prevRequested()
    signal shuffleToggled()
    signal repeatToggled()
    signal lyricsRequested()
    signal queueRequested()
    signal lyricsPanelRequested()
    signal seekRequested(real seconds)
    signal volumeWanted(int value)
    signal likeRequested()
    signal addToPlaylistRequested()

    property bool scrubbing: false
    property real scrubPos: 0

    // Altura del item = tarjeta + 2 márgenes (8 px arriba y abajo).
    implicitHeight: Theme.playerBarH + Theme.s2 * 2
    color: "transparent"

    readonly property color _ui: Theme.hover(Sys.surface)

    // LOCAL vs STREAM sin llamadas nuevas al backend: las pistas de YouTube
    // llegan con `videoId` (y portada remota); los ficheros locales, no.
    readonly property bool isStream: String(bar.videoId || "").length > 0
        || String(bar.currentThumb || "").toLowerCase().indexOf("http") === 0

    // ---- botón de icono reutilizable ---------------------------------
    component BarButton: Rectangle {
        id: bb
        property string kind: "play"
        property bool active: false
        property color iconColor: Sys.textDim
        property int diameter: 30
        property real glyph: 15
        signal tapped()
        width: diameter
        height: diameter
        radius: diameter / 2
        color: (bbHover.hovered || bb.active) ? bar._ui : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        HoverHandler { id: bbHover; cursorShape: Qt.PointingHandCursor }
        Glyph {
            anchors.centerIn: parent
            width: bb.glyph
            height: bb.glyph
            kind: bb.kind
            weight: 1.6
            color: bb.active ? Sys.accent
                   : (bbHover.hovered ? Sys.text : bb.iconColor)
        }
        TapHandler { onTapped: bb.tapped() }
    }

    // ---- tarjeta flotante --------------------------------------------
    Rectangle {
        id: card
        anchors.fill: parent
        anchors.margins: Theme.s2
        radius: Theme.rLg
        color: Sys.surface
        border.width: 1
        border.color: Sys.border
        clip: true

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.s3
            anchors.rightMargin: Theme.s3
            anchors.topMargin: Theme.s1
            anchors.bottomMargin: Theme.s1
            spacing: Theme.s3

            // ---- ahora suena (izquierda) ----------------------------
            RowLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 150
                Layout.alignment: Qt.AlignVCenter
                spacing: Theme.s2

                Item {
                    Layout.alignment: Qt.AlignVCenter
                    width: 40
                    height: 40
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rMd
                        color: Sys.surfaceAlt
                        clip: true
                        Image {
                            id: coverImg
                            anchors.fill: parent
                            source: bar.currentThumb
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: status === Image.Ready
                            sourceSize.width: 120
                            sourceSize.height: 120
                        }
                        LotusMark {
                            anchors.centerIn: parent
                            width: 20
                            height: 19
                            petalColor: Sys.accent
                            active: bar.playing
                            visible: coverImg.status !== Image.Ready
                        }
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: bar.lyricsRequested() }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text {
                        Layout.fillWidth: true
                        text: bar.title.length ? bar.title : "Sin nada en cola"
                        color: bar.title.length ? Sys.text : Sys.textDim
                        font.pixelSize: Theme.tBase
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                    Text {
                        Layout.fillWidth: true
                        text: bar.artist.length ? bar.artist : "—"
                        color: Sys.textDim
                        font.pixelSize: Theme.tMd
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }
            }

            // ---- transporte + progreso (centro) ---------------------
            ColumnLayout {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 320
                Layout.maximumWidth: 420
                Layout.minimumWidth: 180
                spacing: 2

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.s2

                    BarButton {
                        diameter: 30; glyph: 15
                        kind: "prev"
                        iconColor: Sys.text
                        onTapped: bar.prevRequested()
                    }

                    Rectangle {
                        width: 32
                        height: 32
                        radius: 16
                        color: playHover.hovered ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                        scale: playHover.pressed ? 0.94 : (playHover.hovered ? 1.04 : 1)
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: playHover; cursorShape: Qt.PointingHandCursor }
                        Glyph {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: 1
                            width: 16
                            height: 16
                            kind: bar.playing ? "pause" : "play"
                            color: Sys.onAccent
                        }
                        TapHandler { onTapped: bar.toggle() }
                    }

                    BarButton {
                        diameter: 30; glyph: 15
                        kind: "next"
                        iconColor: Sys.text
                        onTapped: bar.nextRequested()
                    }
                }

                // ---- progreso (línea fina de 2 px) ------------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2

                    Text {
                        text: Theme.mmss(bar.scrubbing ? bar.scrubPos : bar.position)
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        Layout.preferredWidth: 32
                        horizontalAlignment: Text.AlignRight
                    }

                    Rectangle {
                        id: scrubTrack
                        Layout.fillWidth: true
                        height: 10
                        color: "transparent"

                        readonly property real ratio: bar.duration > 0
                            ? Math.min(1, (bar.scrubbing ? bar.scrubPos : bar.position) / bar.duration) : 0

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: 2; radius: 1
                            color: Theme.mix(Sys.surface, Sys.text, 0.18)
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * scrubTrack.ratio
                            height: 2; radius: 1
                            color: Sys.accent
                        }
                        Rectangle {
                            x: parent.width * scrubTrack.ratio - width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8; height: 8; radius: 4
                            color: Sys.accent
                            scale: scrubArea.hovered || bar.scrubbing ? 1.05 : 0
                            Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                            HoverHandler { id: scrubArea }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            function posAt(mouse) {
                                return Math.max(0, Math.min(1, mouse.x / width)) * bar.duration
                            }
                            onPressed: (mouse) => { bar.scrubbing = true; bar.scrubPos = posAt(mouse) }
                            onPositionChanged: (mouse) => { if (bar.scrubbing) bar.scrubPos = posAt(mouse) }
                            onReleased: (mouse) => {
                                bar.scrubbing = false
                                if (bar.duration > 0) bar.seekRequested(posAt(mouse))
                            }
                            onCanceled: bar.scrubbing = false
                        }
                    }

                    Text {
                        text: Theme.mmss(bar.duration)
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        Layout.preferredWidth: 32
                    }
                }
            }

            // ---- derecha: etiqueta, panel y volumen ------------------
            RowLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: Theme.s2

                Item { Layout.fillWidth: true }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    visible: bar.title.length > 0
                    text: bar.isStream ? "STREAM" : "LOCAL"
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.0
                }

                BarButton {
                    diameter: 30; glyph: 15
                    kind: "queue"
                    onTapped: bar.queueRequested()
                }
                BarButton {
                    diameter: 30; glyph: 15
                    kind: "lyrics"
                    onTapped: bar.lyricsRequested()
                }

                // ---- volumen: mínimo (glifo + línea fina) ----------
                RowLayout {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: Theme.s1 + 2
                    visible: bar.width >= 700

                    Glyph {
                        Layout.alignment: Qt.AlignVCenter
                        width: 15; height: 15
                        kind: bar.volume > 0 ? "volume" : "volume-x"
                        weight: 1.6
                        color: Sys.textDim
                    }

                    Rectangle {
                        id: volTrack
                        Layout.preferredWidth: 84
                        Layout.alignment: Qt.AlignVCenter
                        height: 10
                        color: "transparent"

                        readonly property real max: 130
                        readonly property real ratio: Math.min(1, bar.volume / max)

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: 2; radius: 1
                            color: Theme.mix(Sys.surface, Sys.text, 0.18)
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * volTrack.ratio
                            height: 2; radius: 1
                            color: Sys.accent
                        }
                        Rectangle {
                            x: parent.width * volTrack.ratio - width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8; height: 8; radius: 4
                            color: Sys.accent
                            scale: volArea.hovered ? 1.05 : 0
                            Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                            HoverHandler { id: volArea }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            function setAt(mouse) {
                                const r = Math.max(0, Math.min(1, mouse.x / width))
                                bar.volumeWanted(Math.round(r * volTrack.max))
                            }
                            onPressed: (mouse) => setAt(mouse)
                            onPositionChanged: (mouse) => { if (pressed) setAt(mouse) }
                        }
                    }
                }
            }
        }
    }
}
