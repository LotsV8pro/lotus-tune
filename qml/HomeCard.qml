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
    // Color dominante de la propia portada: el degradado de respaldo del
    // cuadro lo toma, así la tarjeta tiene el color de su arte mientras
    // carga y, si la imagen no llega, se queda con él en vez de con un
    // azul genérico. Transparente = todavía sin saber el color.
    property color artColor: "transparent"
    readonly property bool hasArtColor: artColor.a > 0
    // Color del icono de respaldo: se resuelve por cuenta propia para no
    // depender del objeto del tema en el instante exacto del repintado (un
    // TypeError intermitente leía Sys.text cuando Sys aún no estaba listo).
    property color iconColor: (typeof Sys === "object")
        ? Theme.alpha(Sys.text, 0.55) : "#8a8a8a"

    signal clicked()
    signal playClicked()

    // Al cambiar la portada se pide su color dominante (el C++ lo saca de
    // la imagen y lo devuelve por la señal «found»).
    onThumbChanged: {
        artColor = "transparent"
        if (thumb && thumb.length > 0 && typeof colorpick !== "undefined")
            colorpick.pick(thumb)
    }

    Connections {
        target: colorpick
        function onFound(url, color) {
            if (String(url) === card.thumb)
                card.artColor = color
        }
    }

    readonly property bool hovered: hoverHandler.hovered

    // Color con el que se tiñe el fondo de la tarjeta: el dominante de la
    // portada cuando ya se sabe; si la tarjeta no tiene foto (Me gusta,
    // los accesos directos), el color base de su cuadro.
    readonly property color tintColor: hasArtColor ? artColor : coverA

    // ---- medidas fijas (no cambian con el hover) ----------------------
    readonly property int cardWidth: 172
    readonly property int coverSize: cardWidth
    readonly property int textHeight: 54

    implicitWidth: cardWidth
    implicitHeight: coverSize + textHeight
    width: implicitWidth
    height: implicitHeight

    HoverHandler { id: hoverHandler }

    // Fondo clicable (abre la lista). Va el PRIMERO, por debajo del contenido:
    // así el botón de play flotante (que vive dentro de `inner`) recibe sus
    // clics y el resto de la tarjeta los de este área. Al revés, esta capa
    // tapaba al botón y el play de las tarjetas no hacía nunca nada.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); card.clicked() }
    }

    // Fondo de la tarjeta teñido con el color de su portada: degradado
    // desde el color fuerte arriba (donde está la foto) hacia
    // transparente abajo, para que el texto siga leyéndose.
    Rectangle {
        anchors.fill: parent
        radius: Theme.rXl
        visible: card.tintColor.a > 0
        gradient: Gradient {
            // Con color de portada el tinte se nota más; con el color
            // base (tarjetas sin foto) va más suave, que si no el carril
            // parece un psicodélico.
            GradientStop { position: 0.0
                          color: Theme.alpha(card.tintColor,
                                             card.hasArtColor ? 0.40 : 0.26) }
            GradientStop { position: 0.62
                          color: Theme.alpha(card.tintColor,
                                             card.hasArtColor ? 0.16 : 0.10) }
            GradientStop { position: 1.0
                          color: Theme.alpha(card.tintColor, 0.0) }
        }
    }

    // El contenido no se mueve al pasar el ratón (antes subía 2 px, que
    // bailaba con el carril): lo que reacciona es la FOTO, con un zoom
    // suave, y el botón de play aparece en el centro.
    Item {
        id: inner
        width: card.width
        height: card.height

        Rectangle {
            id: cover
            width: card.coverSize
            height: card.coverSize
            // La foto se agranda un poco al pasar el ratón (el resto de la
            // tarjeta quieta). El escalado va con su propio radio.
            scale: card.hovered ? 1.045 : 1
            Behavior on scale {
                NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
            }
            // Lo único que se retocó de la tarjeta: el redondeo de la
            // portada sube de rMd a rXl (22 px). Nada más.
            radius: card.round ? width / 2 : Theme.rXl
            clip: true

            gradient: Gradient {
                GradientStop { position: 0.0
                              color: card.hasArtColor ? Qt.lighter(card.artColor, 1.35)
                                                      : card.coverA }
                GradientStop { position: 1.0
                              color: card.hasArtColor ? Qt.darker(card.artColor, 1.7)
                                                      : card.coverB }
            }

            RoundedArt {
                id: coverArt
                anchors.fill: parent
                source: card.thumb
                radiusSpec: card.round ? "circle" : Theme.rXl
            }

            // Icono de respaldo cuando no hay portada.
            Glyph {
                anchors.centerIn: parent
                width: 40
                height: 40
                kind: card.icon
                color: card.iconColor
                visible: card.thumb.length === 0
            }

            // Etiqueta (YT / RADIO / …) en píldora.
            Rectangle {
                visible: card.badge.length > 0
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Theme.s2
                height: 18
                radius: Theme.rPill
                color: Theme.alpha(Sys.bg, 0.72)
                implicitWidth: badgeLabel.implicitWidth + Theme.pillHPad
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

        // Botón de play, en el CENTRO de la portada (estilo Apple Music):
        // aparece al pasar el ratón, encima de la foto que hace zoom.
        Rectangle {
            id: playBtn
            width: 42
            height: 42
            radius: Theme.rPill
            color: playHit.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
            // Fino borde oscuro: se lee sobre cualquier portada, clara u
            // oscura.
            border.width: 1
            border.color: Theme.alpha(Sys.bg, 0.28)
            anchors.centerIn: cover
            opacity: card.hovered ? 1 : 0
            scale: card.hovered ? (playHit.pressed ? 0.92
                                    : (playHit.containsMouse ? 1.06 : 1)) : 0.8
            Behavior on opacity { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            Glyph {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: 1
                width: 17
                height: 17
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
}
