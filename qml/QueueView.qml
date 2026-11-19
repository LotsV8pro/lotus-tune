import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Playback queue. The model is Main's `queue` ListModel; it is passed
// as data (`root` is not referenced) so it can live in its own file.
Item {
    id: qv

    // Interfaz compacta global: espaciados un 10% menores.
    property bool compact: false
    property var tracks: null
    property int currentIndex: -1
    // Bars of the playing row. Only while the queue is REALLY on screen
    // and playing: before they ran forever even with the panel closed,
    // which kept the whole window repainting at 60 fps for nothing.
    property bool barsAnimate: false
    // Local filter: type to narrow the queue without touching the real
    // model. Each filtered row keeps its original index so activating a
    // row still plays the right track.
    property string filter: ""

    readonly property int visibleCount: filtered.count

    ListModel { id: filtered }

    function rebuild() {
        filtered.clear()
        const src = qv.tracks
        if (!src)
            return
        const q = String(qv.filter || "").trim().toLowerCase()
        for (let i = 0; i < src.count; ++i) {
            const t = src.get(i)
            const hay = (String(t.title || "") + " " + String(t.artist || "")).toLowerCase()
            if (q !== "" && hay.indexOf(q) < 0)
                continue
            filtered.append({
                origIndex: i,
                title: t.title || "",
                artist: t.artist || "",
                thumb: t.thumb || "",
                duration: t.duration || 0,
                source: t.source || "",
                url: t.url || ""
            })
        }
    }
    onTracksChanged: rebuild()
    onFilterChanged: rebuild()
    Component.onCompleted: rebuild()

    signal trackActivated(int index)
    // Right click: asks for the context menu of that track (x/y in window
    // coordinates).
    signal trackContextRequested(var track, real x, real y)
    // Drag reorder: original queue index -> destination queue index.
    // Emitted with real queue indices even when a filter is active.
    signal trackMoved(int from, int to)
    // Ask Main to reshuffle the queue in place (current track unchanged).
    signal reshuffleRequested()

    readonly property int count: qv.tracks ? qv.tracks.count : 0

    // Total queue duration. `rev` bumps on insert/remove/reset so the
    // binding recomputes even though `count` alone may stay the same.
    property int rev: 0
    Connections {
        target: qv.tracks
        function onRowsInserted() { qv.rev++ }
        function onRowsRemoved() { qv.rev++ }
        function onRowsMoved() { qv.rev++ }
        function onModelReset() { qv.rev++ }
    }
    readonly property string queueSummary: {
        const n = qv.count
        let secs = 0
        if (qv.tracks)
            for (let i = 0; i < n; ++i)
                secs += Number(qv.tracks.get(i).duration || 0)
        const mins = Math.floor(secs / 60)
        let dur
        if (mins >= 60)
            dur = Math.floor(mins / 60) + " h " + (mins % 60) + " min"
        else
            dur = mins + " min"
        return n + " " + qsTr("canciones") + " · " + dur
    }

    // Tracks left after the current one, and their total duration. `rev`
    // and `currentIndex` make both recompute on reorder or track advance.
    readonly property int remainingCount: {
        const n = qv.count
        const from = qv.currentIndex + 1
        return (qv.rev >= 0 && from < n) ? (n - from) : 0
    }
    readonly property string remainingTime: {
        const n = qv.count
        const from = qv.currentIndex + 1
        let secs = 0
        if (qv.tracks && qv.rev >= 0 && from < n)
            for (let i = from; i < n; ++i)
                secs += Number(qv.tracks.get(i).duration || 0)
        const mins = Math.floor(secs / 60)
        return mins >= 60
               ? Math.floor(mins / 60) + " h " + (mins % 60) + " min"
               : mins + " min"
    }

    // With a filter active, the model index is not the queue index: find
    // the filtered row that holds the current track.
    function filteredIndex() {
        for (let i = 0; i < filtered.count; ++i)
            if (filtered.get(i).origIndex === qv.currentIndex)
                return i
        return -1
    }

    // Row position in the filtered list for a real queue index.
    function filteredIndexForOrig(orig) {
        for (let i = 0; i < filtered.count; ++i)
            if (filtered.get(i).origIndex === orig)
                return i
        return -1
    }

    function scrollToCurrent() {
        const i = filteredIndex()
        if (i < 0)
            return
        list.positionViewAtIndex(i, ListView.Center)
    }
    onCurrentIndexChanged: Qt.callLater(scrollToCurrent)

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.s1

        // Queue summary + one-click shuffle, visible while the queue tab is
        // on screen.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            spacing: Theme.s2

            Text {
                Layout.fillWidth: true
                text: qsTr("%1 pistas").arg(qv.count)
                      + (qv.currentIndex >= 0
                         ? " · " + qsTr("quedan %1 (%2)").arg(qv.remainingCount).arg(qv.remainingTime)
                         : "")
                color: Theme.tDim(Sys.bg, Sys.text)
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
            }

            Rectangle {
                id: qShuffleBtn
                Layout.preferredWidth: qShuffleLabel.implicitWidth + Theme.s3 + 20
                Layout.preferredHeight: 30
                radius: Theme.rPill
                antialiasing: true
                color: qShuffleMa.containsMouse
                       ? Theme.hover(Theme.sAlt(Sys.bg, Sys.text))
                       : Theme.sAlt(Sys.bg, Sys.text)
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 5
                    Glyph {
                        width: 12; height: 12
                        kind: "shuffle"
                        color: qShuffleMa.containsMouse
                               ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                    }
                    Text {
                        id: qShuffleLabel
                        text: qsTr("Mezclar")
                        color: qShuffleMa.containsMouse
                               ? Theme.accentOn(Sys.accent, Sys.bg) : Sys.text
                        font.pixelSize: Theme.font(qv.compact, Theme.tSm)
                        font.weight: Font.DemiBold
                    }
                }
                MouseArea {
                    id: qShuffleMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof sfx !== "undefined") sfx.play("tap")
                        qv.reshuffleRequested()
                    }
                }
            }
        }

        // Local search field. Only shown while the user is looking at a
        // long queue; Escape clears it.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            radius: Theme.rPill
            antialiasing: true
            color: Theme.sAlt(Sys.bg, Sys.text)
            visible: qv.count > 3 || qv.filter.length > 0 || Theme.touch
            Glyph {
                id: qSearchGlyph
                anchors.left: parent.left
                anchors.leftMargin: Theme.s3
                anchors.verticalCenter: parent.verticalCenter
                width: 13
                height: 13
                kind: "search"
                color: Theme.tDim(Sys.bg, Sys.text)
            }
            TextInput {
                id: qSearchInput
                anchors.left: qSearchGlyph.right
                anchors.right: parent.right
                anchors.leftMargin: Theme.s2
                anchors.rightMargin: Theme.s3
                anchors.verticalCenter: parent.verticalCenter
                color: Sys.text
                font.pixelSize: Theme.tSm
                clip: true
                onTextChanged: qv.filter = text
                Keys.onEscapePressed: text = ""
            }
            Text {
                visible: qSearchInput.text.length === 0
                anchors.left: qSearchGlyph.right
                anchors.leftMargin: Theme.s2 + 1
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Buscar en la cola")
                color: Theme.tDim(Sys.bg, Sys.text)
                font.pixelSize: Theme.tSm
            }
        }

    ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: filtered
        reuseItems: true
        cacheBuffer: 240
        // Pills separated by air: one row = one capsule.
        spacing: Theme.s2
        boundsBehavior: Flickable.StopAtBounds
        // Smooth programmatic scroll (scrollToCurrent), but never the user's
        // own flick or drag: those already follow the finger.
        Behavior on contentY {
            enabled: !list.moving && !list.flicking
            NumberAnimation { duration: Theme.fastMs }
        }

        // Row geometry, used to map a drag position to a destination index.
        readonly property real rowStep: Theme.rowCompact + list.spacing

        delegate: Rectangle {
            id: row
            required property int origIndex
            required property string title
            required property string artist
            required property string thumb
            required property var duration
            required property string source
            required property string url
            property bool appeared: false

            width: ListView.view.width
            height: Theme.rowCompact
            // Every row is a pill: a capsule floating over the panel.
            radius: Theme.rPill
            antialiasing: true
            // Current row: the pill lights up with an accent veil and a very
            // faint ring. The rest only get a surface on hover.
            color: origIndex === qv.currentIndex ? Theme.alpha(Sys.accent, 0.14)
                   : (rowHover.hovered ? Theme.hover(Sys.surface) : "transparent")
            border.width: origIndex === qv.currentIndex ? 1 : 0
            border.color: Theme.alpha(Sys.accent, 0.20)
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            // Slight hover lift on desktop only.
            x: !Theme.touch && rowHover.hovered ? 3 : 0
            scale: !Theme.touch && rowHover.hovered ? 1.006 : 1
            Behavior on x { NumberAnimation { duration: Theme.fastMs } }
            Behavior on scale { NumberAnimation { duration: Theme.fastMs } }

            HoverHandler {
                id: rowHover
                cursorShape: Qt.PointingHandCursor
                // When pointing at a queue row, its stream is pre-resolved.
                onHoveredChanged: if (hovered && row.url)
                                      if (!catalog.metered)
                                          player.prefetchFront(row.url)
            }

            // Vertical drag to reorder. Position of this filtered row is
            // captured at press; on release it maps back to a queue index.
            DragHandler {
                id: rowDrag
                xAxis.enabled: false
                yAxis.enabled: true
                target: null
                // A finger drag must not also open the context menu.
                grabPermissions: PointerHandler.TakeOverForbidden
                property int origin: -1
                property real startY: 0
                property real dragY: 0
                onActiveChanged: {
                    if (active) {
                        origin = row.origIndex
                        startY = row.y
                        dragY = 0
                    } else {
                        const step = list.rowStep
                        if (step > 0) {
                            const fromFil = filteredIndexForOrig(origin)
                            let toFil = fromFil + Math.round(dragY / step)
                            toFil = Math.max(0, Math.min(filtered.count - 1, toFil))
                            if (fromFil >= 0 && toFil !== fromFil)
                                qv.trackMoved(origin, filtered.get(toFil).origIndex)
                        }
                        origin = -1
                        dragY = 0
                    }
                }
                onTranslationChanged: if (active) dragY = translation.y
            }

            // Dim while dragged; a new row fades in from 0 to 1.
            opacity: rowDrag.active ? 0.55 : (row.appeared ? 1 : 0)
            Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
            Component.onCompleted: Qt.callLater(() => row.appeared = true)

            // Over the row: the heart sits on top and takes its own click.
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                // Long press = right click on touch: the row menu (queue,
                // like, add to list, download…) was unreachable with a
                // finger.
                property bool menuHeld: false
                onPressAndHold: {
                    rowMouse.menuHeld = true
                    const p = mapToItem(null, mouseX, mouseY)
                    qv.trackContextRequested({
                        title: row.title,
                        artist: row.artist,
                        thumb: row.thumb,
                        duration: row.duration,
                        source: row.source,
                        url: row.url,
                        queueIndex: origIndex,
                        rowData: {
                            title: row.title, artist: row.artist, thumb: row.thumb,
                            duration: row.duration, source: row.source, url: row.url
                        }
                    }, p.x, p.y)
                }
                onClicked: (mouse) => {
                    if (rowMouse.menuHeld) {
                        rowMouse.menuHeld = false
                        return
                    }
                    if (typeof sfx !== "undefined") sfx.play("tap")
                    if (mouse.button === Qt.RightButton) {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        qv.trackContextRequested({
                            title: row.title,
                            artist: row.artist,
                            url: row.url,
                            thumb: row.thumb,
                            duration: row.duration,
                            source: row.source,
                            queueIndex: origIndex,
                            rowData: {
                                title: row.title, artist: row.artist, thumb: row.thumb,
                                duration: row.duration, source: row.source, url: row.url
                            }
                        }, p.x, p.y)
                    } else {
                        qv.trackActivated(origIndex)
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
                        visible: origIndex !== qv.currentIndex
                        text: origIndex + 1
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                    }
                    Row {
                        anchors.centerIn: parent
                        visible: origIndex === qv.currentIndex
                        spacing: 2
                        Repeater {
                            model: 3
                            Rectangle {
                                required property int index
                                width: 3
                                radius: 1.5
                                antialiasing: true
                                color: Sys.accent
                                height: 5
                                SequentialAnimation on height {
                                    running: row.origIndex === qv.currentIndex
                                             && qv.barsAnimate
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
                    antialiasing: true
                    color: Theme.sAlt(Sys.bg, Sys.text)
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
                        color: Theme.tDim(Sys.bg, Sys.text)
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
                            text: row.title || qsTr("Sin título")
                            color: origIndex === qv.currentIndex ? Theme.accentOn(Sys.accent, Sys.bg) : Sys.text
                            font.pixelSize: Theme.tBase
                            font.weight: origIndex === qv.currentIndex ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                        LikeButton {
                            id: rowLike
                            interactive: catalog.loginState === "ok"
                                         && catalog.videoIdOf(row.url) !== ""
                            revealed: rowHover.hovered
                            liked: {
                                // Without relying on likedReady: isLiked is already
                                // authoritative and toggleLiked bumps the
                                // revision, so the heart is marked at once
                                // (also
                                // on local tracks, resolved by their .info.json).
                                const rev = catalog.likedRevision
                                return catalog.isLiked(row.url)
                            }
                            onToggled: catalog.toggleLiked(row.url, rowLike.liked)
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: row.artist || ""
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }

                // Right-side duration. Fixed width keeps the title from
                // shifting when a track has no duration yet.
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: 40
                    horizontalAlignment: Text.AlignRight
                    visible: row.duration > 0
                    text: Theme.mmss(row.duration)
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tXs
                    elide: Text.ElideRight
                    maximumLineCount: 1
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
            antialiasing: true
            color: Theme.sAlt(Sys.bg, Sys.text)
            Glyph {
                anchors.centerIn: parent
                width: 22
                height: 22
                kind: "queue"
                color: Theme.tDim(Sys.bg, Sys.text)
            }
        }
        Text {
            Layout.fillWidth: true
            text: qsTr("La cola está vacía")
            color: Sys.text
            font.pixelSize: Theme.tBase
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            Layout.fillWidth: true
            text: qsTr("Reproduce algo y aparecerá aquí.")
            color: Theme.tDim(Sys.bg, Sys.text)
            font.pixelSize: Theme.tSm
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }
}