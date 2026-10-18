import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Panel derecho conmutable: COLA y LETRAS. Se muestra/oculta desde Main y
// se alimenta de datos por propiedades (la cola) o de los context properties
// (la letra la lee LyricsView directamente).
//
// Es una única "isla flotante": la raíz es transparente y toda la superficie
// redondeada (con su borde sutil y su sombra) la aporta `Panel`.
Item {
    id: panel

    property int tab: 0                 // 0 = cola, 1 = letras
    property var queueModel: null
    property int queueIndex: -1

    signal closeRequested()
    signal trackActivated(int index)
    signal trackContextRequested(var track, real x, real y)

    implicitWidth: 360

    Panel {
        id: island
        anchors.fill: parent
        clipContent: true

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.s3
            spacing: Theme.s2

            // ---- cabecera ---------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2

                // Pestañas-píldora: cápsulas con acento suave en la activa,
                // sin subrayados ni líneas duras.
                Repeater {
                    model: [ { t: 0, name: "Cola", icon: "queue" },
                             { t: 1, name: "Letra", icon: "lyrics" } ]
                    delegate: Item {
                        id: tabItem
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.pillH
                        readonly property bool on: panel.tab === modelData.t

                        HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rPill
                            color: tabItem.on ? Theme.alpha(Sys.accent, 0.16)
                                   : (tabHover.hovered ? Theme.hover(Sys.surface) : "transparent")
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        }

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

                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); panel.tab = tabItem.modelData.t } }
                    }
                }

                // Cerrar: píldora circular, del mismo alto que las pestañas.
                Rectangle {
                    Layout.preferredWidth: Theme.pillH
                    Layout.preferredHeight: Theme.pillH
                    radius: Theme.rPill
                    color: closeHover.hovered ? Theme.hover(Sys.surface) : "transparent"
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

            // ---- contenido --------------------------------------------
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
                    // El difuminado de bordes debe fundirse con el fondo real
                    // de la isla, que ya es la superficie del `Panel`.
                    edgeColor: island.color
                }
            }
        }
    }
}
