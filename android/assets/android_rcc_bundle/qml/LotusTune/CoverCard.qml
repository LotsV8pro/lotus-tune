import QtQuick
import "theme.js" as Theme

// Tarjeta de portada (la voz comun de toda la app): portada cuadrada
// redondeada + titulo + subtitulo, sin botones. Se usa para artistas en
// Buscar (fila y rejilla) y para albumes, singles, radios y artistas
// similares en la pagina del artista.
Item {
    id: card

    property string name: ""
    property string subtitle: ""
    property string thumb: ""
    // Icon drawn when there is no cover: music, disc, radio, list...
    property string glyph: "music"

    // Hover actions (play / download) for the album and single cards. On
    // touch there is no hover: they are always visible there.
    property bool showActions: false
    property bool downloaded: false

    signal clicked()
    signal playClicked()
    signal downloadClicked()

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
            kind: card.glyph
            color: Theme.tDim(Sys.bg, Sys.text)
        }
    }

    // ---- actions (on hover; always on touch) ---------------------------
    // Play: it plays the album right away, without opening its list.
    // Small and tucked in the bottom right corner (Spotify style): it does
    // not cover the artwork and it does not fight the download arrow of
    // the top right corner.
    Rectangle {
        id: playBtn
        z: 2
        anchors.right: coverBox.right
        anchors.bottom: coverBox.bottom
        anchors.rightMargin: Theme.s1
        anchors.bottomMargin: Theme.s1
        width: Theme.touch ? 32 : 34
        height: width
        radius: width / 2
        visible: card.showActions && (hover.hovered || Theme.touch)
        color: playMa.containsMouse ? Qt.darker(Sys.accent, 1.10) : Sys.accent
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        Glyph {
            anchors.centerIn: parent
            width: Math.round(playBtn.width * 0.42)
            height: width
            kind: "play"
            color: Sys.bg
        }
        MouseArea {
            id: playMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined") sfx.play("tap")
                card.playClicked()
            }
        }
    }

    // Download the whole album (one folder = one record).
    Rectangle {
        z: 2
        anchors.right: coverBox.right
        anchors.top: coverBox.top
        anchors.rightMargin: Theme.s1
        anchors.topMargin: Theme.s1
        width: 30
        height: 30
        radius: 15
        visible: card.showActions && (hover.hovered || Theme.touch)
        color: dlMa.containsMouse ? Theme.hover(Sys.bg) : Theme.alpha(Sys.bg, 0.72)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        Glyph {
            anchors.centerIn: parent
            width: 15
            height: 15
            kind: card.downloaded ? "check" : "download"
            color: card.downloaded ? Sys.accent : Sys.text
        }
        MouseArea {
            id: dlMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined") sfx.play("tap")
                card.downloadClicked()
            }
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
