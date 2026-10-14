import QtQuick
import "theme.js" as Theme

// Corazón de "me gusta" (biblioteca) para las filas de las listas.
// Minimalista: solo el glifo. Contorno atenuado cuando la pista no está
// guardada (`Sys.textDim`), acento cuando sí (`Sys.accent`); sin caja ni
// fondo propio, la jerarquía la da el color. Reserva su hueco para que el
// título no se mueva al aparecer. Emite `toggled()`.
//
// Es "tonto": el estado (`liked`) y la acción los decide la fila, que conoce
// el videoId y el estado global de la biblioteca.
Item {
    id: btn

    property bool liked: false
    property bool revealed: false      // el ratón está sobre la fila
    property bool interactive: true    // hay sesión de YT Music

    readonly property bool shown: btn.interactive && (btn.liked || btn.revealed)

    signal toggled()

    // Sin sesión desaparece; con sesión reserva el hueco y aparece/desaparece.
    visible: btn.interactive
    opacity: btn.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
    implicitWidth: 24
    implicitHeight: 24

    HoverHandler {
        id: hh
        enabled: btn.shown
        cursorShape: Qt.PointingHandCursor
    }

    Glyph {
        anchors.centerIn: parent
        width: 15
        height: 15
        kind: btn.liked ? "heart" : "heart-outline"
        weight: 1.6
        color: btn.liked ? Sys.accent : (hh.hovered ? Sys.text : Sys.textDim)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
    }

    TapHandler {
        enabled: btn.shown
        onTapped: btn.toggled()
    }
}
