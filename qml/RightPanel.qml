import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Panel derecho conmutables: COLA y LETRAS. Se muestra/oculta desde Main y
// se alimenta de datos por propiedades (la cola) o de los context properties
// (la letra la lee LyricsView directamente).
Rectangle {
    id: panel

    property int tab: 0                 // 0 = cola, 1 = letras
    property var queueModel: null
    property int queueIndex: -1

    signal closeRequested()
    signal trackActivated(int index)
    signal trackContextRequested(var track, real x, real y)

    implicitWidth: 360
    color: Sys.bg

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        // ---- cabecera -------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.s2

            // Pestañas discretas: texto + subrayado de acento en la activa.
            Repeater {
                model: [ { t: 0, name: "Cola", icon: "queue" },
                         { t: 1, name: "Letra", icon: "lyrics" } ]
                delegate: Item {
                    id: tabItem
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34
                    readonly property bool on: panel.tab === modelData.t

                    HoverHandler { cursorShape: Qt.PointingHandCursor }

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 6
                        Glyph {
                            width: 14; height: 14
                            kind: tabItem.modelData.icon
                            color: tabItem.on ? Sys.accent : Sys.textDim
                        }
                        Text {
                            text: tabItem.modelData.name
                            color: tabItem.on ? Sys.text : Sys.textDim
                            font.pixelSize: Theme.tBase
                            font.weight: tabItem.on ? Font.DemiBold : Font.Medium
                        }
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: Theme.s5
                        anchors.rightMargin: Theme.s5
                        height: 2
                        radius: 1
                        color: Sys.accent
                        visible: tabItem.on
                    }

                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); panel.tab = tabItem.modelData.t } }
                }
            }

            Rectangle {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 34
                radius: Theme.rMd
                color: closeHover.hovered ? Theme.hover(Sys.bg) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                Glyph {
                    anchors.centerIn: parent
                    width: 14; height: 14
                    kind: "chevron-right"
                    color: closeHover.hovered ? Sys.accent : Sys.textDim
                }
                TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); panel.closeRequested() } }
            }
        }

        // ---- contenido ------------------------------------------------
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: panel.tab

            QueueView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                tracks: panel.queueModel
                currentIndex: panel.queueIndex
                onTrackActivated: (i) => panel.trackActivated(i)
                onTrackContextRequested: (t, x, y) => panel.trackContextRequested(t, x, y)
            }

            LyricsView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                // El difuminado de bordes debe pegarse con el fondo real del
                // panel, que no es exactamente Sys.surface.
                edgeColor: panel.color
            }
        }
    }
}