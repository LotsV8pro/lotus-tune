import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Playback bar: a low, minimal floating island (Panel).
//
// Layout (top to bottom):
//   · progress  — thin line, full width, with the two times at the ends.
//                 SWIPE UP on it (or drag it upwards) = the CINEMA mode
//                 (root.openFullscreenLyrics in Main.qml). The gesture is
//                 invisible on purpose: no handle, no arrow, no hint.
//   · content   — one row, three zones:
//                 LEFT   artwork + title + "me gusta" + artist
//                 CENTRE shuffle · prev · play · next · repeat
//                 RIGHT  queue · cinema · volume
//                 The two side zones take the same flexible width, so the
//                 transport sits in the exact centre of the bar.
//
// No extra layers or effects: the island, the line and the glyphs.
Rectangle {
    id: bar

    // Phone: secondary actions (shuffle, repeat, volume) hide so the
    // transport, the queue and the lyrics gesture fit with air.
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
    // Is the right panel currently showing the QUEUE? (highlights the
    // queue button on the bar).
    property bool queueOpen: false
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
    // Pull the bar up: the app's CINEMA mode (the full screen view). The
    // gesture is deliberately invisible: no handle, no hint, no glow.
    signal cinemaRequested()
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

    // ---- painted position (smoothed) ----------------------------------
    // The engine hands the position over in steps (every ~100 ms on Android,
    // less often on the desktop): painting it as it comes makes the line
    // jump. `shownPosition` slides it at the refresh rate of the screen and
    // every notice from the engine only corrects the drift, so the bar moves
    // smoothly even at 60 Hz.
    property real shownPosition: 0
    property bool _shownSynced: false

    function syncShownPosition() {
        if (bar.scrubbing)
            return
        // Direct jump: first value, pause or a big change (seek or new track).
        // Otherwise, the correction is spread over several frames.
        if (!bar._shownSynced || !bar.playing
            || Math.abs(bar.position - bar.shownPosition) > 1.0) {
            bar.shownPosition = bar.position
            bar._shownSynced = true
            return
        }
        bar.shownPosition += (bar.position - bar.shownPosition) * 0.35
    }
    onPositionChanged: syncShownPosition()
    onPlayingChanged: syncShownPosition()
    Component.onCompleted: syncShownPosition()

    // It advances on its own between notices from the engine, with the real
    // time of each frame (no adding a fixed value: it adapts to 60/120/165 Hz).
    FrameAnimation {
        running: bar.playing && bar.duration > 0 && !bar.scrubbing
        onTriggered: {
            const p = bar.shownPosition + frameTime
            bar.shownPosition = Math.min(bar.duration, p)
        }
    }
    // How far the finger has travelled up while pulling. Kept private:
    // nothing in the bar reacts to it (the gesture must stay invisible).
    property real pull: 0
    // Horizontal follow while swiping to the next/previous track.
    property real dragX: 0

    // Island height: the bar measures exactly what its surface does.
    implicitHeight: Theme.playerBarH
    color: "transparent"

    // The bar is a floating CARD that hugs its controls instead of a
    // full-width band. On the desktop it keeps air on both sides; on the
    // phone it lines up with the tab bar (same width, same corner) and
    // floats a step above it, so the two read as one stack.
    readonly property int pillW: compact ? width : Math.min(width, 720)

    // The bar FOLLOWS the finger when pulled up: the gesture is visible, not
    // just guessed. No Behavior while dragging (it would lag behind the
    // finger); on release it goes back on its own with a short animation.
    transform: Translate { x: bar.dragX; y: -bar.pull }
    // The sideways follow returns to rest with a short spring: it is only
    // a confirmation that the swipe was understood.
    Behavior on dragX {
        enabled: !barDrag.pressed
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }
    NumberAnimation {
        id: pullBack
        target: bar
        property: "pull"
        to: 0
        duration: 180
        easing.type: Easing.OutCubic
    }

    // Surfaces derived from the palette (see theme.js): the hover of a
    // button and the two tones of the progress line.
    readonly property color _ui: Theme.sAccent(Sys.bg, Sys.accent)
    readonly property color _trackLine: Theme.mix(Sys.surface, Sys.text, 0.20)
    readonly property color _fill: Theme.accentOn(Sys.accent, Sys.surface)
    readonly property color _ink: Theme.onAccent(Sys.accent)

    // ---- reusable icon button ---------------------------------------
    // Icon of the bar, in the same language as the sidebar of the reference
    // (Liner): no box and no background circle, a bare icon; the inactive one
    // at 62 %, the rest on hover and the active one at full.
    component BarButton: Rectangle {
        id: bb
        property string kind: "play"
        property bool active: false
        property color iconColor: Sys.text
        property int diameter: bar.compact ? 40 : 34
        property real glyph: bar.compact ? 22 : 20
        signal tapped()
        width: diameter
        height: diameter
        radius: diameter / 2
        antialiasing: true
        color: "transparent"
        scale: bbHover.pressed ? 0.92 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
        HoverHandler { id: bbHover; cursorShape: Qt.PointingHandCursor }
        Glyph {
            anchors.centerIn: parent
            width: bb.glyph
            height: bb.glyph
            kind: bb.kind
            weight: bb.active ? 1.9 : 1.6
            color: bb.active ? Sys.text : bb.iconColor
            opacity: bb.active ? 1.0 : (bbHover.hovered ? 0.95 : 0.62)
            Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
        }
        TapHandler { onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bb.tapped() } }
    }

    // ---- draggable zone: the WHOLE bar ------------------------------
    // It used to be draggable from the line only (20 dp): with a finger that
    // was close to impossible to hit. Now any free spot of the island drags
    // it (cover, title, gaps). The buttons stay on top and eat their own
    // touches; the line keeps its drag for seeking.
    MouseArea {
        id: barDrag
        // Only the pill: the transparent air around it belongs to the page.
        anchors.fill: island
        property real startY: 0
        property real startX: 0
        property bool dragging: false
        // Sliding horizontally changes track (next/previous), like in any phone
        // player. The dominant axis tells it apart from the vertical gesture
        // (which opens the cinema).
        property bool sideways: false

        function sceneY(m) {
            return mapToItem(null, m.x, m.y).y
        }
        function sceneX(m) {
            return mapToItem(null, m.x, m.y).x
        }
        onPressed: (m) => {
            startY = sceneY(m)
            startX = sceneX(m)
            dragging = false
            sideways = false
        }
        onPositionChanged: (m) => {
            if (!pressed)
                return
            const dy = startY - sceneY(m)
            const dx = sceneX(m) - startX
            // A gesture starts late on purpose: a click with a shaky pulse on a
            // button cannot end up changing track or opening the cinema (it used to
            // happen "sometimes").
            if (!dragging && !sideways && (Math.abs(dx) > 26 || dy > 16)) {
                // The axis that moved the most wins: a finger going up opens the
                // cinema, one crossing the bar changes track.
                if (Math.abs(dx) > Math.abs(dy) * 1.6)
                    sideways = true
                else if (dy > 16)
                    dragging = true
            }
            if (sideways) {
                // The finger is followed a little, only as visual confirmation.
                bar.pull = 0
                bar.dragX = Math.max(-70, Math.min(70, dx * 0.25))
            } else if (dragging) {
                bar.pull = Math.max(0, Math.min(240, dy))
            }
        }
        onReleased: (m) => {
            const dx = sceneX(m) - startX
            if (sideways && Math.abs(dx) > 90) {
                if (typeof sfx !== "undefined")
                    sfx.play("tap")
                if (dx < 0)
                    bar.nextRequested()
                else
                    bar.prevRequested()
            } else if (dragging && bar.pull > 70) {
                if (typeof sfx !== "undefined")
                    sfx.play("tap")
                bar.cinemaRequested()
            }
            dragging = false
            sideways = false
            bar.dragX = 0
            if (bar.pull > 0)
                pullBack.start()
        }
        onCanceled: {
            dragging = false
            sideways = false
            bar.dragX = 0
            if (bar.pull > 0)
                pullBack.start()
        }
    }

    // ---- floating island ---------------------------------------------
    Panel {
        id: island
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: bar.pillW
        // Rounded card (same language as the tab bar), not a capsule.
        radius: bar.compact ? Theme.rLg : Theme.rPanel
        antialiasing: true
        // Solid: the pill is the dark surface itself, it does not frost the
        // washed artwork behind it (no blurred backdrop).
        color: Sys.surface
        // The content is clipped to the island's corners: the progress
        // line on top follows the rounding instead of sticking out.
        clipContent: true

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: bar.compact ? Theme.s3 : Theme.s5
            anchors.rightMargin: bar.compact ? Theme.s3 : Theme.s5
            anchors.topMargin: 0
            anchors.bottomMargin: Theme.s1
            spacing: 0

            // ---- progress (thin line, full width) ---------------------
            RowLayout {
                id: progressRow
                Layout.fillWidth: true
                Layout.preferredHeight: 20
                spacing: Theme.s2

                Text {
                    text: Theme.mmss(bar.scrubbing ? bar.scrubPos : bar.shownPosition)
                    color: Theme.tFaint(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tXs
                    Layout.preferredWidth: 34
                    horizontalAlignment: Text.AlignRight
                }

                // The gesture + seek zone: 20 dp tall but with a generous
                // implicit slab (the MouseArea is not clipped to the line).
                Item {
                    id: scrubTrack
                    Layout.fillWidth: true
                    height: 20
                    Layout.alignment: Qt.AlignVCenter

                    readonly property real ratio: bar.duration > 0
                        ? Math.min(1, (bar.scrubbing ? bar.scrubPos : bar.shownPosition) / bar.duration) : 0

                    // Track.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width; height: 3; radius: 1.5
                        color: bar._trackLine
                    }
                    // Fill.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width * scrubTrack.ratio)
                        height: 3; radius: 1.5
                        color: bar._fill
                    }
                    // Knob: small, always visible (there is no hover on a
                    // phone) and bigger while scrubbing.
                    Rectangle {
                        x: Math.max(0, Math.min(parent.width - width, parent.width * scrubTrack.ratio - width / 2))
                        anchors.verticalCenter: parent.verticalCenter
                        width: bar.compact ? 11 : 9
                        height: width
                        radius: width / 2
                        antialiasing: true
                        color: bar._fill
                        opacity: bar.scrubbing ? 1 : (scrubArea.hovered ? 0.95 : 0.75)
                        scale: bar.scrubbing ? 1.25 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
                    }

                    MouseArea {
                        id: scrubArea
                        anchors.fill: parent
                        // Invisible extra reach above the line: a thumb
                        // that starts a little high still catches the
                        // gesture (nothing is painted there). Small: the
                        // slab used to reach 18 px above the bar, into the
                        // list, and clicks there sought the song instead of
                        // pressing the row.
                        anchors.topMargin: -8
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        property real startY: 0
                        property real startX: 0
                        property bool swiping: false

                        function posAt(mouse) {
                            return Math.max(0, Math.min(1, mouse.x / width)) * bar.duration
                        }
                        // SCENE coordinates, not local ones: the bar moves with the finger while
                        // dragging, and with local coordinates the gesture cancelled itself (the
                        // finger "went back" to the same spot relative to the bar). Checked:
                        // without this the swipe ended up seeking.
                        function sceneAt(mouse) {
                            return mapToItem(null, mouse.x, mouse.y)
                        }
                        onPressed: (mouse) => {
                            bar.scrubbing = true
                            bar.scrubPos = posAt(mouse)
                            const p = sceneAt(mouse)
                            startY = p.y
                            startX = p.x
                            swiping = false
                        }
                        onPositionChanged: (mouse) => {
                            if (!pressed)
                                return
                            const p = sceneAt(mouse)
                            const dy = startY - p.y
                            const dx = Math.abs(p.x - startX)
                            // Vertical, upwards and clearly dominant: this
                            // is the pull-up that opens the cinema, not a
                            // scrub of the line.
                            if (!swiping && dy > 8 && dy > dx * 1.3) {
                                swiping = true
                                bar.scrubbing = false
                            }
                            if (swiping) {
                                bar.pull = Math.max(0, Math.min(240, dy))
                            } else if (bar.scrubbing) {
                                bar.scrubPos = posAt(mouse)
                            }
                        }
                        onReleased: (mouse) => {
                            if (swiping) {
                                if (bar.pull > 26) {
                                    if (typeof sfx !== "undefined")
                                        sfx.play("tap")
                                    // The view opens rising from the bottom, with the same direction as the
                                    // gesture.
                                    bar.cinemaRequested()
                                }
                            } else {
                                bar.scrubbing = false
                                if (bar.duration > 0)
                                    bar.seekRequested(posAt(mouse))
                            }
                            swiping = false
                            if (bar.pull > 0)
                                pullBack.start()
                        }
                        onCanceled: {
                            bar.scrubbing = false
                            swiping = false
                            if (bar.pull > 0)
                                pullBack.start()
                        }
                    }
                }

                Text {
                    text: Theme.mmss(bar.duration)
                    color: Theme.tFaint(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tXs
                    Layout.preferredWidth: 34
                }
            }

            // ---- content (a single row) -----------------------------
            RowLayout {
                id: barRow
                // Desktop only: the phone uses the two-row block below.
                visible: !bar.compact
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: bar.compact ? Theme.s2 : Theme.s3

                // ---- now playing (left) ------------------------------
                // Cover + title/artist wrapped in one Item: the right
                // click menu (desktop) needs a single surface over the
                // three of them, and the row keeps filling the air.
                Item {
                    id: leftBox
                    // Same flexible width on both sides (rightBox below):
                    // that is what keeps the transport EXACTLY centred in
                    // the bar instead of pushed to the right.
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true

                    RowLayout {
                        anchors.fill: parent
                        spacing: bar.compact ? Theme.s2 : Theme.s3

                        Item {
                            Layout.alignment: Qt.AlignVCenter
                            width: bar.compact ? 40 : 30
                            height: bar.compact ? 40 : 30
                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.rSm
                                antialiasing: true
                                color: Theme.sAccent(Sys.bg, Sys.accent, 0.10)
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
                                    petalColor: bar._fill
                                    active: bar.playing
                                    visible: !coverArt.ready
                                }
                            }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    if (typeof sfx !== "undefined")
                                        sfx.play("tap")
                                    bar.lyricsRequested()
                                }
                            }
                        }

                        ColumnLayout {
                            id: infoCol
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 0
                            // Title + "me gusta" side by side: the heart belongs
                            // to the track, not to the transport group. It is a
                            // plain anchored Item, NOT a RowLayout: binding the
                            // title's maximum width to the column width inside a
                            // layout made Qt rearrange recursively.
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: Math.max(barTitle.implicitHeight,
                                                         barHeart.visible ? barHeart.height : 0)
                                Text {
                                    id: barTitle
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    // It takes the width of its text (capped to
                                    // what is left next to the heart), so the
                                    // heart sits right next to the title and not
                                    // at the far edge of the bar.
                                    width: Math.min(implicitWidth,
                                                    parent.width - (barHeart.visible
                                                                    ? barHeart.width + Theme.s2 : 0))
                                    text: bar.title.length ? bar.title : "Sin nada en cola"
                                    color: bar.title.length ? Sys.text : Theme.tDim(Sys.bg, Sys.text)
                                    font.pixelSize: Theme.tMd
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                BarButton {
                                    id: barHeart
                                    anchors.left: barTitle.right
                                    anchors.leftMargin: Theme.s2
                                    anchors.verticalCenter: parent.verticalCenter
                                    kind: bar.liked ? "heart" : "heart-outline"
                                    active: bar.liked
                                    diameter: bar.compact ? 30 : 22
                                    glyph: bar.compact ? 15 : 12
                                    iconColor: bar.canInteract
                                               ? Sys.text
                                               : Theme.tFaint(Sys.bg, Sys.text)
                                    visible: !bar.compact || bar.canInteract
                                    onTapped: {
                                        if (typeof sfx !== "undefined")
                                            sfx.play("like")
                                        if (bar.canInteract)
                                            bar.likeRequested()
                                    }
                                }
                            }
                            Text {
                                id: barArtist
                                Layout.fillWidth: true
                                visible: !bar.loading
                                text: bar.artist.length ? bar.artist : "—"
                                color: Theme.tDim(Sys.bg, Sys.text)
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
                            // same height as the artist line so the layout
                            // does not move.
                            Row {
                                Layout.fillWidth: true
                                visible: bar.loading
                                spacing: Theme.s2
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 6; height: 6; radius: 3
                                    color: bar._fill
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
                                    color: Theme.tDim(Sys.bg, Sys.text)
                                    font.pixelSize: Theme.tXs
                                }
                            }
                        }
                    }

                    // Right click on the track info (artwork, title or
                    // artist): opens the same menu as in the lists - play,
                    // radio, add to queue, library...
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        onClicked: {
                            const p = mapToItem(null, mouse.x, mouse.y)
                            bar.trackMenuRequested(p.x, p.y)
                        }
                    }
                }

                // ---- transport --------------------------------------
                RowLayout {
                    id: centerCol
                    Layout.alignment: Qt.AlignVCenter
                    spacing: bar.compact ? Theme.s1 : Theme.s2

                    // Shuffle / repeat travel WITH the transport: the right
                    // side is only for the queue, the cinema and the volume.
                    BarButton {
                        kind: "shuffle"
                        active: bar.shuffle
                        // Narrow windows: shuffle/repeat give their room to
                        // the title (the transport stays the essential one).
                        visible: !bar.compact && island.width >= 560
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("toggle")
                            bar.shuffleToggled()
                        }
                    }

                    BarButton {
                        kind: "prev"
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.prevRequested() }
                    }

                    Rectangle {
                        width: bar.compact ? 44 : 30
                        height: bar.compact ? 44 : 30
                        radius: width / 2
                        antialiasing: true
                        color: playHover.hovered ? Qt.lighter(Sys.accent, 1.14) : Sys.accent
                        scale: playHover.pressed ? 0.93 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: playHover; cursorShape: Qt.PointingHandCursor }
                        Glyph {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: bar.playing ? 0 : 1
                            width: bar.compact ? 19 : 15
                            height: bar.compact ? 19 : 15
                            kind: bar.playing ? "pause" : "play"
                            color: bar._ink
                        }
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); bar.toggle() } }
                    }

                    BarButton {
                        kind: "next"
                        onTapped: { if (typeof sfx !== 'undefined') sfx.play('tap'); bar.nextRequested() }
                    }

                    BarButton {
                        id: repBtn
                        kind: "repeat"
                        active: bar.repeatMode !== 0
                        visible: !bar.compact && island.width >= 560
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("toggle")
                            bar.repeatToggled()
                        }
                        // Repeat-one: the glyph carries a "1" drawn on a 24
                        // unit grid, invisible at this size, so the second
                        // mode is marked with a badge.
                        Rectangle {
                            visible: bar.repeatMode === 2
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.rightMargin: -1
                            anchors.bottomMargin: -1
                            width: 11; height: 11
                            radius: 5.5
                            antialiasing: true
                            color: Sys.accent
                            Text {
                                anchors.centerIn: parent
                                text: "1"
                                color: Theme.onAccent(Sys.accent)
                                font.pixelSize: 7
                                font.weight: Font.Bold
                            }
                        }
                    }

                }

                // ---- right side: queue, cinema, volume ----------------
                // The right column mirrors the left one (same flexible
                // width), so the transport above lands in the exact centre
                // of the bar. Its content is anchored to the right edge.
                Item {
                    id: rightBox
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    Layout.minimumWidth: 0

                    RowLayout {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.s2

                        BarButton {
                            kind: "queue"
                            active: bar.queueOpen
                            onTapped: {
                                if (typeof sfx !== "undefined")
                                    sfx.play("tap")
                                bar.queueRequested()
                            }
                        }

                        // Cinema (the full screen view). The swipe up on the
                        // progress line still works; this is the visible way.
                        BarButton {
                            kind: "expand"
                            visible: !bar.compact
                            onTapped: {
                                if (typeof sfx !== "undefined")
                                    sfx.play("tap")
                                bar.cinemaRequested()
                            }
                        }

                        // ---- volume: glyph + thin line (desktop only) --------
                        RowLayout {
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Theme.s1
                            // On the phone the slider is meaningless (touch has
                            // no hover nor drag precision and the transport
                            // needs the room): it stays desktop-only.
                            visible: island.width >= 620 && !Theme.touch

                    Glyph {
                        Layout.alignment: Qt.AlignVCenter
                        width: 18; height: 18
                        kind: bar.volume > 0 ? "volume" : "volume-x"
                        weight: 1.6
                        color: Sys.text
                        opacity: 0.62
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
                            width: parent.width; height: 3; radius: 1.5
                            color: bar._trackLine
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * volTrack.ratio
                            height: 3; radius: 1.5
                            color: bar._fill
                        }
                        Rectangle {
                            x: parent.width * volTrack.ratio - width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8; height: 8; radius: 4
                            color: bar._fill
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

            // ---- compact (phone): two rows -------------------------------
            // One row squeezed the title to "…": the cover, the heart, the
            // transport and the queue all competed for the same 380 dp.
            // Two rows give the title the whole width and put the buttons
            // under it, at thumb reach.
            ColumnLayout {
                id: compactBody
                visible: bar.compact
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Theme.s2

                    // Cover: tap opens the full screen player.
                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        width: 40
                        height: 40
                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.rSm
                            antialiasing: true
                            color: Theme.sAccent(Sys.bg, Sys.accent, 0.10)
                            RoundedArt {
                                id: coverArtPhone
                                anchors.fill: parent
                                source: bar.currentThumb
                                radiusSpec: Theme.rSm
                            }
                            LotusMark {
                                anchors.centerIn: parent
                                width: 20
                                height: 19
                                petalColor: bar._fill
                                active: bar.playing
                                visible: !coverArtPhone.ready
                            }
                        }
                        TapHandler {
                            onTapped: {
                                if (typeof sfx !== "undefined")
                                    sfx.play("tap")
                                bar.lyricsRequested()
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: bar.title.length ? bar.title : "Sin nada en cola"
                            color: bar.title.length ? Sys.text
                                                    : Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tBase
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        Text {
                            Layout.fillWidth: true
                            text: bar.loading ? "Cargando…"
                                              : (bar.artist.length ? bar.artist : "—")
                            color: Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tXs
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }

                    BarButton {
                        kind: bar.liked ? "heart" : "heart-outline"
                        active: bar.liked
                        diameter: 34
                        glyph: 17
                        iconColor: bar.canInteract ? Sys.text
                                                   : Theme.tFaint(Sys.bg, Sys.text)
                        visible: bar.canInteract
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("like")
                            if (bar.canInteract)
                                bar.likeRequested()
                        }
                    }

                    BarButton {
                        kind: "queue"
                        active: bar.queueOpen
                        diameter: 34
                        glyph: 18
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("tap")
                            bar.queueRequested()
                        }
                    }
                }

                // Transport: centred, big enough for a thumb, with air on both sides.
                // Shuffle and repeat go HERE on the phone too: they were the two controls
                // missing from the bar and there is no other place within reach.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    spacing: Theme.s3

                    Item { Layout.fillWidth: true }

                    BarButton {
                        kind: "shuffle"
                        active: bar.shuffle
                        diameter: 40
                        glyph: 20
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("toggle")
                            bar.shuffleToggled()
                        }
                    }

                    BarButton {
                        kind: "prev"
                        diameter: 40
                        glyph: 21
                        onTapped: {
                            if (typeof sfx !== 'undefined') sfx.play('tap')
                            bar.prevRequested()
                        }
                    }

                    Rectangle {
                        width: 44
                        height: 44
                        radius: width / 2
                        antialiasing: true
                        color: playHoverC.hovered ? Qt.lighter(Sys.accent, 1.14) : Sys.accent
                        scale: playHoverC.pressed ? 0.93 : 1
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: playHoverC; cursorShape: Qt.PointingHandCursor }
                        Glyph {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: bar.playing ? 0 : 1
                            width: 20
                            height: 20
                            kind: bar.playing ? "pause" : "play"
                            color: bar._ink
                        }
                        TapHandler {
                            onTapped: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                bar.toggle()
                            }
                        }
                    }

                    BarButton {
                        kind: "next"
                        diameter: 40
                        glyph: 21
                        onTapped: {
                            if (typeof sfx !== 'undefined') sfx.play('tap')
                            bar.nextRequested()
                        }
                    }

                    BarButton {
                        kind: "repeat"
                        active: bar.repeatMode !== 0
                        diameter: 40
                        glyph: 20
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("toggle")
                            bar.repeatToggled()
                        }
                        // "Repeat the song" mode: a small "1" in the corner, like in the desktop
                        // bar.
                        Rectangle {
                            visible: bar.repeatMode === 2
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            width: 12; height: 12
                            radius: 6
                            antialiasing: true
                            color: Sys.accent
                            Text {
                                anchors.centerIn: parent
                                text: "1"
                                color: Theme.onAccent(Sys.accent)
                                font.pixelSize: 7
                                font.weight: Font.Bold
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }
            }
        }
    }
}
