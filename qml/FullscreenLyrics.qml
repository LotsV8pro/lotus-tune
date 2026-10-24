import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Fullscreen lyrics (cinema mode). The layout is the one of the reference
// player: a left column with the artwork, the title and the artist, the
// progress, the transport and the volume; on the right, the lyrics read
// large and left aligned. Top left is the collapse button (down arrow) and
// top centre the time compensation pill. The left column is fixed: it never
// hides (like in the base repo).
//
// The lyrics are `LyricsView` - the same engine as the panel and Now
// Playing - so what the user sees here, in the panel and in the desktop
// widgets (which read the state the app publishes) is literally the same
// representation.
Rectangle {
    id: fl
    anchors.fill: parent
    color: "transparent"
    visible: opacity > 0.01
    opacity: open ? 1 : 0
    z: 72

    property bool open: false
    property string title: ""
    property string artist: ""
    property string thumb: ""
    // YouTube ID of the current track: the big cinema artwork needs it to
    // ask for the sharp variants of the art (the API thumbnails come at
    // 120 px).
    property string videoId: ""
    property bool playing: false
    property real position: 0
    property real duration: 0
    // Real player state for the transport toggles.
    property bool shuffleOn: false
    property int repeatVal: 0
    property bool liked: false

    signal closeRequested()
    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)
    signal shuffleRequested()
    signal repeatRequested()
    signal likeRequested()
    // Right click on the track column: the same track menu as in the lists
    // (radio, queue, library...). Click on the artist: open their page.
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)

    // The properties (title/artist/thumb/videoId/…) are bound from
    // Main.qml to the current values, so the cinema keeps them fresh
    // while it is open: bindings update themselves (an imperative copy
    // here would kill the binding and freeze the cover and the title).
    Behavior on opacity {
        NumberAnimation { duration: Theme.slowMs; easing.type: Easing.OutCubic }
    }

    readonly property var ply: (typeof player !== "undefined") ? player : null

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
    // colder and crisper than the other windows. Under the lyrics, the veil
    // that contrast demands; over the column, the artwork rules.
    Rectangle {
        anchors.fill: parent
        color: Theme.mix(Sys.bg, "#1b2a44", 0.28)
        opacity: 0.66
    }
    // Click eater: the cinema mode has no colour of its own, so clicks on
    // any gap without a control or lyrics went through the window and
    // landed on the playlist behind. This one keeps whatever nobody else
    // wants.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        z: -1
    }
    // Accent aura at the bottom, very faint.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(280, parent.height * 0.34)
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.alpha(Sys.accent, 0.10) }
        }
    }

    // Right click area over the whole left column (artwork, title and
    // artist): opens the track menu. It only accepts the right button, so
    // it does not interfere with buttons or with dragging the lyrics.
    MouseArea {
        anchors.left: leftCol.left
        anchors.right: leftCol.right
        anchors.top: leftCol.top
        anchors.bottom: leftCol.bottom
        acceptedButtons: Qt.RightButton
        onClicked: {
            const p = mapToItem(null, mouse.x, mouse.y)
            fl.trackMenuRequested(p.x, p.y)
        }
    }

    // ---- lyrics -----------------------------------------------------------
    // Right column, read from the left and much bigger than in the panel;
    // the sync pill moves to the centre of the header and always follows
    // the window (the controls do NOT hide: like in the reference repo, the
    // left column is permanent).
    LyricsView {
        id: lyric
        anchors.left: leftCol.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.s6
        anchors.rightMargin: Theme.s4
        lineSize: Math.max(24, Math.min(36, Math.round(fl.width / 44)))
        activeBoost: Math.round(lineSize * 0.20)
        maxLineWidth: Math.min(fl.width * 0.52, 1180)
        edgeColor: Theme.mix(Sys.bg, "#1b2a44", 0.28)
        leftAlign: true
        pillTop: true
        pillShown: fl.open
    }

    // ---- left column: artwork, details and controls ------------------------
    // Centred on the left edge, with the artwork width as the rule. It is
    // PERMANENT (like in the reference repo): it does not hide when the
    // mouse moves; the big lyrics already have their own column on the
    // right.
    ColumnLayout {
        id: leftCol
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Math.max(Theme.s5, Math.round(fl.width * 0.05))
        width: Math.round(Math.max(210, Math.min(fl.height * 0.40, fl.width * 0.30)))
        spacing: Theme.s4

        // Big artwork with the "like" embedded in the bottom left corner
        // (the spot of the "+" in the reference repo). `ArtImage` takes care
        // of the resolution cascade (maxres -> hq -> thumbnail) using the
        // track's REAL ID: the API thumbnails come at 120 px and here the
        // artwork is huge - without the cascade it looked pixelated.
        Rectangle {
            id: coverBox
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: leftCol.width
            Layout.preferredHeight: leftCol.width
            radius: Theme.rXl
            color: Sys.surfaceAlt
            clip: true

            ArtImage {
                anchors.fill: parent
                src: fl.thumb
                videoId: fl.videoId
                // The cinema artwork has rounded corners like the home
                // cards and it is HUGE: ask for the sharpest variant
                // first (maxres) instead of the 480 px one.
                preferMaxRes: true
                radiusSpec: Theme.rXl
                showIconWhenEmpty: false

                // Crossfade on track change: the slot fades to the
                // gradient while the new artwork resolves and fades back
                // in when it is ready. Without this the Image kept the old
                // pixmap until the load finished and the cover looked
                // frozen on the previous song.
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
                    color: fl.liked ? Sys.onAccent : Sys.text
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.likeRequested() }
                }
            }
        }

        // Track and artist, centred under the artwork.
        ColumnLayout {
            Layout.fillWidth: true
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

        // Progress: time . clickable bar . time.
        Item {
            Layout.fillWidth: true
            Layout.topMargin: Theme.s2
            implicitHeight: 22
            height: 22

            Text {
                id: posLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Theme.mmss(track.scrubbing ? track.scrubSec : fl.position)
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                width: 38
            }
            Text {
                id: durLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: fl.duration > 0 ? Theme.mmss(fl.duration) : "0:00"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
            }
            Item {
                id: track
                anchors.left: posLabel.right
                anchors.right: durLabel.left
                anchors.leftMargin: Theme.s2
                anchors.rightMargin: Theme.s2
                anchors.verticalCenter: parent.verticalCenter
                height: 14
                // Drag with the button held: the bar, the knob and the
                // clock follow the cursor live and the real seek is asked
                // on release. Before there was only a click and "hold and
                // drag" did nothing.
                property bool scrubbing: false
                property real scrubSec: 0
                readonly property real shown: scrubbing ? scrubSec : fl.position
                readonly property real frac: fl.duration > 0
                                             ? Theme.clamp(shown / fl.duration, 0, 1) : 0

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 4
                    radius: 2
                    color: Theme.alpha(Sys.text, 0.16)
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * parent.frac
                    height: 4
                    radius: 2
                    color: Sys.accent
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Math.max(0, parent.width * parent.frac - 5)
                    width: 10
                    height: 10
                    radius: 5
                    color: Sys.accent
                    visible: seekMa.pressed || seekMa.containsMouse
                }
                MouseArea {
                    id: seekMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    function secAt(mx) {
                        if (parent.width <= 0)
                            return 0
                        return Math.max(0, Math.min(1, mx / parent.width)) * fl.duration
                    }
                    onPressed: (mouse) => {
                        track.scrubbing = true
                        track.scrubSec = secAt(mouse.x)
                    }
                    onPositionChanged: (mouse) => {
                        if (track.scrubbing)
                            track.scrubSec = secAt(mouse.x)
                    }
                    onReleased: (mouse) => {
                        track.scrubbing = false
                        if (fl.duration > 0)
                            fl.seekRequested(secAt(mouse.x))
                    }
                    onCanceled: track.scrubbing = false
                }
            }
        }

        // Transport: shuffle . previous . play . next . repeat.
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.s3

            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 18
                color: shMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    kind: "shuffle"
                    color: fl.shuffleOn ? Sys.accent : Sys.textDim
                }
                MouseArea {
                    id: shMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.shuffleRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 42
                Layout.preferredHeight: 42
                radius: 21
                color: prevMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    kind: "prev"
                    color: Sys.text
                }
                MouseArea {
                    id: prevMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.prevRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 52
                Layout.preferredHeight: 52
                radius: 26
                color: Sys.accent
                scale: playMa.containsMouse ? 1.05 : 1
                Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    kind: fl.playing ? "pause" : "play"
                    color: Sys.onAccent
                }
                MouseArea {
                    id: playMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.toggleRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 42
                Layout.preferredHeight: 42
                radius: 21
                color: nextMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    kind: "next"
                    color: Sys.text
                }
                MouseArea {
                    id: nextMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.nextRequested() }
                }
            }

            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 18
                color: rpMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Glyph {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    kind: fl.repeatVal === 2 ? "repeat-one" : "repeat"
                    color: fl.repeatVal > 0 ? Sys.accent : Sys.textDim
                }
                MouseArea {
                    id: rpMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); fl.repeatRequested() }
                }
            }
        }

        // Volume: speaker and a short bar, centred.
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.s1
            spacing: Theme.s2

            Glyph {
                width: 16
                height: 16
                kind: (fl.ply && fl.ply.volume > 0) ? "volume" : "volume-x"
                color: Sys.textDim
            }
            Item {
                Layout.preferredWidth: Math.round(leftCol.width * 0.46)
                Layout.preferredHeight: 16

                readonly property real frac: fl.ply ? Theme.clamp(fl.ply.volume / 100, 0, 1) : 0

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 3
                    radius: 2
                    color: Theme.alpha(Sys.text, 0.16)
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * parent.frac
                    height: 3
                    radius: 2
                    color: Sys.accent
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Math.max(0, parent.width * parent.frac - 4)
                    width: 8
                    height: 8
                    radius: 4
                    color: Sys.accent
                    visible: volMa.pressed || volMa.containsMouse
                }
                MouseArea {
                    id: volMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => {
                        if (fl.ply && parent.width > 0)
                            fl.ply.setVolume(Math.round(mouse.x / parent.width * 100))
                    }
                    onPositionChanged: (mouse) => {
                        if (pressed && fl.ply && parent.width > 0)
                            fl.ply.setVolume(Math.round(Theme.clamp(mouse.x / parent.width, 0, 1) * 100))
                    }
                }
            }
        }
    }

    // ---- collapse (top left, soft square) ----------------------------------
    // Down arrow in a rounded square: leaves the cinema mode, in the same
    // spot as in the reference repo.
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

    // The cinema mode no longer hides the controls: the left column is
    // fixed, the lyrics and the artwork always live together (layout of
    // the reference repo).
}
