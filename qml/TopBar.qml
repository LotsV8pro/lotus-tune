import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Barra superior por página. Deliberadamente parca: un título, un acceso al
// buscador y los ajustes. El subtítulo y el chip de fuente se retiraron para
// no competir con el contenido (la fuente activa vive en Biblioteca/Ajustes).
Rectangle {
    id: top

    property string title: ""
    property string subtitle: ""   // se conserva por compatibilidad; no se pinta
    property bool showBack: false

    signal backRequested()
    signal launcherRequested()
    signal settingsRequested()

    color: "transparent"

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 22
        anchors.rightMargin: 18
        spacing: 10

        Rectangle {
            visible: top.showBack
            Layout.alignment: Qt.AlignVCenter
            width: 32
            height: 32
            radius: Theme.rMd
            color: backHover.hovered ? Sys.surfaceAlt : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
            Glyph {
                anchors.centerIn: parent
                width: 16; height: 16
                kind: "chevron-left"
                color: backHover.hovered ? Sys.accent : Sys.text
            }
            TapHandler { onTapped: top.backRequested() }
        }

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: top.title
            color: Sys.text
            font.pixelSize: Theme.tLg
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Item { Layout.fillWidth: true }

        // Buscador rápido (abre el lanzador). Sólo un filo, sin relleno.
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 260
            Layout.maximumWidth: 320
            height: 34
            radius: Theme.rMd
            color: searchHover.hovered ? Theme.hover(Sys.bg) : "transparent"
            border.width: 1
            border.color: searchHover.hovered ? Sys.border : Sys.borderSubtle
            Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            HoverHandler { id: searchHover; cursorShape: Qt.PointingHandCursor }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10
                Glyph {
                    Layout.preferredWidth: 15
                    Layout.preferredHeight: 15
                    Layout.alignment: Qt.AlignVCenter
                    kind: "search"
                    color: searchHover.hovered ? Sys.accent : Sys.textDim
                }
                Text {
                    Layout.fillWidth: true
                    text: "Buscar o pegar un enlace…"
                    color: Sys.textDim
                    font.pixelSize: Theme.tMd
                    elide: Text.ElideRight
                }
            }
            TapHandler { onTapped: top.launcherRequested() }
        }

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: 32
            height: 32
            radius: Theme.rMd
            color: gearHover.hovered ? Sys.surfaceAlt : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            HoverHandler { id: gearHover; cursorShape: Qt.PointingHandCursor }
            Glyph {
                anchors.centerIn: parent
                width: 17; height: 17
                kind: "gear"
                color: gearHover.hovered ? Sys.accent : Sys.textDim
            }
            TapHandler { onTapped: top.settingsRequested() }
        }
    }
}
