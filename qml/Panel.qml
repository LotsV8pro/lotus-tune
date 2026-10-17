import QtQuick
import "theme.js" as Theme

// Isla flotante: superficie redondeada con un filo luminoso muy tenue. Es el
// ladrillo de la interfaz — el rail, la barra de título, la barra de
// reproducción, el panel lateral y el contenido son todos `Panel`.
//
// Nota sobre la sombra: en un fondo tan oscuro (#151115) una sombra negra no
// aporta contraste, así que la sensación de "flotar" la da el aire de
// `panelMargin`/`panelGap` más el borde claro, que son las propiedades que
// realmente se ven. Nada de efectos ni texturas: cero coste de render.
//
// Los hijos declarados dentro se colocan EN la superficie, de modo que
// `clipContent` recorta el contenido a las esquinas de la isla (útil para
// listas que hacen scroll). El relleno interior lo pone cada componente.
Item {
    id: panel

    property real radius: Theme.rPanel
    property color color: Sys.surface
    property color borderColor: Theme.alpha(Sys.text, Theme.panelBorderAlpha)
    property real borderWidth: 1
    property bool clipContent: false

    default property alias content: surface.data

    Rectangle {
        id: surface
        anchors.fill: parent
        radius: panel.radius
        color: panel.color
        border.width: panel.borderWidth
        border.color: panel.borderColor
        clip: panel.clipContent
    }
}
