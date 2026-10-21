import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Home: a one line greeting, a discreet shortcut to Downloads and
// horizontal rails of fixed size cards. Each rail is a ListView with
// reuseItems: it recycles delegates and the grid never jumps on hover.
//
// Visual composition (1.0): every block lives in a FLOATING ISLAND (a
// rounded surface with a very faint edge) and the loose controls are
// PILLS. The hierarchy comes from the air, not from lines. No shadows and
// no shaders.
//
// Comportamiento de clic en las tarjetas:
//   · clic en la PORTADA -> ABRE la lista (vista de pistas), sin reproducir.
//   . play button        -> loads the list and PLAYS it (without leaving
//                           Home).
//   . "Recent" row       -> a click already plays (it has no button of its
//                           own).
Item {
    id: page

    signal playRequested(var list, int index)
    signal navigateRequested(string page)
    signal openSettingsRequested()
    signal openLauncherRequested()
    // Asks to open a list from the catalogue. `play` = play it as soon as
    // it arrives; without playing, Main only shows it (it never
    // auto-plays).
    signal openListRequested(bool play)
    // Re-runs a search from the history: Main opens Search and runs the
    // query.
    signal searchRequested(string query)

    // Altura fija de cada carril de tarjetas (portada 172 + texto 54).
    readonly property int rowHeight: 230
    readonly property int cardSpacing: 14

    // ---- Reciente (deck estilo Sonora) ----------------------------------
    // Rejilla paginada de filas compactas. Es un «RECIENTE» combinado de TODAS
    // las fuentes: las canciones SUELTAS escuchadas (se excluyen las que
    // played inside a playlist) and the 5 most recent lists.
    property int picksPage: 0
    // Rejilla de accesos directos: 3 columnas × 2 filas, como en el repo de
    // reference (full screen without long pagination; the arrows only
    // show if there is more than one page).
    readonly property int picksPerPage: 6
    readonly property int picksCols: 3
    readonly property int picksRows: 2

    // Recent loose songs (catalog.recent, newest first). They
    // excluyen las que sonaron dentro de una playlist (`setId`) y las antiguas
    // sin clasificar (`legacy`).
    function recentTracks() {
        const out = []
        const rec = catalog.recent
        for (var i = 0; i < rec.length && out.length < 5; i++) {
            const t = rec[i]
            if (!t || !t.url || t.setId || t.legacy)
                continue
            out.push({ kind: "track", title: t.title || "",
                       sub: t.artist || "", thumb: t.thumb || "",
                       url: t.url, source: t.source || "" })
        }
        return out
    }

    // Up to `limit` lists, most recent first. ALL of them are combined
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

    // Mismo truco que con las recomendadas: el modelo de los accesos
    // shortcuts are cached and only change if the content changes, so the
    // loading thumbnails are not restarted on every library signal.
    property var picksCache: []
    function refreshPicks() {
        const cur = page.quickPicks()
        if (JSON.stringify(cur) !== JSON.stringify(page.picksCache))
            page.picksCache = cur
    }

    readonly property int picksTotal: page.picksCache.length
    readonly property int picksPages: Math.max(1, Math.ceil(page.picksTotal / page.picksPerPage))
    function picksPageItems() {
        const all = page.picksCache
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
        // Loose song: a single click already plays (it opens neither a list
        // view nor
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
    // The gap without an image is painted DEEP BLUE with a subtle
    // variation per title, so the set is not a flat block: black loses
    // black, in the spirit of the cinema mode.
    function coverA(seed) {
        var h = page._hash(seed)
        var hue = (200 + (h % 46)) / 360
        return Qt.hsla(hue, 0.42, 0.34, 1)
    }
    function coverB(seed) {
        var h = page._hash(seed)
        var hue = (200 + ((h >> 3) % 46)) / 360
        return Qt.hsla(hue, 0.45, 0.12, 1)
    }
    // Mood radios without any artwork: every label gets its OWN hue (the
    // whole spectrum instead of a single blue) so the rail does not
    // sea un clon repetido. La pareja de tonos sale de la misma semilla.
    function moodA(seed) {
        var h = page._hash(seed)
        return Qt.hsla(((h >> 5) % 360) / 360, 0.50, 0.34, 1)
    }
    function moodB(seed) {
        var h = page._hash(seed)
        return Qt.hsla((((h >> 5) + 28) % 360) / 360, 0.55, 0.13, 1)
    }

    // ---- saludo fechado ---------------------------------------------------
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

    // ---- search history (persisted in appcfg) ---------------------------
    // "searchHistory" key: JSON [{ q, t }...], up to 20 entries. It is
    // written by SearchPage.runSearch() and here it is only read, shown
    // and cleared.
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

    Component.onCompleted: {
        refreshSearchHistory()
        refreshPicks()
        refreshRecCards()
        if (visible) {
            startRecPrefetch()
        }
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
                       trackId: page.videoId(t.url), thumb: t.thumb || "" })
        }
        return out
    }

    // Opens a recommendation. It returns true if it started the opening
    // (so the caller can ask to play it or just open it); false if it only
    // opened Settings.
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
            // La primera pista de la radio es la propia semilla: se resuelve
            // YA (con prioridad) mientras yt-dlp trae el resto de la lista, de
            // mode so that on arrival it does not wait for the resolution
            // again and plays
            // de inmediato.
            if (typeof player !== "undefined")
                player.prefetchFront("https://music.youtube.com/watch?v=" + d.trackId)
            page.openListRequested(!!play)
            catalog.openUrl(
                "https://music.youtube.com/watch?v=" + d.trackId
                + "&list=RDAMVM" + d.trackId + "&start_radio=1",
                d.title)
            return true
        }
        return false
    }

    // ---- precarga en segundo plano de las radios de «Para ti» ------------
    // Traer la lista de una radio cuesta ~1,4 s FIJOS de red (dos idas y
    // vueltas a YouTube Music; da igual pedir 8 que 25 pistas). Para que el
    // click is instant, the radios of "Recommended for you" are fetched on
    // their own, one at a time, while Home is visible: by the time the
    // user presses, they are already in the in-memory list cache.
    //
    // It is best-effort: the prefetch is preemptible, so any explicit user
    // action overrides it without more. Each seed is prefetched once per
    // session.
    property var recPrefetchQueue: []
    property var recPrefetched: ({})

    // The model is rebuilt on every `libraryChanged` signal, and since the
    // radio prefetches emit that signal in a cascade, a new model per
    // evaluation restarted the loading artworks (they never finished
    // downloading). The result is cached and only replaced if the CONTENT
    // cambia de verdad: mismo contenido => mismo objeto modelo => las
    // tarjetas no se reciclan gratis.
    property var recCardsCache: []
    function refreshRecCards() {
        const cur = page.recCards()
        if (JSON.stringify(cur) !== JSON.stringify(page.recCardsCache))
            page.recCardsCache = cur
    }

    function startRecPrefetch() {
        if (typeof catalog === "undefined" || !page.ytmOk)
            return
        const cards = page.recCardsCache
        for (var i = 0; i < cards.length; i++) {
            const d = cards[i]
            if (d.kind === "radio" && d.trackId && !page.recPrefetched[d.trackId])
                page.recPrefetchQueue.push({ id: d.trackId, title: d.title })
        }
        if (page.recPrefetchQueue.length && !recPrefetchTimer.running)
            recPrefetchTimer.start()
    }

    Timer {
        id: recPrefetchTimer
        interval: 400
        repeat: true
        running: false
        onTriggered: {
            if (typeof catalog === "undefined" || catalog.busy)
                return   // en cuanto esté libre, se reanuda
            while (page.recPrefetchQueue.length) {
                const it = page.recPrefetchQueue.shift()
                if (page.recPrefetched[it.id])
                    continue
                page.recPrefetched[it.id] = true
                catalog.prefetchRadio(it.id, it.title)
                return
            }
            recPrefetchTimer.stop()
        }
    }

    // Al mostrarse Inicio (y cuando cambia el historial, que rehace las
    // tarjetas) se pone en marcha la ronda de precarga.
    onVisibleChanged: if (visible) { refreshPicks(); refreshRecCards(); page.startRecPrefetch() }

    Connections {
        target: catalog
        function onLibraryChanged() { if (page.visible) { refreshPicks(); refreshRecCards(); page.startRecPrefetch() } }
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

    // Section title: icon in the accent colour + label in bold and
    // mayusculas normalizadas (el estilo del repo de referencia: el icono
    // presenta la seccion, el tamano la jerarquiza).
    component SectionTitle: RowLayout {
        id: secTitle

        property string text: ""
        property string icon: ""

        spacing: Theme.s2
        Glyph {
            width: 17
            height: 17
            visible: secTitle.icon !== ""
            kind: secTitle.icon
            color: Sys.accent
        }
        Text {
            Layout.fillWidth: true
            text: secTitle.text
            color: Sys.text
            font.pixelSize: Theme.tLg
            font.weight: Font.Bold
            elide: Text.ElideRight
        }
    }

    // Home section: FLAT, no box and no edge - the content sits straight on
    // the washed background, like in the reference repo. The air (pad) and the
    // gap (spacing) mark the hierarchy; the height is set by the content.
    component Island: Rectangle {
        id: island

        property real pad: Theme.s2
        property alias spacing: inner.spacing

        implicitHeight: inner.implicitHeight + island.pad * 2
        radius: 0
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

    // ====================================================================
    Flickable {
        id: pageFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight + Theme.s4 * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: content
            x: Theme.s5
            y: Theme.s4
            width: pageFlick.width - Theme.s5 * 2
            spacing: Theme.panelGap

            // ---- cabecera: saludo + buscador (isla flotante) ------------
            Island {
                Layout.fillWidth: true
                spacing: Theme.s4

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

                    // Shortcut to Downloads: an action pill.
                    Rectangle {
                        Layout.preferredHeight: Theme.pillH
                        implicitWidth: dlRow.implicitWidth + Theme.pillHPad * 2
                        radius: Theme.rPill
                        color: dlMa.containsMouse ? Sys.accentDim : Sys.surfaceAlt
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
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.navigateRequested("library") }
                        }
                    }
                }

                // ---- search (opens the launcher) - thin line ------------
                // Minimal: no grey box, just a line below that lights up on
                // hover. The "Downloads" button next to it does have a
                // background (it is a button).
                Rectangle {
                    id: searchSpot
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    color: "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s1
                        anchors.rightMargin: Theme.s1
                        spacing: Theme.s2
                        Glyph {
                            width: 16; height: 16
                            kind: "search"
                            color: spotMouse.containsMouse ? Sys.accent : Sys.textDim
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        }
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

                    // The line: it lights up on hover.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: spotMouse.containsMouse ? Theme.alpha(Sys.accent, 0.55)
                                                      : Theme.alpha(Sys.text, 0.14)
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    }

                    MouseArea {
                        id: spotMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.openLauncherRequested() }
                    }
                }
            }

            // ---- RECIENTE (isla con rejilla paginada) ------------------
            // Max 5 loose songs + 5 recent lists (quickPicks),
            // repartidas en 3 columnas × 5 filas.
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3
                visible: page.picksTotal > 0

                // Sin rotulo: el saludo ya preside la pagina (como en el repo
                // reference). The page arrows are discreet and only
                // existen si hay mas de una pagina de accesos.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2
                    visible: page.picksPages > 1

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        Layout.preferredWidth: Theme.pillH
                        Layout.preferredHeight: Theme.pillH
                        radius: Theme.rPill
                        color: prevMa.containsMouse && page.picksPage > 0
                               ? Sys.accentDim : "transparent"
                        opacity: page.picksPage > 0 ? 1 : 0.35
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 15
                            height: 15
                            kind: "chevron-left"
                            color: prevMa.containsMouse ? Sys.accent : Sys.textDim
                        }
                        MouseArea {
                            id: prevMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.picksPage = Math.max(0, page.picksPage - 1) }
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: Theme.pillH
                        Layout.preferredHeight: Theme.pillH
                        radius: Theme.rPill
                        color: nextMa.containsMouse && page.picksPage < page.picksPages - 1
                               ? Sys.accentDim : "transparent"
                        opacity: page.picksPage < page.picksPages - 1 ? 1 : 0.4
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 15
                            height: 15
                            kind: "chevron-right"
                            color: nextMa.containsMouse ? Sys.accent : Sys.textDim
                        }
                        MouseArea {
                            id: nextMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.picksPage = Math.min(page.picksPages - 1, page.picksPage + 1) }
                        }
                    }
                }

                // Rejilla: 3 columnas × 2 filas (llenado por columnas: con
                // vertical flow the GridLayout groups by ROWS, so the
                // punto de envoltura es rows=2).
                GridLayout {
                    Layout.fillWidth: true
                    rows: page.picksRows
                    flow: GridLayout.TopToBottom
                    columnSpacing: Theme.s3
                    rowSpacing: Theme.s2

                    Repeater {
                        model: page.picksPageItems()

                        delegate: Rectangle {
                            id: pickRow
                            required property var modelData
                            required property int index

                            Layout.fillWidth: true
                            Layout.preferredHeight: 58
                            // Pastilla siempre insinuada (como en el repo de
                            // referencia): el acceso directo se ve accesible
                            // sin pasar el raton encima.
                            radius: Theme.rMd
                            color: pickMouse.containsMouse
                                   ? Theme.alpha(Sys.text, 0.11) : Theme.alpha(Sys.text, 0.055)
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s2
                                spacing: Theme.s3

                                Rectangle {
                                    Layout.preferredWidth: 42
                                    Layout.preferredHeight: 42
                                    radius: Theme.rMd
                                    color: Sys.surfaceAlt
                                    clip: true
                                    RoundedArt {
                                        anchors.fill: parent
                                        source: pickRow.modelData.thumb || ""
                                        radiusSpec: Theme.rMd
                                    }
                                    Glyph {
                                        anchors.centerIn: parent
                                        width: 16
                                        height: 16
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
                                        font.weight: Font.DemiBold
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
                                // Loose songs: on hover they are already
                                // pre-resuelve el stream (un clic = suena ya).
                                onContainsMouseChanged: if (containsMouse
                                        && pickRow.modelData
                                        && pickRow.modelData.kind === "track"
                                        && pickRow.modelData.url)
                                        player.prefetchFront(pickRow.modelData.url)
                                onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.openQuickPick(pickRow.modelData, true) }
                            }
                        }
                    }
                }
            }

            // ---- recomendaciones (radios del historial) — isla ---------
            // Right after RECENT: it is the closest at hand (in the style
            // de los «Made for you» de Spotify).
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3
                visible: page.recCardsCache.length > 0

                SectionTitle {
                    Layout.fillWidth: true
                    icon: "disc"
                    text: "Recomendado para ti"
                }

                ListView {
                    id: recView
                    visible: page.recCardsCache.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: page.rowHeight
                    orientation: ListView.Horizontal
                    clip: true
                    spacing: page.cardSpacing
                    model: page.recCardsCache
                    reuseItems: true
                    cacheBuffer: 600
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: HomeCard {
                        required property var modelData
                        title: modelData.title
                        subtitle: modelData.sub
                        icon: modelData.icon
                        badge: modelData.kind === "liked" ? "YT" : "RADIO"
                        // La radio suena sobre una pista semilla: su portada
                        // (en miniatura grande) es la que preside la tarjeta.
                        thumb: modelData.thumb
                               || (modelData.trackId
                                   ? "https://i.ytimg.com/vi/" + modelData.trackId
                                     + "/hq2.jpg" : "")
                        coverA: modelData.kind === "liked"
                                ? Sys.accentDim : page.coverA(modelData.title)
                        coverB: page.coverB(modelData.title)
                        onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.openRec(modelData, false) }
                        onPlayClicked: page.openRec(modelData, true)
                        // On hover over a radio its list is downloaded (in
                        // the background, blocking nothing) if the page's
                        // prefetch round has not done it yet.
                        onHoveredChanged: if (hovered && modelData
                                              && modelData.kind === "radio"
                                              && modelData.trackId
                                              && !page.recPrefetched[modelData.trackId]) {
                            page.recPrefetched[modelData.trackId] = true
                            catalog.prefetchRadio(modelData.trackId, modelData.title)
                        }
                    }
                }
            }

            // ---- radios de YouTube — isla ------------------------------
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3

                SectionTitle {
                    Layout.fillWidth: true
                    icon: "radio"
                    text: "Radios de YouTube"
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
                        // Every mood radio gets its own hue (see
                        // moodA/moodB).
                        coverA: page.moodA(modelData.t)
                        coverB: page.moodB(modelData.t)
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
            }

            // ---- search history - island -------------------------------
            // Pills with the latest queries (appcfg "searchHistory").
            // Clicking re-runs the search: Main opens Search and runs the
            // query. «Borrar» limpia el historial persistido.
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s3

                    SectionTitle {
                        Layout.fillWidth: true
                        icon: "search"
                        text: "Búsquedas recientes"
                    }

                    Rectangle {
                        visible: page.searchHistory.length > 0
                        Layout.preferredHeight: Theme.pillH
                        radius: Theme.rPill
                        implicitWidth: clearHistBtn.implicitWidth + Theme.pillHPad * 2
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
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.clearSearchHistory() }
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
                    Layout.preferredHeight: Theme.pillH
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

                        height: Theme.pillH
                        radius: Theme.rPill
                        width: Math.min(histTxt.implicitWidth + Theme.pillHPad * 2, 340)
                        color: histChipMa.containsMouse ? Sys.accentDim : Sys.surfaceAlt
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
                            // Re-runs the search: Main opens Search and runs
                            // the query.
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.searchRequested(histChip.modelData.q) }
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 1 }
        }
    }
}
