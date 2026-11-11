import QtQuick
import "theme.js" as Theme

// "Liked" (library) heart for the list rows.
// Minimal: a dimmed outline when the track is not saved
// (`Theme.tDim(Sys.bg, Sys.text)`), a filled glyph in the accent colour plus
// a faint pill behind it when it is (`Sys.accent`). That pill makes the
// MARKED state obvious at a glance in the queue and in the side panel, not
// only by the shape of the glyph. It reserves its space so the title does
// not move when it appears. It emits `toggled()`.
//
// It is "dumb": the state (`liked`) and the action are decided by the row,
// which knows the videoId and the global library state.
Item {
    id: btn

    property bool liked: false
    property bool revealed: false      // the mouse is over the row
    property bool interactive: true    // there is a YouTube Music session

    // The pointer is over the heart itself: it has to stay visible even
    // when the row's hover is lost for a frame (moving the pointer from
    // the row onto a heart that was just appearing made it fade out under
    // the cursor, and the click landed on the row: the song started
    // instead of liking it).
    readonly property bool hovered: ma.containsMouse
    readonly property bool shown: btn.interactive
        && (btn.liked || btn.revealed || btn.hovered || Theme.touch)

    signal toggled()

    // Without a session it disappears; with one it reserves the space
    // and shows/hides.
    visible: btn.interactive
    opacity: btn.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
    // A 24 px glyph in a bigger box: the row target is small and the heart
    // only shows on hover, so the clickable area is what has to be forgiving.
    implicitWidth: 30
    implicitHeight: 30

    // Background pill: ONLY with a liked track. An accent veil around the
    // heart that makes the "liked" obvious (queue and side panel).
    Rectangle {
        anchors.fill: parent
        radius: Theme.rPill
        antialiasing: true
        color: btn.liked
               ? Theme.alpha(Sys.accent, btn.hovered ? 0.24 : 0.15)
               : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
    }

    Glyph {
        anchors.centerIn: parent
        width: 16
        height: 16
        kind: btn.liked ? "heart" : "heart-outline"
        weight: btn.liked ? 1.9 : 1.6
        color: btn.liked ? Theme.accentOn(Sys.accent, Sys.bg)
                         : (btn.hovered ? Sys.text : Theme.tDim(Sys.bg, Sys.text))
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
    }

    // MouseArea (not a TapHandler) so the press is taken here and the row
    // underneath does not steal it: `preventStealing` keeps the drag for
    // this item, and accepting the click stops the row from also opening
    // the track.
    MouseArea {
        id: ma
        anchors.fill: parent
        enabled: btn.interactive
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (typeof sfx !== 'undefined')
                sfx.play(btn.liked ? 'unlike' : 'like')
            btn.toggled()
        }
    }
}
