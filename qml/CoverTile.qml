import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Tile de portada de la rejilla de Biblioteca: tarjeta con portada cuadrada,
// título con elide (nunca desborda) y subtítulo de una línea. La raíz es
// transparente y la tarjeta deja canalón a la derecha/abajo para que el
// fondo de la página separé las columnas de la rejilla. Al pasar el ratón
// la tarjeta se aclara y aparecen las acciones (descargar / quitar).
Rectangle {
    id: tile

    property string title: ""
    property string subtitle: ""
    property string thumb: ""
    property bool downloadable: false
    property bool removable: false

    signal clicked()          // clic en la tarjeta -> ABRIR la lista
    signal playClicked()      // clic en el botón de play flotante -> REPRODUCIR
    signal downloadRequested()
    signal removeRequested()
    // Clic derecho sobre la tarjeta: menú contextual (x/y en ventana).
    signal contextRequested(real x, real y)

    // Ratón sobre el botón de play flotante (feedback visual del botón).
    property bool overPlay: false

    color: "transparent"
    border.width: 0

    Rectangle {                       // tarjeta (con canalón derecha/abajo)
        id: card
        x: 0
        y: 0
        width: tile.width - 14
        height: tile.height - 18
        radius: Theme.rLg
        color: tileMa.containsMouse ? Theme.hover(Sys.surface) : Sys.surface
        border.width: 0
        clip: true
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.s2
            spacing: Theme.s2

            Rectangle {                // portada cuadrada
                id: coverBox
                Layout.fillWidth: true
                Layout.preferredHeight: card.width - Theme.s4
                radius: Theme.rMd
                clip: true
                color: Sys.surfaceAlt

                Image {
                    anchors.fill: parent
                    source: tile.thumb
                    visible: source != ""
                    sourceSize.width: 240
                    sourceSize.height: 240
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                }
                Glyph {
                    anchors.centerIn: parent
                    width: 30
                    height: 30
                    visible: tile.thumb === ""
                    kind: "music"
                    color: Sys.textDim
                }
                Rectangle {            // botón de play flotante (sobre el ratón)
                    id: playBadge
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.s2
                    width: 30
                    height: 30
                    radius: 15
                    color: tile.overPlay ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                    opacity: tileMa.containsMouse ? 1 : 0
                    scale: tileMa.containsMouse
                           ? (tileMa.pressed && tile.overPlay ? 0.92 : 1)
                           : 0.7
                    Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 13
                        height: 13
                        kind: "play"
                        color: Sys.onAccent
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: tile.title
                color: Sys.text
                font.pixelSize: Theme.tMd
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                maximumLineCount: 1
            }
            Text {
                Layout.fillWidth: true
                visible: tile.subtitle !== ""
                text: tile.subtitle
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }

    MouseArea {
        id: tileMa
        anchors.fill: card
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        // ¿El ratón cae dentro del botón de play flotante? (está debajo de
        // este MouseArea, así que se comprueba a mano en vez de con un
        // MouseArea propio: evita robarle el hover a la tarjeta).
        function overPlayBtn(x, y) {
            const p = playBadge.mapToItem(tileMa, 0, 0)
            return x >= p.x && x <= p.x + playBadge.width
                   && y >= p.y && y <= p.y + playBadge.height
        }
        onMouseXChanged: tile.overPlay = overPlayBtn(mouseX, mouseY)
        onMouseYChanged: tile.overPlay = overPlayBtn(mouseX, mouseY)
        onExited: tile.overPlay = false

        // Clic en el botón de play -> REPRODUCIR; el resto -> ABRIR.
        // Clic derecho -> menú contextual de la lista.
        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                const p = mapToItem(null, mouse.x, mouse.y)
                tile.contextRequested(p.x, p.y)
                return
            }
            if (overPlayBtn(mouse.x, mouse.y))
                tile.playClicked()
            else
                tile.clicked()
        }
    }

    // Acciones: por encima del MouseArea principal para recibir los clics.
    Column {
        x: card.width - width - Theme.s1
        y: Theme.s1
        z: 2
        spacing: Theme.s1
        visible: tileMa.containsMouse && (tile.downloadable || tile.removable)

        Rectangle {
            visible: tile.downloadable
            width: 30
            height: 30
            radius: Theme.rMd
            color: dlMa.containsMouse ? Theme.hover(Sys.bg) : Sys.bg
            border.width: 0
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 15
                height: 15
                kind: "download"
                color: dlMa.containsMouse ? Sys.accent : Sys.textDim
            }
            MouseArea {
                id: dlMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tile.downloadRequested()
            }
        }

        Rectangle {
            visible: tile.removable
            width: 30
            height: 30
            radius: Theme.rMd
            color: rmMa.containsMouse ? Theme.alpha(Sys.danger, 0.16) : Sys.bg
            border.width: 0
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 15
                height: 15
                kind: "x"
                color: rmMa.containsMouse ? Sys.danger : Sys.textDim
            }
            MouseArea {
                id: rmMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tile.removeRequested()
            }
        }
    }
}
