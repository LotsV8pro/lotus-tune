import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Left panel of the cinema (the layout of the reference): the big cover,
// the title with its heart, the artist, and, under them, the progress bar,
// the times, the transport and the volume (CinemaTransport.qml). The lyrics
// stay on the right (see FullscreenLyrics.qml).
//
// It lives in its own file because the cinema uses it twice: as the left
// column on desktop and as the top block on the phone (where a second
// column does not fit). On the phone the transport is hidden here
// (`showTransport: false`) and drawn below the lyrics.
Item {
    id: cl
    implicitWidth: inner.implicitWidth
    implicitHeight: inner.implicitHeight

    property string title: ""
    property string artist: ""
    property string thumb: ""
    // YouTube ID of the track: the big cover needs the sharp variants of the
    // artwork (the ones from the API come at 120 px).
    property string videoId: ""
    property bool playing: false
    property real position: 0
    property real duration: 0
    property bool shuffleOn: false
    property int repeatVal: 0
    property bool liked: false
    property int volume: 70
    property real coverSize: 220
    // The phone hides it here and draws it below the lyrics (see
    // FullscreenLyrics.qml): cover on top, lyrics in the middle, controls
    // and progress at the bottom.
    property bool showTransport: true
    // Centre of the cover inside this item: the lyrics pin the active line
    // there, so it does not depend on how tall the block ends up being.
    readonly property real coverCenter: coverBox.y + coverBox.height / 2
    // Desktop: everything aligned left. Phone: centred.
    property bool centered: false
    // Readable ink over the wash of the cinema: the cinema works it out
    // from the average colour of the cover (light artwork -> dark text). The
    // defaults are the normal palette, for whoever does not pass them.
    property color ink: Sys.text
    property color inkDim: Theme.tDim(Sys.bg, Sys.text)

    signal toggleRequested()
    signal nextRequested()
    signal prevRequested()
    signal seekRequested(real secs)
    signal shuffleRequested()
    signal repeatRequested()
    signal likeRequested()
    signal volumeWanted(int value)
    signal trackMenuRequested(real x, real y)
    signal artistRequested(string name)

    ColumnLayout {
        id: inner
        anchors.fill: parent
        spacing: Theme.s2

        // ---- cover -----------------------------------------------------
        // Rounded like the cards of the library. A finger does not drag it
        // (dragging down closes the cinema, but not from the picture). Right
        // click: menu of the track, as in the lists.
        Rectangle {
            id: coverBox
            Layout.alignment: cl.centered ? Qt.AlignHCenter : Qt.AlignLeft
            Layout.topMargin: Theme.s2
            Layout.preferredWidth: Math.round(cl.coverSize)
            Layout.preferredHeight: Math.round(cl.coverSize)
            radius: Theme.rXl
            antialiasing: true
            color: Theme.sAccent(Sys.bg, Sys.accent)

            ArtImage {
                anchors.fill: parent
                src: cl.thumb
                videoId: cl.videoId
                // The cover of the cinema is BIG: ask for the sharpest variant (maxres)
                // first instead of the 480 px one.
                preferMaxRes: true
                radiusSpec: Theme.rXl
                showIconWhenEmpty: false

                opacity: ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.medMs } }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                hoverEnabled: true
                cursorShape: Qt.ArrowCursor
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                onClicked: {
                    const p = mapToItem(null, mouse.x, mouse.y)
                    cl.trackMenuRequested(p.x, p.y)
                }
            }
        }

        // ---- titulo + corazon -------------------------------------------
        RowLayout {
            Layout.fillWidth: !cl.centered
            Layout.alignment: cl.centered ? Qt.AlignHCenter : Qt.AlignLeft
            Layout.topMargin: Theme.s3
            spacing: Theme.s2

            Text {
                id: clTitle
                Layout.fillWidth: false
                Layout.preferredWidth: Math.min(implicitWidth, Math.max(40, cl.width - 32))
                text: cl.title.length ? cl.title : "—"
                color: cl.ink
                font.pixelSize: Theme.t2xl
                font.weight: Font.Bold
                horizontalAlignment: cl.centered ? Text.AlignHCenter : Text.AlignLeft
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            // The heart, next to the title (as in the reference).
            Item {
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                Glyph {
                    anchors.centerIn: parent
                    width: 19; height: 19
                    kind: cl.liked ? "heart" : "heart-outline"
                    color: cl.liked ? Theme.accentOn(Sys.accent, Sys.bg)
                                    : cl.inkDim
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined")
                            sfx.play("like")
                        cl.likeRequested()
                    }
                }
            }
        }

        // ---- artista (click = su pagina) ---------------------------------
        Text {
            id: clArtist
            Layout.fillWidth: true
            text: cl.artist.length ? cl.artist : "—"
            color: cl.inkDim
            font.pixelSize: Theme.tBase
            font.underline: clArtistHover.hovered
            horizontalAlignment: cl.centered ? Text.AlignHCenter : Text.AlignLeft
            elide: Text.ElideRight
            maximumLineCount: 1
            HoverHandler { id: clArtistHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                onTapped: {
                    if (typeof sfx !== "undefined")
                        sfx.play("tap")
                    if (cl.artist.length)
                        cl.artistRequested(cl.artist)
                }
            }
        }

        // ---- progress, times and transport ------------------------------
        CinemaTransport {
            Layout.fillWidth: true
            visible: cl.showTransport

            ink: cl.ink
            inkDim: cl.inkDim
            position: cl.position
            duration: cl.duration
            playing: cl.playing
            shuffleOn: cl.shuffleOn
            repeatVal: cl.repeatVal
            volume: cl.volume
            centered: cl.centered

            onToggleRequested: cl.toggleRequested()
            onNextRequested: cl.nextRequested()
            onPrevRequested: cl.prevRequested()
            onSeekRequested: (secs) => cl.seekRequested(secs)
            onShuffleRequested: cl.shuffleRequested()
            onRepeatRequested: cl.repeatRequested()
            onVolumeWanted: (v) => cl.volumeWanted(v)
        }
    }
}
