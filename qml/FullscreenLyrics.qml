import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Lyrics cinema (was: two columns, controls embedded). The new layout is
// the one the phone asked for: the artwork at the TOP CENTRE, the synced
// letter under it, and the playback controls kept floating at the bottom.
// There is no queue column and no "fullscreen window" chrome: this view is
// an overlay INSIDE the app window (the window never leaves Windowed on
// its own) and it simply stops above the real playback bar, which stays
// visible, catchable and - through `bottomInset`, bound in Main.qml - in
// charge of the transport. On touch (Android) the tab bar keeps its air:
// the overlay lifts with both insets.
//
// The lyrics are `LyricsView` - the same engine as the panel and Now
// Playing - so track change, karaoke and the sync pill behave exactly as
// they did in the two column cinema.
Rectangle {
    id: fl
    anchors.fill: parent
    // Geometry: Main lowers the overlay by `bottomInset` so the normal
    // floating PlayerBar pokes into the window UNTOUCHED (it keeps being
    // the one true transport: nothing here is re-hardcoded).
    anchors.bottomMargin: fl.bottomInset
    color: "transparent"
    visible: opacity > 0.01
    opacity: open ? 1 : 0
    z: 72

    property bool open: false
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
    // Right click on the artwork: the same track menu as in the lists
    // (radio, queue, library...). Click on the artist: open their page.
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)
    // Swipe-down on the artwork: closes the overlay (same as the back
    // button on the phone).
    signal swipeDown()

    // The properties (title/artist/thumb/videoId/…) are bound from
    // Main.qml to the current values, so the cinema keeps them fresh
    // while it is open: bindings update themselves (an imperative copy
    // here would kill the binding and freeze the cover and the title).
    Behavior on opacity {
        NumberAnimation { duration: Theme.slowMs; easing.type: Easing.OutCubic }
    }

    readonly property bool isPhone: Qt.platform.os === "android"

    // Artwork size: the top piece, big enough to read at a glance but
    // leaving the lyrics half of the screen.
    readonly property real coverSize: Math.round(
        Theme.clamp(Math.min(fl.height * 0.32, fl.width * 0.56), 132, 224))
    // Same veil the wash uses under the lyrics: the edge washes must sit
    // on the colour the eye sees.
    readonly property color veilColor: Theme.mix(Sys.bg, "#1b2a44", 0.28)

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
        opacity: 0.66
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

    // ---- top-centre artwork + track ---------------------------------------
    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.panelMargin + Theme.s3
        anchors.rightMargin: Theme.panelMargin + Theme.s3
        anchors.topMargin: fl.isPhone ? Theme.s5 : Theme.s4
        // The phone already pays the gesture zone through bottomInset in
        // Main; a small extra air between the lyrics and the floating
        // bar keeps the two islands from touching.
        anchors.bottomMargin: fl.isPhone ? Theme.s5 + Theme.s3 : Theme.s5
        spacing: Theme.s3

        // Artwork in the middle of the top: rounded like the home cards,
        // with the "like" embedded in the bottom left corner. `ArtImage`
        // takes care of the resolution cascade (maxres -> hq -> thumbnail)
        // using the track's REAL ID. A drag-down on the cover closes the
        // overlay (the phone's "swipe down to dismiss").
        Rectangle {
            id: coverBox
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.s2
            Layout.preferredWidth: fl.coverSize
            Layout.preferredHeight: fl.coverSize
            radius: Theme.rXl
            color: Sys.surfaceAlt
            clip: true

            ArtImage {
                anchors.fill: parent
                src: fl.thumb
                videoId: fl.videoId
                // The cinema artwork is BIG: ask for the sharpest variant
                // first (maxres) instead of the 480 px one.
                preferMaxRes: true
                radiusSpec: Theme.rXl
                showIconWhenEmpty: false

                // Crossfade on track change: the slot fades to the
                // gradient while the new artwork resolves and fades back
                // in when it is ready.
                opacity: ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.medMs } }
            }
            Rectangle {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: Theme.s3
                width: 34
                height: 34
                radius: 17
                color: fl.liked ? Sys.accent : Theme.alpha(Sys.bg, 0.55)
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 17
                    height: 17
                    kind: fl.liked ? "heart" : "heart-outline"
                    color: fl.liked ? Theme.onAccentOf(Sys.accent, Sys.onAccent) : Sys.text
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.likeRequested() }
                }
            }

            // Right click over the artwork: track menu (same as lists).
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: {
                    const p = mapToItem(null, mouse.x, mouse.y)
                    fl.trackMenuRequested(p.x, p.y)
                }
            }

            // Swipe down: dismiss. The threshold is generous so a tap on
            // the like pill never reads as a drag.
            DragHandler {
                id: coverDrag
                yAxis.enabled: true
                onActiveChanged: {
                    if (!active)
                        return
                    if (coverDrag.translation.y > 90)
                        fl.closeRequested()
                }
            }
        }

        // Track and artist, centred under the artwork.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: fl.width * 0.82
            Layout.alignment: Qt.AlignHCenter
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: fl.title.length ? fl.title : "—"
                color: Sys.text
                font.pixelSize: Theme.tLg
                font.weight: Font.Bold
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 6
                Glyph {
                    width: 12
                    height: 12
                    kind: "disc"
                    color: Sys.textDim
                    weight: 1.3
                }
                Text {
                    id: flArtist
                    property bool hot: flArtistHover.hovered
                    text: fl.artist.length ? fl.artist : "—"
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                    font.underline: flArtistHover.hovered
                    elide: Text.ElideRight
                    HoverHandler { id: flArtistHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            if (typeof sfx !== "undefined")
                                sfx.play("tap")
                            if (fl.artist.length)
                                fl.artistRequested(fl.artist)
                        }
                    }
                }
            }
        }

        // ---- lyrics -----------------------------------------------------------
        // Under the artwork, centred column and bigger than in the panel;
        // the sync pill moves to the centre of the header and always follows
        // the window. Same engine, same karaoke fill, same colors - only the
        // reading alignment follows the new symmetric layout
        // (the pill is at the top, near the artwork).
        LyricsView {
            id: lyric
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: Theme.s2
            lineSize: Math.max(22, Math.min(34, Math.round(fl.height / 34)))
            activeBoost: Math.round(lineSize * 0.20)
            maxLineWidth: Math.min(fl.width * 0.62, 900)
            edgeColor: fl.veilColor
            leftAlign: false          // centred, like the artwork above
            pillTop: true
            pillShown: fl.open
        }
    }

    // ---- collapse (top left, soft square) ----------------------------------
    // Down arrow in a rounded square: leaves the cinema mode, in the same
    // spot as before. Back/Esc on the keyboard keeps closing it too
    // (Main's goBack), so nothing extra is needed on the phone.
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: Theme.s5
        anchors.topMargin: Theme.s4
        width: 38
        height: 38
        radius: Theme.rMd
        color: exitMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : Theme.alpha(Sys.text, 0.08)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        Glyph {
            anchors.centerIn: parent
            width: 20
            height: 20
            kind: "chevron-down"
            color: Sys.text
            weight: 1.8
        }
        MouseArea {
            id: exitMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.closeRequested() }
        }
    }
}
