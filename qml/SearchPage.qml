import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Buscar: consulta la fuente activa (yt-dlp) y reproduce al clic.
// Minimalista: campo de una sola superficie, estado en texto y una lista
// VIRTUALIZADA (ListView) para no materializar todos los resultados de golpe.
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
    // El modo elegido se recuerda entre sesiones.
    signal artistRequested(var artist)
    property bool artistMode: false
    // Results of the last artist search ({ name, browseId, thumb, subtitle });
    // only relevant in artists mode.
    property var artistResults: []
    // Is an artist search running? (its process does not use catalog.busy).
    property bool artistBusy: false

    // ---- resultados por fuente -------------------------------------------
    // The search queries ALL the sources at once. Here the groups are
    // flattened into a single list: first YouTube Music, then SoundCloud,
    // and behind them the sources that are still locked (they show their
    // name and the note, so it is clear what is missing).
    readonly property var flatResults: {
        const out = []
        let ti = 0
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
    // Las pistas en orden plano: es la lista que se reproduce al pulsar.
    readonly property var flatTracks: {
        const out = []
        for (let i = 0; i < page.flatResults.length; i++)
            if (!page.flatResults[i].secHead)
                out.push(page.flatResults[i].track)
        return out
    }

    Component.onCompleted:
        page.artistMode = (typeof appcfg !== "undefined")
                          && appcfg.get("searchArtistMode") === "true"

    // Cambia el modo y refresca la lista con el modo nuevo (si hay consulta).
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

    // La rueda que sobra (lista al borde o puntero sobre el campo) se queda en
    // the page: it never drags into a parent container.
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
    // Al teclear, tras una pausa breve se busca sola (sin pulsar Enter). El
    // engine (Catalog) is a single QProcess: if an operation is already
    // running a new search FAILS with "Wait for the current operation to
    // finish". That is why, before searching, catalog.busy is checked and,
    // if it is busy,
    // programa un reintento corto en vez de llamar directamente.
    property int debounceMs: 300        // pausa de tecleo antes de buscar
    property int minQuery: 2            // longitud mínima para buscar solo
    property int retryMs: 250           // espera entre reintentos (backend ocupado)
    property int retryMax: 40           // tope de reintentos (≈10 s): nunca en bucle
    property int retryCount: 0
    property string lastQuery: ""       // última búsqueda enviada (evita repetirla)
    property string pendingQuery: ""    // búsqueda en espera de que el backend libre

    // Only place that calls catalog.search()/searchArtists(): centralising
    // the busy check here avoids the "operation in progress" error. If the
    // backend is busy it stores the query and retries shortly (with a
    // cap
    // de reintentos).
    function dispatchSearch(q) {
        q = String(q || "").trim()
        if (q.length === 0)
            return
        if (page.artistMode) {
            // Los artistas corren por su propio proceso del backend
            // (m_artistProc): no les afecta el busy de las canciones.
            page.lastQuery = q
            page.artistBusy = true
            catalog.searchArtists(q)
            return
        }
        if (catalog.busy) {
            if (retryCount >= retryMax) {   // demasiado tiempo ocupado: desiste
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
        results.positionViewAtBeginning()   // toda búsqueda nueva empieza arriba
        // Todas las fuentes a la vez: no hay que elegir una antes de buscar.
        catalog.searchAll(q)
    }

    // Explicit search: Enter, a History chip or "Search the artist". It
    // does go through the recent searches history (as before).
    function runSearch() {
        const q = String(input.text || "").trim()
        if (q.length === 0)
            return
        page.lastQuery = ""       // Enter relanza aunque repita la consulta
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

    // Llegan los artistas: se pinta la lista (el proceso emite aunque la
    // page is not visible: it is ignored if we are no longer in artists
    // mode).
    Connections {
        target: catalog
        function onArtistsReady(artists) {
            if (!page.artistMode)
                return
            page.artistBusy = false
            page.artistResults = artists || []
            artistList.positionViewAtBeginning()
        }
    }

    // API externa (chips del Historial en Inicio): rellena el campo y busca.
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
            if (e.q === q)          // sin duplicados (se mueve arriba)
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
            // debajo que se enciende con el foco. El resto de la vista
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
                    // Los Item ocultos conservan el foco en QML: al cambiar de
                    // tab the box stayed alive and the keyboard reached it
                    // ("it typed on its own from other pages"). The focus
                    // is released
                    // foco en cuanto la caja deja de verse.
                    onVisibleChanged: if (!visible) focus = false
                    Keys.onReturnPressed: { event.accepted = true; page.runSearch() }
                    Keys.onEnterPressed: { event.accepted = true; page.runSearch() }
                    // Predictive search: every change restarts the pause; if
                    // there are still
                    // no hay letras suficientes no se busca (se cancela la espera).
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

            // ---- modo: Canciones / Artistas ----------------------------------
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

            // ---- estado ----------------------------------------------------
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

            // ---- resultados (lista virtualizada) — sin caja ------------
            // Como el resto de la app, el contenido va plano sobre el
            // fondo: la lista no vive dentro de un recuadro gris.
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
                // Al llegar resultados nuevos, cuece las primeras pistas: un
                // clic en la cabecera de la lista suena al instante. Se cuecen
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
                    // Las cabeceras de fuente son una fila baja; las pistas,
                    // una fila normal.
                    height: rrow.modelData.secHead ? 30 : Theme.rowH
                    radius: Theme.rLg
                    color: !rrow.modelData.secHead && rrowMouse.containsMouse
                           ? Theme.hover(Sys.surfaceAlt) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    // ---- cabecera de fuente (YT, SoundCloud, …) ----------
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
                        // prioridad: si el clic cae enseguida, ya suena.
                        onContainsMouseChanged: if (containsMouse && rrow.modelData
                                                     && rrow.modelData.url)
                                                    player.prefetchFront(rrow.modelData.url)
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                page.trackContextRequested(rrow.modelData, p.x, p.y)
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

                // ---- artistas (modo artistas) -------------------------------
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
