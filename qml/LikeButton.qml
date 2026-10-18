import QtQuick
import "theme.js" as Theme

// Corazón de "me gusta" (biblioteca) para las filas de las listas.
// Minimalista: contorno atenuado cuando la pista no está guardada
// (`Sys.textDim`), glifo lleno en acento + una píldora tenue de fondo cuando
// sí (`Sys.accent`). Esa píldora hace que el estado MARCADO se note de un
// vistazo en la cola y en el lateral, no solo por la forma del glifo.
// Reserva su hueco para que el título no se mueva al aparecer. Emite
// `toggled()`.
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

    // Píldora de fondo: SOLO con la pista marcada. Un velo de acento que
    // rodea el corazón y hace evidente el "me gusta" (cola y lateral).
    Rectangle {
        anchors.fill: parent
        radius: Theme.rPill
        color: btn.liked
               ? Theme.alpha(Sys.accent, hh.hovered ? 0.24 : 0.15)
               : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
    }

    Glyph {
        anchors.centerIn: parent
        width: 15
        height: 15
        kind: btn.liked ? "heart" : "heart-outline"
        weight: btn.liked ? 1.9 : 1.6
        color: btn.liked ? Sys.accent : (hh.hovered ? Sys.text : Sys.textDim)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
    }

    TapHandler {
        enabled: btn.shown
        onTapped: {
            if (typeof sfx !== 'undefined') sfx.play(btn.liked ? 'unlike' : 'like')
            btn.toggled()
        }
    }
}
