import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Letra a pantalla completa (modo cine). Es el mismo motor de letra que el
// panel y Now Playing (`LyricsView`, con el karaoke por palabra y el
// «iluminar la frase entera» idénticos), pero sobre un fondo lavando la
// portada y con los controles de transporte abajo. Los mandos se esconden
// solos tras unos segundos sin mover el ratón y vuelven al moverlo.
//
// Reutilizar LyricsView es deliberado: así la letra que ve el usuario aquí, en
// el panel y en los widgets del escritorio (que leen el estado que publica la
// app) es literalmente la misma representación. Sin tarjetas ni cajas: la
// letra flota sobre el fondo, como el resto de la interfaz.
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
    property bool playing: false
    property real position: 0
    property real duration: 0

    signal closeRequested()
    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)

    Behavior on opacity {
        NumberAnimation { duration: Theme.slowMs; easing.type: Easing.OutCubic }
    }

    readonly property var ply: (typeof player !== "undefined") ? player : null

    // ---- lavado de portada ------------------------------------------------
    // La portada a 64 px ampliada a toda la pantalla (desenfoque barato sin
    // GPU) bajo un velo profundo teñido de acento: da el «más azul» que se
    // pidió sin comerse el contraste de la letra.
    Image {
        id: washImg
        anchors.fill: parent
        source: fl.open ? fl.thumb : ""
        sourceSize.width: 64
        sourceSize.height: 64
        fillMode: Image.PreserveAspectCrop
        smooth: true
        asynchronous: true
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.slowMs } }
    }
    // Velo: fondo de la app casi opaco, mezclado con un azul profundo para que
    // el modo cine sea más frío y nítido que el resto de ventanas.
    Rectangle {
        anchors.fill: parent
        color: Theme.mix(Sys.bg, "#1b2a44", 0.28)
        opacity: 0.80
    }
    // Aura de acento en la parte baja (por donde van los controles), muy tenue.
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

    // ---- letra ------------------------------------------------------------
    LyricsView {
        id: lyric
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: chromeTop.bottom
        anchors.topMargin: Theme.s6
        // En modo cine la columna es más ancha y la letra, mucho más grande.
        lineSize: Math.max(24, Math.min(38, Math.round(fl.width / 42)))
        activeBoost: Math.round(lineSize * 0.18)
        maxLineWidth: Math.min(fl.width * 0.82, 1180)
        edgeColor: Theme.mix(Sys.bg, "#1b2a44", 0.28)
    }

    // ---- cabecera ---------------------------------------------------------
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 96
        visible: fl.chromeVisible
        opacity: fl.chromeVisible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

        // Pista al centro, en una línea; artista debajo.
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(fl.width - 220, 760)
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: fl.title.length ? fl.title : "—"
                color: Sys.text
                font.pixelSize: Theme.tXl
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                text: fl.artist.length ? fl.artist : "—"
                color: Sys.textDim
                font.pixelSize: Theme.tMd
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }

        // Salida (arriba derecha): deja el modo cine.
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: Theme.s5
            anchors.topMargin: Theme.s4
            width: 40
            height: 40
            radius: width / 2
            color: exitMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 20; height: 20
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
    }

    // Ancla invisible: la letra ocupa hasta aquí y lo de abajo es el "chrome".
    Item {
        id: chromeTop
        anchors.bottom: controls.top
    }

    // ---- controles (transporte + progreso) --------------------------------
    Item {
        id: controls
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 116
        visible: fl.chromeVisible
        opacity: fl.chromeVisible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

        RowLayout {
            id: transport
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.s3
            spacing: Theme.s4

            Rectangle {
                width: 46; height: 46; radius: 23
                color: prevMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 22; height: 22
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
                width: 58; height: 58; radius: 29
                color: Sys.accent
                scale: playMa.containsMouse ? 1.05 : 1
                Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 26; height: 26
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
                width: 46; height: 46; radius: 23
                color: nextMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 22; height: 22
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
        }

        // ---- progreso fino con tiempos ------------------------------------
        Item {
            id: seekRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.s5
            anchors.rightMargin: Theme.s5
            anchors.bottomMargin: Theme.s5
            height: 26

            Text {
                id: posLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Theme.mmss(fl.position)
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                width: Theme.mmss(fl.duration).length > 4 ? 46 : 38
            }
            Text {
                id: durLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: fl.duration > 0 ? Theme.mmss(fl.duration) : "0:00"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
            }

            // Pista de progreso clicable (arrastre incluido).
            Item {
                id: track
                anchors.left: posLabel.right
                anchors.right: durLabel.left
                anchors.leftMargin: Theme.s3
                anchors.rightMargin: Theme.s3
                anchors.verticalCenter: parent.verticalCenter
                height: 14

                readonly property real frac: fl.duration > 0
                                             ? Theme.clamp(fl.position / fl.duration, 0, 1) : 0

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
                    anchors.leftMargin: Math.max(0, parent.width * parent.frac - 6)
                    width: 12; height: 12; radius: 6
                    color: Sys.accent
                    visible: seekMa.pressed || seekMa.containsMouse
                }

                MouseArea {
                    id: seekMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => {
                        if (fl.duration > 0 && parent.width > 0)
                            fl.seekRequested(mouse.x / parent.width * fl.duration)
                    }
                }
            }
        }
    }

    // ---- auto-ocultación de mandos ----------------------------------------
    // Al abrir (o al mover el ratón) los mandos salen; tras 2,8 s quietos se
    // esconden y la pantalla se queda sólo con la letra.
    readonly property bool chromeVisible: _chrome
    property bool _chrome: false

    Timer {
        id: chromeTimer
        interval: 2800
        running: false
        onTriggered: fl._chrome = false
    }

    function showChrome() {
        fl._chrome = true
        chromeTimer.restart()
    }

    // Captura los movimientos de ratón en toda la ventana del modo cine.
    MouseArea {
        anchors.fill: parent
        // Dejad que los clics pasen a la letra y a los controles: sólo nos
        // interesa la posición del cursor para reactivar los mandos.
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onPositionChanged: fl.showChrome()
        onContainsMouseChanged: if (containsMouse) fl.showChrome()
    }

    // Al abrir, mandos visibles un rato; al cerrar, los reseteamos.
    onOpenChanged: {
        if (open) {
            showChrome()
        } else {
            _chrome = false
            chromeTimer.stop()
        }
    }
}
