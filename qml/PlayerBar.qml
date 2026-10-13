import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Barra de reproducción (88 px): portada + datos, controles centrados y
// volumen. Se tiñe muy suavemente con el acento activo para dar vida sin
// coste (sin muestreo de imagen ni shaders por frame).
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

    implicitHeight: Theme.playerBarH
    color: Sys.bg

    readonly property color _ui: Theme.hover(Sys.surface)

    // ---- botón de icono reutilizable ---------------------------------
    component BarButton: Rectangle {
        id: bb
        property string kind: "play"
        property bool active: false
        property color iconColor: Sys.textDim
        property int diameter: 34
        property real glyph: 16
        signal tapped()
        width: diameter
        height: diameter
        radius: Theme.rMd
        color: bb.active ? Sys.accentDim : (bbHover.hovered ? bar._ui : "transparent")
        scale: bbHover.pressed ? 0.94 : (bbHover.hovered ? 1.05 : 1)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
        HoverHandler { id: bbHover; cursorShape: Qt.PointingHandCursor }
        Glyph {
            anchors.centerIn: parent
            width: bb.glyph
            height: bb.glyph
            kind: bb.kind
            color: bb.active ? Sys.accent : (bbHover.hovered ? Sys.accent : bb.iconColor)
        }
        TapHandler { onTapped: bb.tapped() }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        spacing: 16

        // ---- ahora suena (izquierda) --------------------------------
        RowLayout {
            Layout.preferredWidth: 300
            Layout.fillWidth: true
            Layout.maximumWidth: 360
            Layout.alignment: Qt.AlignVCenter
            spacing: 12

            Item {
                Layout.alignment: Qt.AlignVCenter
                width: 52
                height: 52
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
                        sourceSize.width: 104
                        sourceSize.height: 104
                    }
                    LotusMark {
                        anchors.centerIn: parent
                        width: 24
                        height: 23
                        petalColor: Sys.accent
                        active: bar.playing
                        visible: coverImg.status !== Image.Ready
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.rMd
                    color: "transparent"
                    border.width: 1
                    border.color: Sys.border
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: bar.lyricsRequested() }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: bar.title.length ? bar.title : "Sin nada en cola"
                    color: bar.title.length ? Sys.text : Sys.textDim
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                Text {
                    Layout.fillWidth: true
                    text: bar.artist.length ? bar.artist : "—"
                    color: Sys.textDim
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }

            BarButton {
                Layout.alignment: Qt.AlignVCenter
                diameter: 34
                glyph: 16
                kind: "expand"
                onTapped: bar.lyricsRequested()
            }
        }

        // ---- controles centrados ------------------------------------
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: 4

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 8

                BarButton {
                    diameter: 32; glyph: 15
                    kind: "shuffle"
                    active: bar.shuffle
                    onTapped: bar.shuffleToggled()
                }
                BarButton {
                    diameter: 36; glyph: 17
                    kind: "prev"
                    iconColor: Sys.text
                    onTapped: bar.prevRequested()
                }

                Rectangle {
                    width: 44
                    height: 44
                    radius: 22
                    color: playHover.hovered ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                    scale: playHover.pressed ? 0.94 : (playHover.hovered ? 1.05 : 1)
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    HoverHandler { id: playHover; cursorShape: Qt.PointingHandCursor }
                    Glyph {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: 1
                        width: 18
                        height: 18
                        kind: bar.playing ? "pause" : "play"
                        color: Sys.onAccent
                    }
                    TapHandler { onTapped: bar.toggle() }
                }

                BarButton {
                    diameter: 36; glyph: 17
                    kind: "next"
                    iconColor: Sys.text
                    onTapped: bar.nextRequested()
                }
                BarButton {
                    diameter: 32; glyph: 15
                    kind: "repeat"
                    active: bar.repeat
                    onTapped: bar.repeatToggled()
                }
            }

            // ---- progreso -------------------------------------------
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 420
                Layout.maximumWidth: 420
                spacing: 10

                Text {
                    text: Theme.mmss(bar.scrubbing ? bar.scrubPos : bar.position)
                    color: Sys.textDim
                    font.pixelSize: 10
                    Layout.preferredWidth: 38
                    horizontalAlignment: Text.AlignRight
                }

                Rectangle {
                    id: scrubTrack
                    Layout.fillWidth: true
                    height: 14
                    color: "transparent"

                    readonly property real ratio: bar.duration > 0
                        ? Math.min(1, (bar.scrubbing ? bar.scrubPos : bar.position) / bar.duration) : 0

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width; height: 3; radius: 2
                        color: Theme.mix(Sys.surface, Sys.text, 0.16)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * scrubTrack.ratio
                        height: 3; radius: 2
                        color: Sys.accent
                    }
                    Rectangle {
                        x: parent.width * scrubTrack.ratio - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10; height: 10; radius: 5
                        color: Sys.accent
                        scale: scrubArea.hovered || bar.scrubbing ? 1.15 : 0
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
                    font.pixelSize: 10
                    Layout.preferredWidth: 38
                }
            }
        }

        // ---- derecha: panel y volumen --------------------------------
        RowLayout {
            Layout.preferredWidth: 300
            Layout.fillWidth: true
            Layout.maximumWidth: 360
            Layout.alignment: Qt.AlignVCenter
            spacing: 6

            Item { Layout.fillWidth: true }

            BarButton {
                diameter: 34; glyph: 16
                kind: "heart"
                active: bar.liked
                enabled: bar.canInteract && bar.videoId.length > 0
                opacity: bar.canInteract && bar.videoId.length > 0 ? 1 : 0.4
                onTapped: bar.likeRequested()
            }
            BarButton {
                diameter: 34; glyph: 16
                kind: "plus"
                enabled: bar.canInteract && bar.videoId.length > 0
                opacity: bar.canInteract && bar.videoId.length > 0 ? 1 : 0.4
                onTapped: bar.addToPlaylistRequested()
            }
            BarButton {
                diameter: 34; glyph: 16
                kind: "lyrics"
                onTapped: bar.lyricsRequested()
            }
            BarButton {
                diameter: 34; glyph: 16
                kind: "queue"
                onTapped: bar.queueRequested()
            }

            Rectangle { width: 8; height: 1; color: "transparent" }

            Glyph {
                Layout.alignment: Qt.AlignVCenter
                width: 16; height: 16
                kind: bar.volume > 0 ? "volume" : "volume-x"
                color: Sys.textDim
            }

            Rectangle {
                id: volTrack
                Layout.preferredWidth: 96
                Layout.alignment: Qt.AlignVCenter
                height: 14
                color: "transparent"

                readonly property real max: 130
                readonly property real ratio: Math.min(1, bar.volume / max)

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width; height: 3; radius: 2
                    color: Theme.mix(Sys.surface, Sys.text, 0.16)
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * volTrack.ratio
                    height: 3; radius: 2
                    color: Sys.accent
                }
                Rectangle {
                    x: parent.width * volTrack.ratio - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 10; height: 10; radius: 5
                    color: Sys.accent
                    scale: volArea.hovered ? 1.15 : 0
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