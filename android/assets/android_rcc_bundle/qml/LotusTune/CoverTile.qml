import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Cover tile of the Library grid: a card with a square cover,
// title with elide (it never overflows) and a one line subtitle. The root is
// transparent and the card leaves a gutter on the right/bottom so the page
// background separates the grid columns. On mouse hover
// the card brightens and the actions appear (download / remove).
Rectangle {
    id: tile

    property string title: ""
    property string subtitle: ""
    property string thumb: ""
    property bool downloadable: false
    property bool removable: false

    signal clicked()          // click on the card -> OPEN the list
    signal playClicked()      // click on the floating play button -> PLAY
    signal downloadRequested()
    signal removeRequested()
    // Right click on the card: context menu (x/y in window coordinates).
    signal contextRequested(real x, real y)

    // Mouse over the floating play button (visual feedback for the
    // button).
    property bool overPlay: false

    color: "transparent"
    border.width: 0

    Rectangle {                       // card WITHOUT box: direct cover and
        id: card                      // text below, like in the base repo
        x: 0
        y: 0
        // Phone: the tile is ~120 dp, so the desktop gutters (14/18) ate a
        // quarter of the cover. They shrink to keep the art big.
        width: tile.width - (Theme.touch ? 6 : 14)
        height: tile.height - (Theme.touch ? 10 : 18)
        radius: Theme.rMd
        color: "transparent"
        border.width: 0
        clip: false

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.touch ? Theme.s1 : Theme.s2
            spacing: Theme.touch ? Theme.s1 : Theme.s2

            Rectangle {                // square cover
                id: coverBox
                Layout.fillWidth: true
                // Cuadrada de verdad: el alto sigue al ancho que le da la
                // rejilla (antes era unos 30 px mas baja que ancha).
                Layout.preferredHeight: coverBox.width
                radius: Theme.rMd
                clip: true
                color: Theme.sAlt(Sys.bg, Sys.text)

                RoundedArt {
                    anchors.fill: parent
                    source: tile.thumb
                    visible: tile.thumb !== ""
                    radiusSpec: Theme.rMd
                }
                Glyph {
                    anchors.centerIn: parent
                    width: 30
                    height: 30
                    visible: tile.thumb === ""
                    kind: "music"
                    color: Theme.tDim(Sys.bg, Sys.text)
                }
                Rectangle {            // floating play button (over the mouse)
                    id: playBadge
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.s2
                    width: 30
                    height: 30
                    radius: Theme.rPill
                    color: tile.overPlay ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                    opacity: tileMa.containsMouse ? 1 : 0
                    scale: tileMa.containsMouse
                           ? (tileMa.pressed && tile.overPlay ? 0.92 : 1)
                           : 0.7
                    Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 13
                        height: 13
                        kind: "play"
                        color: Theme.onAccent(Sys.accent)
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: tile.title
                color: Sys.text
                font.pixelSize: Theme.tMd
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                maximumLineCount: 1
            }
            Text {
                Layout.fillWidth: true
                visible: tile.subtitle !== ""
                text: tile.subtitle
                color: Theme.tDim(Sys.bg, Sys.text)
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }

    // Hover of the WHOLE tile, passive on purpose: the action buttons sit ON
    // TOP of the card, so while the mouse is over them `tileMa.containsMouse`
    // turns false. Using that as the visibility condition made the buttons
    // disappear under the cursor (the blink) and the click landed on the
    // card instead of the button.
    HoverHandler { id: tileHover }

    MouseArea {
        id: tileMa
        anchors.fill: card
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        // Does the mouse fall inside the floating play button? (it is below
        // this MouseArea, so it is checked by hand instead of with a
        // its own MouseArea: it avoids stealing the hover from the card).
        function overPlayBtn(x, y) {
            const p = playBadge.mapToItem(tileMa, 0, 0)
            return x >= p.x && x <= p.x + playBadge.width
                   && y >= p.y && y <= p.y + playBadge.height
        }
        onMouseXChanged: tile.overPlay = overPlayBtn(mouseX, mouseY)
        onMouseYChanged: tile.overPlay = overPlayBtn(mouseX, mouseY)
        onExited: tile.overPlay = false

        // Long press = the right click of the phone: without this the menu
        // of the list (edit / delete / copy link) did not exist on touch.
        // `menuHeld` swallows the click that comes right after, otherwise
        // the menu would open AND the list would start playing.
        property bool menuHeld: false
        onPressAndHold: {
            tileMa.menuHeld = true
            const p = mapToItem(null, mouseX, mouseY)
            tile.contextRequested(p.x, p.y)
        }

        // Click on the play button -> PLAY; the rest -> OPEN.
        // Right click -> context menu of the list.
        onClicked: (mouse) => {
            if (tileMa.menuHeld) {
                tileMa.menuHeld = false
                return
            }
            if (typeof sfx !== "undefined") sfx.play("tap")
            if (mouse.button === Qt.RightButton) {
                const p = mapToItem(null, mouse.x, mouse.y)
                tile.contextRequested(p.x, p.y)
                return
            }
            if (overPlayBtn(mouse.x, mouse.y)) {
                if (typeof sfx !== 'undefined') sfx.play('play')
                tile.playClicked()
            } else {
                if (typeof sfx !== 'undefined') sfx.play('tap')
                tile.clicked()
            }
        }
    }

    // Actions: above the main MouseArea to receive the clicks.
    Column {
        x: card.width - width - Theme.s1
        y: Theme.s1
        z: 2
        spacing: Theme.s1
        visible: (tileHover.hovered || tileMa.containsMouse
                  || dlMa.containsMouse || rmMa.containsMouse || Theme.touch)
            && (tile.downloadable || tile.removable)

        Rectangle {
            visible: tile.downloadable
            width: 30
            height: 30
            radius: Theme.rPill
            color: dlMa.containsMouse ? Theme.hover(Sys.bg) : Sys.bg
            border.width: 0
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 15
                height: 15
                kind: "download"
                color: dlMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
            }
            MouseArea {
                id: dlMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("tap")
                    tile.downloadRequested()
                }
            }
        }

        Rectangle {
            visible: tile.removable
            width: 30
            height: 30
            radius: Theme.rPill
            color: rmMa.containsMouse ? Theme.alpha(Sys.danger, 0.16) : Sys.bg
            border.width: 0
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            Glyph {
                anchors.centerIn: parent
                width: 15
                height: 15
                kind: "x"
                color: rmMa.containsMouse ? Sys.danger : Theme.tDim(Sys.bg, Sys.text)
            }
            MouseArea {
                id: rmMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("tap")
                    tile.removeRequested()
                }
            }
        }
    }
}
