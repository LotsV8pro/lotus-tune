import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Ficha de artista (capa a pantalla completa): su discografía, del disco más
// nuevo al más antiguo. «Reproducir todo» arranca con el más nuevo e irán
// entrando los demás de uno en uno; «Aleatorio» añade todos los temas y
// baraja la cola entera. Pulsar una fila reproduce sólo ese disco.
Item {
    id: page

    // Datos que llegan de Main: artista { name, browseId, thumb } y albums
    // [{ title, browseId, thumb, subtitle, year }].
    property var artist: null
    property var albums: []
    property bool busy: false

    signal backRequested()
    signal playAllRequested(bool random)
    signal albumPlayRequested(var album)

    // Traga los clics: nada de lo de atrás (contenido, barra) debe responder.
    MouseArea {
        anchors.fill: parent
    }

    Rectangle {
        anchors.fill: parent
        color: Sys.bg
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s5
        spacing: Theme.s3

        // ---- cabecera: volver + nombre ------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s2

            Rectangle {
                width: 36
                height: 36
                radius: Theme.rMd
                color: backMa.containsMouse ? Sys.surfaceAlt : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    kind: "back"
                    color: Sys.text
                }
                MouseArea {
                    id: backMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined") sfx.play("tap")
                        page.backRequested()
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: page.artist ? String(page.artist.name || "") : ""
                color: Sys.text
                font.pixelSize: Theme.tXl
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
        }

        // ---- ficha: retrato, acciones --------------------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.s2
            Layout.bottomMargin: Theme.s2
            spacing: Theme.s4

            Rectangle {
                Layout.preferredWidth: 132
                Layout.preferredHeight: 132
                radius: Theme.rLg
                clip: true
                color: Sys.surface
                RoundedArt {
                    id: artImg
                    anchors.fill: parent
                    source: page.artist ? String(page.artist.thumb || "") : ""
                    radiusSpec: Theme.rLg
                    decodeWidth: 264
                }
                Glyph {
                    anchors.centerIn: parent
                    width: 46
                    height: 46
                    visible: !artImg.ready
                    kind: "music"
                    color: Sys.textDim
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.s3

                RowLayout {
                    spacing: Theme.s3

                    // Acción primaria: todo el artista, del más nuevo al viejo.
                    Rectangle {
                        width: playAllLabel.implicitWidth + Theme.pillHPad * 2 + 22
                        height: 40
                        radius: Theme.rPill
                        color: playAllMa.containsMouse
                               ? Theme.hover(Sys.accent) : Sys.accent
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s2
                            Glyph {
                                width: 15
                                height: 15
                                kind: "play"
                                color: Sys.bg
                            }
                            Text {
                                id: playAllLabel
                                text: "Reproducir todo"
                                color: Sys.bg
                                font.pixelSize: Theme.tMd
                                font.weight: Font.DemiBold
                            }
                        }
                        MouseArea {
                            id: playAllMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !page.busy
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.playAllRequested(false)
                            }
                        }
                    }

                    // Secundaria: idéntico pero con la cola entera barajada.
                    Rectangle {
                        width: shuffleAllLabel.implicitWidth + Theme.pillHPad * 2 + 22
                        height: 40
                        radius: Theme.rPill
                        color: shuffleAllMa.containsMouse ? Sys.surfaceAlt : "transparent"
                        border.width: 1
                        border.color: Theme.alpha(Sys.text, 0.28)
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s2
                            Glyph {
                                width: 15
                                height: 15
                                kind: "shuffle"
                                color: Sys.text
                            }
                            Text {
                                id: shuffleAllLabel
                                text: "Aleatorio"
                                color: Sys.text
                                font.pixelSize: Theme.tMd
                            }
                        }
                        MouseArea {
                            id: shuffleAllMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !page.busy
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.playAllRequested(true)
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }

                Text {
                    Layout.fillWidth: true
                    visible: page.busy
                    text: "Leyendo su discografía en YouTube Music…"
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                }
            }
        }

        // ---- discografía -----------------------------------------------------
        Text {
            visible: !page.busy && page.albums.length > 0
            text: "Discografía"
            color: Sys.textDim
            font.pixelSize: Theme.tXs
            font.letterSpacing: 1.4
            Layout.leftMargin: Theme.s1
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Text {
                anchors.centerIn: parent
                visible: !page.busy && page.albums.length === 0
                text: "Esta búsqueda no dejó discos a la vista."
                color: Sys.textDim
                font.pixelSize: Theme.tMd
            }

            ListView {
                anchors.fill: parent
                visible: page.albums.length > 0
                model: page.albums
                clip: true
                spacing: Theme.s1
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: arow
                    required property int index
                    required property var modelData

                    width: ListView.view.width
                    height: 64
                    radius: Theme.rMd
                    color: rowMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    MouseArea {
                        id: rowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            page.albumPlayRequested(arow.modelData)
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s2
                        anchors.rightMargin: Theme.s2
                        spacing: Theme.s3

                        Rectangle {
                            Layout.preferredWidth: 46
                            Layout.preferredHeight: 46
                            Layout.alignment: Qt.AlignVCenter
                            radius: Theme.rSm
                            clip: true
                            color: Sys.surface
                            RoundedArt {
                                id: covImg
                                anchors.fill: parent
                                source: String(arow.modelData.thumb || "")
                                radiusSpec: Theme.rSm
                                decodeWidth: 92
                            }
                            Glyph {
                                anchors.centerIn: parent
                                width: 20
                                height: 20
                                visible: !covImg.ready
                                kind: "disc"
                                color: Sys.textDim
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: String(arow.modelData.title || "")
                                color: Sys.text
                                font.pixelSize: Theme.tBase
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            Text {
                                Layout.fillWidth: true
                                text: String(arow.modelData.subtitle || "")
                                color: Sys.textDim
                                font.pixelSize: Theme.tSm
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // Pista de que la fila se reproduce entera.
                        Glyph {
                            width: 16
                            height: 16
                            visible: rowMa.containsMouse
                            kind: "play"
                            color: Sys.accent
                        }
                    }
                }
            }
        }
    }
}
