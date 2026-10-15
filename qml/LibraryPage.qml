import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Biblioteca con DESPLEGABLE DE FUENTES: arriba se elige la fuente (YouTube
// Music, SoundCloud, Spotify/Tidal bloqueadas y «Local / Descargas») y debajo
// se muestra una rejilla de covers con las listas de ESA fuente — o, en el
// caso local, las descargas y los empleos en curso. Al cambiar de fuente o
// desplegar el menú NO se reproduce nada: al pulsar una cover se ABRE su
// lista (openListRequested + catalog.openPlaylist/openUrl) y sólo el botón
// de play flotante que aparece al pasar el ratón la REPRODUCE.
Item {
    id: page

    signal playRequested(var list, int index)
    // Pide abrir la lista de una cover: `play` = reproducirla en cuanto
    // lleguen las pistas; sin reproducir, Main sólo la muestra.
    signal openListRequested(bool play)
    // Clic derecho sobre una pista: menú contextual (x/y en ventana).
    signal trackContextRequested(var track, real x, real y)
    // Deslizar una fila a la izquierda: añadir la pista a la cola.
    signal enqueueRequested(var track)
    // Clic derecho sobre una lista (cover): menú contextual de la lista.
    signal coverContextRequested(var cover, real x, real y)
    // Pide reproducir la lista abierta en orden aleatorio.
    signal shuffleListRequested()

    property bool showingTracks: false

    function openTracks() { showingTracks = true; sourceMenuOpen = false }
    function showPlaylists() { showingTracks = false; sourceMenuOpen = false }

    // ---- fuente elegida en el desplegable (estado local de la página) ---
    property string selectedSourceId: sources.activeId
    property bool sourceMenuOpen: false
    // Pestaña activa de la biblioteca (0 Canciones · 1 Artistas · 2 Álbumes ·
    // 3 Playlists · 4 Descargadas). Estado puramente visual de la página.
    property int libraryTab: 0
    readonly property bool localSelected: selectedSourceId === "local"
    readonly property var localSource: ({
        id: "local", name: "Local / Descargas", status: "ready",
        note: "Archivos descargados en este equipo."
    })
    readonly property var selectedEntry: localSelected ? localSource
                                                       : sourceEntry(selectedSourceId)
    readonly property bool selectedLocked: !localSelected && !srcReady(selectedSourceId)

    function sourceEntry(id) {
        const l = sources.list
        for (var i = 0; i < l.length; i++)
            if (l[i].id === id)
                return l[i]
        return null
    }
    function srcName(id) {
        const e = sourceEntry(id)
        return e ? e.name : String(id || "")
    }
    function srcNote(id) {
        const e = sourceEntry(id)
        return e && e.note ? e.note : "Disponible cuando el backend esté listo."
    }
    function srcReady(id) {
        const e = sourceEntry(id)
        return !!e && e.status === "ready"
    }
    readonly property var src: sourceEntry(sources.activeId)
    readonly property bool locked: !src || src.status !== "ready"

    // ---- entradas del desplegable (sources + "Local / Descargas") -------
    readonly property var menuEntries: {
        const out = []
        const l = sources.list
        for (var i = 0; i < l.length; i++) {
            const e = l[i]
            out.push({ id: e.id, name: e.name, status: e.status, note: e.note || "",
                       count: page.countFor(e.id), thumbs: page.thumbsFor(e.id, 4) })
        }
        const loc = page.localSource
        out.push({ id: loc.id, name: loc.name, status: loc.status, note: loc.note,
                   count: page.dlLocal.length, thumbs: [] })
        return out
    }

    // Playlists guardadas por fuente (contrato: { name, url, source, count }).
    function playlistsOf(source) {
        const out = []
        const l = catalog.playlists
        for (var i = 0; i < l.length; i++) {
            const p = l[i]
            if (String(p.source || "") !== source)
                continue
            out.push({ index: i, name: p.name || "", url: p.url || "",
                       source: p.source || "", count: p.count || 0,
                       thumb: p.thumb || "" })
        }
        return out
    }

    // Covers (listas/álbumes) de una fuente. savedIndex >= 0 → playlist
    // guardada en `catalog` (se abre con openPlaylist); -1 → URL directa.
    function coversFor(id) {
        const out = []
        if (id === "local")
            return out
        if (id === "ytm") {
            const yl = catalog.ytmLibrary
            for (var i = 0; i < yl.length; i++) {
                const y = yl[i]
                out.push({ name: y.name || "", url: y.url || "", thumb: y.thumb || "",
                           count: y.count || 0, savedIndex: -1, source: "ytm",
                           id: y.id || "", owned: y.owned === true })
            }
        }
        const saved = page.playlistsOf(id)
        for (var j = 0; j < saved.length; j++) {
            const s = saved[j]
            var dup = false
            for (var k = 0; k < out.length; k++) {
                if (s.url && out[k].url === s.url) { dup = true; break }
            }
            if (!dup)
                out.push({ name: s.name || "", url: s.url || "", thumb: s.thumb || "",
                           count: s.count || 0, savedIndex: s.index, source: s.source })
        }
        return out
    }
    readonly property var covers: coversFor(selectedSourceId)

    function countFor(id) { return id === "local" ? dlLocal.length : coversFor(id).length }

    function thumbsFor(id, n) {
        const out = []
        if (id === "local")
            return out
        const c = coversFor(id)
        for (var i = 0; i < c.length && out.length < n; i++)
            if (c[i].thumb)
                out.push(c[i].thumb)
        return out
    }

    function openCover(c) {
        if (!c) return
        if (c.savedIndex !== undefined && c.savedIndex >= 0)
            catalog.openPlaylist(c.savedIndex)
        else
            catalog.openUrl(c.url || "", c.name || "")
    }

    // Abre (o reproduce) la lista de una cover desde el menú contextual.
    function activateCover(c, play) {
        if (!c) return
        page.openListRequested(!!play)
        page.openCover(c)
    }

    // ---- metadatos de la lista abierta (cabecera hero) ------------------
    function tracksMeta() {
        const n = catalog.tracks.length
        var out = n + (n === 1 ? " canción" : " canciones")
        var total = 0
        for (var i = 0; i < n; i++)
            total += Number(catalog.tracks[i].duration || 0)
        if (total > 0) {
            const s = Math.round(total)
            const h = Math.floor(s / 3600)
            const m = Math.floor((s % 3600) / 60)
            const ss = s % 60
            out += " · " + (h > 0
                            ? h + ":" + ("0" + m).slice(-2)
                            : String(m)) + ":" + ("0" + ss).slice(-2)
        }
        return out
    }

    // Portada de la lista abierta: la de la biblioteca YTM si la conocemos
    // (id = openPlaylistId); si no, la de la primera pista.
    function currentCover() {
        const id = String(catalog.openPlaylistId || "")
        if (id) {
            const l = catalog.ytmLibrary
            for (var i = 0; i < l.length; i++)
                if (String(l[i].id || "") === id && l[i].thumb)
                    return String(l[i].thumb)
        }
        const t = catalog.tracks
        return (t && t.length > 0) ? String(t[0].thumb || "") : ""
    }

    function currentOwned() {
        const id = String(catalog.openPlaylistId || "")
        if (!id) return false
        const l = catalog.ytmLibrary
        for (var i = 0; i < l.length; i++)
            if (String(l[i].id || "") === id)
                return l[i].owned === true
        return false
    }

    // Menú (⋮) de la lista abierta: reutiliza el menú de covers con los datos
    // de la lista en curso.
    function openHeaderMenu(x, y) {
        const id = String(catalog.openPlaylistId || "")
        page.coverContextRequested({
            id: id,
            name: String(catalog.tracksTitle || ""),
            url: id ? "https://music.youtube.com/playlist?list=" + id : "",
            owned: page.currentOwned()
        }, x, y)
    }

    // ---- rejilla responsive (columna fija ~180–220 px) ------------------
    readonly property int coverGap: 14
    function gridCols(w) {
        w = Math.max(1, w)
        return Math.max(1, Math.round(w / 210))
    }
    function gridTileW(w) {
        w = Math.max(1, w)
        const c = gridCols(w)
        return Math.min(220, Math.max(1, Math.floor((w - coverGap * (c - 1)) / c)))
    }

    // ---- descargas (backend `downloads`; puede no existir todavía) --------
    readonly property var dlJobs: (typeof downloads !== "undefined") ? downloads.jobs : []
    readonly property var dlLocal: (typeof downloads !== "undefined") ? downloads.local : []
    readonly property bool dlLocalBusy: (typeof downloads !== "undefined") ? downloads.localBusy : false

    // ---- icono de acción (Glyph no incluye descarga/carpeta/refrescar) ----
    component ActionIcon: Canvas {
        id: ico
        property string kind: "download"
        property color color: Sys.textDim
        property real stroke: 1.7

        onColorChanged: requestPaint()
        onKindChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            const u = Math.min(width, height) / 18
            const ox = (width - 18 * u) / 2
            const oy = (height - 18 * u) / 2
            const X = (v) => ox + v * u
            const Y = (v) => oy + v * u
            ctx.strokeStyle = String(ico.color)
            ctx.fillStyle = String(ico.color)
            ctx.lineWidth = ico.stroke * u
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            if (ico.kind === "download") {
                ctx.beginPath()
                ctx.moveTo(X(9), Y(3))
                ctx.lineTo(X(9), Y(11.5))
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(X(4.6), Y(7.6))
                ctx.lineTo(X(9), Y(12))
                ctx.lineTo(X(13.4), Y(7.6))
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(X(3.4), Y(15))
                ctx.lineTo(X(14.6), Y(15))
                ctx.stroke()
            } else if (ico.kind === "folder") {
                ctx.beginPath()
                ctx.moveTo(X(2.5), Y(14.2))
                ctx.lineTo(X(2.5), Y(4.4))
                ctx.lineTo(X(7.4), Y(4.4))
                ctx.lineTo(X(9.4), Y(6.6))
                ctx.lineTo(X(15.5), Y(6.6))
                ctx.lineTo(X(15.5), Y(14.2))
                ctx.closePath()
                ctx.stroke()
            } else if (ico.kind === "refresh") {
                ctx.beginPath()
                ctx.arc(X(9), Y(9), 5.4 * u, -Math.PI * 0.30, Math.PI * 1.10)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(X(11.4), Y(1.8))
                ctx.lineTo(X(14.7), Y(4.3))
                ctx.lineTo(X(11.7), Y(7.2))
                ctx.stroke()
            }
        }
    }

    // ---- cabecera de sección ---------------------------------------------
    component SectionHeader: RowLayout {
        id: header
        property string title: ""
        property string badge: ""
        property bool busy: false
        Layout.fillWidth: true
        spacing: Theme.s2

        Text {
            text: header.title
            color: Sys.text
            font.pixelSize: Theme.tLg
            font.weight: Font.DemiBold
        }
        Rectangle {
            visible: header.badge !== ""
            height: 18
            radius: Theme.rSm
            color: Sys.surfaceAlt
            implicitWidth: badgeLabel.implicitWidth + Theme.s3
            Text {
                id: badgeLabel
                anchors.centerIn: parent
                text: header.badge
                color: Sys.textDim
                font.pixelSize: Theme.tXs
                font.weight: Font.DemiBold
            }
        }
        Text {
            visible: header.busy
            text: "cargando…"
            color: Sys.textDim
            font.pixelSize: Theme.tXs
        }
        Item { Layout.fillWidth: true }
    }

    // ---- botón de icono ---------------------------------------------------
    component IconButton: Rectangle {
        id: ibtn
        property string kind: "refresh"
        signal clicked()
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        radius: Theme.rMd
        color: ibMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
        border.width: 0
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
        ActionIcon {
            anchors.centerIn: parent
            width: 16
            height: 16
            kind: ibtn.kind
            color: ibMa.containsMouse ? Sys.accent : Sys.textDim
        }
        MouseArea {
            id: ibMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ibtn.clicked()
        }
    }

    // ---- fila de descarga en curso ---------------------------------------
    component JobRow: Rectangle {
        id: jrow
        required property var modelData
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.rowH
        radius: Theme.rLg
        color: Sys.surface
        border.width: 0

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.s3
            anchors.rightMargin: Theme.s3
            anchors.topMargin: Theme.s2
            anchors.bottomMargin: Theme.s2
            spacing: Theme.s1

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                Text {
                    Layout.fillWidth: true
                    text: jrow.modelData.name || "Descarga"
                    color: Sys.text
                    font.pixelSize: Theme.tMd
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                Text {
                    text: {
                        const s = String(jrow.modelData.state || "")
                        if (s === "error") return "Error"
                        if (s === "done" || s === "finished" || s === "completed") return "Listo"
                        if (s === "queued" || s === "pending") return "En cola"
                        if (s === "canceled" || s === "cancelled") return "Cancelado"
                        return Math.round((jrow.modelData.progress || 0) * 100) + "%"
                    }
                    color: String(jrow.modelData.state || "") === "error" ? Sys.danger : Sys.textDim
                    font.pixelSize: Theme.tSm
                    font.weight: Font.Medium
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 4
                radius: 2
                color: Theme.mix(Sys.surface, Sys.text, 0.16)
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, jrow.modelData.progress || 0))
                    height: parent.height
                    radius: 2
                    color: String(jrow.modelData.state || "") === "error" ? Sys.danger : Sys.accent
                    Behavior on width { NumberAnimation { duration: Theme.fastMs } }
                }
            }
        }
    }

    // ---- panel de fuente bloqueada ---------------------------------------
    component LockedSection: Rectangle {
        id: lock
        property string title: ""
        property string note: ""
        Layout.fillWidth: true
        implicitHeight: lockCol.implicitHeight + Theme.s5
        radius: Theme.rLg
        color: Sys.surface
        border.width: 0

        ColumnLayout {
            id: lockCol
            anchors.fill: parent
            anchors.margins: Theme.s4
            spacing: Theme.s2

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s3
                Rectangle {
                    Layout.preferredWidth: 30
                    Layout.preferredHeight: 30
                    radius: Theme.rMd
                    color: Sys.accentDim
                    Glyph {
                        anchors.centerIn: parent
                        width: 15
                        height: 15
                        kind: "lock"
                        color: Sys.textDim
                    }
                }
                Text {
                    text: lock.title
                    color: Sys.text
                    font.pixelSize: Theme.tBase
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
            }
            Text {
                Layout.fillWidth: true
                text: lock.note
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 3
                elide: Text.ElideRight
                lineHeight: 1.25
            }
        }
    }

    // ====================================================================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s5
        spacing: Theme.s4

        // ---- vista de pistas de la playlist abierta ----------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: page.showingTracks
            spacing: Theme.s3

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s3

                // ---- volver ----
                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    radius: Theme.rMd
                    color: backMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                    border.width: 0
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 15
                        height: 15
                        kind: "back"
                        color: backMa.containsMouse ? Sys.accent : Sys.textDim
                    }
                    MouseArea {
                        id: backMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.showPlaylists()
                    }
                }

                // ---- portada (hero estilo Sonora) ------------------------
                Rectangle {
                    Layout.alignment: Qt.AlignBottom
                    Layout.preferredWidth: 140
                    Layout.preferredHeight: 140
                    radius: Theme.rLg
                    color: Sys.surfaceAlt
                    border.width: 0
                    clip: true

                    Image {
                        id: heroCover
                        anchors.fill: parent
                        source: page.currentCover()
                        visible: status === Image.Ready
                        sourceSize.width: 280
                        sourceSize.height: 280
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                    }
                    Glyph {
                        anchors.centerIn: parent
                        width: 40
                        height: 40
                        visible: !heroCover.visible
                        kind: "music"
                        color: Sys.textDim
                    }
                }

                // ---- título + metadatos + acciones -----------------------
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignBottom
                    Layout.leftMargin: Theme.s2
                    spacing: Theme.s1

                    Text {
                        text: "LISTA"
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        font.letterSpacing: 1.2
                        font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.fillWidth: true
                        text: catalog.tracksTitle
                        color: Sys.text
                        font.pixelSize: Theme.t2xl
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }
                    Text {
                        Layout.fillWidth: true
                        text: page.tracksMeta()
                        color: Sys.textDim
                        font.pixelSize: Theme.tMd
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    RowLayout {
                        Layout.topMargin: Theme.s2
                        spacing: Theme.s2

                        // Reproducir (primario)
                        Rectangle {
                            Layout.preferredHeight: 38
                            implicitWidth: 128
                            radius: 19
                            color: allMa.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                            scale: allMa.pressed ? 0.96 : 1
                            Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            RowLayout {
                                anchors.centerIn: parent
                                spacing: 8
                                Glyph { width: 14; height: 14; kind: "play"; color: Sys.onAccent }
                                Text {
                                    text: "Reproducir"
                                    color: Sys.onAccent
                                    font.pixelSize: Theme.tMd
                                    font.weight: Font.DemiBold
                                }
                            }
                            MouseArea {
                                id: allMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: page.playRequested(catalog.tracks, 0)
                            }
                        }

                        // Aleatorio (contorno)
                        Rectangle {
                            Layout.preferredWidth: 38
                            Layout.preferredHeight: 38
                            radius: Theme.rMd
                            color: shufMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                            border.width: 0
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            Glyph {
                                anchors.centerIn: parent
                                width: 16
                                height: 16
                                kind: "shuffle"
                                color: shufMa.containsMouse ? Sys.accent : Sys.textDim
                            }
                            MouseArea {
                                id: shufMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: page.shuffleListRequested()
                            }
                        }

                        // Desbordamiento (⋮) -> menú de la lista
                        Rectangle {
                            Layout.preferredWidth: 38
                            Layout.preferredHeight: 38
                            radius: Theme.rMd
                            color: moreMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                            border.width: 0
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            Glyph {
                                anchors.centerIn: parent
                                width: 17
                                height: 17
                                kind: "ellipsis"
                                color: moreMa.containsMouse ? Sys.accent : Sys.textDim
                            }
                            MouseArea {
                                id: moreMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    const p = mapToItem(null, mouse.x, mouse.y)
                                    page.openHeaderMenu(p.x, p.y)
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }
                    }
                }
            }

            // Lista virtualizada: filas de altura fija, reutilizadas al hacer
            // scroll (reuseItems + cacheBuffer) para mantener la RAM baja.
            ListView {
                id: tracksList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: catalog.tracks
                reuseItems: true
                cacheBuffer: 800
                spacing: 0
                boundsBehavior: Flickable.StopAtBounds
                // Lista abierta: cuece ya sus primeras pistas para que el clic
                // en la cabecera suene al instante.
                onCountChanged: {
                    const arr = catalog.tracks
                    const n = Math.min(4, arr ? arr.length : 0)
                    for (let i = 0; i < n; i++) {
                        const t = arr[i]
                        if (t && t.url)
                            player.prefetch(t.url)
                    }
                }

                delegate: Item {
                    id: trow
                    required property int index
                    required property var modelData

                    readonly property bool isLocal: String(modelData.source || "") === "local"
                                                    || String(modelData.url || "").indexOf("file://") === 0

                    width: ListView.view.width
                    height: Theme.rowH

                    readonly property real dx: swipe.active ? swipe.activeTranslation.x : 0
                    readonly property bool willEnqueue: dx <= -80

                    // Indicación discreta al deslizar: "Encolar".
                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.s4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.s2
                        opacity: Math.min(1, -trow.dx / 80)
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

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rMd
                        color: trowMouse.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    }

                    MouseArea {
                        id: trowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // Hover: pre-resuelve con prioridad la pista señalada.
                        onContainsMouseChanged: if (containsMouse && modelData
                                                     && modelData.url)
                                                    player.prefetchFront(modelData.url)
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                page.trackContextRequested(modelData, p.x, p.y)
                            } else {
                                if (typeof sfx !== 'undefined') sfx.play('tap')
                                page.playRequested(catalog.tracks, trow.index)
                            }
                        }
                    }

                    // Deslizar a la izquierda para añadir a la cola.
                    DragHandler {
                        id: swipe
                        xAxis.enabled: true
                        yAxis.enabled: false
                        target: null
                        onActiveChanged: if (!active && trow.willEnqueue)
                                             page.enqueueRequested(modelData)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        spacing: Theme.s3
                        transform: Translate { x: trow.dx }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                Layout.fillWidth: true
                                text: modelData.title || ""
                                color: Sys.text
                                font.pixelSize: Theme.tBase
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.artist || ""
                                color: Sys.textDim
                                font.pixelSize: Theme.tSm
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // Distintivo discreto para ficheros disponibles en local.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            visible: trow.isLocal
                            width: 20
                            height: 20
                            radius: 10
                            color: Theme.alpha(Sys.accent, 0.14)
                            Glyph {
                                anchors.centerIn: parent
                                width: 12
                                height: 12
                                kind: "check"
                                color: Sys.accent
                                weight: 1.8
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: Theme.mmss(modelData.duration)
                            color: Sys.textDim
                            font.pixelSize: Theme.tSm
                        }
                    }
                }
            }
        }

        // ---- biblioteca: desplegable de fuentes + covers ------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !page.showingTracks
            spacing: Theme.s3

            // 0) pestañas de sección: solo texto, subrayado de acento en la
            //    activa. Sin cajas ni fondos.
            RowLayout {
                id: libTabs
                Layout.fillWidth: true
                spacing: Theme.s5

                readonly property var items: [
                    { t: 0, name: "Canciones" },
                    { t: 1, name: "Artistas" },
                    { t: 2, name: "Álbumes" },
                    { t: 3, name: "Playlists" },
                    { t: 4, name: "Descargadas" }
                ]

                Repeater {
                    model: libTabs.items
                    delegate: Item {
                        id: tabItem
                        required property var modelData
                        readonly property bool on: page.libraryTab === modelData.t
                        implicitWidth: tabLabel.implicitWidth
                        implicitHeight: 28

                        Text {
                            id: tabLabel
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: tabItem.modelData.name
                            color: tabItem.on ? Sys.text : Sys.textDim
                            font.pixelSize: Theme.tBase
                            font.weight: tabItem.on ? Font.DemiBold : Font.Normal
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 2
                            radius: 1
                            color: Sys.accent
                            visible: tabItem.on
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.libraryTab = tabItem.modelData.t
                        }
                    }
                }
                Item { Layout.fillWidth: true }
            }

            // 1) desplegable de fuentes (todas + Local / Descargas)
            LibrarySourceMenu {
                Layout.fillWidth: true
                currentId: page.selectedSourceId
                entries: page.menuEntries
                open: page.sourceMenuOpen
                onToggled: (o) => page.sourceMenuOpen = o
                onSelected: (id) => {
                    page.selectedSourceId = id
                    page.sourceMenuOpen = false
                }
            }

            // 2) añadir playlist por URL
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2

                Rectangle {
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: Theme.rowThin
                    radius: Theme.rMd
                    color: Sys.surface
                    border.width: 1
                    border.color: nameInput.activeFocus ? Sys.accent : Sys.borderSubtle
                    Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                    TextInput {
                        id: nameInput
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        verticalAlignment: Text.AlignVCenter
                        color: Sys.text
                        font.pixelSize: Theme.tMd
                        clip: true
                    }
                    Text {
                        visible: nameInput.text.length === 0
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s3
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Nombre (opcional)"
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                    }
                }

                Rectangle {
                    id: urlField
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.rowThin
                    radius: Theme.rMd
                    color: Sys.surface
                    border.width: 1
                    border.color: urlInput.activeFocus ? Sys.accent : Sys.borderSubtle
                    Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                    TextInput {
                        id: urlInput
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        verticalAlignment: Text.AlignVCenter
                        color: Sys.text
                        font.pixelSize: Theme.tMd
                        clip: true
                        Keys.onReturnPressed: { event.accepted = true; addPlaylist() }
                        Keys.onEnterPressed: { event.accepted = true; addPlaylist() }
                    }
                    Text {
                        visible: urlInput.text.length === 0
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.s3
                        anchors.verticalCenter: parent.verticalCenter
                        text: "URL de la playlist (YouTube / SoundCloud)"
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                        elide: Text.ElideRight
                        width: parent.width - Theme.s5
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 88
                    Layout.preferredHeight: Theme.rowThin
                    radius: Theme.rMd
                    color: addMa.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                    scale: addMa.pressed ? 0.96 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Theme.s1
                        Glyph { width: 14; height: 14; kind: "plus"; color: Sys.onAccent }
                        Text {
                            text: "Añadir"
                            color: Sys.onAccent
                            font.pixelSize: Theme.tMd
                            font.weight: Font.DemiBold
                        }
                    }
                    MouseArea {
                        id: addMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: addPlaylist()
                    }
                }

                function addPlaylist() {
                    catalog.addPlaylist(nameInput.text, urlInput.text)
                    urlInput.text = ""
                }
            }

            // 3) descargas activas (visibles desde cualquier fuente)
            ColumnLayout {
                Layout.fillWidth: true
                visible: page.dlJobs.length > 0
                spacing: Theme.s2

                SectionHeader {
                    title: "DESCARGAS ACTIVAS"
                    badge: page.dlJobs.length + " en curso"
                }

                Repeater {
                    model: page.dlJobs
                    delegate: JobRow {}
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2

                    Rectangle {
                        Layout.preferredWidth: 138
                        Layout.preferredHeight: 32
                        radius: Theme.rMd
                        color: folderMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                        border.width: 0
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s2
                            ActionIcon {
                                width: 15
                                height: 15
                                kind: "folder"
                                color: folderMa.containsMouse ? Sys.accent : Sys.textDim
                            }
                            Text {
                                text: "Abrir carpeta"
                                color: folderMa.containsMouse ? Sys.accent : Sys.text
                                font.pixelSize: Theme.tSm
                                font.weight: Font.DemiBold
                            }
                        }
                        MouseArea {
                            id: folderMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (typeof downloads !== "undefined") downloads.openFolder()
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: 110
                        Layout.preferredHeight: 32
                        radius: Theme.rMd
                        color: cancelMa.containsMouse
                               ? Theme.alpha(Sys.danger, 0.12)
                               : "transparent"
                        border.width: 0
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Text {
                            anchors.centerIn: parent
                            text: "Cancelar todo"
                            color: cancelMa.containsMouse ? Sys.danger : Sys.textDim
                            font.pixelSize: Theme.tSm
                        }
                        MouseArea {
                            id: cancelMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (typeof downloads !== "undefined") downloads.cancelAll()
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
            }

            // 4) contenido de la fuente seleccionada
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Theme.s2

                SectionHeader {
                    title: page.localSelected
                           ? page.localSource.name
                           : (page.selectedEntry ? page.selectedEntry.name
                                                 : page.srcName(page.selectedSourceId))
                    badge: page.localSelected
                           ? (page.dlLocal.length > 0 ? page.dlLocal.length + " pistas" : "")
                           : (page.selectedLocked || page.covers.length === 0
                              ? "" : page.covers.length + " listas")
                    busy: page.localSelected ? page.dlLocalBusy
                          : (page.selectedSourceId === "ytm" ? catalog.libraryBusy : false)

                    IconButton { // refrescar
                        visible: page.localSelected || page.selectedSourceId === "ytm"
                        kind: "refresh"
                        onClicked: {
                            if (page.localSelected) {
                                if (typeof downloads !== "undefined") downloads.refreshLocal()
                            } else {
                                catalog.refreshYtmLibrary()
                            }
                        }
                    }
                    IconButton { // abrir carpeta (solo local)
                        visible: page.localSelected
                        kind: "folder"
                        onClicked: if (typeof downloads !== "undefined") downloads.openFolder()
                    }
                }

                // fuente bloqueada (Spotify / Tidal / lo que venga)
                LockedSection {
                    visible: page.selectedLocked && page.libraryTab !== 4
                    title: page.selectedEntry ? page.selectedEntry.name
                                              : page.srcName(page.selectedSourceId)
                    note: page.selectedLocked ? page.srcNote(page.selectedSourceId) : ""
                }

                // ---- LOCAL: descargas (lista virtualizada) ----------------
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: page.localSelected || page.libraryTab === 4

                    ListView {
                        id: localList
                        anchors.fill: parent
                        clip: true
                        model: page.dlLocal
                        reuseItems: true
                        cacheBuffer: 600
                        spacing: 0
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Item {
                            id: lrow
                            required property int index
                            required property var modelData

                            width: ListView.view.width
                            height: Theme.rowH

                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.rMd
                                color: lrowMouse.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            }

                            MouseArea {
                                id: lrowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.RightButton) {
                                        const p = mapToItem(null, mouse.x, mouse.y)
                                        page.trackContextRequested(modelData,
                                                                   p.x, p.y)
                                    } else {
                                        if (typeof sfx !== 'undefined') sfx.play('tap')
                                        page.playRequested(page.dlLocal, lrow.index)
                                    }
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s3
                                anchors.rightMargin: Theme.s3
                                spacing: Theme.s3

                                Rectangle {
                                    Layout.preferredWidth: 32
                                    Layout.preferredHeight: 32
                                    Layout.alignment: Qt.AlignVCenter
                                    radius: Theme.rSm
                                    clip: true
                                    color: Sys.surfaceAlt
                                    Image {
                                        anchors.fill: parent
                                        source: modelData.thumb || ""
                                        visible: source != ""
                                        sourceSize.width: 32
                                        sourceSize.height: 32
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        cache: true
                                    }
                                    ActionIcon {
                                        anchors.centerIn: parent
                                        width: 15
                                        height: 15
                                        visible: !modelData.thumb
                                        kind: "download"
                                        color: Sys.textDim
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.title || ""
                                        color: Sys.text
                                        font.pixelSize: Theme.tBase
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.artist || ""
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tSm
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                }
                                Glyph {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: 13
                                    height: 13
                                    kind: "check"
                                    color: Sys.accent
                                }
                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: Theme.mmss(modelData.duration)
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                }
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        width: Math.min(parent.width - Theme.s4, 320)
                        visible: localList.count === 0 && !page.dlLocalBusy
                        text: "Sin descargas locales. Usa el botón de descarga de una playlist o pista."
                        color: Sys.textDim
                        font.pixelSize: Theme.tSm
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }
                }

                // ---- FUENTE REMOTA: rejilla de covers virtualizada --------
                GridView {
                    id: coversGrid
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !page.localSelected && page.libraryTab !== 4
                             && !page.selectedLocked && page.covers.length > 0
                    clip: true
                    model: page.covers
                    reuseItems: true
                    cacheBuffer: 800
                    boundsBehavior: Flickable.StopAtBounds
                    flow: GridView.FlowLeftToRight
                    readonly property real tileW: page.gridTileW(width)
                    cellWidth: tileW + page.coverGap
                    cellHeight: tileW + 58

                    delegate: CoverTile {
                        required property int index
                        required property var modelData
                        width: GridView.view.cellWidth - page.coverGap
                        height: GridView.view.cellHeight

                        title: modelData.name || ""
                        subtitle: (modelData.count || 0) > 0
                                  ? modelData.count + " pistas"
                                  : (modelData.url || "")
                        thumb: modelData.thumb || ""
                        removable: (modelData.savedIndex || -1) >= 0
                        downloadable: !!modelData.url

                        // Clic en la tarjeta -> ABRIR la lista.
                        onClicked: {
                            page.openListRequested(false)
                            page.openCover(modelData)
                        }
                        // Clic en el botón de play flotante -> REPRODUCIR.
                        onPlayClicked: {
                            page.openListRequested(true)
                            page.openCover(modelData)
                        }
                        onDownloadRequested: {
                            if (typeof downloads !== "undefined")
                                downloads.downloadPlaylist(modelData.url || "",
                                                           modelData.name || "")
                        }
                        onRemoveRequested: {
                            if ((modelData.savedIndex || -1) >= 0)
                                catalog.removePlaylist(modelData.savedIndex)
                        }
                        onContextRequested: (x, y) => page.coverContextRequested(modelData, x, y)
                    }
                }

                // ---- estados vacíos ---------------------------------------
                Text {
                    Layout.fillWidth: true
                    visible: !page.localSelected && page.libraryTab !== 4
                             && !page.selectedLocked && page.covers.length === 0
                    text: page.selectedSourceId === "ytm"
                          ? (catalog.libraryBusy
                             ? "Cargando tus listas de YouTube Music…"
                             : "Sin listas para YouTube Music. Inicia sesión en Ajustes o pega una URL arriba para añadirla.")
                          : ("Sin listas guardadas para "
                             + (page.selectedEntry ? page.selectedEntry.name : "")
                             + ". Pega una URL arriba para añadir una.")
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                }
            }
        }
    }
}
