import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Menú contextual reutilizable (clic derecho), al estilo de Sonora: lista de
// entradas con icono, marca de verificación opcional, separadores y entradas
// atenuadas/deshabilitadas. Se abre en el punto pedido (`at`, en coordenadas de
// ventana) y se recorta a los márgenes. Cada entrada lleva su `action()` (una
// función JS); al pulsarla se cierra el menú y se ejecuta.
//
// Es "tonto": no conoce la app. Main le pasa `items` ya construidos y escucha
// `closed`.
Item {
    id: menu

    // [{ label, icon, enabled, checked, danger, separator, action }]
    property var items: []
    property point at: Qt.point(0, 0)
    property bool open: false

    signal closed()

    readonly property int menuW: 252
    readonly property int pad: 6
    readonly property real idealH: col.implicitHeight + 2 * pad

    visible: open
    z: 96

    // Cierra el menú avisando al dueño (Main), que es quien manda sobre
    // `open` mediante su binding. OJO: no asignar `open = false` aquí, porque
    // rompería ese binding y el menú sólo podría abrirse UNA vez.
    function dismiss() {
        if (!open)
            return
        closed()
    }

    // Capa que captura cualquier clic/fueda fuera del panel para cerrarlo.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: menu.dismiss()
        onWheel: (w) => { w.accepted = true }
    }

    // Isla flotante: `Panel` pone las esquinas redondeadas, el borde sutil y
    // la sombra suave; dentro va la lista, que hace scroll si no cabe.
    Panel {
        id: island
        width: menu.menuW
        height: Math.min(menu.idealH, Math.max(0, menu.height - Theme.s4))
        x: Math.max(Theme.s2, Math.min(menu.at.x, menu.width - width - Theme.s2))
        y: Math.max(Theme.s2, Math.min(menu.at.y, menu.height - height - Theme.s2))
        radius: Theme.rLg
        clipContent: true
        opacity: menu.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

        Flickable {
            id: flick
            anchors.fill: parent
            anchors.margins: menu.pad
            contentWidth: width
            contentHeight: col.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ColumnLayout {
                id: col
                width: flick.width
                spacing: 2

                Repeater {
                    model: menu.items

                    delegate: Item {
                        id: cell
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: modelData.separator === true ? Theme.s3 : Theme.rowThin

                        // Separador blando: en vez de una línea dura, una
                        // franja casi imperceptible que sólo da aire.
                        Rectangle {
                            visible: modelData.separator === true
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Theme.s3
                            anchors.rightMargin: Theme.s3
                            height: 1
                            color: Theme.alpha(Sys.text, 0.05)
                        }

                        Rectangle {
                            id: row
                            visible: modelData.separator !== true
                            anchors.fill: parent
                            radius: Theme.rMd
                            readonly property bool can: modelData.enabled !== false
                            readonly property bool on: hov.hovered && row.can
                            color: row.on ? Theme.alpha(Sys.accent, 0.12) : "transparent"

                            HoverHandler {
                                id: hov
                                enabled: row.can
                                cursorShape: Qt.PointingHandCursor
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s2
                                spacing: Theme.s2

                                Glyph {
                                    Layout.preferredWidth: 15
                                    Layout.preferredHeight: 15
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: (modelData.icon || "").length > 0
                                    kind: modelData.icon || "music"
                                    color: !row.can ? Sys.textDim
                                           : (modelData.danger === true ? Sys.danger
                                              : (modelData.checked === true || row.on
                                                 ? Sys.accent : Sys.text))
                                }

                                Text {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    text: modelData.label || ""
                                    color: !row.can ? Sys.textDim
                                           : (modelData.danger === true ? Sys.danger
                                              : (row.on ? Sys.accent : Sys.text))
                                    font.pixelSize: Theme.tBase
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    opacity: row.can ? 1 : 0.65
                                }

                                Glyph {
                                    Layout.preferredWidth: 13
                                    Layout.preferredHeight: 13
                                    Layout.alignment: Qt.AlignVCenter
                                    visible: modelData.checked === true
                                    kind: "check"
                                    color: Sys.accent
                                }
                            }

                            TapHandler {
                                enabled: row.can
                                onTapped: {
                                    if (typeof sfx !== 'undefined') sfx.play('tap')
                                    const act = cell.modelData.action
                                    menu.dismiss()
                                    if (typeof act === "function")
                                        act()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
