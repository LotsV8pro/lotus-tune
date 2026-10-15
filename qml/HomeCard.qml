import QtQuick
import "theme.js" as Theme

// Tarjeta mínima de los carriles de Inicio.
//
// Tamaño FIJO (cardWidth/coverSize/textHeight) para que la retícula nunca se
// mueva al pasar el ratón: la elevación del hover es sólo un desplazamiento de
// 2 px del contenido, sin sombras ni capas extra.
//
// Clic en la PORTADA -> abre la lista/playlist.
// Clic en el BOTÓN      -> reproduce.
Item {
    id: card

    property string title: ""
    property string subtitle: ""
    property string icon: "play"
    property color coverA: "#232a33"
    property color coverB: "#12151a"
    property string badge: ""
    property string thumb: ""
    property bool round: false

    signal clicked()
    signal playClicked()

    readonly property bool hovered: hoverHandler.hovered

    // ---- medidas fijas (no cambian con el hover) ----------------------
    readonly property int cardWidth: 172
    readonly property int coverSize: cardWidth
    readonly property int textHeight: 54

    implicitWidth: cardWidth
    implicitHeight: coverSize + textHeight
    width: implicitWidth
    height: implicitHeight

    HoverHandler { id: hoverHandler }

    // El contenido se eleva 2 px al pasar el ratón. La tarjeta no cambia de
    // tamaño: sólo se mueve, así el carril no salta.
    Item {
        id: inner
        width: card.width
        height: card.height
        y: card.hovered ? -2 : 0
        Behavior on y {
            NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
        }

        Rectangle {
            id: cover
            width: card.coverSize
            height: card.coverSize
            radius: card.round ? width / 2 : Theme.rLg
            clip: true
            border.width: 1
            border.color: card.hovered ? Theme.alpha(Sys.text, 0.14) : "transparent"
            Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

            gradient: Gradient {
                GradientStop { position: 0.0; color: card.coverA }
                GradientStop { position: 1.0; color: card.coverB }
            }

            Image {
                anchors.fill: parent
                source: card.thumb
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                visible: status === Image.Ready
                sourceSize.width: 320
                sourceSize.height: 320
            }

            // Icono de respaldo cuando no hay portada.
            Glyph {
                anchors.centerIn: parent
                width: 40
                height: 40
                kind: card.icon
                color: Theme.alpha(Sys.text, 0.55)
                visible: card.thumb.length === 0
            }

            // Etiqueta (YT / RADIO / …)
            Rectangle {
                visible: card.badge.length > 0
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Theme.s2
                height: 18
                radius: Theme.rSm
                color: Theme.alpha(Sys.bg, 0.72)
                implicitWidth: badgeLabel.implicitWidth + 14
                Text {
                    id: badgeLabel
                    anchors.centerIn: parent
                    text: card.badge
                    color: Sys.text
                    font.pixelSize: Theme.tXs
                    font.bold: true
                    font.letterSpacing: 0.8
                }
            }
        }

        // Texto: título a 2 líneas como máximo + subtítulo de una línea.
        // La altura está reservada (textHeight) para que el carril no salte.
        Column {
            anchors.top: cover.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            topPadding: Theme.s1
            spacing: 1

            Text {
                width: parent.width
                height: card.textHeight - Theme.s1 - 16
                text: card.title
                color: Sys.text
                font.pixelSize: Theme.tBase
                font.weight: Font.DemiBold
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 2
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
            }
            Text {
                width: parent.width
                height: 16
                text: card.subtitle
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
                maximumLineCount: 1
                verticalAlignment: Text.AlignTop
            }
        }

        // Botón circular de play, flotando sobre la portada (sólo al pasar).
        Rectangle {
            id: playBtn
            width: 36
            height: 36
            radius: 18
            color: playHit.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
            anchors.right: cover.right
            anchors.rightMargin: Theme.s2
            anchors.bottom: cover.bottom
            anchors.bottomMargin: Theme.s2
            opacity: card.hovered ? 1 : 0
            scale: card.hovered ? (playHit.pressed ? 0.94 : (playHit.containsMouse ? 1.06 : 1)) : 0.9
            Behavior on opacity { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            Glyph {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: 1
                width: 15
                height: 15
                kind: "play"
                color: Sys.onAccent
            }

            MouseArea {
                id: playHit
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { if (typeof sfx !== "undefined") sfx.play("play"); card.playClicked() }
            }
        }
    }

    // Fondo clicable (abre la lista). Va por debajo del botón de play.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); card.clicked() }
    }
}
