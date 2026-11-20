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
    property bool showRemaining: false
    // Bitrate of the chosen itag (for example "131 kbps"). Empty = unknown.
    property string audioInfo: ""
    property string title: ""
    property string artist: ""
    // Fades the track info on a song change instead of swapping text dry.
    property real infoOpacity: 1
    SequentialAnimation {
        id: infoFade
        NumberAnimation {
            target: bar; property: "infoOpacity"
            to: 0.25; duration: Theme.fastMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: bar; property: "infoOpacity"
            to: 1; duration: Theme.fastMs * 2
            easing.type: Easing.OutCubic
        }
    }
    onVideoIdChanged: if (videoId !== "") infoFade.restart()
    property string currentThumb: ""
    // Cover size in the bar: 0 small (28 px), 1 normal (40), 2 large (56).
    property int coverSizeMode: 1
    readonly property int coverSize: coverSizeMode === 0 ? 28
                                    : (coverSizeMode === 2 ? 40 : 36)
    property int volume: 70
    property bool shuffle: false
    // 0 = no repeat, 1 = repeat the list, 2 = repeat the track.
    property int repeatMode: 0
    // Seconds left on the sleep timer; 0 = off (no indicator shown).
    property int sleepRemaining: 0
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
    signal muteRequested()
    // Wheel over the bar: ±5 per notch, desktop only.
    signal volumeWheel(int delta)
    signal likeRequested()
    // Double click on the cover: mark/unmark "Me gusta" of the current track.
    signal likeDoubleClicked()
    signal addToPlaylistRequested()
    // Context menu of the track (right click on the left hand info) and
    // go to the artist (click on their name).
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)

    // A line like "Skrillex, Naisha y BEAM" is three artists, not one.
    // Each name gets its own chip so it can open its own page. Cached so
    // the split/filter only runs when the artist actually changes, not on
    // every repaint of the bar.
    property var artistChips: []
    function splitArtists(s) {
        const t = String(s || "").trim()
        if (t === "")
            return []
        return t.split(/,|&|\s+y\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+featuring\s+|\s+con\s+/i)
                .map(function (p) { return p.trim() })
                .filter(function (p) { return p.length > 0 })
    }
    onArtistChanged: bar.artistChips = bar.splitArtists(bar.artist)

    property bool scrubbing: false
    property real scrubPos: 0

    // ---- painted position (smoothed) ----------------------------------
    // The engine hands the position over in steps (every ~100 ms on Android,
    // less often on the desktop): painting it as it comes makes the line
    // jump. `shownPosition` slides it at the refresh rate of the screen and
    // every notice from the engine only corrects the drift, so the bar moves
    // smoothly even at 60 Hz.
    property real shownPosition: 0
    property real _lastEnginePos: 0

    // Only a real seek or a new track jumps the line. Ordinary 240 ms
    // notices are ignored: FrameAnimation already advanced smoothly past
    // them, and correcting against them made the dot jump ("tick").
    onPositionChanged: {
        if (bar.scrubbing)
            return
        const jump = Math.abs(bar.position - bar._lastEnginePos)
        // A real seek or a new track: land on it at once.
        if (jump > 2.0)
            bar.shownPosition = bar.position
        // On the phone FrameAnimation can stop when the screen is idle;
        // follow the engine position directly there so the bar never freezes.
        else if (bar.compact)
            bar.shownPosition = bar.position
        bar._lastEnginePos = bar.position
    }
    onPlayingChanged: {
        bar._lastEnginePos = bar.position
        if (!bar.playing)
            bar.shownPosition = bar.position
    }
    Component.onCompleted: {
        bar.shownPosition = bar.position
        bar._lastEnginePos = bar.position
    }

    // Advances with the real time of each rendered frame. With the `threads`
    // loop there is a frame every ~10 ms, so the line moves continuously.
    FrameAnimation {
        running: bar.playing && bar.duration > 0 && !bar.scrubbing
        onTriggered: {
            bar.shownPosition = Math.min(bar.duration, bar.shownPosition + frameTime)
        }
    }
    // How far the finger has travelled up while pulling. Kept private:
    // nothing in the bar reacts to it (the gesture must stay invisible).
    property real pull: 0
    // Horizontal follow while swiping to the next/previous track.
    property real dragX: 0

    // Island height plus the queue strip when it is shown.
    implicitHeight: Theme.playerBarH
    color: "transparent"

    // The bar is a floating CARD that hugs its controls instead of a
    // full-width band. On the desktop it keeps air on both sides; on the
    // phone it lines up with the tab bar (same width, same corner) and
    // floats a step above it, so the two read as one stack.
    readonly property int pillW: compact ? width : Math.min(width, 560)

    // The bar FOLLOWS the finger when pulled up: the gesture is visible, not
    // just guessed. No Behavior while dragging (it would lag behind the
    // finger); on release it goes back on its own with a short animation.
    transform: Translate { x: bar.dragX; y: -bar.pull }
    // No Behavior on dragX: with the phone's thin single-row bar the
    // spring animation could leave the island shifted after a short swipe
    // (the release was missed and dragX kept its last value). The finger
    // follow is direct and the release snaps back to zero.
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

    // Lotus progress fill: accent to a lighter tint, painted on the track.
    Gradient {
        id: lotusFill
        GradientStop { position: 0.0; color: Sys.accent }
        GradientStop { position: 1.0; color: Theme.mix(Sys.accent, "#ffffff", 0.45) }
    }

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
        // Inside a RowLayout `width` is ignored: without a preferred size
        // every button collapsed to the same spot and the queue tap hit
        // the cinema button stacked on top of it.
        Layout.preferredWidth: diameter
        Layout.preferredHeight: diameter
        width: diameter
        height: diameter
        radius: diameter / 2
        antialiasing: true
        // An active shuffle/repeat has its own pill: opacity alone was
        // impossible to tell apart on a phone screen.
        color: bb.active ? Theme.alpha(Sys.accent, 0.20) : "transparent"
        // Tap pop: grow a little then settle back with a soft overshoot.
        property real pop: 1
        property real popTo: 1.18
        scale: (bbHover.pressed ? 0.92 : 1) * pop
        SequentialAnimation {
            id: popAnim
            NumberAnimation { target: bb; property: "pop"; to: bb.popTo; duration: Theme.animMs(90) }
            NumberAnimation { target: bb; property: "pop"; to: 1; duration: Theme.animMs(220); easing.type: Easing.OutBack }
        }
        HoverHandler { id: bbHover; cursorShape: Qt.PointingHandCursor }
        Glyph {
            anchors.centerIn: parent
            width: bb.glyph
            height: bb.glyph
            kind: bb.kind
            weight: bb.active ? 1.9 : 1.6
            color: bb.active ? Theme.accentOn(Sys.accent, Sys.bg) : bb.iconColor
            opacity: bb.active ? 1.0 : (bbHover.hovered ? 0.95 : 0.62)
            Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
        }
        TapHandler { onTapped: { popAnim.restart(); if (typeof sfx !== 'undefined') sfx.play('tap'); bb.tapped() } }
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
            bar.dragX = 0   // never inherit a previous swipe's offset
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
                if (!bar.compact && Math.abs(dx) > Math.abs(dy) * 1.6)
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
        anchors.horizontalCenter: parent.horizontalCenter
        // Mouse wheel changes volume; disabled on touch devices.
        WheelHandler {
            enabled: !Theme.touch
            acceptedDevices: PointerDevice.Mouse
            onWheel: (event) => bar.volumeWheel(Math.sign(event.angleDelta.y) * 5)
        }
        width: bar.pillW
        height: Theme.playerBarH
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
                    // Fill. Lotus gets a soft violet gradient (accent blended
                    // towards the light); Classic keeps the flat colour.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width * scrubTrack.ratio)
                        height: 3; radius: 1.5
                        color: Sys.interfaceStyle === "lotus" ? "transparent" : bar._fill
                        gradient: Sys.interfaceStyle === "lotus" ? lotusFill : null
                        // The gradient needs an animation to repaint as the
                        // width changes; otherwise only the dot moves.
                        Behavior on width {
                            enabled: !bar.scrubbing
                            NumberAnimation { duration: 120; easing.type: Easing.Linear }
                        }
                    }
                    // Position dot: a 6 px point riding the filled end, Lotus only.
                    Rectangle {
                        x: Math.max(0, parent.width * scrubTrack.ratio - width / 2)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6; height: 6; radius: 3
                        antialiasing: true
                        visible: Sys.interfaceStyle === "lotus"
                        color: Theme.mix(Sys.accent, "#ffffff", 0.45)
                        scale: bar.scrubbing ? 1.5 : 1.0
                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                        Behavior on x {
                            enabled: !bar.scrubbing
                            NumberAnimation { duration: 120; easing.type: Easing.Linear }
                        }
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
                        // In Lotus the violet gradient already has its own
                        // position dot; two knobs on top looked like a smudge.
                        visible: Sys.interfaceStyle !== "lotus"
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
                    // Chosen audio bitrate: tells apart the high-quality stream.
                    text: bar.audioInfo
                    visible: bar.audioInfo !== "" && !bar.compact
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tXs
                }

                Text {
                    // Tap to switch between total length and time left.
                    text: bar.showRemaining
                          ? "-" + Theme.mmss(Math.max(0, bar.duration - bar.shownPosition))
                          : Theme.mmss(bar.duration)
                    color: timeMouse.hovered ? Sys.text : Theme.tFaint(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tXs
                    Layout.preferredWidth: 34
                    MouseArea {
                        id: timeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: bar.showRemaining = !bar.showRemaining
                    }
                }

                // Sleep timer: clock + mm:ss left, only while it is active.
                Row {
                    visible: bar.sleepRemaining > 0
                    spacing: Theme.s1
                    Layout.alignment: Qt.AlignVCenter
                    Glyph {
                        width: 12; height: 12
                        anchors.verticalCenter: parent.verticalCenter
                        kind: "clock"
                        weight: 1.7
                        color: bar._fill
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Theme.mmss(bar.sleepRemaining)
                        color: Theme.tFaint(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tXs
                    }
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

                    Item {
                        anchors.fill: parent

                        Item {
                            id: coverBox
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: bar.compact ? 40 : bar.coverSize
                            height: bar.compact ? 40 : bar.coverSize
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
                            // Single tap opens the lyrics; double tap toggles
                            // "Me gusta". A short timer holds the single tap
                            // back so a double tap does not also open lyrics.
                            Timer {
                                id: coverTapTimer
                                interval: 260
                                onTriggered: {
                                    if (typeof sfx !== "undefined")
                                        sfx.play("tap")
                                    bar.lyricsRequested()
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton
                                onClicked: coverTapTimer.restart()
                                onDoubleClicked: {
                                    coverTapTimer.stop()
                                    bar.likeDoubleClicked()
                                }
                            }
                        }

                        Column {
                            id: infoCol
                            // Title/artist sit to the right of the cover with
                            // a small gap, not centred under it.
                            anchors.left: coverBox.right
                            anchors.leftMargin: Theme.s3
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            width: Math.min(parent.width - coverBox.width - Theme.s3, 300)
                            opacity: bar.infoOpacity
                            Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

                            // Line 1: title + like heart, centred as a group.
                            Item {
                                id: titleRow
                                width: parent.width
                                height: Math.max(barTitle.implicitHeight,
                                                 barHeart.visible ? barHeart.height : 0)
                                Text {
                                    id: barTitle
                                    // Left aligned, right next to the cover.
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, parent.width - (barHeart.visible ? barHeart.width + Theme.s2 : 0))
                                    text: bar.title.length ? bar.title : qsTr("Sin nada en cola")
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
                                    popTo: 1.6
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

                            // Line 2: artist chips, centred under the title.
                            Item {
                                id: artistRow
                                width: parent.width
                                height: artistInner.implicitHeight
                                visible: !bar.loading
                                Row {
                                    id: artistInner
                                    anchors.left: parent.left
                                    width: Math.min(implicitWidth, parent.width)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.s1
                                    clip: true
                                    Repeater {
                                        model: bar.artistChips
                                        Rectangle {
                                            readonly property string artistName: modelData
                                            height: artistLabel.implicitHeight + Theme.s1
                                            // No circular binding on the Row's
                                            // width: that made implicitWidth 0
                                            // and hid the artist entirely.
                                            width: artistLabel.implicitWidth + Theme.s2
                                            radius: height / 2
                                            antialiasing: true
                                            color: artistHover.hovered
                                                   ? Theme.hover(Sys.surface) : "transparent"
                                            Text {
                                                id: artistLabel
                                                anchors.centerIn: parent
                                                text: artistName
                                                color: Theme.tDim(Sys.bg, Sys.text)
                                                font.pixelSize: Theme.tXs
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                            }
                                            HoverHandler {
                                                id: artistHover
                                                cursorShape: Qt.PointingHandCursor
                                            }
                                            TapHandler {
                                                onTapped: {
                                                    if (typeof sfx !== "undefined")
                                                        sfx.play("tap")
                                                    bar.artistRequested(artistName)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Row {
                                id: loadingRow
                                width: parent.width
                                height: 16
                                visible: bar.loading
                                anchors.horizontalCenter: parent.horizontalCenter
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
                                    text: qsTr("Cargando…")
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
                    visible: !bar.compact
                    opacity: bar.compact ? 0 : 1
                    enabled: !bar.compact
                    clip: true
                    Layout.alignment: Qt.AlignVCenter
                    Layout.maximumHeight: bar.compact ? 0 : Number.POSITIVE_INFINITY
                    Layout.preferredHeight: bar.compact ? 0 : -1
                    spacing: Theme.s2

                    // Shuffle / repeat travel WITH the transport: the right
                    // side is only for the queue, the cinema and the volume.
                    BarButton {
                        kind: "shuffle"
                        active: bar.shuffle
                        // Narrow windows: shuffle/repeat give their room to
                        // the title (the transport stays the essential one).
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
                        id: playRect
                        width: bar.compact ? 44 : 30
                        height: bar.compact ? 44 : 30
                        radius: width / 2
                        antialiasing: true
                        color: playHover.hovered ? Qt.lighter(Sys.accent, 1.14) : Sys.accent
                        property real pop: 1
                        scale: (playHover.pressed ? 0.94 : (playHover.hovered ? 1.06 : 1)) * pop
                        SequentialAnimation {
                            id: playPop
                            NumberAnimation { target: playRect; property: "pop"; to: 1.22; duration: Theme.animMs(90) }
                            NumberAnimation { target: playRect; property: "pop"; to: 1; duration: Theme.animMs(240); easing.type: Easing.OutBack }
                        }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: playHover; cursorShape: Qt.PointingHandCursor }
                        Glyph {
                            id: playGlyph
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: bar.playing ? 0 : 1
                            width: bar.compact ? 19 : 15
                            height: bar.compact ? 19 : 15
                            kind: bar.playing ? "pause" : "play"
                            color: bar._ink
                        }
                        SequentialAnimation {
                            id: glyphSwap
                            NumberAnimation {
                                target: playGlyph; property: "opacity"
                                to: 0.25; duration: Theme.fastMs / 2
                                easing.type: Easing.OutCubic
                            }
                            NumberAnimation {
                                target: playGlyph; property: "opacity"
                                to: 1; duration: Theme.fastMs
                                easing.type: Easing.OutCubic
                            }
                        }
                        Connections {
                            target: bar
                            function onPlayingChanged() { glyphSwap.restart() }
                        }
                        TapHandler { onTapped: { playPop.restart(); if (typeof sfx !== "undefined") sfx.play("tap"); bar.toggle() } }
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
                            // needs the room): it stays desktop-only. The
                            // threshold is lower so it shows on narrow desktops.
                            visible: island.width >= 520 && !Theme.touch

                    Item {
                        Layout.alignment: Qt.AlignVCenter
                        Layout.preferredWidth: 20
                        Layout.preferredHeight: 20
                        // Tap the speaker glyph to mute / unmute, with the
                        // same pop feedback as the other controls.
                        property real pop: 1
                        scale: muteArea.pressed ? 0.9 : pop
                        SequentialAnimation {
                            id: mutePop
                            NumberAnimation { target: parent; property: "pop"; to: 1.4; duration: Theme.animMs(90) }
                            NumberAnimation { target: parent; property: "pop"; to: 1; duration: Theme.animMs(220); easing.type: Easing.OutBack }
                        }
                        Glyph {
                            anchors.centerIn: parent
                            width: 18; height: 18
                            kind: bar.volume > 0 ? "volume" : "volume-x"
                            weight: 1.6
                            color: Sys.text
                            opacity: muteArea.hovered ? 0.95 : 0.62
                        }
                        HoverHandler { id: muteArea; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                mutePop.restart()
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                bar.muteRequested()
                            }
                        }
                    }

                    Rectangle {
                        id: volTrack
                        Layout.preferredWidth: 48
                        Layout.minimumWidth: 48
                        Layout.maximumWidth: 48
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
                        Timer {
                            id: coverTapTimerPhone
                            interval: 260
                            onTriggered: {
                                if (typeof sfx !== "undefined")
                                    sfx.play("tap")
                                bar.lyricsRequested()
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            onClicked: coverTapTimerPhone.restart()
                            onDoubleClicked: {
                                coverTapTimerPhone.stop()
                                bar.likeDoubleClicked()
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1
                        opacity: bar.infoOpacity
                        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

                        Text {
                            Layout.fillWidth: true
                            text: bar.title.length ? bar.title : qsTr("Sin nada en cola")
                            color: bar.title.length ? Sys.text
                                                    : Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tBase
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        Text {
                            Layout.fillWidth: true
                            text: bar.loading ? qsTr("Cargando…")
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
                        // The liked heart is a fill: size is what makes it
                        // read as bolder, weight only affects strokes.
                        diameter: bar.liked ? 40 : 34
                        glyph: bar.liked ? 21 : 17
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
                        kind: bar.playing ? "pause" : "play"
                        diameter: 40
                        glyph: 20
                        active: bar.playing
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("tap")
                            bar.toggle()
                        }
                    }

                    BarButton {
                        kind: "next"
                        diameter: 34
                        glyph: 18
                        Layout.leftMargin: Theme.s1
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("tap")
                            bar.nextRequested()
                        }
                    }
                }

                // Transport: centred, big enough for a thumb, with air on both sides.
                // Shuffle and repeat go HERE on the phone too: they were the two controls
                // missing from the bar and there is no other place within reach.
                RowLayout {
                    // Second transport row (desktop only). On the phone it
                    // was drawn as a second play button under the pill.
                    visible: !bar.compact
                    opacity: bar.compact ? 0 : 1
                    enabled: !bar.compact
                    clip: true
                    Layout.maximumHeight: bar.compact ? 0 : Number.POSITIVE_INFINITY
                    Layout.fillWidth: true
                    Layout.preferredHeight: bar.compact ? 0 : 44
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
                        scale: playHoverC.pressed ? 0.94 : (playHoverC.hovered ? 1.06 : 1)
                        Behavior on scale {
                            NumberAnimation {
                                duration: Theme.fastMs
                                easing.type: Easing.OutCubic
                            }
                        }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        HoverHandler { id: playHoverC; cursorShape: Qt.PointingHandCursor }
                        Glyph {
                            id: playGlyphC
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: bar.playing ? 0 : 1
                            width: 20
                            height: 20
                            kind: bar.playing ? "pause" : "play"
                            color: bar._ink
                        }
                        SequentialAnimation {
                            id: glyphSwapC
                            NumberAnimation {
                                target: playGlyphC; property: "opacity"
                                to: 0.25; duration: Theme.fastMs / 2
                                easing.type: Easing.OutCubic
                            }
                            NumberAnimation {
                                target: playGlyphC; property: "opacity"
                                to: 1; duration: Theme.fastMs
                                easing.type: Easing.OutCubic
                            }
                        }
                        Connections {
                            target: bar
                            function onPlayingChanged() { glyphSwapC.restart() }
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

    // ---- upcoming queue strip -----------------------------------------
    // A compact horizontal row of the next tracks, sitting just under the
}
