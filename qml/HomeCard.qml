import QtQuick
import "theme.js" as Theme

// Minimal card for the home rails.
//
// FIXED size (cardWidth/coverSize/textHeight) so the grid never shifts on
// hover: the hover feedback is a soft zoom on the artwork, no shadows and
// no extra layers.
//
// Click on the ARTWORK  -> opens the list/playlist.
// Click on the BUTTON  -> plays it.
Item {
    id: card

    property string title: ""
    property string subtitle: ""
    property string icon: "play"
    property color coverA: "#232a33"
    property color coverB: "#12151a"
    property string badge: ""
    property string thumb: ""
    property bool round: false
    // Dominant colour of the artwork: the placeholder gradient takes it, so
    // the card carries the colour of its art while it loads and, if the
    // image never arrives, it keeps that colour instead of a generic blue.
    // Transparent = colour not known yet.
    property color artColor: "transparent"
    readonly property bool hasArtColor: artColor.a > 0
    // Fallback icon colour: resolved on its own so it never depends on the
    // theme object at the exact repaint moment (an intermittent TypeError
    // read Sys.text before Sys was ready).
    property color iconColor: (typeof Sys === "object")
        ? Theme.alpha(Sys.text, 0.55) : "#8a8a8a"

    signal clicked()
    signal playClicked()

    // When the artwork changes, ask for its dominant colour (the C++ side
    // extracts it from the image and reports it through the "found" signal).
    onThumbChanged: {
        artColor = "transparent"
        if (thumb && thumb.length > 0 && typeof colorpick !== "undefined")
            colorpick.pick(thumb)
    }

    Connections {
        target: colorpick
        function onFound(url, color) {
            if (String(url) === card.thumb)
                card.artColor = color
        }
    }

    readonly property bool hovered: hoverHandler.hovered || playHit.containsMouse

    // Colour that tints the card background: the artwork's dominant colour
    // once known; for cards without artwork (Liked, the shortcuts) the
    // base colour of its cover.
    readonly property color tintColor: hasArtColor ? artColor : coverA

    // ---- fixed measurements (they never change on hover) ------------
    readonly property int cardWidth: 172
    readonly property int coverSize: cardWidth
    readonly property int textHeight: 54

    implicitWidth: cardWidth
    implicitHeight: coverSize + textHeight
    width: implicitWidth
    height: implicitHeight

    HoverHandler { id: hoverHandler }

    // Clickable background (opens the list). It comes FIRST, under the
    // content: that way the play button (which lives inside `inner`) keeps
    // its clicks and the rest of the card gets the ones of this area. The
    // other way round this layer covered the button and the card's play
    // never did anything.
    MouseArea {
        anchors.fill: parent
        // Without `hoverEnabled`: a MouseArea with the hover enabled keeps the
        // hover events and the card's HoverHandler would be left without
        // them (and the zoom and the play button would never appear).
        cursorShape: Qt.PointingHandCursor
        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); card.clicked() }
    }

    // Card background tinted with the colour of its artwork: a gradient
    // from the strong colour at the top (where the picture is) to
    // transparent at the bottom, so the text stays readable.
    Rectangle {
        anchors.fill: parent
        radius: Theme.rXl
        visible: card.tintColor.a > 0
        gradient: Gradient {
            // With an artwork colour the tint reads stronger; with the
            // base colour (cards without artwork) it stays subtle,
            // otherwise the rail looks like a rave.
            GradientStop { position: 0.0
                          color: Theme.alpha(card.tintColor,
                                             card.hasArtColor ? 0.40 : 0.26) }
            GradientStop { position: 0.62
                          color: Theme.alpha(card.tintColor,
                                             card.hasArtColor ? 0.16 : 0.10) }
            GradientStop { position: 1.0
                          color: Theme.alpha(card.tintColor, 0.0) }
        }
    }

    // The content does not move on hover (it used to rise 2 px, which
    // made the rail wobble): what reacts is the PICTURE, with a soft
    // zoom, and the play button appears in the corner.
    Item {
        id: inner
        width: card.width
        height: card.height

        Rectangle {
            id: cover
            width: card.coverSize
            height: card.coverSize
            // The picture grows a little on hover (the rest of the card
            // stays put). The scaling carries its own corner radius.
            scale: card.hovered ? 1.045 : 1
            Behavior on scale {
                NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
            }
            // The only thing reworked on the card: the artwork corner
            // radius goes from rMd to rXl (22 px). Nothing else.
            radius: card.round ? width / 2 : Theme.rXl
            clip: true

            gradient: Gradient {
                GradientStop { position: 0.0
                              color: card.hasArtColor ? Qt.lighter(card.artColor, 1.35)
                                                      : card.coverA }
                GradientStop { position: 1.0
                              color: card.hasArtColor ? Qt.darker(card.artColor, 1.7)
                                                      : card.coverB }
            }

            RoundedArt {
                id: coverArt
                anchors.fill: parent
                source: card.thumb
                radiusSpec: card.round ? "circle" : Theme.rXl
            }

            // Fallback icon when there is no artwork.
            Glyph {
                anchors.centerIn: parent
                width: 40
                height: 40
                kind: card.icon
                color: card.iconColor
                visible: card.thumb.length === 0
            }

            // Tag (YT / RADIO / …) as a pill.
            Rectangle {
                visible: card.badge.length > 0
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Theme.s2
                height: 18
                radius: Theme.rPill
                color: Theme.alpha(Sys.bg, 0.72)
                implicitWidth: badgeLabel.implicitWidth + Theme.pillHPad
                Text {
                    id: badgeLabel
                    anchors.centerIn: parent
                    text: card.badge
                    color: Sys.text
                    font.pixelSize: Theme.tXs
                    font.bold: true
                    font.letterSpacing: 0.8
                }
            }

            // Play button in the CORNER of the artwork (bottom right): it
            // shows on hover, over the picture that zooms. It lives INSIDE
            // the artwork so it stays in its corner when the artwork
            // grows.
            Rectangle {
                id: playBtn
                width: 38
                height: 38
                radius: Theme.rPill
                color: playHit.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                // No border: on a round shape the outline is traced inside
                // and it comes out uneven (a halo around the button). The
                // accent colour is enough contrast on its own.
                anchors.right: parent.right
                anchors.rightMargin: Theme.s2
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Theme.s2
                opacity: card.hovered ? 1 : 0
                scale: card.hovered ? (playHit.pressed ? 0.92
                                        : (playHit.containsMouse ? 1.06 : 1)) : 0.8
                Behavior on opacity { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                Glyph {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 1
                    width: 16
                    height: 16
                    kind: "play"
                    color: Sys.onAccent
                }

                MouseArea {
                    id: playHit
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("play"); card.playClicked() }
                }
            }
        }

        // Text: title on at most 2 lines + a one line subtitle. The height
        // is reserved (textHeight) so the rail never jumps.
        Column {
            anchors.top: cover.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            topPadding: Theme.s1
            spacing: 1

            Text {
                width: parent.width
                height: card.textHeight - Theme.s1 - 16
                text: card.title
                color: Sys.text
                font.pixelSize: Theme.tBase
                font.weight: Font.DemiBold
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 2
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
            }
            Text {
                width: parent.width
                height: 16
                text: card.subtitle
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
                maximumLineCount: 1
                verticalAlignment: Text.AlignTop
            }
        }
    }
}
