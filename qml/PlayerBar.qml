import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Barra de reproducción: una isla flotante (Panel) baja y minimalista.
//
// El progreso va ARRIBA, a todo el ancho, en una línea fina: así debajo
// queda una sola fila de contenido (ficha a la izquierda, transporte en el
// centro, accesos a la derecha) y la barra puede ser baja sin que el
// transport se quede sin sitio. Nada de capas ni efectos extra.
Rectangle {
    id: bar

    property bool playing: false
    // Pista pedida pero aún sin sonar (resolviendo el stream): muestra un
    // estado de espera en la barra para que el arranque no parezca colgado.
    property bool loading: false
    property real position: 0
    property real duration: 0
    property string title: ""
    property string artist: ""
    property string currentThumb: ""
    property int volume: 70
    property bool shuffle: false
    // 0 = sin repetición, 1 = repetir lista, 2 = repetir canción.
    property int repeatMode: 0
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
    // Menú contextual de la pista (clic derecho sobre la ficha de la izquierda)
    // e ir al artista (clic sobre su nombre).
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)

    property bool scrubbing: false
    property real scrubPos: 0

    // Altura de la isla: la barra mide exactamente lo que su superficie.
    implicitHeight: Theme.playerBarH
    color: "transparent"

    readonly property color _ui: Theme.hover(Sys.surface)

    // ---- botón de icono reutilizable ---------------------------------
    component BarButton: Rectangle {
        id: bb
        property string kind: "play"
        property bool active: false
        property color iconColor: Sys.textDim
        property int diameter: 28
        property real glyph: 14
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
        TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bb.tapped() } }
    }

    // ---- isla flotante -----------------------------------------------
    Panel {
        id: island
        anchors.fill: parent
        // El contenido se recorta a las esquinas de la isla: la línea de
        // progreso de arriba acompaña el redondeo en vez de salirse.
        clipContent: true

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- progreso (línea fina, a todo el ancho) ---------------
            RowLayout {
                id: progressRow
                Layout.fillWidth: true
                Layout.preferredHeight: 18
                spacing: Theme.s2

                Text {
                    text: Theme.mmss(bar.scrubbing ? bar.scrubPos : bar.position)
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    Layout.preferredWidth: 30
                    horizontalAlignment: Text.AlignRight
                }

                Rectangle {
                    id: scrubTrack
                    Layout.fillWidth: true
                    height: 18
                    color: "transparent"

                    readonly property real ratio: bar.duration > 0
                        ? Math.min(1, (bar.scrubbing ? bar.scrubPos : bar.position) / bar.duration) : 0

                    // Carril.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width; height: 2; radius: 1
                        color: Theme.mix(Sys.surface, Sys.text, 0.18)
                    }
                    // Relleno.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * scrubTrack.ratio
                        height: 2; radius: 1
                        color: Sys.accent
                    }
                    // Pomo: sólo aparece al pasar el ratón o al arrastrar.
                    Rectangle {
                        x: parent.width * scrubTrack.ratio - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: Sys.accent
                        scale: scrubArea.hovered || bar.scrubbing ? 1.1 : 0
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
                    Layout.preferredWidth: 30
                }
            }

            // ---- contenido (una sola fila) ---------------------------
            Item {
                id: barRow
                Layout.fillWidth: true
                Layout.fillHeight: true
                // Aire a los lados: ni la ficha ni los controles tocan el
                // filo de la isla.
                anchors.leftMargin: Theme.s3
                anchors.rightMargin: Theme.s3
                property int gap: Theme.s3

                // ---- ahora suena (izquierda) ------------------------
                RowLayout {
                    id: leftSide
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.s2
                    // Anchura hasta el centro (deja el hueco del gap); igual que la
                    // derecha => el transporte queda siempre centrado, sin moverse
                    // con el ancho del título.
                    width: Math.max(0, (parent.width - centerCol.width) / 2 - Theme.s3)

                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        width: 30
                        height: 30
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rSm
                            color: Sys.surfaceAlt
                            // La portada se redondea por recorte en CPU
                            // (RoundedArt): el `clip` del Rectangle ignoraba el
                            // radio y la imagen salía cuadrada.
                            RoundedArt {
                                id: coverArt
                                anchors.fill: parent
                                source: bar.currentThumb
                                radiusSpec: Theme.rSm
                            }
                            LotusMark {
                                anchors.centerIn: parent
                                width: 16
                                height: 15
                                petalColor: Sys.accent
                                active: bar.playing
                                visible: !coverArt.ready
                            }
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); bar.lyricsRequested() } }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: bar.title.length ? bar.title : "Sin nada en cola"
                            color: bar.title.length ? Sys.text : Sys.textDim
                            font.pixelSize: Theme.tMd
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        Text {
                            id: barArtist
                            Layout.fillWidth: true
                            visible: !bar.loading
                            text: bar.artist.length ? bar.artist : "—"
                            color: Sys.textDim
                            font.pixelSize: Theme.tXs
                            font.underline: barArtistHover.hovered
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            HoverHandler { id: barArtistHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    if (typeof sfx !== "undefined")
                                        sfx.play("tap")
                                    if (bar.artist.length)
                                        bar.artistRequested(bar.artist)
                                }
                            }
                        }
                        // Estado de espera: punto que late + texto, con la misma
                        // altura que la línea de artista para no mover el layout.
                        Row {
                            Layout.fillWidth: true
                            visible: bar.loading
                            spacing: Theme.s2
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6; height: 6; radius: 3
                                color: Sys.accent
                                SequentialAnimation on opacity {
                                    running: bar.loading
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.25; duration: 520; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutSine }
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Cargando…"
                                color: Sys.textDim
                                font.pixelSize: Theme.tXs
                            }
                        }
                    }
                }

                // Clic derecho sobre la ficha de la pista (portada, título o
                // artista): abre el mismo menú que en las listas —reproducir,
                // radio, añadir a la cola, biblioteca…—.
                MouseArea {
                    anchors.left: leftSide.left
                    anchors.right: leftSide.right
                    anchors.top: leftSide.top
                    anchors.bottom: leftSide.bottom
                    acceptedButtons: Qt.RightButton
                    onClicked: {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        bar.trackMenuRequested(p.x, p.y)
                    }
                }

                // ---- transporte (centro) ------------------------------
                RowLayout {
                    id: centerCol
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.s1 + 2

                    BarButton {
                        kind: "shuffle"
                        active: bar.shuffle
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('toggle'); bar.shuffleToggled() }
                    }

                    BarButton {
                        kind: "prev"
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.prevRequested() }
                    }

                    Rectangle {
                        width: 30
                        height: 30
                        radius: 15
                        color: playHover.hovered ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                        scale: playHover.pressed ? 0.94 : (playHover.hovered ? 1.04 : 1)
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: playHover; cursorShape: Qt.PointingHandCursor }
                        Glyph {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: 1
                            width: 15
                            height: 15
                            kind: bar.playing ? "pause" : "play"
                            color: Sys.onAccent
                        }
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); bar.toggle() } }
                    }

                    BarButton {
                        kind: "next"
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.nextRequested() }
                    }

                    BarButton {
                        kind: bar.repeatMode === 2 ? "repeat-one" : "repeat"
                        active: bar.repeatMode !== 0
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('toggle'); bar.repeatToggled() }
                    }
                }

                // ---- derecha: accesos y volumen -----------------------
                RowLayout {
                    id: rightSide
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.s1
                    width: Math.max(0, (parent.width - centerCol.width) / 2 - Theme.s3)

                    Item { Layout.fillWidth: true }

                    BarButton {
                        kind: bar.liked ? "heart" : "heart-outline"
                        active: bar.liked
                        iconColor: bar.canInteract ? Sys.text : Sys.textDim
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('like'); if (bar.canInteract) bar.likeRequested() }
                    }
                    BarButton {
                        kind: "queue"
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.queueRequested() }
                    }
                    BarButton {
                        kind: "lyrics"
                        onTapped: bar.lyricsRequested()
                    }

                    // ---- volumen: glifo + línea fina --------------------
                    RowLayout {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Theme.s1
                        visible: bar.width >= 620

                        Glyph {
                            Layout.alignment: Qt.AlignVCenter
                            width: 14; height: 14
                            kind: bar.volume > 0 ? "volume" : "volume-x"
                            weight: 1.6
                            color: Sys.textDim
                        }

                        Rectangle {
                            id: volTrack
                            Layout.preferredWidth: 70
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
}
