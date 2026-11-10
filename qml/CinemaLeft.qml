import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Panel izquierdo del cinema (la distribucion de la referencia): la
// portada grande, el titulo con su corazon, el artista, la barra de
// progreso con los tiempos, el transporte y el volumen, todo apilado
// debajo de la portada. La letra queda a la derecha (ver
// FullscreenLyrics.qml).
//
// Vive en su propio archivo porque el cinema lo usa dos veces: como
// columna izquierda en escritorio y como bloque superior en el movil
// (donde no cabe una segunda columna). Dos instancias, una visible cada
// vez: el estado de arrastre de la barra es local a cada una.
Item {
    id: cl
    implicitWidth: inner.implicitWidth
    implicitHeight: inner.implicitHeight

    property string title: ""
    property string artist: ""
    property string thumb: ""
    // YouTube ID de la pista: la portada grande necesita las variantes
    // nitidas de la caratula (las de la API vienen a 120 px).
    property string videoId: ""
    property bool playing: false
    property real position: 0
    property real duration: 0
    property bool shuffleOn: false
    property int repeatVal: 0
    property bool liked: false
    property int volume: 70
    property real coverSize: 220
    // Centre of the cover inside this item: the lyrics pin the active line
    // there, so it does not depend on how tall the block ends up being.
    readonly property real coverCenter: coverBox.y + coverBox.height / 2
    // Escritorio: todo alineado a la izquierda. Movil: centrado.
    property bool centered: false
    // Tinta legible sobre el lavado del cinema: el cinema la calcula con el
    // color medio de la portada (caratula clara -> texto oscuro). Los
    // valores por defecto son la paleta normal, para quien no las pase.
    property color ink: Sys.text
    property color inkDim: Theme.tDim(Sys.bg, Sys.text)

    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)
    signal shuffleRequested()
    signal repeatRequested()
    signal likeRequested()
    signal volumeWanted(int value)
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)

    ColumnLayout {
        id: inner
        anchors.fill: parent
        spacing: Theme.s2

        // ---- portada -----------------------------------------------------
        // Redondeada como las tarjetas de la biblioteca. El dedo no la
        // arrastra (bajar con el dedo cierra el cinema, pero no desde la
        // foto). Click derecho: menu de la pista, igual que en las listas.
        Rectangle {
            id: coverBox
            Layout.alignment: cl.centered ? Qt.AlignHCenter : Qt.AlignLeft
            Layout.topMargin: Theme.s2
            Layout.preferredWidth: Math.round(cl.coverSize)
            Layout.preferredHeight: Math.round(cl.coverSize)
            radius: Theme.rXl
            antialiasing: true
            color: Theme.sAccent(Sys.bg, Sys.accent)

            ArtImage {
                anchors.fill: parent
                src: cl.thumb
                videoId: cl.videoId
                // La portada del cinema es GRANDE: pedir primero la variante
                // mas nitida (maxres) en vez de la de 480 px.
                preferMaxRes: true
                radiusSpec: Theme.rXl
                showIconWhenEmpty: false

                opacity: ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.medMs } }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                hoverEnabled: true
                cursorShape: Qt.ArrowCursor
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: {
                    const p = mapToItem(null, mouse.x, mouse.y)
                    cl.trackMenuRequested(p.x, p.y)
                }
            }
        }

        // ---- titulo + corazon -------------------------------------------
        RowLayout {
            Layout.fillWidth: !cl.centered
            Layout.alignment: cl.centered ? Qt.AlignHCenter : Qt.AlignLeft
            Layout.topMargin: Theme.s3
            spacing: Theme.s2

            Text {
                id: clTitle
                Layout.fillWidth: false
                Layout.preferredWidth: Math.min(implicitWidth, Math.max(40, cl.width - 32))
                text: cl.title.length ? cl.title : "—"
                color: cl.ink
                font.pixelSize: Theme.t2xl
                font.weight: Font.Bold
                horizontalAlignment: cl.centered ? Text.AlignHCenter : Text.AlignLeft
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            // El corazon, junto al titulo (como en la referencia).
            Item {
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                Glyph {
                    anchors.centerIn: parent
                    width: 19; height: 19
                    kind: cl.liked ? "heart" : "heart-outline"
                    color: cl.liked ? Theme.accentOn(Sys.accent, Sys.bg)
                                    : cl.inkDim
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined")
                            sfx.play("like")
                        cl.likeRequested()
                    }
                }
            }
        }

        // ---- artista (click = su pagina) ---------------------------------
        Text {
            id: clArtist
            Layout.fillWidth: true
            text: cl.artist.length ? cl.artist : "—"
            color: cl.inkDim
            font.pixelSize: Theme.tBase
            font.underline: clArtistHover.hovered
            horizontalAlignment: cl.centered ? Text.AlignHCenter : Text.AlignLeft
            elide: Text.ElideRight
            maximumLineCount: 1
            HoverHandler { id: clArtistHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                onTapped: {
                    if (typeof sfx !== "undefined")
                        sfx.play("tap")
                    if (cl.artist.length)
                        cl.artistRequested(cl.artist)
                }
            }
        }

        // ---- progreso ----------------------------------------------------
        Item {
            id: seekRow
            Layout.fillWidth: true
            Layout.topMargin: Theme.s3
            implicitHeight: 26
            // -1 = no se esta arrastrando (manda la posicion real).
            property real scrub: -1
            readonly property real ratio: cl.duration > 0
                ? Math.min(1, Math.max(0, (seekRow.scrub >= 0
                                           ? seekRow.scrub : cl.position)
                                          / cl.duration))
                : 0
            function posAt(mx) {
                return Math.max(0, Math.min(1, mx / width)) * cl.duration
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: Theme.rMd
                antialiasing: true
                color: Theme.alpha(cl.ink, 0.18)
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width * seekRow.ratio)
                height: 4
                radius: Theme.rMd
                antialiasing: true
                color: Theme.accentOn(Sys.accent, Sys.bg)
            }
            Rectangle {
                x: Math.max(0, Math.min(seekRow.width - width,
                                        seekRow.width * seekRow.ratio - width / 2))
                anchors.verticalCenter: parent.verticalCenter
                width: 13
                height: 13
                radius: Theme.rLg
                antialiasing: true
                color: Theme.accentOn(Sys.accent, Sys.bg)
            }
            MouseArea {
                anchors.fill: parent
                anchors.topMargin: -10
                anchors.bottomMargin: -10
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: (m) => seekRow.scrub = seekRow.posAt(m.x)
                onPositionChanged: (m) => {
                    if (pressed)
                        seekRow.scrub = seekRow.posAt(m.x)
                }
                onReleased: (m) => {
                    const v = seekRow.posAt(m.x)
                    seekRow.scrub = -1
                    cl.seekRequested(v)
                }
                onCanceled: seekRow.scrub = -1
            }
        }

        // ---- tiempos ------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: Theme.mmss(seekRow.scrub >= 0 ? seekRow.scrub : cl.position)
                color: Theme.alpha(cl.ink, 0.60)
                font.pixelSize: Theme.tXs
            }
            Item { Layout.fillWidth: true }
            Text {
                text: Theme.mmss(cl.duration)
                color: Theme.alpha(cl.ink, 0.60)
                font.pixelSize: Theme.tXs
            }
        }

        // ---- transporte ---------------------------------------------------
        // Orden de la referencia: aleatorio, anterior, play, siguiente,
        // bucle. El play va en un disco de acento (es el unico control que
        // tiene que verse sin buscarlo).
        RowLayout {
            Layout.alignment: cl.centered ? Qt.AlignHCenter : Qt.AlignLeft
            Layout.topMargin: Theme.s2
            spacing: Theme.s2

            // Aleatorio
            Item {
                width: 40; height: 40
                Rectangle {
                    anchors.centerIn: parent
                    width: 32; height: 32
                    radius: width / 2
                    antialiasing: true
                    color: Theme.sAccent(Sys.bg, Sys.accent, 0.18)
                    visible: cl.shuffleOn
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }
                Glyph {
                    anchors.centerIn: parent
                    width: 19; height: 19
                    kind: "shuffle"
                    color: cl.shuffleOn ? Theme.accentOn(Sys.accent, Sys.bg)
                                        : cl.inkDim
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined")
                            sfx.play("toggle")
                        cl.shuffleRequested()
                    }
                }
            }
            // Anterior
            Item {
                width: 40; height: 40
                Glyph {
                    anchors.centerIn: parent
                    width: 24; height: 24
                    kind: "prev"
                    color: cl.ink
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined")
                            sfx.play("tap")
                        cl.prevRequested()
                    }
                }
            }
            // Play / pausa
            Rectangle {
                id: bigPlay
                width: 54; height: 54
                radius: Theme.rPanel
                antialiasing: true
                color: Theme.accentOn(Sys.accent, Sys.bg)
                scale: playPress.pressed ? 0.93 : 1
                Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
                HoverHandler { id: playPress; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 24; height: 24
                    kind: cl.playing ? "pause" : "play"
                    color: Theme.onAccentOf(Sys.accent, Theme.onAccent(Sys.accent))
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (typeof sfx !== "undefined")
                            sfx.play("play")
                        cl.toggleRequested()
                    }
                }
            }
            // Siguiente
            Item {
                width: 40; height: 40
                Glyph {
                    anchors.centerIn: parent
                    width: 24; height: 24
                    kind: "next"
                    color: cl.ink
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined")
                            sfx.play("tap")
                        cl.nextRequested()
                    }
                }
            }
            // Bucle: modo 1 = repetir la lista, modo 2 = repetir SOLO esta
            // pista. El "1" interno del glifo es invisible a este tamano: el
            // modo 2 se marca con un badge.
            Item {
                width: 40; height: 40
                Rectangle {
                    id: repDisc
                    anchors.centerIn: parent
                    width: 32; height: 32
                    radius: width / 2
                    antialiasing: true
                    color: Theme.sAccent(Sys.bg, Sys.accent, 0.18)
                    visible: cl.repeatVal > 0
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }
                Glyph {
                    anchors.centerIn: parent
                    width: 19; height: 19
                    kind: "repeat"
                    color: cl.repeatVal > 0 ? Theme.accentOn(Sys.accent, Sys.bg)
                                            : cl.inkDim
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }
                Rectangle {
                    visible: cl.repeatVal === 2
                    anchors.right: repDisc.right
                    anchors.bottom: repDisc.bottom
                    anchors.rightMargin: -1
                    anchors.bottomMargin: -1
                    width: 13; height: 13
                    radius: Theme.rLg
                    antialiasing: true
                    color: Sys.accent
                    Text {
                        anchors.centerIn: parent
                        text: "1"
                        color: Theme.onAccent(Sys.accent)
                        font.pixelSize: 9
                        font.weight: Font.Bold
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined")
                            sfx.play("toggle")
                        cl.repeatRequested()
                    }
                }
            }


            // El separador solo existe en escritorio: en el movil empujaria
            // el transporte a la izquierda y no quedaria centrado.
            Item { Layout.fillWidth: true; visible: !cl.centered }
            // Volumen (escritorio): en el movil sobran los botones
            // fisicos y el espacio es oro.
            RowLayout {
                visible: !cl.centered
                Layout.leftMargin: Theme.s3
                spacing: Theme.s1

                Glyph {
                    Layout.alignment: Qt.AlignVCenter
                    width: 16; height: 16
                    kind: cl.volume > 0 ? "volume" : "volume-x"
                    weight: 1.6
                    color: cl.inkDim
                }

                Rectangle {
                    id: fsVolTrack
                    Layout.preferredWidth: 76
                    Layout.alignment: Qt.AlignVCenter
                    height: 16
                    color: "transparent"

                    readonly property real max: 130
                    readonly property real ratio: Math.min(1, cl.volume / max)

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width; height: 3; radius: 1.5
                        color: Theme.alpha(Sys.text, 0.18)
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * fsVolTrack.ratio
                        height: 3; radius: 1.5
                        color: Theme.accentOn(Sys.accent, Sys.bg)
                    }
                    Rectangle {
                        x: parent.width * fsVolTrack.ratio - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10; height: 10; radius: 5
                        color: Theme.accentOn(Sys.accent, Sys.bg)
                        scale: fsVolMa.containsMouse ? 1.05 : 0.9
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    }
                    MouseArea {
                        id: fsVolMa
                        anchors.fill: parent
                        anchors.topMargin: -8
                        anchors.bottomMargin: -8
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        function setAt(mouse) {
                            const r = Math.max(0, Math.min(1, mouse.x / fsVolTrack.width))
                            cl.volumeWanted(Math.round(r * fsVolTrack.max))
                        }
                        onPressed: (mouse) => setAt(mouse)
                        onPositionChanged: (mouse) => { if (pressed) setAt(mouse) }
                    }
                }
            }
        }
    }
}
