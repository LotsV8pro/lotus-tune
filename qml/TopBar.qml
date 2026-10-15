import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Barra superior por página. Plana y silenciosa: atrás (si aplica), el título
// de la página y dos accesos discretos (lanzador y ajustes). Sin subtítulo, sin
// sombra inferior y sin bordes pesados: la jerarquía viene del aire.
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
        anchors.leftMargin: Theme.s4
        anchors.rightMargin: Theme.s3
        spacing: Theme.s1

        // Atrás: sólo cuando la página es hija de otra.
        Rectangle {
            visible: top.showBack
            Layout.alignment: Qt.AlignVCenter
            width: Theme.rowThin
            height: Theme.rowThin
            radius: Theme.rMd
            color: backHover.hovered ? Theme.hover(Sys.surface) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
            Glyph {
                anchors.centerIn: parent
                width: 16; height: 16
                kind: "chevron-left"
                color: Sys.text
            }
            TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.backRequested() } }
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

        // Lanzador: un acceso callado, no un campo con borde.
        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: Theme.rowThin
            height: Theme.rowThin
            radius: Theme.rMd
            color: launcherHover.hovered ? Theme.hover(Sys.surface) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            HoverHandler { id: launcherHover; cursorShape: Qt.PointingHandCursor }
            Glyph {
                anchors.centerIn: parent
                width: 17; height: 17
                kind: "search"
                color: launcherHover.hovered ? Sys.text : Sys.textDim
            }
            TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.launcherRequested() } }
        }

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: Theme.rowThin
            height: Theme.rowThin
            radius: Theme.rMd
            color: gearHover.hovered ? Theme.hover(Sys.surface) : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            HoverHandler { id: gearHover; cursorShape: Qt.PointingHandCursor }
            Glyph {
                anchors.centerIn: parent
                width: 17; height: 17
                kind: "gear"
                color: gearHover.hovered ? Sys.text : Sys.textDim
            }
            TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); top.settingsRequested() } }
        }
    }
}
