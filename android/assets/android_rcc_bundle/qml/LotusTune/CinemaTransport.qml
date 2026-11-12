import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Progress bar, times, transport and volume of the cinema, in one block.
//
// It is split from CinemaLeft because the phone puts the lyrics between
// the cover and the controls: the top block is the cover with the title,
// the lyrics follow, and this block closes the screen at the bottom.
// Desktop keeps both together in the left column.
ColumnLayout {
    id: ct
    spacing: Theme.s2

    property real position: 0
    property real duration: 0
    property bool playing: false
    property bool shuffleOn: false
    property int repeatVal: 0
    property int volume: 70
    // Desktop: everything aligned left. Phone: centred.
    property bool centered: false
    property color ink: Sys.text
    property color inkDim: Theme.tDim(Sys.bg, Sys.text)

    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)
    signal shuffleRequested()
    signal repeatRequested()
    signal volumeWanted(int value)

    // ---- progress ----------------------------------------------------
    Item {
        id: seekRow
        Layout.fillWidth: true
        Layout.topMargin: Theme.s3
        implicitHeight: 26
        // -1 = not dragging (the real position rules).
        property real scrub: -1
        readonly property real ratio: ct.duration > 0
            ? Math.min(1, Math.max(0, (seekRow.scrub >= 0
                                       ? seekRow.scrub : ct.position)
                                      / ct.duration))
            : 0
        function posAt(mx) {
            return Math.max(0, Math.min(1, mx / width)) * ct.duration
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 4
            radius: Theme.rMd
            antialiasing: true
            color: Theme.alpha(ct.ink, 0.18)
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width * seekRow.ratio)
            height: 4
            radius: Theme.rMd
            antialiasing: true
            color: Theme.accentOn(Sys.accent, Sys.bg)
        }
        Rectangle {
            x: Math.max(0, Math.min(seekRow.width - width,
                                    seekRow.width * seekRow.ratio - width / 2))
            anchors.verticalCenter: parent.verticalCenter
            width: 13
            height: 13
            radius: Theme.rLg
            antialiasing: true
            color: Theme.accentOn(Sys.accent, Sys.bg)
        }
        MouseArea {
            anchors.fill: parent
            anchors.topMargin: -10
            anchors.bottomMargin: -10
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: (m) => seekRow.scrub = seekRow.posAt(m.x)
            onPositionChanged: (m) => {
                if (pressed)
                    seekRow.scrub = seekRow.posAt(m.x)
            }
            onReleased: (m) => {
                const v = seekRow.posAt(m.x)
                seekRow.scrub = -1
                ct.seekRequested(v)
            }
            onCanceled: seekRow.scrub = -1
        }
    }

    // ---- tiempos ------------------------------------------------------
    RowLayout {
        Layout.fillWidth: true
        Text {
            text: Theme.mmss(seekRow.scrub >= 0 ? seekRow.scrub : ct.position)
            color: Theme.alpha(ct.ink, 0.60)
            font.pixelSize: Theme.tXs
        }
        Item { Layout.fillWidth: true }
        Text {
            text: Theme.mmss(ct.duration)
            color: Theme.alpha(ct.ink, 0.60)
            font.pixelSize: Theme.tXs
        }
    }

    // ---- transport ---------------------------------------------------
    // Order of the reference: shuffle, previous, play, next, loop. Play sits
    // on an accent disc (it is the only control that has to be seen without
    // looking for it).
    RowLayout {
        Layout.alignment: ct.centered ? Qt.AlignHCenter : Qt.AlignLeft
        Layout.topMargin: Theme.s2
        spacing: Theme.s2

        // Shuffle
        Item {
            width: 40; height: 40
            Rectangle {
                anchors.centerIn: parent
                width: 32; height: 32
                radius: width / 2
                antialiasing: true
                color: Theme.sAccent(Sys.bg, Sys.accent, 0.18)
                visible: ct.shuffleOn
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            }
            Glyph {
                anchors.centerIn: parent
                width: 19; height: 19
                kind: "shuffle"
                color: ct.shuffleOn ? Theme.accentOn(Sys.accent, Sys.bg)
                                    : ct.inkDim
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined")
                        sfx.play("toggle")
                    ct.shuffleRequested()
                }
            }
        }
        // Previous
        Item {
            width: 40; height: 40
            Glyph {
                anchors.centerIn: parent
                width: 24; height: 24
                kind: "prev"
                color: ct.ink
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined")
                        sfx.play("tap")
                    ct.prevRequested()
                }
            }
        }
        // Play / pause
        Rectangle {
            id: bigPlay
            width: 54; height: 54
            radius: Theme.rPanel
            antialiasing: true
            color: Theme.accentOn(Sys.accent, Sys.bg)
            scale: playPress.pressed ? 0.93 : 1
            Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
            HoverHandler { id: playPress; cursorShape: Qt.PointingHandCursor }
            Glyph {
                anchors.centerIn: parent
                width: 24; height: 24
                kind: ct.playing ? "pause" : "play"
                color: Theme.onAccentOf(Sys.accent, Theme.onAccent(Sys.accent))
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (typeof sfx !== "undefined")
                        sfx.play("play")
                    ct.toggleRequested()
                }
            }
        }
        // Next
        Item {
            width: 40; height: 40
            Glyph {
                anchors.centerIn: parent
                width: 24; height: 24
                kind: "next"
                color: ct.ink
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined")
                        sfx.play("tap")
                    ct.nextRequested()
                }
            }
        }
        // Loop: mode 1 = repeat the list, mode 2 = repeat ONLY this track. The
        // inner "1" of the glyph is invisible at this size: mode 2 is marked
        // with a badge.
        Item {
            width: 40; height: 40
            Rectangle {
                id: repDisc
                anchors.centerIn: parent
                width: 32; height: 32
                radius: width / 2
                antialiasing: true
                color: Theme.sAccent(Sys.bg, Sys.accent, 0.18)
                visible: ct.repeatVal > 0
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            }
            Glyph {
                anchors.centerIn: parent
                width: 19; height: 19
                kind: "repeat"
                color: ct.repeatVal > 0 ? Theme.accentOn(Sys.accent, Sys.bg)
                                        : ct.inkDim
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            }
            Rectangle {
                visible: ct.repeatVal === 2
                anchors.right: repDisc.right
                anchors.bottom: repDisc.bottom
                anchors.rightMargin: -1
                anchors.bottomMargin: -1
                width: 13; height: 13
                radius: Theme.rLg
                antialiasing: true
                color: Sys.accent
                Text {
                    anchors.centerIn: parent
                    text: "1"
                    color: Theme.onAccent(Sys.accent)
                    font.pixelSize: 9
                    font.weight: Font.Bold
                }
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined")
                        sfx.play("toggle")
                    ct.repeatRequested()
                }
            }
        }


        // The separator exists on desktop only: on the phone it would push the
        // transport to the left and it would not be centred.
        Item { Layout.fillWidth: true; visible: !ct.centered }
        // Volume (desktop): on the phone the physical buttons do the job and
        // space is gold.
        RowLayout {
            visible: !ct.centered
            Layout.leftMargin: Theme.s3
            spacing: Theme.s1

            Glyph {
                Layout.alignment: Qt.AlignVCenter
                width: 16; height: 16
                kind: ct.volume > 0 ? "volume" : "volume-x"
                weight: 1.6
                color: ct.inkDim
            }

            Rectangle {
                id: fsVolTrack
                Layout.preferredWidth: 76
                Layout.alignment: Qt.AlignVCenter
                height: 16
                color: "transparent"

                readonly property real max: 130
                readonly property real ratio: Math.min(1, ct.volume / max)

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width; height: 3; radius: 1.5
                    color: Theme.alpha(Sys.text, 0.18)
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * fsVolTrack.ratio
                    height: 3; radius: 1.5
                    color: Theme.accentOn(Sys.accent, Sys.bg)
                }
                Rectangle {
                    x: parent.width * fsVolTrack.ratio - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 10; height: 10; radius: 5
                    color: Theme.accentOn(Sys.accent, Sys.bg)
                    scale: fsVolMa.containsMouse ? 1.05 : 0.9
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                }
                MouseArea {
                    id: fsVolMa
                    anchors.fill: parent
                    anchors.topMargin: -8
                    anchors.bottomMargin: -8
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    function setAt(mouse) {
                        const r = Math.max(0, Math.min(1, mouse.x / fsVolTrack.width))
                        ct.volumeWanted(Math.round(r * fsVolTrack.max))
                    }
                    onPressed: (mouse) => setAt(mouse)
                    onPositionChanged: (mouse) => { if (pressed) setAt(mouse) }
                }
            }
        }
    }
}
