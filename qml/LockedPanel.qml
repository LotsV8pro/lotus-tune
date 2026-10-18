import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Shown by every page while the active source cannot stream yet: explains
// exactly what is needed to activate it.
// Minimalismo: un icono quieto, un titular, una línea de apoyo y un único
// botón de texto en acento. Sin cajas, sin adornos.
ColumnLayout {
    id: panel

    property string sourceName: ""
    property string note: ""

    spacing: Theme.s3

    Item { Layout.preferredHeight: Theme.s6 }

    Glyph {
        Layout.alignment: Qt.AlignHCenter
        width: 28
        height: 28
        kind: "lock"
        color: Sys.textDim
        weight: 1.4
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

    // Indicación de acción como píldora tenue: se enciende con el ratón.
    Rectangle {
        Layout.alignment: Qt.AlignHCenter
        Layout.topMargin: Theme.s1
        implicitWidth: actText.implicitWidth + Theme.pillHPad * 2
        implicitHeight: Theme.pillH
        radius: Theme.rPill
        color: actMa.containsMouse ? Theme.alpha(Sys.accent, 0.14) : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

        Text {
            id: actText
            anchors.centerIn: parent
            text: "Elige una fuente activa en la barra lateral"
            color: actMa.containsMouse ? Sys.accent : Sys.textDim
            font.pixelSize: Theme.tSm
            font.weight: Font.Medium
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        }

        MouseArea {
            id: actMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
        }
    }
}