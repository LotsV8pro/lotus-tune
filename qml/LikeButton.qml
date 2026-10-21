import QtQuick
import "theme.js" as Theme

// "Liked" (library) heart for the list rows.
// Minimal: a dimmed outline when the track is not saved (`Sys.textDim`),
// a filled glyph in the accent colour plus a faint pill behind it when it
// is (`Sys.accent`). That pill makes the MARKED state obvious at a
// glance in the queue and in the side panel, not only by the shape of the
// glyph. It reserves its space so the title does not move when it
// appears. It emits `toggled()`.
//
// It is "dumb": the state (`liked`) and the action are decided by the row,
// which knows the videoId and the global library state.
Item {
    id: btn

    property bool liked: false
    property bool revealed: false      // the mouse is over the row
    property bool interactive: true    // there is a YouTube Music session

    readonly property bool shown: btn.interactive && (btn.liked || btn.revealed)

    signal toggled()

    // Without a session it disappears; with one it reserves the space
    // and shows/hides.
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

    // Background pill: ONLY with a liked track. An accent veil around the
    // heart that makes the "liked" obvious (queue and side panel).
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
