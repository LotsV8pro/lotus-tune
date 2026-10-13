import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Shown by every page while the active source cannot stream yet: explains
// exactly what is needed to activate it.
ColumnLayout {
    id: panel

    property string sourceName: ""
    property string note: ""

    spacing: Theme.s3

    Item { Layout.preferredHeight: Theme.s6 }

    Glyph {
        Layout.alignment: Qt.AlignHCenter
        width: 42
        height: 42
        kind: "lock"
        color: Sys.textDim
        weight: 1.3
    }

    Text {
        Layout.alignment: Qt.AlignHCenter
        text: panel.sourceName + " — fuente inactiva"
        color: Sys.text
        font.pixelSize: Theme.tLg
        font.weight: Font.DemiBold
    }

    Text {
        Layout.alignment: Qt.AlignHCenter
        Layout.fillWidth: true
        Layout.maximumWidth: 420
        text: panel.note
        color: Sys.textDim
        font.pixelSize: Theme.tMd
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        lineHeight: 1.25
    }

    Text {
        Layout.alignment: Qt.AlignHCenter
        text: "Elige una fuente activa en la barra lateral"
        color: Sys.textDim
        font.pixelSize: Theme.tSm
        opacity: 0.75
    }
}
