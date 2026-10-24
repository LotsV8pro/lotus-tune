import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Playback bar: a low, minimal floating island (Panel).
//
// The progress bar goes ON TOP, full width, as a thin line: that leaves a
// single row of content below (track info on the left, transport in the
// middle, actions on the right) and the bar can stay low without the
// transport running out of room. No extra layers or effects.
Rectangle {
    id: bar

    // Phone: secondary actions (shuffle, repeat, volume, the heart when
    // it cannot be used yet) hide so the transport and queue/lyrics fit
    // with air; active sizes grow for touch targets.
    readonly property bool compact: Theme.touch

    property bool playing: false
    // Track requested but not playing yet (resolving the stream): the bar
    // shows a waiting state so the start does not look stuck.
    property bool loading: false
    property real position: 0
    property real duration: 0
    property string title: ""
    property string artist: ""
    property string currentThumb: ""
    property int volume: 70
    property bool shuffle: false
    // 0 = no repeat, 1 = repeat the list, 2 = repeat the track.
    property int repeatMode: 0
    // videoId of the current track + its "liked" state (YouTube Music).
    property string videoId: ""
    property bool liked: false
    // Is there a YouTube Music session? (enables like / add to list)
    property bool canInteract: false

    signal toggle()
    signal nextRequested()
    signal prevRequested()
    signal shuffleToggled()
    signal repeatToggled()
    signal lyricsRequested()
    signal queueRequested()
    signal lyricsPanelRequested()
    signal seekRequested(real seconds)
    signal volumeWanted(int value)
    signal likeRequested()
    signal addToPlaylistRequested()
    // Context menu of the track (right click on the left hand info) and
    // go to the artist (click on their name).
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)

    property bool scrubbing: false
    property real scrubPos: 0

    // Island height: the bar measures exactly what its surface does.
    implicitHeight: Theme.playerBarH
    color: "transparent"

    readonly property color _ui: Theme.hover(Sys.surface)

    // ---- reusable icon button ---------------------------------------
    component BarButton: Rectangle {
        id: bb
        property string kind: "play"
        property bool active: false
        property color iconColor: bar.compact ? Sys.text : Sys.textDim
        property int diameter: bar.compact ? 34 : 28
        property real glyph: bar.compact ? 16 : 14
        signal tapped()
        width: diameter
        height: diameter
        radius: diameter / 2
        color: (bbHover.hovered || bb.active) ? bar._ui : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        HoverHandler { id: bbHover; cursorShape: Qt.PointingHandCursor }
        Glyph {
            anchors.centerIn: parent
            width: bb.glyph
            height: bb.glyph
            kind: bb.kind
            weight: 1.6
            color: bb.active ? Sys.accent
                   : (bbHover.hovered ? Sys.text : bb.iconColor)
        }
        TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bb.tapped() } }
    }

    // ---- floating island ---------------------------------------------
    Panel {
        id: island
        anchors.fill: parent
        // The content is clipped to the island's corners: the progress
        // line on top follows the rounding instead of sticking out.
        clipContent: true

        ColumnLayout {
            anchors.fill: parent
            // Generous side margins: the bar breathes and nothing
            // (buttons, artwork, volume) is glued to the island's edge.
            anchors.leftMargin: bar.compact ? Theme.s3 : Theme.s5
            anchors.rightMargin: bar.compact ? Theme.s3 : Theme.s5
            anchors.bottomMargin: Theme.s1
            spacing: 0

            // ---- progress (thin line, full width) ---------------------
            // The row has extra height so the times are not glued to the
            // top edge of the island: there is air above them.
            RowLayout {
                id: progressRow
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                spacing: Theme.s2

                Text {
                    text: Theme.mmss(bar.scrubbing ? bar.scrubPos : bar.position)
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    Layout.preferredWidth: 30
                    horizontalAlignment: Text.AlignRight
                }

                Rectangle {
                    id: scrubTrack
                    Layout.fillWidth: true
                    height: 24
                    color: "transparent"

                    readonly property real ratio: bar.duration > 0
                        ? Math.min(1, (bar.scrubbing ? bar.scrubPos : bar.position) / bar.duration) : 0

                    // Track.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width; height: 2; radius: 1
                        color: Theme.mix(Sys.surface, Sys.text, 0.18)
                    }
                    // Fill.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * scrubTrack.ratio
                        height: 2; radius: 1
                        color: Sys.accent
                    }
                    // Knob: only shows on hover or while dragging.
                    Rectangle {
                        x: parent.width * scrubTrack.ratio - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: Sys.accent
                        scale: scrubArea.hovered || bar.scrubbing ? 1.1 : 0
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: scrubArea }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        function posAt(mouse) {
                            return Math.max(0, Math.min(1, mouse.x / width)) * bar.duration
                        }
                        onPressed: (mouse) => { bar.scrubbing = true; bar.scrubPos = posAt(mouse) }
                        onPositionChanged: (mouse) => { if (bar.scrubbing) bar.scrubPos = posAt(mouse) }
                        onReleased: (mouse) => {
                            bar.scrubbing = false
                            if (bar.duration > 0) bar.seekRequested(posAt(mouse))
                        }
                        onCanceled: bar.scrubbing = false
                    }
                }

                Text {
                    text: Theme.mmss(bar.duration)
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    Layout.preferredWidth: 30
                }
            }

            // ---- content (a single row) -----------------------------
            Item {
                id: barRow
                Layout.fillWidth: true
                Layout.fillHeight: true
                property int gap: Theme.s3

                // ---- now playing (left) ------------------------------
                RowLayout {
                    id: leftSide
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.s2
                    // Width up to the centre (leaving the gap); the right
                    // side is the same, so the transport always stays
                    // centred no matter how long the title is.
                    width: Math.max(0, (parent.width - centerCol.width) / 2 - Theme.s3)

                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        width: bar.compact ? 38 : 30
                        height: bar.compact ? 38 : 30
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rSm
                            color: Sys.surfaceAlt
                            // The artwork is rounded by a CPU crop
                            // (RoundedArt): the Rectangle's `clip` ignored
                            // the radius and the image came out square.
                            RoundedArt {
                                id: coverArt
                                anchors.fill: parent
                                source: bar.currentThumb
                                radiusSpec: Theme.rSm
                            }
                            LotusMark {
                                anchors.centerIn: parent
                                width: bar.compact ? 20 : 16
                                height: bar.compact ? 19 : 15
                                petalColor: Sys.accent
                                active: bar.playing
                                visible: !coverArt.ready
                            }
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); bar.lyricsRequested() } }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: bar.title.length ? bar.title : "Sin nada en cola"
                            color: bar.title.length ? Sys.text : Sys.textDim
                            font.pixelSize: Theme.tMd
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        Text {
                            id: barArtist
                            Layout.fillWidth: true
                            visible: !bar.loading
                            text: bar.artist.length ? bar.artist : "—"
                            color: Sys.textDim
                            font.pixelSize: Theme.tXs
                            font.underline: barArtistHover.hovered
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            HoverHandler { id: barArtistHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    if (typeof sfx !== "undefined")
                                        sfx.play("tap")
                                    if (bar.artist.length)
                                        bar.artistRequested(bar.artist)
                                }
                            }
                        }
                        // Waiting state: a pulsing dot + text, with the
                        // same height as the artist line so the layout does
                        // not move.
                        Row {
                            Layout.fillWidth: true
                            visible: bar.loading
                            spacing: Theme.s2
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6; height: 6; radius: 3
                                color: Sys.accent
                                SequentialAnimation on opacity {
                                    running: bar.loading
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.25; duration: 520; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutSine }
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Cargando…"
                                color: Sys.textDim
                                font.pixelSize: Theme.tXs
                            }
                        }
                    }
                }

                // Right click on the track info (artwork, title or
                // artist): opens the same menu as in the lists - play,
                // radio, add to queue, library...
                MouseArea {
                    anchors.left: leftSide.left
                    anchors.right: leftSide.right
                    anchors.top: leftSide.top
                    anchors.bottom: leftSide.bottom
                    acceptedButtons: Qt.RightButton
                    onClicked: {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        bar.trackMenuRequested(p.x, p.y)
                    }
                }

                // ---- transport (centre) -------------------------------
                RowLayout {
                    id: centerCol
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: bar.compact ? Theme.s1 : Theme.s2

                    BarButton {
                        kind: "shuffle"
                        active: bar.shuffle
                        iconColor: Sys.text
                        visible: !bar.compact
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('toggle'); bar.shuffleToggled() }
                    }

                    BarButton {
                        kind: "prev"
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.prevRequested() }
                    }

                    Rectangle {
                        width: bar.compact ? 40 : 30
                        height: bar.compact ? 40 : 30
                        radius: width / 2
                        color: playHover.hovered ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                        scale: playHover.pressed ? 0.94 : (playHover.hovered ? 1.04 : 1)
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: playHover; cursorShape: Qt.PointingHandCursor }
                        Glyph {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: 1
                            width: bar.compact ? 17 : 15
                            height: bar.compact ? 17 : 15
                            kind: bar.playing ? "pause" : "play"
                            color: Sys.onAccent
                        }
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); bar.toggle() } }
                    }

                    BarButton {
                        kind: "next"
                        iconColor: Sys.text
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.nextRequested() }
                    }

                    BarButton {
                        kind: bar.repeatMode === 2 ? "repeat-one" : "repeat"
                        active: bar.repeatMode !== 0
                        iconColor: Sys.text
                        visible: !bar.compact
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('toggle'); bar.repeatToggled() }
                    }
                }

                // ---- right: actions and volume ------------------------
                RowLayout {
                    id: rightSide
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: bar.compact ? Theme.s1 : Theme.s2
                    width: Math.max(0, (parent.width - centerCol.width) / 2 - Theme.s3)

                    Item { Layout.fillWidth: true }

                    BarButton {
                        kind: bar.liked ? "heart" : "heart-outline"
                        active: bar.liked
                        iconColor: bar.canInteract ? Sys.text : Sys.textDim
                        // On the phone it takes room without doing
                        // anything until the session is up: it only
                        // shows when it works (always on desktop).
                        visible: !bar.compact || bar.canInteract
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('like'); if (bar.canInteract) bar.likeRequested() }
                    }
                    BarButton {
                        kind: "queue"
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.queueRequested() }
                    }
                    BarButton {
                        kind: "lyrics"
                        onTapped: {
                            if (typeof sfx !== 'undefined') sfx.play('tap')
                            bar.lyricsRequested()
                            bar.lyricsPanelRequested()
                        }
                    }

                    // ---- volume: glyph + thin line ----------------------
                    RowLayout {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Theme.s1
                        // On the phone the slider is meaningless (touch has
                        // no hover nor drag precision and the transport
                        // needs the room): it stays desktop-only.
                        visible: bar.width >= 620 && !Theme.touch

                        Glyph {
                            Layout.alignment: Qt.AlignVCenter
                            width: 14; height: 14
                            kind: bar.volume > 0 ? "volume" : "volume-x"
                            weight: 1.6
                            color: Sys.textDim
                        }

                        Rectangle {
                            id: volTrack
                            Layout.preferredWidth: 70
                            Layout.alignment: Qt.AlignVCenter
                            height: 10
                            color: "transparent"

                            readonly property real max: 130
                            readonly property real ratio: Math.min(1, bar.volume / max)

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width; height: 2; radius: 1
                                color: Theme.mix(Sys.surface, Sys.text, 0.18)
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width * volTrack.ratio
                                height: 2; radius: 1
                                color: Sys.accent
                            }
                            Rectangle {
                                x: parent.width * volTrack.ratio - width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8; height: 8; radius: 4
                                color: Sys.accent
                                scale: volArea.hovered ? 1.05 : 0
                                Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                                HoverHandler { id: volArea }
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                function setAt(mouse) {
                                    const r = Math.max(0, Math.min(1, mouse.x / width))
                                    bar.volumeWanted(Math.round(r * volTrack.max))
                                }
                                onPressed: (mouse) => setAt(mouse)
                                onPositionChanged: (mouse) => { if (pressed) setAt(mouse) }
                            }
                        }
                    }
                }
            }
        }
    }
}
