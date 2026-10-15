import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Cola de reproducción. El modelo es el ListModel `queue` de Main; se pasa
// como dato (no se referencia `root`) para poder vivir en su propio archivo.
Item {
    id: qv

    property var tracks: null
    property int currentIndex: -1

    signal trackActivated(int index)
    // Clic derecho: pide el menú contextual para esa pista (x/y en ventana).
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
        spacing: 2
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
            radius: Theme.rMd
            color: index === qv.currentIndex ? Theme.alpha(Sys.accent, 0.12)
                   : (rowHover.hovered ? Theme.hover(Sys.bg) : "transparent")
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            HoverHandler {
                id: rowHover
                cursorShape: Qt.PointingHandCursor
                // Al señalar una fila de la cola, pre-resuelve su stream.
                onHoveredChanged: if (hovered && row.url)
                                      player.prefetchFront(row.url)
            }

            // Detrás de la fila: el corazón va encima y recibe su propio clic.
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton)
                        qv.trackContextRequested({
                            title: row.title,
                            artist: row.artist,
                            url: row.url,
                            thumb: row.thumb,
                            duration: row.duration,
                            source: row.source
                        }, mouse.scenePos.x, mouse.scenePos.y)
                    else
                        qv.trackActivated(index)
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.s2
                anchors.rightMargin: Theme.s2
                spacing: Theme.s2

                // índice / ecualizador
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
                    radius: Theme.rSm
                    clip: true
                    color: Sys.surfaceAlt
                    Image {
                        anchors.fill: parent
                        source: row.thumb || ""
                        visible: source !== ""
                        sourceSize.width: 34
                        sourceSize.height: 34
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
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
                                const rev = catalog.likedRevision
                                return catalog.likedReady && catalog.isLiked(row.url)
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

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: Theme.mmss(row.duration)
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
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