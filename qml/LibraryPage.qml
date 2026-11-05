import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Library: it shows EVERYTHING saved together (the YouTube Music library +
// all the saved playlists, without filtering by source) in a grid of
// covers; the local downloads live apart, in the "Downloaded" tab.
// Clicking a cover OPENS its list (openListRequested +
// catalog.openPlaylist/openUrl) and only the floating play button that
// appears on hover PLAYS it. Clicking a DOWNLOADED list opens it as a
// real playlist (its own tracks view), without filtering the flat list.
Item {
    id: page

    signal playRequested(var list, int index)
    // Asks to open the list of a cover: `play` = play it as soon as
    // the tracks arrive; without playing, Main only shows it.
    signal openListRequested(bool play)
    // Right click on a track: context menu (x/y in window coordinates).
    signal trackContextRequested(var track, real x, real y)
    // Swipe a row to the left: add the track to the queue.
    signal enqueueRequested(var track)
    // Right click on a list (cover): context menu of the list.
    signal coverContextRequested(var cover, real x, real y)
    // Asks to play the open list in random order.
    signal shuffleListRequested()
    // Asks to append the whole open list to the queue.
    signal queueListRequested()
    // Asks to uninstall a downloaded list (it deletes its folder).
    signal uninstallListRequested(string folder, string name)
    // Menu (...) of a DOWNLOADED list opened as a playlist.
    signal downloadMenuRequested(string folder, string name, real x, real y)
    // Asks to open a DOWNLOADED list as a playlist (records the back
    // step).
    signal downloadOpenRequested(string folder)

    property bool showingTracks: false

    // Una radio (RDAMVM/RDCLAK, "start_radio") no es una lista con autor:
    // la cabecera enseñaba el artista de la PRIMERA pista como si fuera el
    // de la radio ("Radio de Calva Louise" → "VIOLENT VIRA").
    readonly property bool viewIsRadio:
        /(?:[?&]list=RD|start_radio=1)/.test(String(catalog.openListUrl || ""))

    function openTracks() { showingTracks = true; openDownloadFolder = "" }
    function showPlaylists() { showingTracks = false; openDownloadFolder = "" }

    // Active tab of the library (0 Songs . 1 Artists . 2 Albums .
    // 3 Playlists . 4 Downloaded). Purely visual state of the page.
    property int libraryTab: 0
    // The Library no longer filters by source: it shows EVERYTHING together
    // (the YouTube Music library + all the saved playlists). The local
    // downloads go apart, in the "Downloaded" tab.
    readonly property bool localSelected: libraryTab === 4

    // Covers (lists) of the library: EVERYTHING together, without filtering
    // by source.
    // savedIndex >= 0 → playlist saved in `catalog` (it is opened with
    // openPlaylist); -1 → list of the YTM library or direct URL.
    function coversFor() {
        const out = []
        const yl = catalog.ytmLibrary
        for (var i = 0; i < yl.length; i++) {
            const y = yl[i]
            out.push({ name: y.name || "", url: y.url || "", thumb: y.thumb || "",
                       count: y.count || 0, savedIndex: -1, source: "ytm",
                       id: y.id || "", owned: y.owned === true })
        }
        const l = catalog.playlists
        for (var j = 0; j < l.length; j++) {
            const s = l[j]
            var dup = false
            for (var k = 0; k < out.length; k++) {
                if (s.url && out[k].url === s.url) { dup = true; break }
            }
            if (!dup)
                out.push({ name: s.name || "", url: s.url || "", thumb: s.thumb || "",
                           count: s.count || 0, savedIndex: j, source: s.source || "" })
        }
        return out
    }
    readonly property var covers: coversFor()

    // ---- barra de la biblioteca: buscar / crear lista -------------------
    property string libFilter: ""
    property bool addListOpen: false
    // Phone: the filter field takes the full width in its own row and only
    // appears when the magnifier is pressed (in the tab row it did not
    // fit: 200 dp of a 372 dp screen).
    property bool libSearchOpen: false

    // Covers filtradas por el campo "Buscar en la biblioteca" (nombre o
    // URL). El filtro es local: no vuelve a pedir nada a la red.
    readonly property var filteredCovers: {
        const src = page.covers
        const q = String(page.libFilter || "").trim().toLowerCase()
        if (q === "")
            return src
        const out = []
        for (let i = 0; i < (src ? src.length : 0); ++i) {
            const c = src[i]
            const hay = (String(c.name || "") + " " + String(c.url || "")).toLowerCase()
            if (hay.indexOf(q) >= 0)
                out.push(c)
        }
        return out
    }

    function openCover(c) {
        if (!c) return
        if (c.savedIndex !== undefined && c.savedIndex >= 0)
            catalog.openPlaylist(c.savedIndex)
        else
            catalog.openUrl(c.url || "", c.name || "")
    }

    // Opens (or plays) the list of a cover from the context menu.
    function activateCover(c, play) {
        if (!c) return
        page.openListRequested(!!play)
        page.openCover(c)
    }

    // ---- metadata of the open list (hero header) ------------------------
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

    // Cover of the open list: the one from the YTM library if we know it
    // (id = openPlaylistId); if not, the one of the first track.
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

    // Can the open list be downloaded? (real http URL; it includes lists
    // that
    // are not the user's.)
    function canDownloadTracks() {
        return String(catalog.openListUrl || "").indexOf("http") === 0
    }

    // URL of the open list, whether it comes from the catalogue or from an
    // already downloaded list (in that case the one stored in its
    // metadata). Empty if it cannot be downloaded.
    function viewListUrl() {
        if (page.localPlaylistOpen)
            return page.openDownloadInfo
                   ? String(page.openDownloadInfo.url || "") : ""
        return String(catalog.openListUrl || "")
    }

    // Can the open list be (re)downloaded? (it has a real http URL)
    readonly property bool viewDownloadable: page.viewListUrl().indexOf("http") === 0

    // Download job of the open list (the most recent one with the same
    // URL), whether it comes from the catalogue or from a downloaded
    // list. Null if there is none.
    readonly property var viewDlJob: {
        if (typeof downloads === "undefined")
            return null
        const u = page.viewListUrl()
        if (u === "")
            return null
        const js = downloads.jobs
        let found = null
        for (let i = 0; i < js.length; i++)
            if (String(js[i].url || "") === u)
                found = js[i]   // the last one wins (the most recent)
        return found
    }

    // Download job of the open list (the most recent one with the same
    // URL),
    // to give progress feedback INSIDE the list view itself.
    readonly property var dlTracksJob: {
        if (typeof downloads === "undefined")
            return null
        const u = String(catalog.openListUrl || "")
        if (u === "")
            return null
        const js = downloads.jobs
        let found = null
        for (let i = 0; i < js.length; i++) {
            if (String(js[i].url || "") === u)
                found = js[i]   // the last one wins (the most recent)
        }
        return found
    }

    // Installed download folder that matches the open list
    // (by the metadata URL or, as a fallback, by the sanitised name).
    // Empty if the list is not downloaded.
    readonly property string dlOpenFolder: {
        if (typeof downloads === "undefined")
            return ""
        const u = String(catalog.openListUrl || "")
        const fs = downloads.folders
        if (u !== "") {
            for (let i = 0; i < fs.length; i++)
                if (String(fs[i].url || "") === u)
                    return String(fs[i].folder || "")
        }
        const nm = String(catalog.tracksTitle || "")
        if (nm !== "") {
            const want = downloads.listFolderName(nm)
            for (let j = 0; j < fs.length; j++)
                if (String(fs[j].folder || "") === want)
                    return String(fs[j].folder || "")
        }
        return ""
    }
    // Menu (...) of the open list: it reuses the cover menu with the data
    // of the current list.
    function openHeaderMenu(x, y) {
        // Downloaded list open: its own menu (play / uninstall).
        if (page.localPlaylistOpen) {
            page.downloadMenuRequested(page.openDownloadFolder, page.viewTitle(), x, y)
            return
        }
        const id = String(catalog.openPlaylistId || "")
        page.coverContextRequested({
            id: id,
            name: String(catalog.tracksTitle || ""),
            url: id ? "https://music.youtube.com/playlist?list=" + id : "",
            owned: page.currentOwned()
        }, x, y)
    }

    // ---- responsive grid ------------------------------------------------
    // Columnas como en la referencia: tarjetas mas pequeñas y juntas, con
    // la portada cuadrada, en vez de cuatro tarjetas enormes. A 1240 px
    // de ancho salen 6 columnas de ~196 px (antes 5 de ~220).
    readonly property int coverGap: 12
    function gridCols(w) {
        w = Math.max(1, w)
        // Phone: 3 columns of ~120 dp. With the desktop 180 dp minimum the
        // phone only fitted 2 slabs of 186 dp (a gallery, not a library).
        const min = Theme.touch ? 112 : 180
        return Math.max(1, Math.floor(w / min))
    }
    // Ancho de celda exacto: la rejilla reparte el ancho entre las
    // columnas y la tarjeta deja el hueco dentro de su celda. Antes se
    // sumaba el hueco a cada celda y la ultima columna no cabia (a 1240
    // px se veian 5 columnas en vez de 6).
    function gridCellW(w) {
        w = Math.max(1, w)
        return Math.floor(w / gridCols(w))
    }
    function gridTileW(w) {
        return Math.max(1, gridCellW(w) - coverGap)
    }

    // ---- downloads (the `downloads` backend; it may not exist yet) -------
    readonly property var dlJobs: (typeof downloads !== "undefined") ? downloads.jobs : []
    // Downloaded lists (one folder = one list) and loose tracks.
    readonly property var dlFolders: (typeof downloads !== "undefined") ? downloads.folders : []

    // Folder of a downloaded list (empty if that cover is not downloaded).
    // It matches by the list URL and, as a fallback, by the sanitised name
    // (older downloads without URL in their metadata).
    function downloadedFolder(c) {
        if (!c || typeof downloads === "undefined")
            return ""
        const fs = page.dlFolders
        const u = String(c.url || "")
        if (u !== "") {
            for (let i = 0; i < fs.length; i++)
                if (String(fs[i].url || "") === u)
                    return String(fs[i].folder || "")
        }
        const nm = String(c.name || "")
        if (nm !== "") {
            const want = downloads.listFolderName(nm)
            for (let j = 0; j < fs.length; j++) {
                const f = String(fs[j].folder || "")
                if (f === "" || f === undefined)
                    continue
                if (f === want || f === nm || String(fs[j].name || "") === nm)
                    return f
            }
        }
        return ""
    }

    // Is this library cover already downloaded? (it has its folder in
    // Downloads).
    function isDownloaded(c) {
        return page.downloadedFolder(c) !== ""
    }
    readonly property var dlLocalAll: (typeof downloads !== "undefined") ? downloads.local : []
    readonly property bool dlLocalBusy: (typeof downloads !== "undefined") ? downloads.localBusy : false

    // ---- download error feedback ----------------------------------------
    // Last failure reason published by the backend (`downloadError`), with
    // the list name, to show it as a readable notice inside the page.
    property string lastDownloadError: ""
    property string lastErrorName: ""

    Connections {
        target: (typeof downloads !== "undefined") ? downloads : null
        function onDownloadError(name, message) {
            page.lastErrorName = String(name || "")
            page.lastDownloadError = String(message || "")
        }
        // When the same list finishes (or is retried), the notice is removed.
        function onDownloadCompleted(name) {
            if (String(name || "") === page.lastErrorName)
                page.lastDownloadError = ""
        }
    }

    // ---- downloaded list opened AS A PLAYLIST ---------------------------
    // Clicking a downloaded list opens it as a real playlist (the tracks
    // view with its header), instead of filtering the flat list of
    // Downloads songs.
    property string openDownloadFolder: ""     // open folder ("" = none)
    readonly property var openDownloadInfo: {
        if (page.openDownloadFolder === "")
            return null
        const fs = page.dlFolders
        for (var i = 0; i < fs.length; i++)
            if (String(fs[i].folder || "") === page.openDownloadFolder)
                return fs[i]
        return null
    }
    readonly property var openDownloadTracks: {
        if (page.openDownloadFolder === "")
            return []
        const out = []
        const all = page.dlLocalAll
        for (var i = 0; i < all.length; i++)
            if (String(all[i].folder || "") === page.openDownloadFolder)
                out.push(all[i])
        return out
    }
    // Does the tracks view show a downloaded list (and not the catalogue)?
    readonly property bool localPlaylistOpen: page.showingTracks
                                              && page.openDownloadFolder !== ""

    // Opens a downloaded list as a playlist (tracks view).
    function openDownloadPlaylist(folder) {
        const f = String(folder || "")
        if (f === "")
            return
        page.openDownloadFolder = f
        page.showingTracks = true
    }

    // ---- source of the tracks view (catalogue or downloaded list) --------
    function viewTracks() {
        return page.localPlaylistOpen ? page.openDownloadTracks : catalog.tracks
    }
    function viewTitle() {
        return page.localPlaylistOpen
               ? (page.openDownloadInfo ? String(page.openDownloadInfo.name || "") : "")
               : String(catalog.tracksTitle || "")
    }
    function viewCover() {
        return page.localPlaylistOpen
               ? (page.openDownloadInfo ? String(page.openDownloadInfo.thumb || "") : "")
               : page.currentCover()
    }
    function viewMeta() {
        if (!page.localPlaylistOpen)
            return page.tracksMeta()
        const n = page.openDownloadTracks.length
        return n + (n === 1 ? " canción" : " canciones") + " · descargada"
    }
    // Chips de la cabecera: numero de pistas y duracion total, por
    // separado (la referencia los muestra como dos pastillas).
    // Autor de la lista: el de la primera pista (la cabecera de la
    // referencia lo enseña bajo el titulo, a 18 px).
    function viewArtistText() {
        if (page.localPlaylistOpen)
            return ""
        // La radio no tiene autor propio: el de su primera pista no lo es.
        if (page.viewIsRadio)
            return "Radio · YouTube Music"
        const t = page.viewTracks()
        return (t && t.length > 0) ? String(t[0].artist || "") : ""
    }
    // Año (si las pistas lo traen): primera pastilla de la cabecera.
    function viewYearText() {
        const t = page.viewTracks()
        const y = (t && t.length > 0) ? t[0].year : 0
        return y ? String(y) : ""
    }

    function viewCountText() {
        const n = page.viewTracks().length
        return n + (n === 1 ? " canción" : " canciones")
    }
    function viewDurationText() {
        const arr = page.viewTracks()
        let total = 0
        for (let i = 0; i < (arr ? arr.length : 0); ++i)
            total += Number(arr[i].duration || 0)
        if (!(total > 0))
            return ""
        const t = Math.round(total)
        const h = Math.floor(t / 3600)
        const m = Math.floor((t % 3600) / 60)
        if (h > 0)
            return h + " h " + m + " min"
        return m + " min " + (t % 60) + " s"
    }

    function viewFolder() {
        return page.localPlaylistOpen ? page.openDownloadFolder
                                      : String(page.dlOpenFolder || "")
    }

    // ---- "Buscar en la lista" -------------------------------------------
    // El filtro es solo de la vista: cada fila guarda su indice ORIGINAL
    // (`_listIndex`) para que al pulsar suene la pista correcta de la
    // lista, no la de la posicion filtrada.
    property string listFilter: ""
    property bool listSearchOpen: false

    readonly property var listRows: {
        const src = page.viewTracks()
        const q = String(page.listFilter || "").trim().toLowerCase()
        const out = []
        for (let i = 0; i < (src ? src.length : 0); ++i) {
            const t = src[i]
            if (!t)
                continue
            if (q !== "") {
                const hay = (String(t.title || "") + " " + String(t.artist || "")
                             + " " + String(t.album || "")).toLowerCase()
                if (hay.indexOf(q) < 0)
                    continue
            }
            const row = {}
            for (const k in t)
                row[k] = t[k]
            row._listIndex = i
            out.push(row)
        }
        return out
    }

    // ---- action icon (Glyph has no download/folder/refresh) --------------
    component ActionIcon: Canvas {
        id: ico
        property string kind: "download"
        property color color: Theme.tDim(Sys.bg, Sys.text)
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

        // ---- flat content section ------------------------------------------
    // No box and no edge: the list header, the grid and the tracks go
    // straight over the background, like in the reference repo. The air (pad)
    // and the gap (spacing) mark the hierarchy; the height is set by the
    // content unless the section fills it (Layout.fillHeight).
    component Island: Rectangle {
        id: island

        property real pad: Theme.s2
        property alias spacing: inner.spacing

        implicitHeight: inner.implicitHeight + island.pad * 2
        radius: Theme.rPanel
        color: "transparent"
        border.width: 0

        default property alias content: inner.data

        ColumnLayout {
            id: inner
            anchors.fill: parent
            anchors.margins: island.pad
            spacing: Theme.s3
        }
    }

    // ---- section header --------------------------------------------------
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
            color: Theme.sAlt(Sys.bg, Sys.text)
            implicitWidth: badgeLabel.implicitWidth + Theme.s3
            Text {
                id: badgeLabel
                anchors.centerIn: parent
                text: header.badge
                color: Theme.tDim(Sys.bg, Sys.text)
                font.pixelSize: Theme.tXs
                font.weight: Font.DemiBold
            }
        }
        Text {
            visible: header.busy
            text: "cargando…"
            color: Theme.tDim(Sys.bg, Sys.text)
            font.pixelSize: Theme.tXs
        }
        Item { Layout.fillWidth: true }
    }

    // ---- icon button ------------------------------------------------------
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
            color: ibMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
        }
        MouseArea {
            id: ibMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (typeof sfx !== "undefined") sfx.play("tap")
                ibtn.clicked()
            }
        }
    }

    // ---- download row in progress ---------------------------------------
    component JobRow: Rectangle {
        id: jrow
        required property var modelData
        required property int index
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
                        if (s === "paused") return "Pausado"
                        if (s === "canceled" || s === "cancelled") return "Cancelado"
                        return Math.round(jrow.modelData.progress || 0) + "%"
                    }
                    color: String(jrow.modelData.state || "") === "error" ? Sys.danger : Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                    font.weight: Font.Medium
                }

                // Pause (while downloading) / resume (paused or failed).
                // Pausing stops yt-dlp but KEEPS the .part, so resuming goes
                // on from the same byte instead of starting the track again.
                Rectangle {
                    readonly property string st: String(jrow.modelData.state || "")
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    radius: Theme.rSm
                    visible: st === "downloading" || st === "paused" || st === "error"
                    color: jobCtlMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 13
                        height: 13
                        kind: parent.st === "downloading" ? "pause" : "play"
                        color: parent.st === "error"
                               ? Sys.danger
                               : (jobCtlMa.containsMouse
                                  ? Theme.accentOn(Sys.accent, Sys.bg)
                                  : Theme.tDim(Sys.bg, Sys.text))
                    }
                    MouseArea {
                        id: jobCtlMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            if (typeof downloads === "undefined") return
                            const st = String(jrow.modelData.state || "")
                            if (st === "downloading")
                                downloads.pauseDownload(jrow.index)
                            else
                                downloads.resumeDownload(jrow.index)
                        }
                    }
                }
            }

            // Real reason of the failure ("Playlist does not exist", "Missing ffprobe"…)
            Text {
                visible: String(jrow.modelData.state || "") === "error"
                         && !!jrow.modelData.error
                Layout.fillWidth: true
                text: String(jrow.modelData.error || "")
                color: Sys.danger
                font.pixelSize: Theme.tSm
                opacity: 0.85
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 4
                radius: 2
                color: Theme.mix(Sys.surface, Sys.text, 0.16)
                visible: String(jrow.modelData.state || "") !== "error"
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, (jrow.modelData.progress || 0) / 100))
                    height: parent.height
                    radius: 2
                    color: Sys.accent
                    Behavior on width { NumberAnimation { duration: Theme.fastMs } }
                }
            }
        }
    }

    // ---- fondo desenfocado de la lista abierta --------------------------
    // La portada de la lista, ampliada y desenfocada detras de la cabecera
    // y de las filas (referencia). El velo en degradado deja el texto
    // legible y se funde con el fondo en la mitad inferior.
    Item {
        anchors.fill: parent
        z: -1
        visible: page.showingTracks
        clip: true

        // Desenfoque REAL en C++ (rart + el pipeline del wash): la app va
        // con el backend software, donde `MultiEffect` no dibuja nada y
        // el fondo salia plano. RoundedArt se encarga de la descarga, el
        // cache y de repintar cuando el C++ termina.
        //
        // Va como TARJETA, no a sangre: mismos margenes que los demas
        // paneles (Theme.panelMargin) y radio Theme.rXl, redondeado en el
        // C++ (el alfa lo pone rart, un `clip` de Rectangle no recorta las
        // esquinas). El rectangulo que hacia de fondo llegaba cuadrado
        // hasta los bordes de la pantalla y desentonaba con las islas.
        RoundedArt {
            id: listBgArt
            anchors.fill: parent
            anchors.margins: Theme.panelMargin
            source: page.viewCover()
            radiusSpec: Theme.rXl
            blur: 2
            opacity: 0.8
        }
        Rectangle {
            anchors.fill: listBgArt
            radius: Theme.rXl
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.alpha(Sys.bg, 0.40) }
                GradientStop { position: 0.5; color: Theme.alpha(Sys.bg, 0.70) }
                GradientStop { position: 1.0; color: Theme.alpha(Sys.bg, 0.95) }
            }
        }
    }

    // ---- locked source panel ---------------------------------------------
    // ====================================================================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.panelMargin
        spacing: Theme.panelGap

        // ---- tracks view of the open playlist ----------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: page.showingTracks
            spacing: Theme.panelGap
            // El fondo es una TARJETA con esquinas de Theme.rXl: sin aire
            // dentro, la portada y la primera fila pisaban el arco de la
            // esquina y parecia todo desplazado (el fondo iba a sangre
            // antes de convertirlo en tarjeta).
            Layout.margins: Theme.s3

            // ---- cabecera de la lista (referencia: Liner) --------------
            // Portada 168, titulo 30 en negrita, autor 18 y las pastillas
            // de datos. Debajo, la fila de acciones: Reproducir todo +
            // aleatorio a la izquierda; buscar, anadir, descargar y el
            // menu a la derecha. Radios de 9 px y 32 de alto, como la
            // referencia (no pastillas de 36).
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.s1
                spacing: Theme.touch ? Theme.s3 : 22

                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    // Phone: 168 dp left only ~180 dp for the title, so
                    // "Radio de Serj Tankian…" was cut at the right edge.
                    Layout.preferredWidth: Theme.touch ? 104 : 168
                    Layout.preferredHeight: Theme.touch ? 104 : 168
                    radius: Theme.rXl
                    color: Theme.alpha(Sys.text, 0.08)
                    clip: true

                    RoundedArt {
                        id: heroCover
                        anchors.fill: parent
                        source: page.viewCover()
                        radiusSpec: Theme.rXl
                    }
                    Glyph {
                        anchors.centerIn: parent
                        width: 40
                        height: 40
                        visible: !heroCover.ready
                        kind: "music"
                        color: Theme.tDim(Sys.bg, Sys.text)
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 2
                    spacing: 0

                    Text {
                        Layout.fillWidth: true
                        text: page.viewTitle()
                        color: Sys.text
                        font.pixelSize: Theme.touch ? Theme.tXl : 30
                        font.weight: Font.Bold
                        elide: Text.ElideRight
                        maximumLineCount: Theme.touch ? 2 : 1
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }
                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        visible: page.viewArtistText() !== ""
                        text: page.viewArtistText()
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.touch ? Theme.tSm : 18
                        font.weight: Font.Normal
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    // Pastillas de datos: año y "N canciones · duracion".
                    RowLayout {
                        Layout.topMargin: 12
                        spacing: 6

                        Rectangle {
                            Layout.preferredHeight: 26
                            implicitWidth: yearLabel.implicitWidth + 22
                            radius: Theme.rPill
                            color: Theme.alpha(Sys.text, 0.10)
                            visible: page.viewYearText() !== ""
                            Text {
                                id: yearLabel
                                anchors.centerIn: parent
                                text: page.viewYearText()
                                color: Sys.text
                                font.pixelSize: 12
                            }
                        }

                        Rectangle {
                            Layout.preferredHeight: 26
                            implicitWidth: metaRow.implicitWidth + 22
                            radius: Theme.rPill
                            color: Theme.alpha(Sys.text, 0.10)
                            RowLayout {
                                id: metaRow
                                anchors.centerIn: parent
                                spacing: 6
                                Glyph {
                                    width: 13
                                    height: 13
                                    kind: "music"
                                    color: Theme.tDim(Sys.bg, Sys.text)
                                }
                                Text {
                                    text: page.viewCountText()
                                    color: Sys.text
                                    font.pixelSize: 12
                                }
                                Rectangle {
                                    width: 3
                                    height: 3
                                    radius: 1.5
                                    color: Theme.alpha(Sys.text, 0.35)
                                }
                                Text {
                                    text: page.viewDurationText()
                                    color: Sys.text
                                    font.pixelSize: 12
                                }
                            }
                        }
                    }
                }
            }

            // ---- acciones ----------------------------------------------
            // Phone: two rows (transport + utilities / search + queue).
            // In one row the search field (220 dp) pushed everything past
            // the right edge: the menu button was off screen.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.touch ? Theme.s3 : 26
                spacing: Theme.s2

            RowLayout {
                id: actionsRow
                Layout.fillWidth: true
                spacing: 8

                // Reproducir todo: pastilla clara (como la referencia, que
                // usa el boton primario del tema: fondo casi blanco y texto
                // oscuro), no el color de acento.
                Rectangle {
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    implicitWidth: playAllRow.implicitWidth + 44
                    radius: Theme.rPill
                    readonly property color pill: Theme.alpha(Sys.text, 0.92)
                    color: allMa.containsMouse ? Qt.darker(pill, 1.06) : pill
                    scale: allMa.pressed ? 0.97 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        id: playAllRow
                        anchors.centerIn: parent
                        spacing: 7
                        Glyph { width: 16; height: 16; kind: "play"; color: Sys.bg }
                        Text {
                            text: "Reproducir todo"
                            color: Sys.bg
                            font.pixelSize: 14
                            font.weight: Font.Medium
                        }
                    }
                    MouseArea {
                        id: allMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("play")
                            page.playRequested(page.viewTracks(), 0)
                        }
                    }
                }

                // Aleatorio: 52 de ancho, mismo alto y radio.
                Rectangle {
                    Layout.preferredWidth: Theme.touch ? 56 : 52
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    color: shufMa.containsMouse ? Theme.alpha(Sys.text, 0.16)
                                                : Theme.alpha(Sys.text, 0.10)
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 18; height: 18
                        kind: "shuffle"
                        color: Sys.text
                    }
                    MouseArea {
                        id: shufMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { if (typeof sfx !== "undefined") sfx.play("toggle"); page.shuffleListRequested() }
                    }
                }

                Item { Layout.fillWidth: true }

                // Descarga de la lista (con su progreso)
                Rectangle {
                    id: dlBtn
                    Layout.preferredWidth: Theme.touch ? 40 : 32
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    visible: !page.localPlaylistOpen && page.canDownloadTracks()
                    color: dlMa.containsMouse ? Theme.alpha(Sys.text, 0.16) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    readonly property var job: page.dlTracksJob
                    readonly property string jstate: job !== null ? String(job.state || "") : ""
                    readonly property bool downloading: jstate === "downloading"
                    readonly property bool failed: jstate === "error"
                    readonly property bool installed: page.dlOpenFolder !== ""
                    readonly property real frac: job !== null
                        ? Math.max(0, Math.min(1, (job.progress || 0) / 100)) : 0

                    Glyph {
                        anchors.centerIn: parent
                        width: 18
                        height: 18
                        visible: !dlBtn.downloading
                        kind: dlBtn.installed ? "check" : "download"
                        color: dlBtn.failed ? Sys.danger
                               : ((dlBtn.installed || dlMa.containsMouse) ? Sys.text : Theme.tDim(Sys.bg, Sys.text))
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: dlBtn.downloading
                        text: Math.round(dlBtn.job ? (dlBtn.job.progress || 0) : 0) + "%"
                        color: Sys.text
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                    }
                    Rectangle {
                        visible: dlBtn.downloading || dlBtn.installed || dlBtn.failed
                        x: 5
                        y: parent.height - 5
                        width: parent.width - 10
                        height: 2
                        radius: 1
                        color: Theme.alpha(Sys.text, 0.20)
                        Rectangle {
                            height: parent.height
                            radius: 1
                            color: dlBtn.failed ? Sys.danger : Sys.text
                            width: parent.width * (dlBtn.installed ? 1 : dlBtn.frac)
                            Behavior on width { NumberAnimation { duration: Theme.fastMs } }
                        }
                    }
                    MouseArea {
                        id: dlMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            if (dlBtn.installed)
                                page.uninstallListRequested(page.dlOpenFolder,
                                                            String(catalog.tracksTitle || ""))
                            else if (typeof downloads !== "undefined")
                                downloads.downloadPlaylist(
                                    String(catalog.openListUrl || ""),
                                    String(catalog.tracksTitle || ""))
                        }
                    }
                }

                // Desinstalar (solo si ya esta descargada)
                Rectangle {
                    Layout.preferredWidth: Theme.touch ? 40 : 32
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    visible: page.localPlaylistOpen
                             || (dlBtn.installed && !dlBtn.downloading)
                    color: unMa.containsMouse ? Theme.alpha(Sys.text, 0.16) : "transparent"
                    Glyph {
                        anchors.centerIn: parent
                        width: 16
                        height: 16
                        kind: "trash"
                        color: unMa.containsMouse ? Sys.danger : Sys.text
                    }
                    MouseArea {
                        id: unMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            page.uninstallListRequested(page.viewFolder(), page.viewTitle())
                        }
                    }
                }

                // Menu de la lista (…)
                Rectangle {
                    Layout.preferredWidth: Theme.touch ? 40 : 32
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    color: moreMa.containsMouse ? Theme.alpha(Sys.text, 0.16) : "transparent"
                    Glyph {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        kind: "ellipsis"
                        color: Sys.text
                    }
                    MouseArea {
                        id: moreMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: (mouse) => {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            const p = mapToItem(null, mouse.x, mouse.y)
                            page.openHeaderMenu(p.x, p.y)
                        }
                    }
                }
            }
            // ---- segunda fila (solo movil): buscar + anadir a cola ---
            // No caben en la fila de arriba (el buscador solo ya
            // ocupa 220 dp de los 372 utiles).
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: Theme.touch
                // Buscar en la lista: 220 x 32, radio 9 y fondo tenue.
                Rectangle {
                    // En el movil ocupa todo el ancho que sobra.
                    Layout.fillWidth: true
                    Layout.preferredWidth: 220
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    color: Theme.alpha(Sys.text, listSearchInput.activeFocus ? 0.14 : 0.10)
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    Glyph {
                        id: searchGlyph
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        kind: "search"
                        color: Theme.tDim(Sys.bg, Sys.text)
                    }
                    TextInput {
                        id: listSearchInput
                        anchors.left: searchGlyph.right
                        anchors.right: parent.right
                        anchors.leftMargin: 8
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        color: Sys.text
                        font.pixelSize: 14
                        clip: true
                        onTextChanged: page.listFilter = text
                        Keys.onEscapePressed: text = ""
                    }
                    Text {
                        visible: listSearchInput.text.length === 0
                        anchors.left: searchGlyph.right
                        anchors.leftMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Buscar en la lista"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: 14
                    }
                }

                Item { Layout.preferredWidth: 4 }

                // Anadir a la cola
                Rectangle {
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    implicitWidth: qlRow.implicitWidth + 44
                    radius: Theme.rPill
                    color: qlMa.containsMouse ? Theme.alpha(Sys.text, 0.16)
                                              : Theme.alpha(Sys.text, 0.10)
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        id: qlRow
                        anchors.centerIn: parent
                        spacing: 7
                        Glyph {
                            width: 16; height: 16
                            kind: "plus"
                            color: Sys.text
                        }
                        Text {
                            text: "Añadir a la cola"
                            color: Sys.text
                            font.pixelSize: 14
                            font.weight: Font.Medium
                        }
                    }
                    MouseArea {
                        id: qlMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            page.queueListRequested()
                        }
                    }
                }
            }
            }

            // Lista de pistas: filas de altura fija, reutilizadas al
            // desplazar (reuseItems + cacheBuffer) para no gastar RAM.
            // Sin tarjeta alrededor: las filas van sobre el fondo
            // desenfocado de la portada, como en la referencia.
            ListView {
                id: tracksList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: page.listRows
                reuseItems: true
                cacheBuffer: 800
                spacing: 0
                boundsBehavior: Flickable.StopAtBounds
                // Open list: it already cooks its first tracks so the click
                // on the header sounds right away.
                onCountChanged: {
                    const arr = page.viewTracks()
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

                    // Discreet hint while swiping: "Enqueue".
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
                            color: Theme.accentOn(Sys.accent, Sys.bg)
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Encolar"
                            color: Theme.accentOn(Sys.accent, Sys.bg)
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
                        // Hover: pre-resolve with priority the pointed
                        // track.
                        onContainsMouseChanged: if (containsMouse && modelData
                                                     && modelData.url)
                                                    player.prefetchFront(modelData.url)
                        // Long press = right click on touch (context menu of
                        // the track). The click that follows is swallowed.
                        property bool menuHeld: false
                        onPressAndHold: {
                            trowMouse.menuHeld = true
                            const p = mapToItem(null, mouseX, mouseY)
                            page.trackContextRequested(modelData, p.x, p.y)
                        }
                        onClicked: (mouse) => {
                            if (trowMouse.menuHeld) {
                                trowMouse.menuHeld = false
                                return
                            }
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                page.trackContextRequested(modelData, p.x, p.y)
                            } else {
                                if (typeof sfx !== 'undefined') sfx.play('tap')
                                page.playRequested(page.viewTracks(), trow.modelData._listIndex !== undefined ? trow.modelData._listIndex : trow.index)
                            }
                        }
                    }

                    // Swipe to the left to add to the queue.
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

                        // Numero de la pista (posicion en la lista, no en el
                        // filtro): como en la referencia.
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 24
                            // Numero a dos cifras ("01"), como la referencia.
                            text: {
                                const n = (trow.modelData && trow.modelData._listIndex !== undefined)
                                          ? (trow.modelData._listIndex + 1) : (trow.index + 1)
                                return n < 10 ? "0" + n : String(n)
                            }
                            color: Theme.tFaint(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tMd
                            horizontalAlignment: Text.AlignRight
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                Layout.fillWidth: true
                                text: modelData.title || ""
                                color: Sys.text
                                font.pixelSize: Theme.tLg
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.artist || ""
                                color: Theme.tDim(Sys.bg, Sys.text)
                                font.pixelSize: Theme.tMd
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // Discreet badge for files available locally.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            visible: trow.isLocal
                            width: 20
                            height: 20
                            radius: Theme.rLg
                            color: Theme.alpha(Sys.accent, 0.14)
                            Glyph {
                                anchors.centerIn: parent
                                width: 12
                                height: 12
                                kind: "check"
                                color: Theme.accentOn(Sys.accent, Sys.bg)
                                weight: 1.8
                            }
                        }

                        // Heart: "liked" from the library itself and from
                        // "Local / Downloads" (the local tracks resolve their
                        // videoId through the .info.json and sync with YT Music).
                        LikeButton {
                            id: libRowLike
                            Layout.alignment: Qt.AlignVCenter
                            interactive: catalog.loginState === "ok"
                                         && catalog.videoIdOf(modelData.url) !== ""
                            revealed: trowMouse.containsMouse
                            liked: {
                                const rev = catalog.likedRevision
                                return catalog.isLiked(modelData.url)
                            }
                            onToggled: catalog.toggleLiked(modelData.url,
                                                            libRowLike.liked)
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: Theme.mmss(modelData.duration)
                            color: Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tMd
                        }

                        // Menu de la pista (⋮), tambien con el raton: en
                        // movil no hay click derecho.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            radius: Theme.rXl
                            color: rowMoreMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            Glyph {
                                anchors.centerIn: parent
                                width: 15; height: 15
                                kind: "ellipsis"
                                color: rowMoreMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg)
                                                               : Theme.tDim(Sys.bg, Sys.text)
                            }
                            MouseArea {
                                id: rowMoreMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    const p = rowMoreMa.mapToItem(null, mouse.x, mouse.y)
                                    page.trackContextRequested(modelData, p.x, p.y)
                                }
                            }
   }
                    }
                }

            // Lista vacia por el filtro: se dice, no se deja en blanco.
            // (Va dentro de un Item porque el Island coloca a sus hijos en
            // un ColumnLayout y ahi no se puede anclar.)
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: (page.listFilter !== ""
                                         && page.listRows.length === 0) ? 72 : 0
                Text {
                    anchors.centerIn: parent
                    visible: page.listFilter !== ""
                             && page.listRows.length === 0
                    text: "Ninguna pista coincide con «" + page.listFilter + "»"
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                }
            }
            }
        }

        // ---- library: sources dropdown + covers ---------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !page.showingTracks
            spacing: Theme.s3

            // 0) section tabs: TWO pills (Library / Downloaded).
            //    The active one is filled with an accent tint and a bright edge.
            RowLayout {
                id: libTabs
                Layout.fillWidth: true
                spacing: Theme.s2

                readonly property var items: [
                    { t: 0, name: "Biblioteca" },
                    { t: 4, name: "Descargadas" }
                ]

                Repeater {
                    model: libTabs.items
                    delegate: Rectangle {
                        id: tabItem
                        required property var modelData
                        readonly property bool on: page.libraryTab === modelData.t
                        Layout.preferredHeight: Theme.pillH
                        implicitWidth: tabLabel.implicitWidth + Theme.pillHPad * 2
                        radius: Theme.rPill
                        color: tabItem.on
                               ? Sys.accentDim
                               : (tabMa.containsMouse ? Theme.hover(Theme.sAlt(Sys.bg, Sys.text))
                                                      : Theme.sAlt(Sys.bg, Sys.text))
                        border.width: 1
                        border.color: tabItem.on
                                      ? Theme.alpha(Sys.accent, 0.55)
                                      : Theme.alpha(Sys.text, Theme.panelBorderAlpha)
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s1
                            Glyph {
                                visible: tabItem.on
                                Layout.preferredWidth: 12
                                Layout.preferredHeight: 12
                                kind: tabItem.modelData.t === 4 ? "download" : "library"
                                color: Theme.accentOn(Sys.accent, Sys.bg)
                            }
                            Text {
                                id: tabLabel
                                text: tabItem.modelData.name
                                color: tabItem.on ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                                font.pixelSize: Theme.tMd
                                font.weight: tabItem.on ? Font.DemiBold : Font.Medium
                                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            }
                        }
                        MouseArea {
                            id: tabMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.libraryTab = tabItem.modelData.t }
                        }
                    }
                }
                Item { Layout.fillWidth: true }

                // Buscar en la biblioteca (filtra las tarjetas al escribir).
                // En el movil viejo una lupa que abre el campo en su propia
                // fila: aqui no cabe (200 dp de 372).
                Rectangle {
                    visible: !Theme.touch
                    Layout.preferredWidth: 200
                    Layout.preferredHeight: Theme.pillH
                    radius: Theme.rPill
                    color: Theme.sAlt(Sys.bg, Sys.text)
                    border.width: 1
                    border.color: libSearchInput.activeFocus
                                  ? Theme.alpha(Sys.accent, 0.55) : "transparent"
                    Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

                    Glyph {
                        id: libSearchGlyph
                        x: Theme.s3
                        anchors.verticalCenter: parent.verticalCenter
                        width: 13
                        height: 13
                        kind: "search"
                        color: Theme.tDim(Sys.bg, Sys.text)
                    }
                    TextInput {
                        id: libSearchInput
                        anchors.left: libSearchGlyph.right
                        anchors.right: parent.right
                        anchors.leftMargin: Theme.s2
                        anchors.rightMargin: Theme.s3
                        anchors.verticalCenter: parent.verticalCenter
                        color: Sys.text
                        font.pixelSize: Theme.tSm
                        clip: true
                        onTextChanged: page.libFilter = text
                        Keys.onEscapePressed: text = ""
                    }
                    Text {
                        visible: libSearchInput.text.length === 0
                        anchors.left: libSearchGlyph.right
                        anchors.leftMargin: Theme.s2 + 1
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Buscar en la biblioteca"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                    }
                }

                // Phone: la lupa abre el filtro en su propia fila (el campo
                // de 200 dp no cabe en esta).
                Rectangle {
                    visible: Theme.touch
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    radius: Theme.rPill
                    color: page.libSearchOpen ? Sys.accentDim
                                              : Theme.sAlt(Sys.bg, Sys.text)
                    border.width: 1
                    border.color: page.libSearchOpen
                                  ? Theme.alpha(Sys.accent, 0.55)
                                  : Theme.alpha(Sys.text, Theme.panelBorderAlpha)
                    Glyph {
                        anchors.centerIn: parent
                        width: 16; height: 16
                        kind: "search"
                        color: page.libSearchOpen ? Theme.accentOn(Sys.accent, Sys.bg)
                                                  : Theme.tDim(Sys.bg, Sys.text)
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            page.libSearchOpen = !page.libSearchOpen
                            if (!page.libSearchOpen) {
                                phoneFilter.text = ""
                                page.libFilter = ""
                            }
                        }
                    }
                }

                // Crear / añadir una lista por URL: el formulario se
                // despliega desde aqui en vez de ocupar sitio siempre.
                Rectangle {
                    Layout.preferredHeight: Theme.touch ? 40 : Theme.pillH
                    implicitWidth: Math.max(Theme.touch ? 40 : 0,
                                            createRow.implicitWidth + Theme.s4)
                    radius: Theme.rPill
                    color: page.addListOpen ? Sys.accentDim
                                            : (createMa.containsMouse ? Theme.hover(Theme.sAlt(Sys.bg, Sys.text))
                                                                      : Theme.sAlt(Sys.bg, Sys.text))
                    border.width: 1
                    border.color: page.addListOpen ? Theme.alpha(Sys.accent, 0.55)
                                                   : Theme.alpha(Sys.text, Theme.panelBorderAlpha)
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        id: createRow
                        anchors.centerIn: parent
                        spacing: Theme.s1
                        Glyph {
                            width: 13; height: 13
                            kind: "plus"
                            color: page.addListOpen ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                        }
                        Text {
                            visible: !Theme.touch
                            text: "Crear lista"
                            color: page.addListOpen ? Theme.accentOn(Sys.accent, Sys.bg) : Sys.text
                            font.pixelSize: Theme.tSm
                            font.weight: Font.DemiBold
                        }
                    }
                    MouseArea {
                        id: createMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            page.addListOpen = !page.addListOpen
                            if (page.addListOpen)
                                Qt.callLater(function () { urlInput.forceActiveFocus() })
                        }
                    }
                }
            }

            // ---- filtro de la biblioteca (solo movil) --------------------
            // Se despliega desde la lupa y ocupa todo el ancho.
            RowLayout {
                Layout.fillWidth: true
                visible: Theme.touch && page.libSearchOpen
                spacing: Theme.s2

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    radius: Theme.rPill
                    color: Theme.sAlt(Sys.bg, Sys.text)
                    border.width: 1
                    border.color: phoneFilter.activeFocus
                                  ? Theme.alpha(Sys.accent, 0.55) : "transparent"

                    Glyph {
                        id: phoneFilterGlyph
                        x: Theme.s3
                        anchors.verticalCenter: parent.verticalCenter
                        width: 15
                        height: 15
                        kind: "search"
                        color: Theme.tDim(Sys.bg, Sys.text)
                    }
                    TextInput {
                        id: phoneFilter
                        anchors.left: phoneFilterGlyph.right
                        anchors.right: parent.right
                        anchors.leftMargin: Theme.s2
                        anchors.rightMargin: Theme.s3
                        anchors.verticalCenter: parent.verticalCenter
                        color: Sys.text
                        font.pixelSize: Theme.tBase
                        clip: true
                        onTextChanged: page.libFilter = text
                    }
                    Text {
                        visible: phoneFilter.text.length === 0
                        anchors.left: phoneFilterGlyph.right
                        anchors.leftMargin: Theme.s2 + 1
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Buscar en la biblioteca"
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tBase
                    }
                }
            }

            // Readable notice of the last download failure (downloadError
            // signal).
            Island {
                Layout.fillWidth: true
                pad: Theme.s3
                visible: page.lastDownloadError !== ""
                color: Theme.alpha(Sys.danger, 0.10)
                border.color: Theme.alpha(Sys.danger, 0.40)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2
                    Glyph {
                        Layout.preferredWidth: 15
                        Layout.preferredHeight: 15
                        Layout.alignment: Qt.AlignVCenter
                        kind: "x"
                        color: Sys.danger
                    }
                    Text {
                        Layout.fillWidth: true
                        text: (page.lastErrorName !== ""
                               ? "«" + page.lastErrorName + "»: " : "")
                              + page.lastDownloadError
                        color: Sys.danger
                        font.pixelSize: Theme.tSm
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }
                    Rectangle {
                        Layout.preferredWidth: Theme.pillH
                        Layout.preferredHeight: Theme.pillH
                        radius: Theme.rPill
                        color: errCloseMa.containsMouse ? Theme.hover(Theme.sAlt(Sys.bg, Sys.text))
                                                        : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 13
                            height: 13
                            kind: "x"
                            color: errCloseMa.containsMouse ? Sys.text : Theme.tDim(Sys.bg, Sys.text)
                        }
                        MouseArea {
                            id: errCloseMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.lastDownloadError = ""; page.lastErrorName = ""
                            }
                        }
                    }
                }
            }

            // 2) add a playlist by URL (floating island with pills)
            Island {
                Layout.fillWidth: true
                visible: page.addListOpen
                spacing: Theme.s2

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s2

                Rectangle {
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: Theme.rowThin
                    radius: Theme.rPill
                    color: Sys.surface
                    border.width: 1
                    border.color: nameInput.activeFocus ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.line(Sys.bg, Sys.text)
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
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                    }
                }

                Rectangle {
                    id: urlField
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.rowThin
                    radius: Theme.rPill
                    color: Sys.surface
                    border.width: 1
                    border.color: urlInput.activeFocus ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.line(Sys.bg, Sys.text)
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
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                        elide: Text.ElideRight
                        width: parent.width - Theme.s5
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 88
                    Layout.preferredHeight: Theme.rowThin
                    radius: Theme.rPill
                    color: addMa.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                    scale: addMa.pressed ? 0.96 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Theme.s1
                        Glyph { width: 14; height: 14; kind: "plus"; color: Theme.onAccent(Sys.accent) }
                        Text {
                            text: "Añadir"
                            color: Theme.onAccent(Sys.accent)
                            font.pixelSize: Theme.tMd
                            font.weight: Font.DemiBold
                        }
                    }
                    MouseArea {
                        id: addMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); addPlaylist() }
                    }
                }

                function addPlaylist() {
                    catalog.addPlaylist(nameInput.text, urlInput.text)
                    urlInput.text = ""
                    nameInput.text = ""
                    // El formulario se recoge al terminar: la biblioteca
                    // vuelve a estar limpia.
                    page.addListOpen = false
                }
            }
            }

            // 3) active downloads (visible from any source)
            Island {
                Layout.fillWidth: true
                visible: page.dlJobs.length > 0
                spacing: Theme.s2

            ColumnLayout {
                Layout.fillWidth: true
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
                                color: folderMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                            }
                            Text {
                                text: "Abrir carpeta"
                                color: folderMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Sys.text
                                font.pixelSize: Theme.tSm
                                font.weight: Font.DemiBold
                            }
                        }
                        MouseArea {
                            id: folderMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); if (typeof downloads !== "undefined") downloads.openFolder() }
                        }
                    }
                    // Pause / resume the whole queue. A job that failed is
                    // retried from where it stopped (the .part is kept).
                    Rectangle {
                        readonly property bool anyActive: {
                            const js = page.dlJobs
                            for (let i = 0; i < js.length; ++i) {
                                const s = String(js[i].state || "")
                                if (s === "downloading" || s === "queued")
                                    return true
                            }
                            return false
                        }
                        visible: anyActive
                        Layout.preferredWidth: 96
                        Layout.preferredHeight: 32
                        radius: Theme.rMd
                        color: pauseAllMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s1
                            ActionIcon { width: 13; height: 13; kind: "pause"
                                         color: Theme.tDim(Sys.bg, Sys.text) }
                            Text {
                                text: "Pausar"
                                color: pauseAllMa.containsMouse
                                       ? Theme.accentOn(Sys.accent, Sys.bg) : Sys.text
                                font.pixelSize: Theme.tSm
                                font.weight: Font.DemiBold
                            }
                        }
                        MouseArea {
                            id: pauseAllMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                if (typeof downloads !== "undefined") downloads.pauseAll()
                            }
                        }
                    }
                    Rectangle {
                        readonly property bool anyPaused: {
                            const js = page.dlJobs
                            for (let i = 0; i < js.length; ++i) {
                                const s = String(js[i].state || "")
                                if (s === "paused" || s === "error")
                                    return true
                            }
                            return false
                        }
                        visible: anyPaused
                        Layout.preferredWidth: 106
                        Layout.preferredHeight: 32
                        radius: Theme.rMd
                        color: resumeAllMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s1
                            ActionIcon { width: 13; height: 13; kind: "play"
                                         color: Theme.accentOn(Sys.accent, Sys.bg) }
                            Text {
                                text: "Reanudar"
                                color: resumeAllMa.containsMouse
                                       ? Theme.accentOn(Sys.accent, Sys.bg) : Sys.text
                                font.pixelSize: Theme.tSm
                                font.weight: Font.DemiBold
                            }
                        }
                        MouseArea {
                            id: resumeAllMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                if (typeof downloads !== "undefined") downloads.resumeAll()
                            }
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
                            color: cancelMa.containsMouse ? Sys.danger : Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tSm
                        }
                        MouseArea {
                            id: cancelMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); if (typeof downloads !== "undefined") downloads.cancelAll() }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
            }
            }

            // 4) library content (or the downloads)
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Theme.s2

                SectionHeader {
                    title: page.localSelected ? "Descargadas" : "Biblioteca"
                    badge: page.localSelected
                           ? (page.dlLocalAll.length > 0 ? page.dlLocalAll.length + " pistas" : "")
                           : (page.covers.length === 0 ? ""
                                                       : page.covers.length + " listas")
                    busy: page.localSelected ? page.dlLocalBusy : catalog.libraryBusy

                    IconButton { // refresh
                        kind: "refresh"
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            if (page.localSelected) {
                                if (typeof downloads !== "undefined") downloads.refreshLocal()
                            } else {
                                catalog.refreshYtmLibrary()
                            }
                        }
                    }
                    IconButton { // open folder (local only)
                        visible: page.localSelected
                        kind: "folder"
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            if (typeof downloads !== "undefined") downloads.openFolder()
                        }
                    }
                }

                // ---- Downloaded lists (one folder = one list) --------------
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: page.dlFolders.length > 0 ? 112 : 0
                    visible: page.localSelected && page.dlFolders.length > 0
                    clip: true

                    ListView {
                        id: folderStrip
                        anchors.fill: parent
                        orientation: ListView.Horizontal
                        spacing: Theme.s3
                        model: page.dlFolders
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Item {
                            id: fcell
                            required property var modelData
                            width: 128
                            height: folderStrip.height

                            Rectangle {
                                id: fthumb
                                width: parent.width
                                height: 84
                                radius: Theme.rMd
                                color: Theme.sAlt(Sys.bg, Sys.text)
                                clip: true
                                RoundedArt {
                                    anchors.fill: parent
                                    source: fcell.modelData.thumb || ""
                                    visible: String(fcell.modelData.thumb || "") !== ""
                                    radiusSpec: Theme.rMd
                                }
                                Glyph {
                                    anchors.centerIn: parent
                                    width: 22
                                    height: 22
                                    visible: !fcell.modelData.thumb
                                    kind: "download"
                                    color: Theme.tDim(Sys.bg, Sys.text)
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.rMd
                                    color: "transparent"
                                    border.width: page.openDownloadFolder
                                                  === fcell.modelData.folder ? 2 : 0
                                    border.color: Sys.accent
                                }
                            }
                            Text {
                                anchors.top: fthumb.bottom
                                anchors.topMargin: 4
                                width: parent.width
                                text: (fcell.modelData.name || "")
                                      + " · " + (fcell.modelData.count || 0)
                                color: page.openDownloadFolder === fcell.modelData.folder
                                       ? Theme.accentOn(Sys.accent, Sys.bg) : Sys.text
                                font.pixelSize: Theme.tXs
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            MouseArea {
                                id: cellMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                // Long press = menu of the downloaded list
                                // (play / uninstall), which on desktop was
                                // the right click.
                                property bool menuHeld: false
                                onPressAndHold: {
                                    cellMa.menuHeld = true
                                    const p = mapToItem(null, mouseX, mouseY)
                                    page.downloadMenuRequested(
                                        String(fcell.modelData.folder || ""),
                                        String(fcell.modelData.name || ""),
                                        p.x, p.y)
                                }
                                onClicked: {
                                    if (cellMa.menuHeld) {
                                        cellMa.menuHeld = false
                                        return
                                    }
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    // Opens the downloaded list AS A PLAYLIST (its
                                    // own tracks view), without filtering.
                                    page.downloadOpenRequested(
                                        String(fcell.modelData.folder || ""))
                                }
                            }
                            // Uninstall this list (it deletes its files). It
                            // shows on mouse over the card; on touch it is
                            // always visible (there is no hover).
                            Rectangle {
                                width: Theme.touch ? 34 : 26
                                height: width
                                radius: width / 2
                                visible: cellMa.containsMouse || Theme.touch
                                color: delMa.containsMouse ? Sys.danger
                                                           : Qt.rgba(0, 0, 0, 0.55)
                                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                anchors.right: fthumb.right
                                anchors.top: fthumb.top
                                anchors.rightMargin: 4
                                anchors.topMargin: 4
                                Glyph {
                                    anchors.centerIn: parent
                                    width: 13
                                    height: 13
                                    kind: "trash"
                                    color: delMa.containsMouse ? Theme.onAccent(Sys.accent) : Sys.text
                                }
                                MouseArea {
                                    id: delMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (typeof sfx !== "undefined") sfx.play("tap")
                                        page.uninstallListRequested(
                                            String(fcell.modelData.folder || ""),
                                            String(fcell.modelData.name || ""))
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- LOCAL: downloads (virtualized list) -------------------
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: page.localSelected

                    ListView {
                        id: localList
                        anchors.fill: parent
                        clip: true
                        model: page.dlLocalAll
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
                                property bool menuHeld: false
                                onPressAndHold: {
                                    lrowMouse.menuHeld = true
                                    const p = mapToItem(null, mouseX, mouseY)
                                    page.trackContextRequested(modelData,
                                                               p.x, p.y)
                                }
                                onClicked: (mouse) => {
                                    if (lrowMouse.menuHeld) {
                                        lrowMouse.menuHeld = false
                                        return
                                    }
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    if (mouse.button === Qt.RightButton) {
                                        const p = mapToItem(null, mouse.x, mouse.y)
                                        page.trackContextRequested(modelData,
                                                                   p.x, p.y)
                                    } else {
                                        if (typeof sfx !== 'undefined') sfx.play('tap')
                                        page.playRequested(page.dlLocalAll, lrow.index)
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
                                    color: Theme.sAlt(Sys.bg, Sys.text)
                                    RoundedArt {
                                        anchors.fill: parent
                                        source: modelData.thumb || ""
                                        visible: String(modelData.thumb || "") !== ""
                                        radiusSpec: Theme.rSm
                                    }
                                    ActionIcon {
                                        anchors.centerIn: parent
                                        width: 15
                                        height: 15
                                        visible: !modelData.thumb
                                        kind: "download"
                                        color: Theme.tDim(Sys.bg, Sys.text)
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
                                        color: Theme.tDim(Sys.bg, Sys.text)
                                        font.pixelSize: Theme.tSm
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                }
                                // "Liked" in the downloads: the videoId comes from the
                                // .info.json, so it is marked and synced with
                                // YouTube Music.
                                LikeButton {
                                    id: dlRowLike
                                    Layout.alignment: Qt.AlignVCenter
                                    interactive: catalog.loginState === "ok"
                                                 && catalog.videoIdOf(
                                                        modelData.url) !== ""
                                    revealed: lrowMouse.containsMouse
                                    liked: {
                                        const rev = catalog.likedRevision
                                        return catalog.isLiked(modelData.url)
                                    }
                                    onToggled: catalog.toggleLiked(modelData.url,
                                                                    dlRowLike.liked)
                                }
                                Glyph {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: 13
                                    height: 13
                                    kind: "check"
                                    color: Theme.accentOn(Sys.accent, Sys.bg)
                                }
                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: Theme.mmss(modelData.duration)
                                    color: Theme.tDim(Sys.bg, Sys.text)
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
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }
                }

                // ---- Library: virtualized covers grid -----------------------
                GridView {
                    id: coversGrid
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !page.localSelected && page.covers.length > 0
                    clip: true
                    model: page.filteredCovers
                    reuseItems: true
                    cacheBuffer: 800
                    boundsBehavior: Flickable.StopAtBounds
                    flow: GridView.FlowLeftToRight
                    readonly property real tileW: page.gridTileW(width)
                    cellWidth: page.gridCellW(width)
                    cellHeight: tileW + 56

                    delegate: CoverTile {
                        required property int index
                        required property var modelData
                        width: GridView.view.cellWidth - page.coverGap
                        height: GridView.view.cellHeight

                        title: modelData.name || ""
                        // Sin contar pistas no se enseña la URL cruda
                        // (era ilegible y ocupaba dos lineas).
                        subtitle: (modelData.count || 0) > 0
                                  ? modelData.count + " pistas" : ""

                        thumb: modelData.thumb || ""
                        removable: (modelData.savedIndex || -1) >= 0
                        downloadable: !!modelData.url
                        // Tick on the cover if this list is already
                        // downloaded.
                        downloaded: page.isDownloaded(modelData)

                        // Click on the card -> OPEN the list.
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            page.openListRequested(false)
                            page.openCover(modelData)
                        }
                        // Click on the floating play button -> PLAY.
                        onPlayClicked: {
                            page.openListRequested(true)
                            page.openCover(modelData)
                        }
                        onDownloadRequested: {
                            if (typeof downloads !== "undefined")
                                downloads.downloadPlaylist(modelData.url || "",
                                                           modelData.name || "")
                        }
                        // Tick pressed: ask before deleting the files.
                        onUninstallRequested: {
                            const f = page.downloadedFolder(modelData)
                            if (f !== "")
                                page.uninstallListRequested(f, modelData.name || "")
                        }
                        onRemoveRequested: {
                            if ((modelData.savedIndex || -1) >= 0)
                                catalog.removePlaylist(modelData.savedIndex)
                        }
                        onContextRequested: (x, y) => page.coverContextRequested(modelData, x, y)
                    }
                }

                // ---- empty states -----------------------------------------
                Text {
                    Layout.fillWidth: true
                    visible: !page.localSelected && page.covers.length === 0
                    text: catalog.libraryBusy
                          ? "Cargando tu biblioteca…"
                          : "Biblioteca vacía. Inicia sesión en Ajustes o pega una URL arriba para añadir una lista."
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                }
            }
        }
    }

    // Fundido del borde inferior de la lista abierta: la ultima fila se
    // cortaba a hueso justo en la esquina redondeada de la tarjeta y
    // parecia que el contenido se salia del fondo. Se apaga hacia el
    // mismo tono del velo (0.95 de Sys.bg) para que la lista "termine"
    // suave en vez de con un tajo recto.
    Rectangle {
        z: 5
        visible: page.showingTracks
        height: Theme.s6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.panelMargin + Theme.s3
        anchors.rightMargin: Theme.panelMargin + Theme.s3
        anchors.bottomMargin: Theme.panelMargin + Theme.s3
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.alpha(Sys.bg, 0.0) }
            GradientStop { position: 1.0; color: Theme.alpha(Sys.bg, 0.97) }
        }
    }
}
