import QtQuick
import "theme.js" as Theme

// Tarjeta de artista (resultados de Buscar): la misma voz que las tarjetas
// de la Biblioteca — portada cuadrada redondeada + nombre + subtitulo —,
// pero sin botones de descarga ni de reproduccion: al pulsar se abre el
// artista. Se usa en la fila horizontal de "Artistas" (modo Canciones) y
// en la rejilla del modo Artistas.
Item {
    id: card

    property string name: ""
    property string subtitle: ""
    property string thumb: ""

    signal clicked()

    readonly property bool hovered: hover.hovered

    // Altura reservada: portada cuadrada + dos lineas de texto. El que lo
    // usa (fila o rejilla) reserva exactamente esto para que nada se corte.
    readonly property int textHeight: Theme.cardLineH(Theme.tMd)
                                       + Theme.cardLineH(Theme.tSm) + Theme.s1
    implicitHeight: width + textHeight

    HoverHandler { id: hover }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (typeof sfx !== "undefined") sfx.play("tap")
            card.clicked()
        }
    }

    Rectangle {
        id: coverBox
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: width
        radius: Theme.rMd
        clip: true
        color: Theme.sAlt(Sys.bg, Sys.text)

        RoundedArt {
            anchors.fill: parent
            source: card.thumb
            visible: card.thumb !== ""
            radiusSpec: Theme.rMd
        }
        Glyph {
            anchors.centerIn: parent
            width: Math.round(coverBox.width * 0.28)
            height: width
            visible: card.thumb === ""
            kind: "music"
            color: Theme.tDim(Sys.bg, Sys.text)
        }
    }

    Column {
        anchors.top: coverBox.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        topPadding: Theme.s1
        spacing: 1

        Text {
            width: parent.width
            text: card.name
            color: Sys.text
            font.pixelSize: Theme.tMd
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Text {
            width: parent.width
            visible: card.subtitle !== ""
            text: card.subtitle
            color: Theme.tDim(Sys.bg, Sys.text)
            font.pixelSize: Theme.tSm
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }
}
