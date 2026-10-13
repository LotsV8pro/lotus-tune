import QtQuick
import "theme.js" as Theme

// Tarjeta cuadrada estilo Spotifast. Tamaño FIJO para que la retícula nunca
// se mueva al pasar el ratón.
//
// El hover se sigue con un HoverHandler de Qt Quick (handlers de puntero), de
// modo que sigue activo aunque el cursor esté SOBRE el botón de play: el
// MouseArea de la tarjeta ya no es la fuente del estado de hover (ese era el
// bug: al entrar en el botón el hover de la tarjeta se perdía y el botón
// desaparecía/desactivaba).
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

    Rectangle {
        id: cover
        width: card.coverSize
        height: card.coverSize
        radius: card.round ? width / 2 : Theme.rLg
        border.width: 1
        border.color: card.hovered ? Qt.rgba(1, 1, 1, 0.16) : Qt.rgba(1, 1, 1, 0.05)
        clip: true

        gradient: Gradient {
            GradientStop { position: 0.0; color: card.coverA }
            GradientStop { position: 1.0; color: card.coverB }
        }
        Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

        Image {
            anchors.fill: parent
            source: card.thumb
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: status === Image.Ready
            sourceSize.width: card.coverSize * 2
            sourceSize.height: card.coverSize * 2
        }

        // Icono de respaldo cuando no hay portada.
        Glyph {
            anchors.centerIn: parent
            width: 40
            height: 40
            kind: card.icon
            color: Qt.rgba(1, 1, 1, 0.55)
            visible: card.thumb.length === 0
        }

        // Degradado inferior para asentar el botón sobre la portada.
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: parent.height * 0.5
            visible: card.thumb.length > 0
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.36) }
            }
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

    Column {
        anchors.top: cover.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        topPadding: Theme.s2
        spacing: 2

        Text {
            width: parent.width
            text: card.title
            color: Sys.text
            font.pixelSize: Theme.tBase
            font.bold: true
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Text {
            width: parent.width
            text: card.subtitle
            color: Sys.textDim
            font.pixelSize: Theme.tSm
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }

    // Fondo clicable (abre la lista). Va ANTES del botón, así queda por debajo.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: card.clicked()
    }

    // Botón circular de play, flotando sobre la portada.
    Rectangle {
        id: playBtn
        width: 40
        height: 40
        radius: 20
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
            onClicked: card.playClicked()
        }
    }
}