import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Biblioteca: muestra TODO lo guardado junto (la biblioteca de YouTube Music +
// todas las playlists guardadas, sin filtrar por fuente) en una rejilla de
// covers; las descargas locales viven aparte, en la pestaña «Descargadas».
// Al pulsar una cover se ABRE su lista (openListRequested +
// catalog.openPlaylist/openUrl) y sólo el botón de play flotante que aparece al
// pasar el ratón la REPRODUCE. Al pulsar una LISTA DESCARGADA se abre como una
// playlist de verdad (su propia vista de pistas), sin filtrar la lista plana.
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
    // Pide desinstalar una lista descargada (borra su carpeta).
    signal uninstallListRequested(string folder, string name)
    // Menú (⋮) de una lista DESCARGADA abierta como playlist.
    signal downloadMenuRequested(string folder, string name, real x, real y)
    // Pide abrir una lista DESCARGADA como playlist (registra el paso atrás).
    signal downloadOpenRequested(string folder)

    property bool showingTracks: false

    function openTracks() { showingTracks = true; openDownloadFolder = "" }
    function showPlaylists() { showingTracks = false; openDownloadFolder = "" }

    // Pestaña activa de la biblioteca (0 Canciones · 1 Artistas · 2 Álbumes ·
    // 3 Playlists · 4 Descargadas). Estado puramente visual de la página.
    property int libraryTab: 0
    // La Biblioteca ya no filtra por fuente: muestra TODO junto (la biblioteca
    // de YouTube Music + todas las playlists guardadas). Las descargas locales
    // van aparte, en la pestaña "Descargadas".
    readonly property bool localSelected: libraryTab === 4

    // Covers (listas) de la biblioteca: TODO junto, sin filtrar por fuente.
    // savedIndex >= 0 → playlist guardada en `catalog` (se abre con
    // openPlaylist); -1 → lista de la biblioteca de YTM o URL directa.
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

    // ¿Se puede descargar la lista abierta? (URL http real; incluye listas que
    // no son del usuario.)
    function canDownloadTracks() {
        return String(catalog.openListUrl || "").indexOf("http") === 0
    }

    // URL de la lista abierta, sirva del catálogo o de una lista ya descargada
    // (en ese caso la guardada en sus metadatos). Vacía si no se puede bajar.
    function viewListUrl() {
        if (page.localPlaylistOpen)
            return page.openDownloadInfo
                   ? String(page.openDownloadInfo.url || "") : ""
        return String(catalog.openListUrl || "")
    }

    // ¿La lista abierta se puede (re)descargar? (tiene URL http real)
    readonly property bool viewDownloadable: page.viewListUrl().indexOf("http") === 0

    // Job de descarga de la lista abierta (el más reciente con su misma URL),
    // sirva del catálogo o de una lista descargada. Null si no hay ninguno.
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
                found = js[i]   // gana el último (el más reciente)
        return found
    }

    // Job de descarga de la lista abierta (el más reciente con su misma URL),
    // para dar feedback de progreso DENTRO de la propia vista de la lista.
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
                found = js[i]   // gana el último (el más reciente)
        }
        return found
    }

    // Carpeta de descarga instalada que corresponde a la lista abierta
    // (por URL de los metadatos o, de respaldo, por nombre sanitizado).
    // Vacía si la lista no está descargada.
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
    // Menú (⋮) de la lista abierta: reutiliza el menú de covers con los datos
    // de la lista en curso.
    function openHeaderMenu(x, y) {
        // Lista descargada abierta: menú propio (reproducir / desinstalar).
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
    // Listas descargadas (una carpeta = una lista) y pistas sueltas.
    readonly property var dlFolders: (typeof downloads !== "undefined") ? downloads.folders : []
    readonly property var dlLocalAll: (typeof downloads !== "undefined") ? downloads.local : []
    readonly property bool dlLocalBusy: (typeof downloads !== "undefined") ? downloads.localBusy : false

    // ---- feedback de errores de descarga --------------------------------
    // Último motivo de fallo publicado por el backend (`downloadError`), con el
    // nombre de la lista, para mostrarlo como aviso legible dentro de la página.
    property string lastDownloadError: ""
    property string lastErrorName: ""

    Connections {
        target: (typeof downloads !== "undefined") ? downloads : null
        function onDownloadError(name, message) {
            page.lastErrorName = String(name || "")
            page.lastDownloadError = String(message || "")
        }
        // Al completarse (o reintentarse) la misma lista, se retira el aviso.
        function onDownloadCompleted(name) {
            if (String(name || "") === page.lastErrorName)
                page.lastDownloadError = ""
        }
    }

    // ---- lista descargada abierta COMO PLAYLIST --------------------------
    // Al pulsar una lista descargada se abre como una playlist de verdad (vista
    // de pistas con su cabecera), en lugar de filtrar la lista plana de
    // canciones de Descargas.
    property string openDownloadFolder: ""     // carpeta abierta ("" = ninguna)
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
    // ¿La vista de pistas muestra una lista descargada (y no el catálogo)?
    readonly property bool localPlaylistOpen: page.showingTracks
                                              && page.openDownloadFolder !== ""

    // Abre una lista descargada como playlist (vista de pistas).
    function openDownloadPlaylist(folder) {
        const f = String(folder || "")
        if (f === "")
            return
        page.openDownloadFolder = f
        page.showingTracks = true
    }

    // ---- fuente de la vista de pistas (catálogo o lista descargada) ------
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
    function viewFolder() {
        return page.localPlaylistOpen ? page.openDownloadFolder
                                      : String(page.dlOpenFolder || "")
    }

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

    // ---- isla flotante de sección ---------------------------------------
    // Superficie redondeada con un filo luminoso muy tenue y un ColumnLayout
    // interior. El aire (pad) y el hueco (spacing) marcan la jerarquía; el alto
    // lo fija el contenido salvo que la isla rellene (Layout.fillHeight).
    // Sin sombras ni efectos: en un fondo tan oscuro el borde claro es lo que
    // realmente despega la isla del fondo.
    component Island: Rectangle {
        id: island

        property real pad: Theme.s4
        property alias spacing: inner.spacing

        implicitHeight: inner.implicitHeight + island.pad * 2
        radius: Theme.rPanel
        color: Sys.surface
        border.width: 1
        border.color: Theme.alpha(Sys.text, Theme.panelBorderAlpha)

        default property alias content: inner.data

        ColumnLayout {
            id: inner
            anchors.fill: parent
            anchors.margins: island.pad
            spacing: Theme.s3
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
                        return Math.round(jrow.modelData.progress || 0) + "%"
                    }
                    color: String(jrow.modelData.state || "") === "error" ? Sys.danger : Sys.textDim
                    font.pixelSize: Theme.tSm
                    font.weight: Font.Medium
                }
            }

            // Motivo real del fallo ("Playlist does not exist", "Falta ffprobe"…)
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

    // ---- panel de fuente bloqueada ---------------------------------------
    // ====================================================================
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.panelMargin
        spacing: Theme.panelGap

        // ---- vista de pistas de la playlist abierta ----------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: page.showingTracks
            spacing: Theme.panelGap

            // Cabecera hero de la lista, en isla flotante.
            Island {
                Layout.fillWidth: true
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
                        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.showPlaylists() }
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
                        source: page.viewCover()
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
                        text: page.localPlaylistOpen ? "DESCARGADA" : "LISTA"
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        font.letterSpacing: 1.2
                        font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.fillWidth: true
                        text: page.viewTitle()
                        color: Sys.text
                        font.pixelSize: Theme.t2xl
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    }
                    Text {
                        Layout.fillWidth: true
                        text: page.viewMeta()
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
                                onClicked: { if (typeof sfx !== "undefined") sfx.play("play"); page.playRequested(page.viewTracks(), 0) }
                            }
                        }

                        // Descargar la lista (funciona también con listas que no
                        // son del usuario: usa la URL real de la lista abierta).
                        // Muestra el progreso 0-100 % de TODA la lista mientras
                        // descarga, y un check al terminar.
                        Rectangle {
                            id: dlBtn
                            Layout.preferredWidth: 38
                            Layout.preferredHeight: 38
                            radius: Theme.rMd
                            visible: !page.localPlaylistOpen && page.canDownloadTracks()
                            color: dlMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                            border.width: 0
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            readonly property var job: page.dlTracksJob
                            readonly property string jstate: job !== null ? String(job.state || "") : ""
                            readonly property bool downloading: jstate === "downloading"
                            readonly property bool failed: jstate === "error"
                            // "Instalada" se basa en el disco (persiste entre
                            // reinicios), no en el job en memoria.
                            readonly property bool installed: page.dlOpenFolder !== ""
                            readonly property real frac: job !== null
                                ? Math.max(0, Math.min(1, (job.progress || 0) / 100)) : 0

                            Glyph {
                                anchors.centerIn: parent
                                width: 16
                                height: 16
                                visible: !dlBtn.downloading
                                kind: dlBtn.installed ? "check" : "download"
                                color: dlBtn.failed ? Sys.danger
                                       : ((dlBtn.installed || dlMa.containsMouse) ? Sys.accent : Sys.textDim)
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: dlBtn.downloading
                                text: Math.round(dlBtn.job ? (dlBtn.job.progress || 0) : 0) + "%"
                                color: Sys.accent
                                font.pixelSize: Theme.tXs
                                font.weight: Font.DemiBold
                            }
                            // Barra de progreso fina bajo el botón.
                            Rectangle {
                                visible: dlBtn.downloading || dlBtn.installed || dlBtn.failed
                                x: 5
                                y: parent.height - 6
                                width: parent.width - 10
                                height: 2
                                radius: 1
                                color: Theme.mix(Sys.surface, Sys.text, 0.20)
                                Rectangle {
                                    height: parent.height
                                    radius: 1
                                    color: dlBtn.failed ? Sys.danger : Sys.accent
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
                                    // Si ya está instalada, el botón desinstala;
                                    // si no, descarga toda la lista.
                                    if (dlBtn.installed)
                                        page.uninstallListRequested(dlBtn.installed ? page.dlOpenFolder : "",
                                                                    String(catalog.tracksTitle || ""))
                                    else if (typeof downloads !== "undefined")
                                        downloads.downloadPlaylist(
                                            String(catalog.openListUrl || ""),
                                            String(catalog.tracksTitle || ""))
                                }
                            }
                        }

                        // Botón de desinstalar (sólo cuando la lista está ya
                        // instalada; el tick va en el propio botón de descarga).
                        // En una lista DESCARGADA abierta como playlist, el
                        // botón de descarga no aplica: se muestra la papelera.
                        RowLayout {
                            spacing: Theme.s1
                            visible: page.localPlaylistOpen
                                     || (dlBtn.installed && !dlBtn.downloading)
                            Rectangle {
                                Layout.preferredWidth: 26
                                Layout.preferredHeight: 26
                                radius: Theme.rSm
                                color: unMa.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                                Glyph {
                                    anchors.centerIn: parent
                                    width: 14
                                    height: 14
                                    kind: "trash"
                                    color: unMa.containsMouse ? Sys.danger : Sys.textDim
                                }
                                MouseArea {
                                    id: unMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (typeof sfx !== "undefined") sfx.play("tap")
                                        page.uninstallListRequested(page.viewFolder(),
                                                                    page.viewTitle())
                                    }
                                }
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
                                onClicked: { if (typeof sfx !== "undefined") sfx.play("toggle"); page.shuffleListRequested() }
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

                        // Estado de la descarga en curso (dentro de la propia
                        // vista de la lista), alineado a la derecha.
                        Text {
                            visible: dlBtn.downloading
                            text: "Descargando " + Math.round(page.dlTracksJob ? (page.dlTracksJob.progress || 0) : 0) + "%"
                            color: Sys.accent
                            font.pixelSize: Theme.tSm
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                    }
                }
            }
            }

            // Lista virtualizada, en isla flotante: filas de altura fija,
            // reutilizadas al hacer scroll (reuseItems + cacheBuffer) para
            // mantener la RAM baja.
            Island {
                Layout.fillWidth: true
                Layout.fillHeight: true
                pad: Theme.s2

            ListView {
                id: tracksList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: page.viewTracks()
                reuseItems: true
                cacheBuffer: 800
                spacing: 0
                boundsBehavior: Flickable.StopAtBounds
                // Lista abierta: cuece ya sus primeras pistas para que el clic
                // en la cabecera suene al instante.
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
                                page.playRequested(page.viewTracks(), trow.index)
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

                        // Corazón: "me gusta" desde la propia biblioteca y desde
                        // "Local / Descargas" (las pistas locales resuelven su
                        // videoId por el .info.json y sincronizan con YT Music).
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
                            color: Sys.textDim
                            font.pixelSize: Theme.tSm
                        }
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

            // 0) pestañas de sección: DOS píldoras (Biblioteca / Descargadas).
            //    La activa se rellena con un tinte de acento y un filo claro.
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
                               : (tabMa.containsMouse ? Theme.hover(Sys.surfaceAlt)
                                                      : Sys.surfaceAlt)
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
                                color: Sys.accent
                            }
                            Text {
                                id: tabLabel
                                text: tabItem.modelData.name
                                color: tabItem.on ? Sys.accent : Sys.textDim
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
            }

            // Aviso legible del último fallo de descarga (señal downloadError).
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
                        color: errCloseMa.containsMouse ? Theme.hover(Sys.surfaceAlt)
                                                        : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 13
                            height: 13
                            kind: "x"
                            color: errCloseMa.containsMouse ? Sys.text : Sys.textDim
                        }
                        MouseArea {
                            id: errCloseMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { page.lastDownloadError = ""; page.lastErrorName = "" }
                        }
                    }
                }
            }

            // 2) añadir playlist por URL (isla flotante con píldoras)
            Island {
                Layout.fillWidth: true
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
                    radius: Theme.rPill
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
                    radius: Theme.rPill
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
                        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); addPlaylist() }
                    }
                }

                function addPlaylist() {
                    catalog.addPlaylist(nameInput.text, urlInput.text)
                    urlInput.text = ""
                }
            }
            }

            // 3) descargas activas (visibles desde cualquier fuente)
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
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); if (typeof downloads !== "undefined") downloads.openFolder() }
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
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); if (typeof downloads !== "undefined") downloads.cancelAll() }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
            }
            }

            // 4) contenido de la biblioteca (o de las descargas)
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

                    IconButton { // refrescar
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

                // ---- Listas descargadas (una carpeta = una lista) --------
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
                                color: Sys.surfaceAlt
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    source: fcell.modelData.thumb || ""
                                    visible: source !== ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: true
                                    sourceSize.width: 256
                                    sourceSize.height: 168
                                }
                                Glyph {
                                    anchors.centerIn: parent
                                    width: 22
                                    height: 22
                                    visible: !fcell.modelData.thumb
                                    kind: "download"
                                    color: Sys.textDim
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
                                       ? Sys.accent : Sys.text
                                font.pixelSize: Theme.tXs
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            MouseArea {
                                id: cellMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    // Abre la lista descargada COMO PLAYLIST (su
                                    // propia vista de pistas), sin filtrar.
                                    page.downloadOpenRequested(
                                        String(fcell.modelData.folder || ""))
                                }
                            }
                            // Desinstalar esta lista (borra sus archivos). Se
                            // muestra al pasar el ratón por encima de la tarjeta.
                            Rectangle {
                                width: 26
                                height: 26
                                radius: 13
                                visible: cellMa.containsMouse
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
                                    color: delMa.containsMouse ? Sys.onAccent : Sys.text
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

                // ---- LOCAL: descargas (lista virtualizada) ----------------
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
                                onClicked: (mouse) => {
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
                                // "Me gusta" en las descargas: el videoId sale del
                                // .info.json, así se marca y sincroniza con YT Music.
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

                // ---- Biblioteca: rejilla de covers virtualizada -----------
                GridView {
                    id: coversGrid
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !page.localSelected && page.covers.length > 0
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
                    visible: !page.localSelected && page.covers.length === 0
                    text: catalog.libraryBusy
                          ? "Cargando tu biblioteca…"
                          : "Biblioteca vacía. Inicia sesión en Ajustes o pega una URL arriba para añadir una lista."
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                }
            }
        }
    }
}
