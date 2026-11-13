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
    // Play ALL the downloaded tracks: `random` = shuffle; `newestFirst` =
    // newest downloads first (by default, the order they were downloaded).
    signal downloadsPlayRequested(bool random, bool newestFirst)

    property bool showingTracks: false
    // Discography batch being queued (from Main): when several albums are
    // being prepared, Downloads shows them as ONE "Discography of X" group
    // instead of a flat list of loose album jobs.
    property string discArtist: ""
    property int discTotal: 0
    property int discDone: 0
    property var discTitles: []
    // Live downloads: everything that is not finished ("done") nor a
    // cancelled job. The section is called ACTIVE downloads: including
    // the finished ones made the badge lie ("44 en curso" with songs
    // already in the library) and pushed the rest off screen.
    readonly property var dlLive: {
        const out = []
        const js = page.dlJobs
        for (let i = 0; i < (js ? js.length : 0); ++i) {
            const st = String(js[i].state || "")
            if (st === "done")
                continue
            if (st === "error" && String(js[i].error || "") === "Cancelado")
                continue
            out.push(js[i])
        }
        return out
    }
    // Batch being prepared (albums still resolving their audio list).
    readonly property bool discPreparing: discTotal > 1 && discDone < discTotal
    // Downloads of the batch that are still alive.
    readonly property int discLive: {
        if (!discTitles || discTitles.length === 0)
            return 0
        let n = 0
        const js = page.dlLive
        for (let i = 0; i < js.length; ++i) {
            if (discTitles.indexOf(String(js[i].name || "")) >= 0)
                ++n
        }
        return n
    }
    // Shown while the batch is being prepared or while any of its records
    // is still downloading; it disappears when the whole discography is
    // done, so it never lingers as a stale card.
    readonly property bool discActive: discArtist !== ""
                                       && discTotal > 1
                                       && (discPreparing || discLive > 0)
    // Order of the Downloads page: false = the order the tracks were
    // downloaded, true = the newest first.
    property bool dlNewestFirst: false

    // A radio (RDAMVM/RDCLAK, "start_radio") is not a list with an
    // author: the header showed the artist of the FIRST track as the author
    // of the radio ("Radio de Calva Louise" -> "VIOLENT VIRA").
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

    // ---- library bar: search / create list -------------------------------
    property string libFilter: ""
    property bool addListOpen: false
    // Phone: the filter field takes the full width in its own row and only
    // appears when the magnifier is pressed (in the tab row it did not
    // fit: 200 dp of a 372 dp screen).
    property bool libSearchOpen: false

    // Covers filtered by the "Search in the library" box (name or URL).
    // The filter is local: it asks the network for nothing.
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
            catalog.openUrlArt(c.url || "", c.name || "", c.thumb || "")
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
        var out = qsTr("%n canción", "", n)
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

    // Cover of the open list: the artwork of the card it was opened from
    // (a radio's face is the artist photo, NOT the seed song's cover),
    // then the one from the YTM library, then the first track's.
    function currentCover() {
        const art = String(catalog.openListThumb || "")
        if (art.length > 0)
            return art
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

    // Second cover candidate for downloaded lists (the signed YouTube
    // one expires; the backend also sends the stable first-track one).
    function viewCoverAlt() {
        if (!page.localPlaylistOpen || !page.openDownloadInfo)
            return ""
        return String(page.openDownloadInfo.thumbFallback || "")
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
    // Columns like in the reference: smaller cards, closer together, with
    // the cover square, instead of four huge cards. At 1240 px wide that is
    // 6 columns of about 196 px (it was 5 of about 220).
    readonly property int coverGap: 12
    function gridCols(w) {
        w = Math.max(1, w)
        // Phone: 3 columns of ~120 dp. With the desktop 180 dp minimum the
        // phone only fitted 2 slabs of 186 dp (a gallery, not a library).
        const min = Theme.touch ? 112 : 180
        return Math.max(1, Math.floor(w / min))
    }
    // Exact cell width: the grid divides the width between the columns and
    // the card keeps the gap inside its own cell. It used to add the gap to
    // every cell, so the last column did not fit (at 1240 px you saw 5
    // columns instead of 6).
    function gridCellW(w) {
        w = Math.max(1, w)
        return Math.floor(w / gridCols(w))
    }
    function gridTileW(w) {
        return Math.max(1, gridCellW(w) - coverGap)
    }

    // ---- downloads (the `downloads` backend; it may not exist yet) -------
    readonly property var dlJobs: (typeof downloads !== "undefined") ? downloads.jobs : []
    // Downloaded folders grouped by what they are: a discography mixes
    // albums and singles, and a single ("Nobody") must not look like a
    // record or hide among the saved playlists.
    readonly property var dlAlbums: (page.dlFolders || []).filter(
        function (f) { return String(f.kind || "") === "album" })
    readonly property var dlSingles: (page.dlFolders || []).filter(
        function (f) { return String(f.kind || "") === "single" })
    readonly property var dlLists: (page.dlFolders || []).filter(
        function (f) { return String(f.kind || "") === "list" })
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
        return qsTr("%n canción descargada", "", n)
    }
    // Header chips: number of tracks and total length, apart (the reference
    // shows them as two pills).
    // Author of the list: the one of the first track (the header of the
    // reference shows it under the title, at 18 px).
    function viewArtistText() {
        if (page.localPlaylistOpen)
            return ""
        // A radio has no author of its own: the one of its first track is not it.
        if (page.viewIsRadio)
            return qsTr("Radio · YouTube Music")
        const t = page.viewTracks()
        return (t && t.length > 0) ? String(t[0].artist || "") : ""
    }
    // Year (when the tracks carry it): first chip of the header.
    function viewYearText() {
        const t = page.viewTracks()
        const y = (t && t.length > 0) ? t[0].year : 0
        return y ? String(y) : ""
    }

    function viewCountText() {
        const n = page.viewTracks().length
        return qsTr("%n canción", "", n)
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
            return qsTr("%1 h %2 min").arg(h).arg(m)
        return qsTr("%1 min %2 s").arg(m).arg(t % 60)
    }

    function viewFolder() {
        return page.localPlaylistOpen ? page.openDownloadFolder
                                      : String(page.dlOpenFolder || "")
    }

    // ---- "Search in the list" -------------------------------------------
    // The filter is only for the view: every row keeps its ORIGINAL index
    // (`_listIndex`) so pressing it plays the right track of the list, not
    // the one at the filtered position.
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
        antialiasing: true
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
            antialiasing: true
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
            text: qsTr("cargando…")
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
        antialiasing: true
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
    // ---- a downloaded list (one folder) ----------------------------------
    component FolderCard: Item {
        id: fcell
        required property var modelData
        width: 104
        height: 124

        // Hover of the whole card (it lives here, not in the MouseArea, so
        // the trash button showing up under the cursor does not steal it).
        HoverHandler { id: fcellHover }

        Rectangle {
            id: fthumb
            width: parent.width
            height: width
            radius: Theme.rMd
            antialiasing: true
            color: Theme.sAlt(Sys.bg, Sys.text)
            RoundedArt {
                anchors.fill: parent
                source: fcell.modelData.thumb || ""
                sources: [fcell.modelData.thumbFallback || ""]
                visible: String(fcell.modelData.thumb || "") !== ""
                         || String(fcell.modelData.thumbFallback || "") !== ""
                radiusSpec: Theme.rMd
            }
            Glyph {
                anchors.centerIn: parent
                width: 22
                height: 22
                visible: !fcell.modelData.thumb && !fcell.modelData.thumbFallback
                kind: "download"
                color: Theme.tDim(Sys.bg, Sys.text)
            }
            Rectangle {
                anchors.fill: parent
                radius: Theme.rMd
                antialiasing: true
                color: "transparent"
                border.width: page.openDownloadFolder === fcell.modelData.folder ? 2 : 0
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
            // Long press = menu of the downloaded list (play / uninstall),
            // which on desktop was the right click.
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
                page.downloadOpenRequested(String(fcell.modelData.folder || ""))
            }
        }
        // Uninstall this list (it deletes its files). It shows on mouse
        // over the card; on touch it is always visible (there is no hover).
        // It is always LAID OUT and only changes its opacity: toggling
        // `visible` made it flicker (when it appeared under the cursor it
        // stole the hover, hid itself, and so on in a loop).
        Rectangle {
            width: Theme.touch ? 34 : 26
            height: width
            radius: width / 2
            antialiasing: true
            opacity: (fcellHover.hovered || Theme.touch) ? 1 : 0
            enabled: opacity > 0.5
            Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
            color: delMa.containsMouse ? Sys.danger : Qt.rgba(0, 0, 0, 0.55)
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

    // A labelled strip of downloaded lists: the "apartado" of each kind.
    component FolderStrip: ColumnLayout {
        id: fgroup
        property var items: []
        property string title: ""
        // `active` is set by the page (is the Downloads tab selected?);
        // the component itself hides when its strip is empty.
        property bool active: true
        Layout.fillWidth: true
        visible: active && items.length > 0
        spacing: 2

        Text {
            Layout.fillWidth: true
            text: fgroup.title + "  " + fgroup.items.length
            color: Theme.tDim(Sys.bg, Sys.text)
            font.pixelSize: Theme.tXs
            font.weight: Font.DemiBold
            font.letterSpacing: 0.4
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 124
            clip: true

            ListView {
                anchors.fill: parent
                orientation: ListView.Horizontal
                spacing: Theme.s3
                model: fgroup.items
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                delegate: FolderCard { }
            }
        }
    }

    component JobRow: Rectangle {
        id: jrow
        required property var modelData
        required property int index
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.rowH
        radius: Theme.rLg
        antialiasing: true
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
                    text: jrow.modelData.name || qsTr("Descarga")
                    color: Sys.text
                    font.pixelSize: Theme.tMd
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
                Text {
                    text: {
                        const s = String(jrow.modelData.state || "")
                        if (s === "error") return qsTr("Error")
                        if (s === "done" || s === "finished" || s === "completed") return qsTr("Listo")
                        if (s === "queued" || s === "pending") return qsTr("En cola")
                        if (s === "paused") return qsTr("Pausado")
                        if (s === "canceled" || s === "cancelled") return qsTr("Cancelado")
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
                    antialiasing: true
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

            // Real reason of the failure ("Playlist does not exist", "Missing ffprobe"...)
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
                antialiasing: true
                color: Theme.mix(Sys.surface, Sys.text, 0.16)
                visible: String(jrow.modelData.state || "") !== "error"
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, (jrow.modelData.progress || 0) / 100))
                    height: parent.height
                    radius: 2
                    antialiasing: true
                    color: Sys.accent
                    Behavior on width { NumberAnimation { duration: Theme.fastMs } }
                }
            }
        }
    }

    // ---- blurred background of the open list ----------------------------
    // The cover of the list, enlarged and blurred behind the header and the
    // rows (reference). The gradient veil keeps the text readable and melts
    // into the background on the lower half.
    Item {
        anchors.fill: parent
        z: -1
        visible: page.showingTracks
        clip: true

        // REAL blur in C++ (rart plus the wash pipeline): the app runs on the
        // software backend, where `MultiEffect` draws nothing and the background
        // came out flat. RoundedArt takes care of the download, the cache and of
        // repainting when C++ finishes.
        //
        // It goes as a CARD, not edge to edge: same margins as the other panels
        // (Theme.panelMargin) and Theme.rXl radius, rounded in C++ (rart sets the
        // alpha; a `clip` on a Rectangle does not round the corners). The
        // rectangle that used to be the background reached square to the screen
        // edges and clashed with the islands.
        RoundedArt {
            id: listBgArt
            anchors.fill: parent
            anchors.margins: Theme.panelMargin
            source: page.viewCover()
            sources: [page.viewCoverAlt()]
            radiusSpec: Theme.rXl
            blur: 2
            // Faint: the artwork is a tint, not a light box. With 0.8 a
            // pale cover turned the whole card into a grey blob that
            // stood out against the page (and washed out the title).
            opacity: 0.55
        }
        // Veil: the blurred cover is often near-white (a pale artwork
        // lit up the whole list and the white title fell to ~3,4:1). The
        // scrim is denser at the top, where the header text sits, and
        // melts into the page at the bottom while still letting the
        // colours of the cover through.
        Rectangle {
            anchors.fill: listBgArt
            radius: Theme.rXl
            antialiasing: true
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.alpha(Sys.bg, 0.60) }
                GradientStop { position: 0.45; color: Theme.alpha(Sys.bg, 0.74) }
                GradientStop { position: 1.0; color: Theme.alpha(Sys.bg, 0.92) }
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
            // The background is a CARD with Theme.rXl corners: with no air inside,
            // the cover and the first row stepped on the corner arc and everything
            // looked shifted (the background was edge to edge before it became a
            // card).
            Layout.margins: Theme.s3

            // ---- list header (reference: Liner) -------------------------
            // Cover 168, title 30 bold, author 18 and the data pills. Under them, the
            // row of actions: Play all + shuffle on the left; search, add, download
            // and the menu on the right. 9 px radii and 32 high, as in the reference
            // (not 36 px pills).
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
                    antialiasing: true
                    color: Theme.alpha(Sys.text, 0.08)

                    RoundedArt {
                        id: heroCover
                        anchors.fill: parent
                        source: page.viewCover()
                        sources: [page.viewCoverAlt()]
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

                    // Data pills: year and the track count with the total length.
                    RowLayout {
                        Layout.topMargin: 12
                        spacing: 6

                        Rectangle {
                            Layout.preferredHeight: 26
                            implicitWidth: yearLabel.implicitWidth + 22
                            radius: Theme.rPill
                            antialiasing: true
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
                            antialiasing: true
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
                                    antialiasing: true
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

                // Play all: light pill (like the reference, which uses the primary
                // button of the theme: near white background and dark text), not the
                // accent colour.
                Rectangle {
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    implicitWidth: playAllRow.implicitWidth + 44
                    radius: Theme.rPill
                    antialiasing: true
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
                            text: qsTr("Reproducir todo")
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

                // Shuffle: 52 wide, same height and radius.
                Rectangle {
                    Layout.preferredWidth: Theme.touch ? 56 : 52
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    antialiasing: true
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

                // Download of the list (with its progress)
                Rectangle {
                    id: dlBtn
                    Layout.preferredWidth: Theme.touch ? 40 : 32
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    antialiasing: true
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
                        antialiasing: true
                        color: Theme.alpha(Sys.text, 0.20)
                        Rectangle {
                            height: parent.height
                            radius: 1
                            antialiasing: true
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
                                    String(catalog.tracksTitle || ""),
                                    "list")
                        }
                    }
                }

                // Uninstall (only when it is already downloaded)
                Rectangle {
                    Layout.preferredWidth: Theme.touch ? 40 : 32
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    antialiasing: true
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

                // Menu of the list (...)
                Rectangle {
                    Layout.preferredWidth: Theme.touch ? 40 : 32
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    antialiasing: true
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
            // ---- second row (phone only): search + add to queue ---
            // They do not fit in the row above (the search box alone takes
            // 220 dp out of the 372 usable).
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: Theme.touch
                // Search in the list: 220 x 32, radius 9 and a faint background.
                Rectangle {
                    // On the phone it takes all the width left over.
                    Layout.fillWidth: true
                    Layout.preferredWidth: 220
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    radius: Theme.rPill
                    antialiasing: true
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
                        text: qsTr("Buscar en la lista")
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: 14
                    }
                }

                Item { Layout.preferredWidth: 4 }

                // Add to queue
                Rectangle {
                    Layout.preferredHeight: Theme.touch ? 40 : 32
                    implicitWidth: qlRow.implicitWidth + 44
                    radius: Theme.rPill
                    antialiasing: true
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
                            text: qsTr("Añadir a la cola")
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

            // Track list: fixed height rows, reused while scrolling
            // (reuseItems + cacheBuffer) so they do not eat RAM. No card
            // around them: the rows sit over the blurred cover of the
            // list, as in the reference.
            ListView {
                id: tracksList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: page.listRows
                reuseItems: true
                cacheBuffer: 800
                spacing: 0
                // Room at the end so the last row comes out from under the
                // bottom edge of the card (before, it was cut and a black
                // gradient was painted over it: that band looked dirty).
                bottomMargin: Theme.s6
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
                            text: qsTr("Encolar")
                            color: Theme.accentOn(Sys.accent, Sys.bg)
                            font.pixelSize: Theme.tSm
                            font.weight: Font.DemiBold
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.rMd
                        antialiasing: true
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

                        // Track number (position in the list, not in the filter):
                        // as in the reference.
                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 24
                            // Number in two digits ("01"), as in the reference.
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
                            antialiasing: true
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

                        // Menu of the track (⋮), with the mouse too: on a phone
                        // there is no right click.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            radius: Theme.rXl
                            antialiasing: true
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

            // Empty list because of the filter: say so instead of leaving it
            // blank. (It sits inside an Item because Island puts its children in
            // a ColumnLayout, where anchoring does not work.)
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: (page.listFilter !== ""
                                         && page.listRows.length === 0) ? 72 : 0
                Text {
                    anchors.centerIn: parent
                    visible: page.listFilter !== ""
                             && page.listRows.length === 0
                    text: qsTr("Ninguna pista coincide con «%1»").arg(page.listFilter)
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
                    { t: 0, name: qsTr("Biblioteca") },
                    { t: 4, name: qsTr("Descargadas") }
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
                        antialiasing: true
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

                // Search in the library (filters the cards as you type). On an
                // old phone, a magnifier that opens the field on its own row:
                // it does not fit here (200 dp out of 372).
                Rectangle {
                    visible: !Theme.touch
                    Layout.preferredWidth: 200
                    Layout.preferredHeight: Theme.pillH
                    radius: Theme.rPill
                    antialiasing: true
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
                        text: qsTr("Buscar en la biblioteca")
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                    }
                }

                // Phone: the magnifier opens the filter on its own row (the 200
                // dp field does not fit in this one).
                Rectangle {
                    visible: Theme.touch
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    radius: Theme.rPill
                    antialiasing: true
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

                // Create / add a list by URL: the form unfolds from here
                // instead of taking room all the time.
                Rectangle {
                    Layout.preferredHeight: Theme.touch ? 40 : Theme.pillH
                    implicitWidth: Math.max(Theme.touch ? 40 : 0,
                                            createRow.implicitWidth + Theme.s4)
                    radius: Theme.rPill
                    antialiasing: true
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
                            text: qsTr("Crear lista")
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

            // ---- library filter (phone only) --------------------
            // It unfolds from the magnifier and takes the full width.
            RowLayout {
                Layout.fillWidth: true
                visible: Theme.touch && page.libSearchOpen
                spacing: Theme.s2

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    radius: Theme.rPill
                    antialiasing: true
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
                        text: qsTr("Buscar en la biblioteca")
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
                        antialiasing: true
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
                    antialiasing: true
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
                        text: qsTr("Nombre (opcional)")
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                    }
                }

                Rectangle {
                    id: urlField
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.rowThin
                    radius: Theme.rPill
                    antialiasing: true
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
                        text: qsTr("URL de la playlist (YouTube / SoundCloud)")
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
                    antialiasing: true
                    color: addMa.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                    scale: addMa.pressed ? 0.96 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Theme.s1
                        Glyph { width: 14; height: 14; kind: "plus"; color: Theme.onAccent(Sys.accent) }
                        Text {
                            text: qsTr("Añadir")
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
                    // The form folds back when it is done: the library looks
                    // clean again.
                    page.addListOpen = false
                }
            }
            }

            // 3) active downloads (visible from any source)
            Island {
                Layout.fillWidth: true
                // Visible while there is something to show: live jobs or
                // a discography that is still being prepared.
                visible: page.dlLive.length > 0 || page.discActive
                spacing: Theme.s2

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.s2

                // Discography: one artist, N records. It is shown as a
                // single group with the artist's name and the overall
                // progress, so a 28-record batch reads as a real
                // "download the artist" and not as 28 loose jobs.
                Island {
                    Layout.fillWidth: true
                    visible: page.discActive
                    pad: Theme.s3

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.s3

                        Rectangle {
                            Layout.preferredWidth: 34
                            Layout.preferredHeight: 34
                            radius: Theme.rPill
                            antialiasing: true
                            color: Theme.alpha(Sys.accent, 0.18)
                            Glyph {
                                anchors.centerIn: parent
                                width: 17
                                height: 17
                                kind: "download"
                                color: Theme.accentOn(Sys.accent, Sys.bg)
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                Layout.fillWidth: true
                                text: qsTr("Discografía de %1").arg(page.discArtist)
                                color: Sys.text
                                font.pixelSize: Theme.tMd
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            Text {
                                Layout.fillWidth: true
                                text: page.discPreparing
                                      ? qsTr("%1 de %2 discos preparados · descargando en orden")
                                            .arg(page.discDone).arg(page.discTotal)
                                      : qsTr("%1 de %2 discos en cola de descarga")
                                            .arg(page.discLive).arg(page.discTotal)
                                color: Theme.tDim(Sys.bg, Sys.text)
                                font.pixelSize: Theme.tXs
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }
                    }
                }

                SectionHeader {
                    title: qsTr("DESCARGAS ACTIVAS")
                    badge: qsTr("%1 en curso").arg(page.dlLive.length)
                }

                // Capped and scrollable: a discography queues dozens of
                // jobs and, without its own scroll, everything below it
                // (the lists, the songs) was pushed off screen.
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(
                        page.dlLive.length * (Theme.rowH + Theme.s2) - Theme.s2,
                        5 * (Theme.rowH + Theme.s2) - Theme.s2)
                    visible: page.dlLive.length > 0

                    ListView {
                        id: jobsList
                        anchors.fill: parent
                        model: page.dlLive
                        spacing: Theme.s2
                        clip: true
                        reuseItems: true
                        cacheBuffer: 400
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: JobRow {
                            // In a ListView the Layout attached
                            // properties are ignored: without an explicit
                            // height every row collapsed and all the
                            // titles were drawn on top of each other.
                            width: jobsList.width
                            height: Theme.rowH
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2

                    Rectangle {
                        Layout.preferredWidth: 138
                        Layout.preferredHeight: 32
                        radius: Theme.rMd
                        antialiasing: true
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
                                text: qsTr("Abrir carpeta")
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
                        antialiasing: true
                        color: pauseAllMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s1
                            ActionIcon { width: 13; height: 13; kind: "pause"
                                         color: Theme.tDim(Sys.bg, Sys.text) }
                            Text {
                                text: qsTr("Pausar")
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
                        antialiasing: true
                        color: resumeAllMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s1
                            ActionIcon { width: 13; height: 13; kind: "play"
                                         color: Theme.accentOn(Sys.accent, Sys.bg) }
                            Text {
                                text: qsTr("Reanudar")
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
                        antialiasing: true
                        color: cancelMa.containsMouse
                               ? Theme.alpha(Sys.danger, 0.12)
                               : "transparent"
                        border.width: 0
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Text {
                            anchors.centerIn: parent
                            text: qsTr("Cancelar todo")
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
                    title: page.localSelected ? qsTr("Descargadas") : qsTr("Biblioteca")
                    badge: page.localSelected
                           ? (page.dlLocalAll.length > 0 ? qsTr("%1 pistas").arg(page.dlLocalAll.length) : "")
                           : (page.covers.length === 0 ? ""
                                                       : qsTr("%1 listas").arg(page.covers.length))
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

                // Play all / Shuffle go ABOVE the strips: the action
                // comes before the content, not after it (same order as
                // the artist page).
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: page.localSelected
                    spacing: Theme.s3

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.s1
                        spacing: Theme.s2
                        visible: page.dlLocalAll.length > 0

                        // Play all, in download order.
                        Rectangle {
                            Layout.preferredWidth: dlPlayRow.implicitWidth + Theme.s5 * 2
                            Layout.preferredHeight: Theme.touch ? 42 : 40
                            radius: Theme.rPill
                            antialiasing: true
                            color: dlPlayMa.containsMouse || dlPlayMa.pressed
                                   ? Qt.darker(Sys.accent, 1.12) : Sys.accent
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            RowLayout {
                                id: dlPlayRow
                                anchors.centerIn: parent
                                spacing: Theme.s2
                                Glyph { width: 15; height: 15; kind: "play"; color: Sys.bg }
                                Text {
                                    text: qsTr("Reproducir todo")
                                    color: Sys.bg
                                    font.pixelSize: Theme.tMd
                                    font.weight: Font.DemiBold
                                }
                            }
                            MouseArea {
                                id: dlPlayMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    page.downloadsPlayRequested(false, page.dlNewestFirst)
                                }
                            }
                        }

                        // Shuffle everything.
                        Rectangle {
                            Layout.preferredWidth: dlShuffleRow.implicitWidth + Theme.pillHPad * 2 + 22
                            Layout.preferredHeight: Theme.touch ? 42 : 40
                            radius: Theme.rPill
                            antialiasing: true
                            color: dlShuffleMa.containsMouse
                                   ? Theme.sAlt(Sys.bg, Sys.text) : "transparent"
                            border.width: 1
                            border.color: Theme.alpha(Sys.text, 0.28)
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            RowLayout {
                                id: dlShuffleRow
                                anchors.centerIn: parent
                                spacing: Theme.s2
                                Glyph { width: 15; height: 15; kind: "shuffle"; color: Sys.text }
                                Text {
                                    text: qsTr("Aleatorio")
                                    color: Sys.text
                                    font.pixelSize: Theme.tMd
                                }
                            }
                            MouseArea {
                                id: dlShuffleMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    page.downloadsPlayRequested(true, page.dlNewestFirst)
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Download order: the order the files arrived in.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            visible: !Theme.touch && page.width > 560
                            Layout.preferredWidth: dlOrderLabel.implicitWidth + Theme.pillHPad * 2 + 16
                            Layout.preferredHeight: Theme.pillH
                            radius: Theme.rPill
                            antialiasing: true
                            color: dlOrderMa.containsMouse
                                   ? Theme.sAlt(Sys.bg, Sys.text) : "transparent"
                            border.width: 1
                            border.color: Theme.alpha(Sys.text, 0.18)
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            RowLayout {
                                anchors.centerIn: parent
                                spacing: Theme.s1
                                Glyph {
                                    width: 13
                                    height: 13
                                    kind: page.dlNewestFirst ? "arrow-down" : "arrow-up"
                                    color: Theme.tDim(Sys.bg, Sys.text)
                                }
                                Text {
                                    id: dlOrderLabel
                                    text: page.dlNewestFirst ? qsTr("Más recientes primero")
                                                             : qsTr("En orden de descarga")
                                    color: Theme.tDim(Sys.bg, Sys.text)
                                    font.pixelSize: Theme.tSm
                                }
                            }
                            MouseArea {
                                id: dlOrderMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    page.dlNewestFirst = !page.dlNewestFirst
                                }
                            }
                        }
                    }

                    // Phone: the order chip does not fit next to the two
                    // buttons, so it goes on its own line.
                    Rectangle {
                        visible: Theme.touch && page.dlLocalAll.length > 0
                        Layout.preferredWidth: dlOrderLabel2.implicitWidth + Theme.pillHPad * 2 + 16
                        Layout.preferredHeight: Theme.pillH
                        Layout.alignment: Qt.AlignLeft
                        radius: Theme.rPill
                        antialiasing: true
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.alpha(Sys.text, 0.18)
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s1
                            Glyph {
                                width: 13
                                height: 13
                                kind: page.dlNewestFirst ? "arrow-down" : "arrow-up"
                                color: Theme.tDim(Sys.bg, Sys.text)
                            }
                            Text {
                                id: dlOrderLabel2
                                text: page.dlNewestFirst ? qsTr("Más recientes primero")
                                                         : qsTr("En orden de descarga")
                                color: Theme.tDim(Sys.bg, Sys.text)
                                font.pixelSize: Theme.tSm
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.dlNewestFirst = !page.dlNewestFirst
                            }
                        }
                    }

                }

                // ---- Downloaded lists, grouped by kind -------------------
                // A discography mixes albums and singles: each kind gets its
                // own strip so "Nobody" does not appear as a record.
                FolderStrip {
                    active: page.localSelected
                    title: qsTr("ÁLBUMES")
                    items: page.dlAlbums
                }
                FolderStrip {
                    active: page.localSelected
                    title: qsTr("SINGLES Y EPS")
                    items: page.dlSingles
                }
                FolderStrip {
                    active: page.localSelected
                    title: qsTr("LISTAS")
                    items: page.dlLists
                }

                // If there is nothing downloaded yet, say it.
                Text {
                    Layout.fillWidth: true
                    visible: page.localSelected && page.dlFolders.length === 0
                    text: qsTr("Aún no hay nada descargado.")
                    color: Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                }

                // ---- LOCAL: downloads -------------------------------------
                // Text hints under the strips (the actions live above
                // them). Opening a list shows its tracks; a single song is
                // found with the search.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: page.localSelected
                    spacing: Theme.s3

                    // Hint: the lists above open with their tracks.
                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.s1
                        visible: page.dlLocalAll.length > 0
                        text: qsTr("Todo lo descargado, en el orden en que llegó. Abre una lista para ver sus pistas.")
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: page.dlLocalAll.length === 0 && !page.dlLocalBusy
                        text: qsTr("Sin descargas locales. Usa el botón de descarga de una playlist o pista.")
                        color: Theme.tDim(Sys.bg, Sys.text)
                        font.pixelSize: Theme.tSm
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
                        // With no track count the raw URL is not shown (it was
                        // unreadable and took two lines).
                        subtitle: (modelData.count || 0) > 0
                                  ? qsTr("%1 pistas").arg(modelData.count) : ""

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
                                                           modelData.name || "",
                                                           "list")
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
                    // When the fetch failed the reason wins over the generic
                    // "empty library": "empty" and "did not arrive" look the
                    // same on screen and mean different things.
                    text: catalog.libraryBusy
                          ? qsTr("Cargando tu biblioteca…")
                          : (catalog.libraryError !== ""
                             ? catalog.libraryError
                             : qsTr("Biblioteca vacía. Inicia sesión en Ajustes o pega una URL arriba para añadir una lista."))
                    color: (!catalog.libraryBusy && catalog.libraryError !== "")
                           ? Theme.accentOn(Sys.accent, Sys.bg)
                           : Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tSm
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                }
            }
        }
    }

}
