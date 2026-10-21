import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Search: it queries the active source (yt-dlp) and plays on click.
// Minimalist: a single surface field, the state in text and a
// VIRTUALIZED list (ListView) so all the results are not materialized at once.
Item {
    id: page

    signal playRequested(var list, int index)
    // Right click: asks for the context menu of that track (x/y in window
    // coordinates).
    signal trackContextRequested(var track, real x, real y)
    // Swipe a row to the left: add the track to the queue.
    signal enqueueRequested(var track)
    // Artists mode: the field looks for artists (and opens their discography
    // on click).
    // The chosen mode is remembered between sessions.
    signal artistRequested(var artist)
    property bool artistMode: false
    // Results of the last artist search ({ name, browseId, thumb, subtitle });
    // only relevant in artists mode.
    property var artistResults: []
    // Is an artist search running? (its process does not use catalog.busy).
    property bool artistBusy: false

    // ---- results per source ---------------------------------------------
    // The search queries ALL the sources at once. Here the groups are
    // flattened into a single list: first YouTube Music, then SoundCloud,
    // and behind them the sources that are still locked (they show their
    // name and the note, so it is clear what is missing).
    readonly property var flatResults: {
        const out = []
        let ti = 0
        // The artists first ("ARTISTS" section): there are few of them and
        // that is what people look for when typing an artist name.
        if (!page.artistMode && page.artistResults && page.artistResults.length > 0) {
            out.push({ secHead: true, sec: "Artistas", note: "" })
            for (let a = 0; a < page.artistResults.length && a < 3; a++) {
                const ar = page.artistResults[a]
                out.push({ secHead: false, kind: "artist", map: ar,
                           title: ar.name || "", artist: ar.subtitle || "",
                           thumb: ar.thumb || "", url: "" })
            }
        }
        const groups = catalog.resultsBySource
        for (let i = 0; i < groups.length; i++) {
            const g = groups[i]
            const name = String(g.name || "")
            const items = g.items || []
            if (items.length === 0) {
                if (g.locked === true)
                    out.push({ secHead: true, sec: name, note: "bloqueada" })
                continue
            }
            out.push({ secHead: true, sec: name, note: "" })
            for (let j = 0; j < items.length; j++) {
                const t = items[j]
                out.push({ secHead: false, track: t, ti: ti++,
                           title: t.title || "", artist: t.artist || "",
                           thumb: t.thumb || "", url: t.url || "",
                           duration: t.duration, liked: t.liked })
            }
        }
        return out
    }
    // The tracks in flat order: it is the list that is played on click.
    readonly property var flatTracks: {
        const out = []
        for (let i = 0; i < page.flatResults.length; i++) {
            const r = page.flatResults[i]
            if (!r.secHead && r.track)
                out.push(r.track)
        }
        return out
    }

    Component.onCompleted:
        page.artistMode = (typeof appcfg !== "undefined")
                          && appcfg.get("searchArtistMode") === "true"

    // Changes the mode and refreshes the list with the new mode (if there is a query).
    function setArtistMode(v) {
        if (v === page.artistMode)
            return
        page.artistMode = v
        if (typeof appcfg !== "undefined") {
            appcfg.set("searchArtistMode", v ? "true" : "false")
            appcfg.save()
        }
        page.lastQuery = ""
        page.autoSearch()
    }

    // The leftover wheel (list at the edge or pointer over the field) stays
    // in the page: it never drags into a parent container.
    WheelHandler { onWheel: (event) => { event.accepted = true } }

    function sourceEntry(id) {
        const l = sources.list
        for (var i = 0; i < l.length; i++)
            if (l[i].id === id)
                return l[i]
        return null
    }
    readonly property var src: sourceEntry(sources.activeId)
    readonly property bool locked: !src || src.status !== "ready"

    readonly property int rowHeight: Theme.rowH

    // ---- predictive search (search-as-you-type) -------------------------
    // While typing, after a brief pause it searches by itself (without
    // pressing Enter). The
    // engine (Catalog) is a single QProcess: if an operation is already
    // running a new search FAILS with "Wait for the current operation to
    // finish". That is why, before searching, catalog.busy is checked and,
    // if it is busy,
    // it schedules a short retry instead of calling directly.
    property int debounceMs: 300        // typing pause before searching
    property int minQuery: 2            // minimum length to search on its own
    property int retryMs: 250           // wait between retries (backend busy)
    property int retryMax: 40           // retry cap (≈10 s): never in a loop
    property int retryCount: 0
    property string lastQuery: ""       // last query sent (it avoids repeating it)
    property string pendingQuery: ""    // query waiting for the backend to be free

    // Only place that calls catalog.search()/searchArtists(): centralising
    // the busy check here avoids the "operation in progress" error. If the
    // backend is busy it stores the query and retries shortly (with a
    // cap
    // on the retries).
    function dispatchSearch(q) {
        q = String(q || "").trim()
        if (q.length === 0)
            return
        if (page.artistMode) {
            // The artists run through their own backend process
            // (m_artistProc): the busy of the songs does not affect them.
            page.lastQuery = q
            page.artistBusy = true
            catalog.searchArtists(q)
            return
        }
        if (catalog.busy) {
            if (retryCount >= retryMax) {   // busy for too long: it gives up
                pendingQuery = ""
                retryCount = 0
                return
            }
            retryCount++
            pendingQuery = q
            retryTimer.restart()
            return
        }
        retryCount = 0
        pendingQuery = ""
        page.lastQuery = q
        results.positionViewAtBeginning()   // every new search starts at the top
        // All the sources at once: there is no need to pick one before searching.
        catalog.searchAll(q)
        // And in parallel the artists (they run in their own backend process):
        // they show up as a section at the top of the list, without having to
        // change the mode.
        if (q.length >= 2)
            catalog.searchArtists(q)
    }

    // Explicit search: Enter, a History chip or "Search the artist". It
    // does go through the recent searches history (as before).
    function runSearch() {
        const q = String(input.text || "").trim()
        if (q.length === 0)
            return
        page.lastQuery = ""       // Enter relaunches it even if it repeats the query
        pushHistory(q)
        dispatchSearch(q)
    }

    // Predictive search (fired by the debounce). It does NOT touch the
    // history: every prefix typed would be stored. The history stays for
    // explicit searches (Enter / chips) and does not re-run the SAME
    // query.
    function autoSearch() {
        const q = String(input.text || "").trim()
        if (q.length < minQuery || q === lastQuery)
            return
        dispatchSearch(q)
    }

    // Typing pause: every keystroke restarts it, so the search only runs
    // when the user stops (one search per pause, not per character).
    Timer {
        id: debounceTimer
        interval: page.debounceMs
        repeat: false
        onTriggered: page.autoSearch()
    }

    // Retry while the backend is busy: once per trigger and it only
    // reschedules if it is still busy, capped at retryMax (no loops).
    Timer {
        id: retryTimer
        interval: page.retryMs
        repeat: false
        onTriggered: page.dispatchSearch(page.pendingQuery)
    }

    // The artists arrive: the list is painted (the process emits even if the
    // page is not visible: it is ignored if we are no longer in artists
    // mode).
    Connections {
        target: catalog
        function onArtistsReady(artists) {
            // The artists arrive in both modes: in the songs mode they are
            // a section at the top of the list, in the artist mode they are
            // the list itself.
            page.artistBusy = false
            page.artistResults = artists || []
            if (page.artistMode)
                artistList.positionViewAtBeginning()
        }
    }

    // External API (History chips in Home): it fills the field and searches.
    function startSearch(q) {
        input.text = String(q || "")
        runSearch()
        input.forceActiveFocus()
        input.selectAll()
    }

    // ---- search history (appcfg, "searchHistory" key) -------------------
    // JSON: [{ "q": text, "t": timestamp }...], max 20, no duplicates.
    function pushHistory(q) {
        if (typeof appcfg === "undefined")
            return
        var arr = []
        try {
            arr = JSON.parse(String(appcfg.get("searchHistory") || "[]")) || []
        } catch (e) {
            arr = []
        }
        var out = [{ q: q, t: Date.now() }]
        for (var i = 0; i < arr.length && out.length < 20; i++) {
            const e = arr[i]
            if (!e || typeof e.q !== "string" || e.q.length === 0)
                continue
            if (e.q === q)          // no duplicates (it moves to the top)
                continue
            out.push({ q: e.q, t: Number(e.t || 0) })
        }
        try {
            appcfg.set("searchHistory", JSON.stringify(out))
            appcfg.save()
        } catch (e2) {
            // without persistent history: the search keeps working
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s5
        spacing: Theme.s3

        LockedPanel {
            visible: page.locked
            Layout.alignment: Qt.AlignHCenter
            sourceName: page.src ? page.src.name : ""
            note: page.src ? page.src.note : ""
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !page.locked
            spacing: Theme.s3

            // ---- search field (thin line) -----------------------------
            // Minimal: no grey capsule and no closed border, just a line
            // below that lights up with the focus. The rest of the view
            // rules: here what matters is the list.
            Panel {
                id: field
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                radius: Theme.rPill
                color: "transparent"
                borderWidth: 0

                // The field's line.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: input.activeFocus ? Sys.accent
                                            : Theme.alpha(Sys.text, 0.14)
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }

                Glyph {
                    id: searchIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.s4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16
                    height: 16
                    kind: "search"
                    color: input.activeFocus ? Sys.accent : Sys.textDim
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }

                TextInput {
                    id: input
                    anchors.left: searchIcon.right
                    anchors.leftMargin: Theme.s2
                    anchors.right: clearBtn.left
                    anchors.rightMargin: Theme.s2
                    anchors.verticalCenter: parent.verticalCenter
                    color: Sys.text
                    font.pixelSize: Theme.tBase
                    clip: true
                    selectByMouse: true
                    // The hidden Items keep the focus in QML: when changing
                    // tab the box stayed alive and the keyboard reached it
                    // ("it typed on its own from other pages"). The focus
                    // is released
                    // as soon as the box stops being visible.
                    onVisibleChanged: if (!visible) focus = false
                    Keys.onReturnPressed: { event.accepted = true; page.runSearch() }
                    Keys.onEnterPressed: { event.accepted = true; page.runSearch() }
                    // Predictive search: every change restarts the pause; if
                    // there are still
                    // not enough characters it does not search (the wait is cancelled).
                    onTextChanged: {
                        if (input.text.trim().length < page.minQuery) {
                            debounceTimer.stop()
                            page.pendingQuery = ""
                            return
                        }
                        debounceTimer.restart()
                    }
                }
                Text {
                    visible: input.text.length === 0
                    anchors.left: input.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: input.width
                    text: "¿Qué quieres escuchar en "
                          + (page.src ? page.src.name : "") + "?"
                    color: Sys.textDim
                    font.pixelSize: Theme.tBase
                    elide: Text.ElideRight
                }
                Rectangle {
                    id: clearBtn
                    visible: input.text.length > 0
                    width: Theme.rowThin
                    height: Theme.rowThin
                    radius: Theme.rPill
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.s2
                    anchors.verticalCenter: parent.verticalCenter
                    color: clearMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 11
                        height: 11
                        kind: "x"
                        color: clearMa.containsMouse ? Sys.accent : Sys.textDim
                    }
                    MouseArea {
                        id: clearMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { input.text = ""; input.forceActiveFocus() }
                    }
                }
            }

            // ---- mode: Songs / Artists --------------------------------------
            // The same voice as the field, two targets. The chosen one is
            // remembered.
            RowLayout {
                Layout.leftMargin: Theme.s2
                spacing: Theme.s2
                Repeater {
                    model: 2
                    delegate: Rectangle {
                        id: modePill
                        required property int index
                        readonly property bool on: (index === 0) ? !page.artistMode
                                                                 : page.artistMode
                        width: modeLabel.implicitWidth + Theme.pillHPad * 2
                        height: Theme.pillH
                        radius: Theme.rPill
                        color: modePill.on ? Sys.accent : "transparent"
                        border.width: modePill.on ? 0 : 1
                        border.color: Theme.alpha(Sys.text, 0.28)
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Text {
                            id: modeLabel
                            anchors.centerIn: parent
                            text: index === 0 ? "Canciones" : "Artistas"
                            color: modePill.on ? Sys.bg : Sys.textDim
                            font.pixelSize: Theme.tSm
                            font.weight: modePill.on ? Font.DemiBold : Font.Normal
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.setArtistMode(modePill.index === 1)
                            }
                        }
                    }
                }
            }

            // ---- state ----------------------------------------------------
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.s1
                visible: catalog.busy || page.artistBusy
                text: page.artistMode ? "Buscando artistas…"
                      : (catalog.multiSearching ? "Buscando en todas las fuentes…"
                                                : "Buscando…")
                color: Sys.textDim
                font.pixelSize: Theme.tSm
            }
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.s1
                visible: !catalog.busy && !page.artistMode
                         && page.flatTracks.length > 0
                text: page.flatTracks.length + " resultados para «"
                      + catalog.resultsQuery + "»"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.s1
                visible: page.artistMode && !page.artistBusy && page.artistResults.length > 0
                text: page.artistResults.length + " artistas para «"
                      + page.lastQuery + "»"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
            }

            // ---- results (virtualized list) — no box --------------------
            // Like the rest of the app, the content goes flat over the
            // background: the list does not live inside a grey box.
            Panel {
                id: resultsIsland
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Theme.rPanel
                color: "transparent"
                clipContent: true

                ListView {
                    id: results
                    anchors.fill: parent
                    anchors.margins: Theme.s2
                    visible: !page.artistMode
                    clip: true
                    model: page.flatResults
                    spacing: Theme.s1
                    boundsBehavior: Flickable.StopAtBounds
                    reuseItems: true
                    cacheBuffer: 600
                // When new results arrive, it cooks the first tracks: a
                // click on the list header sounds right away. It cooks
                // a few of them (not only the first) because, without
                // discarding the hover prefetch already in flight, they all
                // finish and the whole list answers fast.
                onCountChanged: {
                    const arr = page.flatTracks
                    const n = Math.min(8, arr ? arr.length : 0)
                    for (let i = 0; i < n; i++) {
                        const t = arr[i]
                        if (t && t.url)
                            player.prefetch(t.url)
                    }
                }

                delegate: Rectangle {
                    id: rrow
                    required property int index
                    required property var modelData

                    width: ListView.view.width
                    // The source headers are a short row; the tracks,
                    // a normal row.
                    height: rrow.modelData.secHead ? 30 : Theme.rowH
                    radius: Theme.rLg
                    color: !rrow.modelData.secHead && rrowMouse.containsMouse
                           ? Theme.hover(Sys.surfaceAlt) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    // ---- source header (YT, SoundCloud, …) --------------------
                    Text {
                        visible: rrow.modelData.secHead === true
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s3
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Theme.s3
                        text: String(rrow.modelData.sec || "").toUpperCase()
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                        opacity: 0.85
                    }
                    Text {
                        visible: rrow.modelData.secHead === true
                                  && rrow.modelData.note === "bloqueada"
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s3
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Theme.s3
                        text: "— bloqueada, necesita credenciales"
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        opacity: 0.6
                    }

                    readonly property real dx: swipe.active ? swipe.activeTranslation.x : 0
                    readonly property bool willEnqueue: dx <= -80

                    // Discreet hint while swiping: "Enqueue".
                    Row {
                        visible: !rrow.modelData.secHead
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.s4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.s2
                        opacity: Math.min(1, -rrow.dx / 80)
                        Glyph {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 16; height: 16
                            kind: "queue"
                            color: Sys.accent
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Encolar"
                            color: Sys.accent
                            font.pixelSize: Theme.tSm
                            font.weight: Font.DemiBold
                        }
                    }

                    MouseArea {
                        id: rrowMouse
                        anchors.fill: parent
                        enabled: !rrow.modelData.secHead
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // On hover, pre-resolve that track with
                        // priority: if the click lands right away, it already sounds.
                        onContainsMouseChanged: if (containsMouse && rrow.modelData
                                                     && rrow.modelData.url)
                                                    player.prefetchFront(rrow.modelData.url)
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                page.trackContextRequested(rrow.modelData, p.x, p.y)
                            } else if (rrow.modelData.kind === "artist") {
                                // It is an artist: its page is opened.
                                page.artistRequested(rrow.modelData.map)
                            } else {
                                page.playRequested(page.flatTracks, rrow.modelData.ti)
                            }
                        }
                    }

                    // Swipe to the left to add to the queue.
                    DragHandler {
                        id: swipe
                        enabled: !rrow.modelData.secHead
                        xAxis.enabled: true
                        yAxis.enabled: false
                        target: null
                        onActiveChanged: if (!active && rrow.willEnqueue)
                                             page.enqueueRequested(rrow.modelData)
                    }

                    RowLayout {
                        visible: !rrow.modelData.secHead
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        spacing: Theme.s3
                        transform: Translate { x: rrow.dx }

                        Rectangle {
                            Layout.preferredWidth: 34
                            Layout.preferredHeight: 34
                            Layout.alignment: Qt.AlignVCenter
                            radius: Theme.rMd
                            clip: true
                            color: Sys.surface

                            RoundedArt {
                                anchors.fill: parent
                                source: rrow.modelData.thumb || ""
                                visible: String(rrow.modelData.thumb || "") !== ""
                                radiusSpec: Theme.rMd
                            }
                            Glyph {
                                anchors.centerIn: parent
                                width: 15
                                height: 15
                                visible: !rrow.modelData.thumb
                                kind: rrowMouse.containsMouse ? "play" : "music"
                                color: rrowMouse.containsMouse ? Sys.accent : Sys.textDim
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
                                    text: rrow.modelData.title || ""
                                    color: Sys.text
                                    font.pixelSize: Theme.tBase
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                LikeButton {
                                    id: rrowLike
                                    interactive: catalog.loginState === "ok"
                                                 && catalog.videoIdOf(
                                                        rrow.modelData.url) !== ""
                                    revealed: rrowMouse.containsMouse
                                    liked: {
                                        const rev = catalog.likedRevision
                                        if (!rrow.modelData)
                                            return false
                                        if (catalog.likedReady)
                                            return catalog.isLiked(rrow.modelData.url)
                                        return rrow.modelData.liked === true
                                    }
                                    onToggled: {
                                        if (rrow.modelData)
                                            catalog.toggleLiked(rrow.modelData.url,
                                                                rrowLike.liked)
                                    }
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: rrow.modelData.artist || ""
                                color: Sys.textDim
                                font.pixelSize: Theme.tSm
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: Theme.mmss(rrow.modelData.duration)
                            color: Sys.textDim
                            font.pixelSize: Theme.tSm
                        }
                    }
                }
                }

                // ---- artists (artists mode) ----------------------------------
                ListView {
                    id: artistList
                    anchors.fill: parent
                    anchors.margins: Theme.s2
                    visible: page.artistMode
                    clip: true
                    model: page.artistResults
                    spacing: Theme.s1
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: arow
                        required property int index
                        required property var modelData

                        width: ListView.view.width
                        height: 64
                        radius: Theme.rLg
                        color: arowMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                        MouseArea {
                            id: arowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.artistRequested(arow.modelData)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.s3
                            anchors.rightMargin: Theme.s3
                            spacing: Theme.s3

                            Rectangle {
                                Layout.preferredWidth: 44
                                Layout.preferredHeight: 44
                                Layout.alignment: Qt.AlignVCenter
                                radius: 22
                                clip: true
                                color: Sys.surface
                                RoundedArt {
                                    anchors.fill: parent
                                    source: arow.modelData.thumb || ""
                                    visible: String(arow.modelData.thumb || "") !== ""
                                    radiusSpec: 22
                                }
                                Glyph {
                                    anchors.centerIn: parent
                                    width: 18
                                    height: 18
                                    visible: !arow.modelData.thumb
                                    kind: "music"
                                    color: Sys.textDim
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text {
                                    Layout.fillWidth: true
                                    text: arow.modelData.name || ""
                                    color: Sys.text
                                    font.pixelSize: Theme.tBase
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: arow.modelData.subtitle || ""
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }
                        }
                    }
                }
            }

            // ---- empty / help ---------------------------------------------
            // Empty state: centred text with air, no box. It is the same
            // quiet voice as the "locked" state: the hierarchy is the air.
            Text {
                Layout.fillWidth: true
                Layout.maximumWidth: 520
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.s5
                visible: !catalog.busy && !page.artistBusy
                         && (page.artistMode
                             ? page.artistResults.length === 0
                             : catalog.results.length === 0)
                text: page.artistMode
                      ? "Escribe un nombre: al abrir un artista tienes su "
                        + "discografía entera, del disco más nuevo al más "
                        + "antiguo, con «Reproducir todo» y aleatorio."
                      : "Escribe al menos " + page.minQuery + " letras y los "
                        + "resultados aparecen solos (también puedes pulsar Enter). "
                        + "Se usa la extracción directa de la fuente: sin anuncios, "
                        + "sin navegador."
                color: Sys.textDim
                font.pixelSize: Theme.tMd
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                lineHeight: 1.35
            }
        }
    }
}
