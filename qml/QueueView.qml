import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Playback queue. The model is Main's `queue` ListModel; it is passed
// como dato (no se referencia `root`) para poder vivir en su propio archivo.
Item {
    id: qv

    property var tracks: null
    property int currentIndex: -1

    signal trackActivated(int index)
    // Right click: asks for the context menu of that track (x/y in window
    // coordinates).
    signal trackContextRequested(var track, real x, real y)

    readonly property int count: qv.tracks ? qv.tracks.count : 0

    function scrollToCurrent() {
        if (currentIndex < 0 || currentIndex >= count)
            return
        list.positionViewAtIndex(currentIndex, ListView.Center)
    }
    onCurrentIndexChanged: Qt.callLater(scrollToCurrent)

    ListView {
        id: list
        anchors.fill: parent
        clip: true
        model: qv.tracks
        // Pills separated by air: one row = one capsule.
        spacing: Theme.s2
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 400

        delegate: Rectangle {
            id: row
            required property int index
            required property string title
            required property string artist
            required property string thumb
            required property var duration
            required property string source
            required property string url

            width: ListView.view.width
            height: Theme.rowCompact
            // Every row is a pill: a capsule floating over the panel.
            radius: Theme.rPill
            // Current row: the pill lights up with an accent veil and a very
            // faint ring. The rest only get a surface on hover.
            color: index === qv.currentIndex ? Theme.alpha(Sys.accent, 0.14)
                   : (rowHover.hovered ? Theme.hover(Sys.surface) : "transparent")
            border.width: index === qv.currentIndex ? 1 : 0
            border.color: Theme.alpha(Sys.accent, 0.20)
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            HoverHandler {
                id: rowHover
                cursorShape: Qt.PointingHandCursor
                // When pointing at a queue row, its stream is pre-resolved.
                onHoveredChanged: if (hovered && row.url)
                                      player.prefetchFront(row.url)
            }

            // Over the row: the heart sits on top and takes its own click.
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        qv.trackContextRequested({
                            title: row.title,
                            artist: row.artist,
                            url: row.url,
                            thumb: row.thumb,
                            duration: row.duration,
                            source: row.source
                        }, p.x, p.y)
                    } else {
                        qv.trackActivated(index)
                    }
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.s3
                anchors.rightMargin: Theme.s3
                spacing: Theme.s2

                // index / equalizer
                Item {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        anchors.centerIn: parent
                        visible: index !== qv.currentIndex
                        text: index + 1
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                    }
                    Row {
                        anchors.centerIn: parent
                        visible: index === qv.currentIndex
                        spacing: 2
                        Repeater {
                            model: 3
                            Rectangle {
                                required property int index
                                width: 3
                                radius: 1.5
                                color: Sys.accent
                                height: 5
                                SequentialAnimation on height {
                                    running: row.index === qv.currentIndex
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 14; duration: 380 + index * 90; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 5; duration: 380 + index * 90; easing.type: Easing.InOutSine }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 34
                    Layout.preferredHeight: 34
                    Layout.alignment: Qt.AlignVCenter
                    radius: Theme.rMd
                    clip: true
                    color: Sys.surfaceAlt
                    RoundedArt {
                        anchors.fill: parent
                        source: row.thumb || ""
                        visible: row.thumb !== ""
                        radiusSpec: Theme.rMd
                    }
                    Glyph {
                        anchors.centerIn: parent
                        width: 15
                        height: 15
                        visible: !row.thumb
                        kind: "music"
                        color: Sys.textDim
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.s1
                        Text {
                            Layout.fillWidth: true
                            text: row.title || "Sin título"
                            color: index === qv.currentIndex ? Sys.accent : Sys.text
                            font.pixelSize: Theme.tBase
                            font.weight: index === qv.currentIndex ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        LikeButton {
                            id: rowLike
                            interactive: catalog.loginState === "ok"
                                         && catalog.videoIdOf(row.url) !== ""
                            revealed: rowHover.hovered
                            liked: {
                                // Sin depender de likedReady: isLiked ya es
                                // authoritative and toggleLiked bumps the
                                // revision, so the heart is marked at once
                                // (also
                                // en pistas locales, resueltas por su .info.json).
                                const rev = catalog.likedRevision
                                return catalog.isLiked(row.url)
                            }
                            onToggled: catalog.toggleLiked(row.url, rowLike.liked)
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: row.artist || ""
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }

                // Duration as a faint pill: it groups the metadata on the
                // right
                // y ordena la lectura de la fila.
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: durText.implicitWidth + Theme.s2 * 2
                    implicitHeight: 20
                    radius: Theme.rPill
                    color: index === qv.currentIndex ? Theme.alpha(Sys.accent, 0.16)
                                                     : Theme.alpha(Sys.text, 0.05)
                    Text {
                        id: durText
                        anchors.centerIn: parent
                        text: Theme.mmss(row.duration)
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.s6, 260)
        spacing: Theme.s3
        visible: qv.count === 0

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            width: 52
            height: 52
            radius: 26
            color: Sys.surfaceAlt
            Glyph {
                anchors.centerIn: parent
                width: 22
                height: 22
                kind: "queue"
                color: Sys.textDim
            }
        }
        Text {
            Layout.fillWidth: true
            text: "La cola está vacía"
            color: Sys.text
            font.pixelSize: Theme.tBase
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            Layout.fillWidth: true
            text: "Reproduce algo y aparecerá aquí."
            color: Sys.textDim
            font.pixelSize: Theme.tSm
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }
}