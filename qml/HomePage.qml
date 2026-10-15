import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Inicio: saludo en una línea, atajo discreto a Descargas y carriles
// horizontales de tarjetas de tamaño fijo. Cada carril es un ListView con
// reuseItems: recicla delegados y la retícula nunca salta al pasar el ratón.
//
// Comportamiento de clic en las tarjetas:
//   · clic en la PORTADA -> ABRE la lista (vista de pistas), sin reproducir.
//   · botón de play      -> carga la lista y la REPRODUCE (sin salir de Inicio).
//   · fila de «Reciente» -> un clic ya suena (no tiene botón aparte).
Item {
    id: page

    signal playRequested(var list, int index)
    signal navigateRequested(string page)
    signal openSettingsRequested()
    signal openLauncherRequested()
    // Pide abrir una lista del catálogo. `play` = reproducirla en cuanto
    // llegue; sin reproducir, Main sólo la muestra (nunca auto-reproduce).
    signal openListRequested(bool play)
    // Re-ejecuta una búsqueda del historial: Main abre Buscar y lanza la query.
    signal searchRequested(string query)

    // Altura fija de cada carril de tarjetas (portada 172 + texto 54).
    readonly property int rowHeight: 230
    readonly property int cardSpacing: 14

    // ---- Reciente (deck estilo Sonora) ----------------------------------
    // Rejilla paginada de filas compactas. Es un «RECIENTE» combinado de TODAS
    // las fuentes: las canciones SUELTAS escuchadas (se excluyen las que
    // sonaron dentro de una playlist) y las 5 listas más recientes.
    property int picksPage: 0
    readonly property int picksPerPage: 15
    readonly property int picksCols: 3
    readonly property int picksRows: 5

    // Canciones sueltas recientes (catalog.recent, más nueva primero). Se
    // excluyen las que sonaron dentro de una playlist (`setId`) y las antiguas
    // sin clasificar (`legacy`).
    function recentTracks() {
        const out = []
        const rec = catalog.recent
        for (var i = 0; i < rec.length && out.length < 30; i++) {
            const t = rec[i]
            if (!t || !t.url || t.setId || t.legacy)
                continue
            out.push({ kind: "track", title: t.title || "",
                       sub: t.artist || "", thumb: t.thumb || "",
                       url: t.url, source: t.source || "" })
        }
        return out
    }

    // Hasta `limit` listas, más recientes primero. Se combinan TODAS las
    // fuentes: las listas guardadas por el usuario y las de YouTube Music.
    function recentLists(limit) {
        const out = []
        const seen = {}
        function push(url, name, thumb, count, source) {
            if (!url || seen[url])
                return
            seen[url] = true
            const sname = source ? page.srcName(source) : ""
            var sub = sname
            if (count)
                sub += (sub ? " · " : "") + count + " pistas"
            out.push({ kind: "playlist", title: name || "", sub: sub,
                       thumb: thumb || "", url: url, source: source || "" })
        }
        const pls = catalog.playlists
        for (var i = 0; i < pls.length; i++)
            push(pls[i].url, pls[i].name, pls[i].thumb, pls[i].count, pls[i].source)
        const lib = catalog.ytmLibrary
        for (var j = 0; j < lib.length; j++)
            push(lib[j].url, lib[j].name, lib[j].thumb, lib[j].count, "ytm")
        return out.slice(0, limit)
    }

    function quickPicks() {
        const out = []
        const tracks = page.recentTracks()
        for (var i = 0; i < tracks.length; i++)
            out.push(tracks[i])
        const lists = page.recentLists(5)
        for (var j = 0; j < lists.length; j++)
            out.push(lists[j])
        return out
    }

    readonly property int picksTotal: page.quickPicks().length
    readonly property int picksPages: Math.max(1, Math.ceil(page.picksTotal / page.picksPerPage))
    function picksPageItems() {
        const all = page.quickPicks()
        return all.slice(page.picksPage * page.picksPerPage,
                         page.picksPage * page.picksPerPage + page.picksPerPage)
    }

    function openQuickPick(item, play) {
        if (!item)
            return
        if (item.kind === "liked") {
            if (!page.ytmOk) {
                page.openSettingsRequested()
                return
            }
            page.openListRequested(!!play)
            catalog.openUrl("https://music.youtube.com/playlist?list=LM",
                            "Música que me gusta")
            return
        }
        // Canción suelta: un solo clic ya suena (no abre vista de lista ni
        // pasa por yt-dlp: se entrega la pista tal cual al reproductor).
        if (item.kind === "track") {
            page.playRequested([{
                title: item.title || "",
                artist: item.sub || "",
                url: item.url || "",
                thumb: item.thumb || "",
                source: item.source || ""
            }], 0)
            return
        }
        if (item.url) {
            page.openListRequested(!!play)
            catalog.openUrl(item.url, item.title)
        }
    }

    function sourceEntry(id) {
        const l = sources.list
        for (var i = 0; i < l.length; i++)
            if (l[i].id === id)
                return l[i]
        return null
    }
    readonly property var src: sourceEntry(sources.activeId)
    readonly property bool ytmOk: String(catalog.loginState || "") === "ok"

    // ---- portadas con degradado derivadas del propio texto --------------
    function _hash(s) {
        var h = 0
        s = String(s || "")
        for (var i = 0; i < s.length; i++)
            h = (h * 31 + s.charCodeAt(i)) >>> 0
        return h
    }
    function coverA(seed) {
        return Qt.hsla(((page._hash(seed) % 360) / 360), 0.33, 0.30, 1)
    }
    function coverB(seed) {
        return Qt.hsla((((page._hash(seed) >> 3) % 360) / 360), 0.30, 0.10, 1)
    }

    // ---- saludo fechado --------------------------------------------------
    readonly property string today: {
        const d = new Date()
        const dias = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
        const meses = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
                       "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
        return dias[d.getDay()] + " " + d.getDate() + " de " + meses[d.getMonth()]
    }
    readonly property string greeting: {
        const h = new Date().getHours()
        return h < 12 ? "Buenos días" : (h < 20 ? "Buenas tardes" : "Buenas noches")
    }

    function videoId(url) {
        const u = String(url || "")
        var m = /[?&]v=([A-Za-z0-9_-]{6,})/.exec(u)
        if (m)
            return m[1]
        const m2 = u.match(/youtu\.be\/([A-Za-z0-9_-]+)/)
        return m2 ? m2[1] : ""
    }

    function srcName(id) {
        const e = sourceEntry(id)
        return e ? e.name : String(id || "")
    }

    // ---- historial de búsquedas (persistido en appcfg) -------------------
    // Clave "searchHistory": JSON [{ q, t }…], máx. 20 entradas. Se escribe
    // desde SearchPage.runSearch() y aquí sólo se lee/muestra/borra.
    property var searchHistory: []

    function refreshSearchHistory() {
        var arr = []
        if (typeof appcfg !== "undefined") {
            try {
                arr = JSON.parse(String(appcfg.get("searchHistory") || "[]")) || []
            } catch (e) {
                arr = []
            }
        }
        const out = []
        for (var i = 0; i < arr.length && out.length < 20; i++) {
            const e = arr[i]
            if (e && typeof e.q === "string" && e.q.length > 0)
                out.push({ q: e.q, t: Number(e.t || 0) })
        }
        searchHistory = out
    }

    function clearSearchHistory() {
        if (typeof appcfg !== "undefined") {
            appcfg.set("searchHistory", "[]")
            appcfg.save()
        }
        searchHistory = []
    }

    Component.onCompleted: refreshSearchHistory()

    // ---- sección: tus playlists -----------------------------------------
    function playlistCards() {
        const out = []
        const l = catalog.playlists
        for (var i = 0; i < l.length; i++) {
            const p = l[i]
            var sub = sourceEntry(p.source) ? sourceEntry(p.source).name : p.source
            if (p.count)
                sub += " · " + p.count + " pistas"
            out.push({ index: i, title: p.name, sub: sub })
        }
        return out
    }

    // ---- recomendaciones: radios a partir del historial ------------------
    function recCards() {
        const out = []
        if (page.ytmOk) {
            out.push({ kind: "liked", title: "Me gusta",
                       sub: "Tu música que te gusta", icon: "heart" })
        }
        const seen = {}
        const rec = catalog.recent
        for (var i = 0; i < rec.length && out.length < 10; i++) {
            const t = rec[i]
            const artist = t.artist || ""
            if (!artist || seen[artist])
                continue
            seen[artist] = true
            out.push({ kind: "radio", title: "Radio de " + artist,
                       sub: t.title || "Mix de YouTube", icon: "radio",
                       trackId: page.videoId(t.url) })
        }
        return out
    }

    // Abre una recomendación. Devuelve true si lanzó la apertura (para que el
    // llamante pida reproducirla o sólo abrirla); false si sólo abrió Ajustes.
    function openRec(d, play) {
        if (d.kind === "liked") {
            if (!page.ytmOk) {
                page.openSettingsRequested()
                return false
            }
            page.openListRequested(!!play)
            catalog.openUrl("https://music.youtube.com/playlist?list=LM", "Me gusta")
            return true
        }
        if (d.trackId) {
            page.openListRequested(!!play)
            catalog.openUrl(
                "https://music.youtube.com/watch?v=" + d.trackId
                + "&list=RDAMVM" + d.trackId + "&start_radio=1",
                d.title)
            return true
        }
        return false
    }

    // ---- radios de YouTube (estado de animo / genero) --------------------
    readonly property var moodRadios: [
        { q: "éxitos pop 2024", t: "Éxitos pop", s: "Lo más escuchado", icon: "radio" },
        { q: "reggaeton 2024", t: "Reggaetón", s: "Para la fiesta", icon: "radio" },
        { q: "lofi hip hop", t: "Lo-fi", s: "Para concentrarte", icon: "radio" },
        { q: "rock clásico", t: "Rock clásico", s: "Clásicos de siempre", icon: "radio" },
        { q: "electrónica chill", t: "Electrónica", s: "Beats suaves", icon: "radio" },
        { q: "jazz relax", t: "Jazz", s: "Relájate", icon: "radio" },
        { q: "música latina", t: "Latino", s: "Ritmo y sabor", icon: "radio" },
        { q: "indie alternativo", t: "Indie", s: "Descubre algo nuevo", icon: "radio" },
        { q: "r&b soul", t: "R&B / Soul", s: "Suave y con groove", icon: "radio" },
        { q: "clásica para estudiar", t: "Clásica", s: "Enfoque", icon: "radio" }
    ]

    // Título de sección: pequeño, en Sys.textDim, sin adornos.
    component SectionTitle: Text {
        color: Sys.textDim
        font.pixelSize: Theme.tSm
        font.weight: Font.DemiBold
        font.letterSpacing: 1.1
        elide: Text.ElideRight
    }

    // ====================================================================
    Flickable {
        id: pageFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight + Theme.s5 * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: content
            x: Theme.s5
            y: Theme.s5
            width: pageFlick.width - Theme.s5 * 2
            spacing: Theme.s5

            // ---- saludo (una sola línea) + atajo a Descargas ------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s3

                Text {
                    text: page.greeting
                    color: Sys.text
                    font.pixelSize: Theme.t2xl
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignBaseline
                    text: "· " + page.today + (page.src ? " · " + page.src.name : "")
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                    elide: Text.ElideRight
                }

                Rectangle {
                    Layout.preferredHeight: Theme.rowThin
                    implicitWidth: dlRow.implicitWidth + Theme.s4
                    radius: Theme.rSm
                    color: dlMa.containsMouse ? Sys.surface : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    RowLayout {
                        id: dlRow
                        anchors.centerIn: parent
                        spacing: Theme.s2
                        Glyph {
                            Layout.preferredWidth: 14
                            Layout.preferredHeight: 14
                            kind: "download"
                            color: dlMa.containsMouse ? Sys.accent : Sys.textDim
                        }
                        Text {
                            text: "Descargas"
                            color: dlMa.containsMouse ? Sys.accent : Sys.textDim
                            font.pixelSize: Theme.tMd
                            font.weight: Font.DemiBold
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        }
                    }
                    MouseArea {
                        id: dlMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.navigateRequested("library")
                    }
                }
            }

            // ---- buscador (abre el lanzador) ---------------------------
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.rowCompact
                radius: Theme.rMd
                color: spotMouse.containsMouse ? Theme.hover(Sys.surface) : Sys.surface
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.s4
                    anchors.rightMargin: Theme.s4
                    spacing: Theme.s3
                    Glyph { width: 16; height: 16; kind: "search"; color: Sys.textDim }
                    Text {
                        text: "Buscar en cualquier fuente…"
                        color: Sys.textDim
                        font.pixelSize: Theme.tBase
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                    Text {
                        text: "Ctrl+Espacio"
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        opacity: 0.7
                    }
                }
                MouseArea {
                    id: spotMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: page.openLauncherRequested()
                }
            }

            // ---- RECIENTE (rejilla paginada, sin marco) -----------------
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.s2
                visible: page.picksTotal > 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2

                    SectionTitle {
                        Layout.fillWidth: true
                        text: "RECIENTE"
                    }

                    Rectangle {
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                        radius: Theme.rSm
                        color: prevMa.containsMouse && page.picksPage > 0
                               ? Theme.hover(Sys.surface) : "transparent"
                        opacity: page.picksPage > 0 ? 1 : 0.35
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 14
                            height: 14
                            kind: "chevron-left"
                            color: prevMa.containsMouse ? Sys.accent : Sys.textDim
                        }
                        MouseArea {
                            id: prevMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.picksPage = Math.max(0, page.picksPage - 1)
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 28
                        radius: Theme.rSm
                        color: nextMa.containsMouse && page.picksPage < page.picksPages - 1
                               ? Theme.hover(Sys.surface) : "transparent"
                        opacity: page.picksPage < page.picksPages - 1 ? 1 : 0.4
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 14
                            height: 14
                            kind: "chevron-right"
                            color: nextMa.containsMouse ? Sys.accent : Sys.textDim
                        }
                        MouseArea {
                            id: nextMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.picksPage = Math.min(page.picksPages - 1,
                                                                 page.picksPage + 1)
                        }
                    }
                }

                // Rejilla: 3 columnas × 5 filas (llenado por columnas).
                GridLayout {
                    Layout.fillWidth: true
                    columns: page.picksCols
                    flow: GridLayout.TopToBottom
                    columnSpacing: Theme.s3
                    rowSpacing: 0

                    Repeater {
                        model: page.picksPageItems()

                        delegate: Rectangle {
                            id: pickRow
                            required property var modelData
                            required property int index

                            Layout.fillWidth: true
                            Layout.preferredHeight: Theme.rowCompact
                            radius: Theme.rMd
                            color: pickMouse.containsMouse ? Theme.hover(Sys.bg) : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s2
                                spacing: Theme.s3

                                Rectangle {
                                    Layout.preferredWidth: 34
                                    Layout.preferredHeight: 34
                                    radius: Theme.rSm
                                    color: Sys.surfaceAlt
                                    clip: true
                                    Image {
                                        anchors.fill: parent
                                        source: pickRow.modelData.thumb || ""
                                        visible: source != ""
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
                                        visible: !pickRow.modelData.thumb
                                        kind: pickRow.modelData.kind === "liked"
                                              ? "heart"
                                              : (pickRow.modelData.kind === "playlist"
                                                 ? "list" : "music")
                                        color: pickMouse.containsMouse ? Sys.accent : Sys.textDim
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text {
                                        Layout.fillWidth: true
                                        text: pickRow.modelData.title || ""
                                        color: Sys.text
                                        font.pixelSize: Theme.tBase
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: pickRow.modelData.sub || ""
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tSm
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                }
                            }

                            MouseArea {
                                id: pickMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                // Canciones sueltas: al pasar el ratón ya se
                                // pre-resuelve el stream (un clic = suena ya).
                                onContainsMouseChanged: if (containsMouse
                                        && pickRow.modelData
                                        && pickRow.modelData.kind === "track"
                                        && pickRow.modelData.url)
                                        player.prefetchFront(pickRow.modelData.url)
                                onClicked: page.openQuickPick(pickRow.modelData, true)
                            }
                        }
                    }
                }
            }

            // ---- TUS LISTAS (YouTube Music) ---------------------------
            SectionTitle {
                Layout.fillWidth: true
                visible: catalog.ytmLibrary.length > 0 || catalog.libraryBusy
                text: "TUS LISTAS"
            }

            ListView {
                id: ytmLibView
                visible: catalog.ytmLibrary.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: page.rowHeight
                orientation: ListView.Horizontal
                clip: true
                spacing: page.cardSpacing
                model: catalog.ytmLibrary
                reuseItems: true
                cacheBuffer: 600
                boundsBehavior: Flickable.StopAtBounds

                delegate: HomeCard {
                    required property var modelData
                    thumb: modelData.thumb || ""
                    title: modelData.name
                    subtitle: modelData.count
                              ? "YouTube Music · " + modelData.count + " pistas"
                              : "YouTube Music"
                    icon: "queue"
                    coverA: page.coverA(modelData.name)
                    coverB: page.coverB(modelData.name)
                    // Portada -> ABRIR la lista; botón de play -> reproducirla.
                    onClicked: {
                        page.openListRequested(false)
                        catalog.openUrl(modelData.url, modelData.name)
                    }
                    onPlayClicked: {
                        page.openListRequested(true)
                        catalog.openUrl(modelData.url, modelData.name)
                    }
                }
            }

            Text {
                visible: catalog.libraryBusy
                text: "Cargando…"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                opacity: 0.8
            }

            // ---- TUS PLAYLISTS ----------------------------------------
            SectionTitle {
                Layout.fillWidth: true
                text: "TUS PLAYLISTS"
            }

            ListView {
                id: plView
                visible: catalog.playlists.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: page.rowHeight
                orientation: ListView.Horizontal
                clip: true
                spacing: page.cardSpacing
                model: page.playlistCards()
                reuseItems: true
                cacheBuffer: 600
                boundsBehavior: Flickable.StopAtBounds

                delegate: HomeCard {
                    required property var modelData
                    title: modelData.title
                    subtitle: modelData.sub
                    icon: "queue"
                    coverA: page.coverA(modelData.title)
                    coverB: page.coverB(modelData.title)
                    // Portada -> ABRIR la lista; botón de play -> reproducirla.
                    onClicked: {
                        page.openListRequested(false)
                        catalog.openPlaylist(modelData.index)
                    }
                    onPlayClicked: {
                        page.openListRequested(true)
                        catalog.openPlaylist(modelData.index)
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: catalog.playlists.length === 0
                text: "Aún no hay playlists guardadas. Pega una URL en Biblioteca para empezar."
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            }

            // ---- recomendaciones (radios del historial) ---------------
            SectionTitle {
                Layout.fillWidth: true
                visible: page.recCards().length > 0
                text: "RECOMENDADO PARA TI"
            }

            ListView {
                id: recView
                visible: page.recCards().length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: page.rowHeight
                orientation: ListView.Horizontal
                clip: true
                spacing: page.cardSpacing
                model: page.recCards()
                reuseItems: true
                cacheBuffer: 600
                boundsBehavior: Flickable.StopAtBounds

                delegate: HomeCard {
                    required property var modelData
                    title: modelData.title
                    subtitle: modelData.sub
                    icon: modelData.icon
                    badge: modelData.kind === "liked" ? "YT" : "RADIO"
                    coverA: modelData.kind === "liked"
                            ? Sys.accentDim : page.coverA(modelData.title)
                    coverB: page.coverB(modelData.title)
                    onClicked: page.openRec(modelData, false)
                    onPlayClicked: page.openRec(modelData, true)
                }
            }

            // ---- radios de YouTube ------------------------------------
            SectionTitle {
                Layout.fillWidth: true
                text: "RADIOS DE YOUTUBE"
            }

            ListView {
                id: moodView
                Layout.fillWidth: true
                Layout.preferredHeight: page.rowHeight
                orientation: ListView.Horizontal
                clip: true
                spacing: page.cardSpacing
                model: page.moodRadios
                reuseItems: true
                cacheBuffer: 600
                boundsBehavior: Flickable.StopAtBounds

                delegate: HomeCard {
                    required property var modelData
                    title: modelData.t
                    subtitle: modelData.s
                    icon: modelData.icon
                    badge: "YT"
                    coverA: page.coverA(modelData.t)
                    coverB: page.coverB(modelData.t)
                    onClicked: {
                        page.openListRequested(false)
                        catalog.openUrl("ytsearch15:" + modelData.q, modelData.t)
                    }
                    onPlayClicked: {
                        page.openListRequested(true)
                        catalog.openUrl("ytsearch15:" + modelData.q, modelData.t)
                    }
                }
            }

            // ---- historial de búsquedas --------------------------------
            // Chips con las últimas consultas (appcfg "searchHistory").
            // El clic re-ejecuta la búsqueda: Main abre Buscar y lanza la
            // query. «Borrar» limpia el historial persistido.
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s3

                SectionTitle {
                    Layout.fillWidth: true
                    text: "HISTORIAL DE BÚSQUEDAS"
                }

                Rectangle {
                    visible: page.searchHistory.length > 0
                    height: 22
                    radius: Theme.rSm
                    implicitWidth: clearHistBtn.implicitWidth + 18
                    color: clearHistMa.containsMouse ? Sys.accentDim : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    Text {
                        id: clearHistBtn
                        anchors.centerIn: parent
                        text: "Borrar historial"
                        color: clearHistMa.containsMouse ? Sys.accent : Sys.textDim
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    }
                    MouseArea {
                        id: clearHistMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.clearSearchHistory()
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: page.searchHistory.length === 0
                text: "Todavía no hay búsquedas: escribe en la barra superior o pulsa Ctrl+Espacio."
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                opacity: 0.8
            }

            ListView {
                id: histView
                visible: page.searchHistory.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.rowThin
                orientation: ListView.Horizontal
                spacing: Theme.s2
                clip: true
                model: page.searchHistory
                reuseItems: true
                cacheBuffer: 400
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: histChip
                    required property var modelData
                    required property int index

                    height: 32
                    radius: Theme.rSm
                    width: Math.min(histTxt.implicitWidth + 38, 340)
                    color: histChipMa.containsMouse ? Sys.accentDim : Sys.surface
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Theme.s2

                        Glyph {
                            Layout.preferredWidth: 12
                            Layout.preferredHeight: 12
                            kind: "search"
                            color: histChipMa.containsMouse ? Sys.accent : Sys.textDim
                        }
                        Text {
                            id: histTxt
                            text: histChip.modelData.q
                            color: histChipMa.containsMouse ? Sys.accent : Sys.textDim
                            font.pixelSize: Theme.tMd
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, 280)
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        }
                    }

                    MouseArea {
                        id: histChipMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // Re-ejecuta la búsqueda: Main abre Buscar y lanza la query.
                        onClicked: page.searchRequested(histChip.modelData.q)
                    }
                }
            }

            Item { Layout.preferredHeight: 1 }
        }
    }
}
