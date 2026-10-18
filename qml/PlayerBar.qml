import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Barra de reproducción: UNA isla flotante (Panel) de Theme.playerBarH de
// alto. El item raíz es transparente y Main.qml lo coloca a lo ancho del
// ColumnLayout, separado del resto por `panelGap`; la superficie redondeada,
// el borde sutil y la sombra suave los pone `Panel`.
//
// Contenido: portada + título/artista, transporte compacto (acento solo en
// play), progreso fino de 2 px con tiempos discretos, cuatro accesos callados
// (me gusta, añadir a lista, cola y letras) y volumen mínimo. Sin capas ni
// efectos extra.
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
        TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bb.tapped() } }
    }

    // ---- isla flotante -----------------------------------------------
    // Una sola superficie redondeada: radio (Theme.rPanel), borde sutil y
    // sombra suave vienen de `Panel`. El contenido va ENCIMA, transparente,
    // con aire generoso a los lados y apenas un suspiro arriba y abajo.
    Panel {
        id: island
        anchors.fill: parent

        Item {
            id: barRow
            anchors.fill: parent
            anchors.leftMargin: Theme.s3
            anchors.rightMargin: Theme.s3
            anchors.topMargin: Theme.s1
            anchors.bottomMargin: Theme.s1
            property int gap: Theme.s3

            // ---- ahora suena (izquierda) ----------------------------
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
                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); bar.lyricsRequested() } }
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
                        visible: !bar.loading
                        text: bar.artist.length ? bar.artist : "—"
                        color: Sys.textDim
                        font.pixelSize: Theme.tMd
                        elide: Text.ElideRight
                        maximumLineCount: 1
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
                            font.pixelSize: Theme.tMd
                        }
                    }
                }
            }

            // ---- transporte + progreso (centro) ---------------------
            ColumnLayout {
                id: centerCol
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                width: Math.min(320, parent.width - Theme.s3 * 2)

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.s2

                    BarButton {
                        diameter: 30; glyph: 15
                        kind: "shuffle"
                        active: bar.shuffle
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('toggle'); bar.shuffleToggled() }
                    }

                    BarButton {
                        diameter: 30; glyph: 15
                        kind: "prev"
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.prevRequested() }
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
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); bar.toggle() } }
                    }

                    BarButton {
                        diameter: 30; glyph: 15
                        kind: "next"
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.nextRequested() }
                    }

                    BarButton {
                        diameter: 30; glyph: 15
                        kind: "repeat"
                        active: bar.repeat
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('toggle'); bar.repeatToggled() }
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

            // ---- derecha: panel y volumen ----------------------------
            RowLayout {
                id: rightSide
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.s2
                width: Math.max(0, (parent.width - centerCol.width) / 2 - Theme.s3)

                Item { Layout.fillWidth: true }

                BarButton {
                    diameter: 30; glyph: 15
                    kind: bar.liked ? "heart" : "heart-outline"
                    active: bar.liked
                    iconColor: bar.canInteract ? Sys.text : Sys.textDim
                    onTapped: { if (typeof sfx !== 'undefined') sfx.play('like'); if (bar.canInteract) bar.likeRequested() }
                }
                BarButton {
                    diameter: 30; glyph: 15
                    kind: "queue"
                    onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.queueRequested() }
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
