import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Cinema (fullscreen): the reference layout.
//
//   +----------------------------------+---------------------------+
//   | cover                            |                           |
//   | title + heart                    |           lyrics          |
//   | artist                           |  (lead voice on the left, |
//   | ---- progress ---- 5:30    8:00  | second voice on the right)|
//   | shuffle < > play > repeat volume |                           |
//   +----------------------------------+---------------------------+
//
// The left block is `CinemaLeft.qml` (it is also used, stacked, on the
// phone, where two columns do not fit). The transport lives INSIDE the
// view (the cinema covers the bar: `bottomInset` = 0 in Main.qml), so the
// screen stands on its own. Close sits top right, with the queue to its
// left.
//
// The lyrics are `LyricsView` - the same engine as the panel and Now
// Playing - with `duetSides: true`: when the source tags two voices, the
// second voice's phrases come in from the right side, like in Sonora.
Rectangle {
    id: fl
    anchors.fill: parent
    // Geometry: Main lowers the overlay by `bottomInset` so the normal
    // floating PlayerBar pokes into the window UNTOUCHED (it keeps being
    // the one true transport: nothing here is re-hardcoded).
    anchors.bottomMargin: fl.bottomInset
    color: "transparent"
    visible: opacity > 0.01
    // Pulling down with a finger fades the view a little: the movement and
    // the transparency tell the same story.
    opacity: (open ? 1 : 0) * pullFade
    z: 72

    property bool open: false
    // The app is in the foreground (see RightPanel).
    property bool appActive: true
    property string title: ""
    property string artist: ""
    property string thumb: ""
    // YouTube ID of the current track: the big artwork needs it to
    // ask for the sharp variants of the art (the API thumbnails come at
    // 120 px).
    property string videoId: ""
    property bool playing: false
    property real position: 0
    property real duration: 0
    // Kept for API compatibility even though the transport lives in the
    // (reused) PlayerBar now; Main still binds them.
    property bool shuffleOn: false
    property int repeatVal: 0
    property bool liked: false
    // Player volume (0..130, the same range as the bar). The cinema had no
    // volume control: you had to leave it and use the bar.
    property int volume: 70
    // Height the overlay must lift to leave the real playback bar visible
    // below (Main: bar height +, on the phone, tab bar + gap + margin).
    property real bottomInset: 0

    signal closeRequested()
    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)
    signal shuffleRequested()
    signal repeatRequested()
    signal likeRequested()
    // Volume asked for from the cinema (0..130).
    signal volumeWanted(int value)
    // The queue no longer lives in the bar: it opens from here (top right,
    // symmetric with the close button).
    signal queueRequested()
    // Right click on the artwork: the same track menu as in the lists
    // (radio, queue, library...). Click on the artist: open their page.
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)
    // Swipe-down on the artwork: closes the overlay (same as the back
    // button on the phone).
    signal swipeDown()

    // The properties (title/artist/thumb/videoId/...) are bound from
    // Main.qml to the current values, so the cinema keeps them fresh
    // while it is open: bindings update themselves (an imperative copy
    // here would kill the binding and freeze the cover and the title).
    Behavior on opacity {
        NumberAnimation { duration: Theme.slowMs; easing.type: Easing.OutCubic }
    }
    // It comes in rising from below (where the bar was): the drag gesture
    // and the full view are the same movement. It is a translate (solved
    // in the compositor), not a relayout, so it runs at the screen rate
    // (120 Hz if the phone has it).
    property real revealOffset: fl.open ? 0 : fl.height * 0.14
    Behavior on revealOffset {
        NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
    }

    // ---- drag down: close -------------------------------------------
    // The entrance gesture, backwards: the view drops with the finger and,
    // past the threshold, closes on its own. Works on the cover, the title,
    // the background and (via the lyrics bounce) over the lyrics too. The
    // animations are transform/opacity: they run at the screen rate.
    property real pullDown: 0
    readonly property real pullLimit: fl.height * 0.45
    readonly property real pullFade: 1 - Math.min(0.85, fl.pullDown / (fl.height * 0.6))
    NumberAnimation {
        id: pullBack
        target: fl
        property: "pullDown"
        to: 0
        duration: 200
        easing.type: Easing.OutCubic
    }
    // Releasing past the threshold: the view KEEPS going down while it
    // fades. Before, closing set pullDown to 0 in one go and the view rose
    // back up and then vanished: that was the jump you could see.
    NumberAnimation {
        id: closeOut
        target: fl
        property: "pullDown"
        to: fl.height * 0.55
        duration: 240
        easing.type: Easing.OutCubic
        onStopped: fl.pullDown = 0
    }
    onOpenChanged: {
        if (fl.open) {
            closeOut.stop()
            fl.pullDown = 0
        } else if (!closeOut.running) {
            fl.pullDown = 0
        }
    }


    transform: Translate { y: fl.revealOffset + fl.pullDown }

    readonly property bool isPhone: Qt.platform.os === "android"

    // Same veil the wash uses under the lyrics: the edge washes must sit
    // on the colour the eye sees. It was a hard coded deep blue (#1b2a44),
    // which is exactly why the cinema mode did not match the desktop
    // palette: now it is the palette accent mixed over the background.
    readonly property color veilColor: Theme.sAccent(Sys.bg, Sys.accent, 0.10)
    // How much the veil covers the wash. It used to be 0.66: over a white
    // cover the mix landed on a mid grey where white lyrics only cleared
    // ~5:1 and the neighbours looked washed out. 0.72 keeps the artwork
    // recognisable and gives the ink room to be really legible.
    readonly property real veilOpacity: 0.72

    // ---- ink of the cinema ------------------------------------------------
    // The veil below is drawn at 0.66 over the blurred artwork, so the
    // really visible background is the artwork's average mixed with that
    // veil. From it the chrome (title, artist, transport icons) and the
    // lyrics pick a near-white or a near-black tone: over the white cover
    // of "A Little Piece of Heaven" white text used to vanish.
    // The chrome (title, artist, transport) sits on the left column on the
    // desktop and on the top one on the phone: it uses THAT cell of the
    // wash, not the global average (the cover is right there and it can be
    // white while the rest of the artwork is black).
    readonly property int chromeZone: fl.isPhone ? 1 : 3
    readonly property color bgBehind: {
        const a = fl.veilOpacity
        const base = (typeof wash !== "undefined" && wash.valid)
                     ? wash.zoneColor(fl.chromeZone) : Sys.bg
        return Theme.alpha(Theme.mix(base, fl.veilColor, a), 1)
    }
    readonly property color ink: Theme.onAccent(fl.bgBehind)
    readonly property color inkDim: Theme.readableOn(
        Theme.tDim(fl.bgBehind, fl.ink), fl.bgBehind)

    // ---- artwork wash -----------------------------------------------------
    // The cinema mode is an overlay on top of the app: it needs its own
    // opaque background, otherwise the page behind shows through while
    // the wash is being recomputed (when the track changes).
    Rectangle {
        anchors.fill: parent
        color: Sys.bg
    }
    // REAL blur done in the backend (CPU): a soft veil that, stretched over
    // the whole screen, comes out without blocks but still lets you
    // recognise the artwork.
    Image {
        id: washImg
        anchors.fill: parent
        // Same wash the app menu uses: "image://wash/<serial>" tracks the
        // current artwork. Here it follows the cinema's OWN thumb property
        // (bound from Main.qml): referencing ids of another file (`root`)
        // does not resolve reliably in QML. The wash content is refreshed
        // by the backend on every track change, whatever the "dynamic
        // background" setting of the main view is.
        source: fl.open && fl.thumb ? "image://wash/" + wash.serial : ""
        // STRETCHED, not cropped: the veil adapts to the window so the
        // artwork covers the 100 % of it (cropped, a tall window only showed
        // the middle of the art with dark edges on the sides).
        fillMode: Image.Stretch
        smooth: true
        asynchronous: true
        cache: false
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.slowMs } }
    }
    // Veil: the app background mixed with a deep blue so the cinema mode is
    // colder and crisper than the other windows.
    Rectangle {
        anchors.fill: parent
        color: fl.veilColor
        opacity: fl.veilOpacity
    }
    // Click eater: the cinema mode has no colour of its own, so clicks on
    // any gap without a control or lyrics went through the window and
    // landed on the playlist behind. This one keeps whatever nobody else
    // wants. It ends where the real playback bar begins (the bar is OUTSIDE
    // this overlay, it must keep its clicks).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        z: -1
    }
    // Accent aura at the bottom, very faint: it fades just above the hole
    // where the floating bar shows through.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(240, parent.height * 0.32)
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.alpha(Sys.accent, 0.10) }
        }
    }

    // ---- draggable background (pull down = close) -------------------------
    // Behind the content: the buttons and the lyrics take the touch first,
    // so this MouseArea only acts on the background. Before there was a
    // global DragHandler that swallowed the gesture and left buttons like
    // "next" without an answer.
    Item {
        id: sheetDrag
        anchors.fill: parent
        z: -1
        property real startY: 0
        property bool active: false
        property real translation: 0

        MouseArea {
            anchors.fill: parent
            function sceneY(m) { return mapToItem(null, m.x, m.y).y }
            onPressed: (m) => {
                sheetDrag.startY = sceneY(m)
                sheetDrag.active = false
                sheetDrag.translation = 0
            }
            onPositionChanged: (m) => {
                if (!pressed)
                    return
                const dy = sceneY(m) - sheetDrag.startY
                if (!sheetDrag.active && dy > 12)
                    sheetDrag.active = true
                if (sheetDrag.active) {
                    sheetDrag.translation = dy
                    fl.pullDown = Math.max(0, Math.min(fl.pullLimit, dy))
                }
            }
            onReleased: {
                if (sheetDrag.active && fl.pullDown > 110) {
                    if (typeof sfx !== "undefined")
                        sfx.play("tap")
                    closeOut.start()
                    fl.closeRequested()
                } else if (fl.pullDown > 0) {
                    pullBack.start()
                }
                sheetDrag.active = false
                sheetDrag.translation = 0
            }
            onCanceled: {
                if (fl.pullDown > 0)
                    pullBack.start()
                sheetDrag.active = false
                sheetDrag.translation = 0
            }
        }
    }

    // ---- content: info on the LEFT, lyrics on the RIGHT -------------------
    // The reference layout: the cover with the title, the artist, the
    // progress and the controls below it, in one column; the lyrics take
    // the other half, a wider one. On the phone two columns do not fit:
    // the cover and the title go on top, the lyrics follow and the
    // progress with the transport close the screen at the bottom.
    Item {
        id: content
        anchors.fill: parent
        anchors.leftMargin: Theme.panelMargin + Theme.s4
        anchors.rightMargin: Theme.panelMargin + Theme.s4
        anchors.topMargin: fl.isPhone ? Theme.s5 : Theme.s4
        anchors.bottomMargin: fl.isPhone ? Theme.s5 + Theme.s3 : Theme.s5

        readonly property bool wide: width >= 720
        readonly property real leftW: Math.min(420, Math.round(width * 0.36))
        readonly property real coverSize: Math.round(
            Theme.clamp(Math.min(leftW - Theme.s2, height * 0.46), 120, 360))

        // ---- DESKTOP: two columns --------------------------------------
        RowLayout {
            anchors.fill: parent
            visible: content.wide
            spacing: Math.max(24, Math.round(content.width * 0.05))

            CinemaLeft {
                id: left
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: content.leftW

                ink: fl.ink
                inkDim: fl.inkDim
                title: fl.title
                artist: fl.artist
                thumb: fl.thumb
                videoId: fl.videoId
                playing: fl.playing
                position: fl.position
                duration: fl.duration
                shuffleOn: fl.shuffleOn
                repeatVal: fl.repeatVal
                liked: fl.liked
                volume: fl.volume
                coverSize: content.coverSize
                centered: false

                onToggleRequested: fl.toggleRequested()
                onNextRequested: fl.nextRequested()
                onPrevRequested: fl.prevRequested()
                onSeekRequested: (secs) => fl.seekRequested(secs)
                onShuffleRequested: fl.shuffleRequested()
                onRepeatRequested: fl.repeatRequested()
                onLikeRequested: fl.likeRequested()
                onVolumeWanted: (v) => fl.volumeWanted(v)
                onTrackMenuRequested: (x, y) => fl.trackMenuRequested(x, y)
                onArtistRequested: (name) => fl.artistRequested(name)
            }

            // Lyrics: the right column, left aligned, with the voices on
            // the sides when the source tags a duet.
            LyricsView {
                id: lyric
                Layout.fillWidth: true
                Layout.fillHeight: true
                live: fl.open && content.wide
                      && (Qt.platform.os !== "android" || fl.appActive)
                lineSize: Math.max(20, Math.min(30, Math.round(content.height / 32)))
                activeBoost: Math.round(lineSize * 0.20)
                maxLineWidth: 860
                edgeColor: Theme.alpha(fl.veilColor, fl.veilOpacity)
                leftAlign: true
                duetSides: true
                // Subtitle window: previous, active and next line. The
                // whole song made the column run into the progress bar of
                // the left block.
                visibleLines: 3
                // Right half of the screen: its own cell of the wash.
                zone: 5
                // The active line is pinned at the centre of the cover
                // (not at the centre of the window: the cover sits higher
                // because the title and the controls go under it).
                pinFrac: {
                    // `left.y` has to be part of the expression: a value
                    // read inside mapToItem() is not tracked, so the pin
                    // stayed with the fraction measured before the row was
                    // laid out (the line sat near the top).
                    var center = left.y + left.coverCenter
                    if (!(content.height > 0))
                        return 0.50
                    return Math.max(0.0, Math.min(1.0, center / content.height))
                }
                pillTop: true
                syncAdjustAllowed: false
                pillShown: false
            }
        }

        // ---- PHONE: one column -----------------------------------------
        ColumnLayout {
            anchors.fill: parent
            visible: !content.wide
            spacing: Theme.s3

            CinemaLeft {
                id: leftPhone
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                // Cover, title and artist only: the progress and the
                // transport go below the lyrics.
                showTransport: false

                ink: fl.ink
                inkDim: fl.inkDim
                title: fl.title
                artist: fl.artist
                thumb: fl.thumb
                videoId: fl.videoId
                playing: fl.playing
                position: fl.position
                duration: fl.duration
                shuffleOn: fl.shuffleOn
                repeatVal: fl.repeatVal
                liked: fl.liked
                volume: fl.volume
                coverSize: Math.min(168, Math.round(content.width * 0.46))
                centered: true

                onToggleRequested: fl.toggleRequested()
                onNextRequested: fl.nextRequested()
                onPrevRequested: fl.prevRequested()
                onSeekRequested: (secs) => fl.seekRequested(secs)
                onShuffleRequested: fl.shuffleRequested()
                onRepeatRequested: fl.repeatRequested()
                onLikeRequested: fl.likeRequested()
                onVolumeWanted: (v) => fl.volumeWanted(v)
                onTrackMenuRequested: (x, y) => fl.trackMenuRequested(x, y)
                onArtistRequested: (name) => fl.artistRequested(name)
            }

            LyricsView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                live: fl.open && !content.wide
                      && (Qt.platform.os !== "android" || fl.appActive)
                lineSize: Math.max(20, Math.min(28, Math.round(content.height / 34)))
                activeBoost: Math.round(lineSize * 0.20)
                maxLineWidth: Math.min(content.width * 0.86, 720)
                edgeColor: Theme.alpha(fl.veilColor, fl.veilOpacity)
                leftAlign: false
                duetSides: true
                // Phone: the lyrics sit between the cover and the
                // transport, in the middle of the screen. That cell is the
                // one that decides light or dark ink.
                zone: 7
                pinFrac: 0.50
                pillTop: true
                syncAdjustAllowed: false
                pillShown: false
            }

            // Progress bar and transport, at the bottom: the cover is on
            // top, the lyrics in the middle and the controls close the
            // screen, the way the phone players lay it out.
            CinemaTransport {
                Layout.fillWidth: true
                ink: fl.ink
                inkDim: fl.inkDim
                position: fl.position
                duration: fl.duration
                playing: fl.playing
                shuffleOn: fl.shuffleOn
                repeatVal: fl.repeatVal
                volume: fl.volume
                centered: true

                onToggleRequested: fl.toggleRequested()
                onNextRequested: fl.nextRequested()
                onPrevRequested: fl.prevRequested()
                onSeekRequested: (secs) => fl.seekRequested(secs)
                onShuffleRequested: fl.shuffleRequested()
                onRepeatRequested: fl.repeatRequested()
                onVolumeWanted: (v) => fl.volumeWanted(v)
            }
        }
    }

    // ---- close (top RIGHT) + queue -----------------------------------------
    // The reference puts the close button in the top right corner; the
    // queue sits to its left, as a pair of window actions. Back/Esc still
    // closes too (Main's goBack).
    Rectangle {
        id: closeBtn
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: Theme.s5
        anchors.topMargin: Theme.s4
        width: 38
        height: 38
        radius: Theme.rMd
        antialiasing: true
        color: exitMa.containsMouse ? Theme.sAccentHi(Sys.bg, Sys.accent)
                                    : Theme.alpha(fl.ink, 0.10)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        scale: exitMa.pressed ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
        Glyph {
            anchors.centerIn: parent
            width: 16
            height: 16
            kind: "x"
            color: fl.ink
            weight: 1.9
        }
        MouseArea {
            id: exitMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined")
                    sfx.play("tap")
                fl.closeRequested()
            }
        }
    }

    Rectangle {
        id: queueBtn
        anchors.right: closeBtn.left
        anchors.top: parent.top
        anchors.rightMargin: Theme.s2
        anchors.topMargin: Theme.s4
        width: 38
        height: 38
        radius: Theme.rMd
        antialiasing: true
        color: queueMa.containsMouse ? Theme.sAccentHi(Sys.bg, Sys.accent)
                                     : Theme.alpha(fl.ink, 0.10)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        scale: queueMa.pressed ? 0.94 : 1
        Behavior on scale { NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic } }
        Glyph {
            anchors.centerIn: parent
            width: 19
            height: 19
            kind: "queue"
            color: fl.ink
            weight: 1.8
        }
        MouseArea {
            id: queueMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined")
                    sfx.play("tap")
                fl.queueRequested()
            }
        }
    }
}
