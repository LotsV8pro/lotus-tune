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
// Click behaviour on the cards:
//   · click on the COVER -> OPENS the list (tracks view), without playing.
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
    // Menu button of a compact row: Main shows the shared context menu.
    signal itemMenuRequested(var item, real x, real y)

    // 0 = horizontal card rails, 1 = compact rows. Main persists it.
    property int viewMode: 0
    // Interfaz compacta global: espaciados un 10% menores.
    property bool compact: false

    // Fixed height of each card rail (cover 172 + text 54).
    // Card size adapts to the device: on a narrow screen the radio /
    // recommended squares shrink (about 3.5 visible per row) instead of
    // getting cut; the desktop keeps the 172 px card.
    readonly property int deckCardWidth: {
        const avail = page.width - Theme.panelMargin * 2
        if (avail < 620)
            return Math.round(Math.max(104, (avail - 3 * cardSpacing) / 3.4))
        return 172
    }
    readonly property int rowHeight: page.deckCardWidth + Theme.cardTextH
    readonly property int cardSpacing: 14

    // ---- Recent (Sonora style deck) -------------------------------------
    // Paginated grid of compact rows. It is a «RECENT» combined of ALL
    // the sources: the LOOSE songs listened (the ones played inside a
    // playlist are excluded) and the 5 most recent lists.
    property int picksPage: 0
    // Shortcuts grid: 3 columns × 2 rows, like in the reference
    // repo (full screen without long pagination; the arrows only
    // show if there is more than one page).
    readonly property int picksPerPage: 6
    // Main sets 4 on wide screens in the Lotus interface; classic stays 3.
    property int picksCols: 3
    readonly property int picksRows: 2

    // Recent loose songs (catalog.recent, newest first). They
    // exclude the ones played inside a playlist (`setId`) and the old
    // unclassified ones (`legacy`).
    function recentTracks() {
        const out = []
        const rec = catalog.recent
        for (var i = 0; i < rec.length && out.length < 5; i++) {
            const t = rec[i]
            if (!t || !t.url || t.setId || t.legacy)
                continue
            out.push({ kind: "track", title: t.title || "",
                       sub: t.artist || "", thumb: t.thumb || "",
                       url: t.url, source: t.source || "",
                       duration: Number(t.duration || 0) })
        }
        return out
    }

    // Up to `limit` lists, most recent first. ALL of them are combined
    // sources: the lists saved by the user and the YouTube Music ones.
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
                sub += (sub ? " · " : "") + qsTr("%1 pistas").arg(count)
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
        // Only lists (playlists / albums / "me gusta"): a quick access
        // opens something to listen to, it is not a single song.
        return page.recentLists(10)
    }

    // Same trick as with the recommended ones: the model of the
    // shortcuts is cached and only changes if the content changes, so the
    // loading thumbnails are not restarted on every library signal.
    property var picksCache: []
    // Cheap content check: compare a signature of ids/titles instead of
    // serialising whole arrays on every library signal.
    function sameCards(a, b) {
        if (a.length !== b.length)
            return false
        for (let i = 0; i < a.length; i++) {
            if (a[i].title !== b[i].title || a[i].url !== b[i].url
                    || a[i].thumb !== b[i].thumb)
                return false
        }
        return true
    }
    function refreshPicks() {
        const cur = page.quickPicks()
        if (!page.sameCards(cur, page.picksCache))
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
                            qsTr("Música que me gusta"))
            return
        }
        // Loose song: a single click already plays (it opens neither a list
        // view nor
        // goes through yt-dlp: the track is handed to the player as it is).
        if (item.kind === "track") {
            page.playRequested([{
                title: item.title || "",
                artist: item.sub || "",
                url: item.url || "",
                thumb: item.thumb || "",
                source: item.source || "",
                duration: Number(item.duration || 0)
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

    // ---- covers with gradients derived from the text itself ---------------
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
    // become a repeated clone. The pair of tones comes from the same seed.
    function moodA(seed) {
        var h = page._hash(seed)
        return Qt.hsla(((h >> 5) % 360) / 360, 0.50, 0.34, 1)
    }
    function moodB(seed) {
        var h = page._hash(seed)
        return Qt.hsla((((h >> 5) + 28) % 360) / 360, 0.55, 0.13, 1)
    }

    // ---- dated greeting ---------------------------------------------------
    // The date follows the language of the interface: Qt.locale() is the one
    // the Translator sets (QLocale::setDefault), so the month and the day
    // names come out in the chosen language without a table here. The tag is
    // an argument and not a global so the binding re-evaluates when the
    // language changes.
    function dateLine(tag) {
        return tag.length >= 0 ? new Date().toLocaleDateString(Qt.locale(), "dddd d MMMM") : ""
    }
    readonly property string today: dateLine(lang.language)
    readonly property string greeting: {
        const h = new Date().getHours()
        return h < 12 ? qsTr("Buenos días")
                      : (h < 20 ? qsTr("Buenas tardes") : qsTr("Buenas noches"))
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

    property bool firstShow: true

    Component.onCompleted: {
        refreshSearchHistory()
        refreshPicks()
        refreshRecCards()
        // On a cold start the radio prefetch competes with the window and
        // with the mini-player cover. Give the first frames to the UI and
        // only then warm the radios in the background.
        Qt.callLater(function() {
            if (visible && firstShow)
                bootPrefetchTimer.start()
        })
    }

    Timer {
        id: bootPrefetchTimer
        interval: 5000
        onTriggered: {
            page.firstShow = false
            page.startRecPrefetch()
        }
    }

    // ---- recommendations: radios from the history ------------------------
    function recCards() {
        const out = []
        if (page.ytmOk) {
            out.push({ kind: "liked", title: qsTr("Me gusta"),
                       sub: qsTr("Tu música que te gusta"), icon: "heart" })
        }
        const seen = {}
        // First the artists the user LIKES (their radios are the ones that
        // make sense); then the recently played ones for the rest.
        const liked = catalog.likedTracks || []
        for (var i = 0; i < liked.length && out.length < 10; i++) {
            const t = liked[i]
            const artist = t.artist || ""
            if (!artist || seen[artist])
                continue
            seen[artist] = true
            out.push({ kind: "radio", title: qsTr("Radio de %1").arg(artist),
                       sub: t.title || qsTr("Tus favoritos"), icon: "radio",
                       trackId: page.videoId(t.url), thumb: t.thumb || "",
                       artist: artist })
        }
        const rec = catalog.recent
        // Order by how often each artist appears in the history, so the
        // radios shown are the ones actually listened to the most.
        const counts = {}
        for (var n = 0; n < rec.length; n++) {
            const an = rec[n].artist || ""
            if (an)
                counts[an] = (counts[an] || 0) + 1
        }
        const ranked = rec.slice().sort(function (a, b) {
            return (counts[b.artist || ""] || 0) - (counts[a.artist || ""] || 0)
        })
        for (var j = 0; j < ranked.length && out.length < 10; j++) {
            const t = ranked[j]
            const artist = t.artist || ""
            if (!artist || seen[artist])
                continue
            seen[artist] = true
            out.push({ kind: "radio", title: qsTr("Radio de %1").arg(artist),
                       sub: t.title || qsTr("Mix de YouTube"), icon: "radio",
                       trackId: page.videoId(t.url), thumb: t.thumb || "",
                       artist: artist })
        }
        // The face of the radio is the artist, like on YouTube Music (not
        // the cover of its first track). The photo is looked up in the
        // background the first time and cached from then on.
        for (var k = 0; k < out.length; k++) {
            const d = out[k]
            if (d.kind !== "radio" || !d.artist)
                continue
            const face = catalog.artistThumb(d.artist)
            if (face)
                d.thumb = face
            else
                catalog.ensureArtistThumb(d.artist)
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
            catalog.openUrl("https://music.youtube.com/playlist?list=LM", qsTr("Me gusta"))
            return true
        }
        if (d.trackId) {
            // The first track of the radio is the seed itself: it is
            // resolved RIGHT AWAY (with priority) while yt-dlp brings the rest
            // of the list, in such a
            // mode so that on arrival it does not wait for the resolution
            // again and plays
            // immediately.
            if (typeof player !== "undefined")
                if (!catalog.metered)
                    player.prefetchFront("https://music.youtube.com/watch?v=" + d.trackId)
            page.openListRequested(!!play)
            catalog.openUrlArt(
                "https://music.youtube.com/watch?v=" + d.trackId
                + "&list=RDAMVM" + d.trackId + "&start_radio=1",
                d.title, d.thumb || "")
            return true
        }
        return false
    }

    // One row model for the compact view, built from the same arrays the
    // card rails use: quick picks, recommendations and YouTube radios.
    function buildListItems() {
        const out = []
        for (const p of page.picksCache)
            out.push({ src: "quick", item: p, title: p.title || "",
                       sub: p.sub || "", thumb: p.thumb || "", icon: p.icon || "disc",
                       a: page.coverA(p.title), b: page.coverB(p.title) })
        for (const r of page.recCardsCache)
            out.push({ src: "rec", item: r, title: r.title || "",
                       sub: r.sub || "",
                       thumb: r.thumb || (r.trackId
                              ? "https://i.ytimg.com/vi/" + r.trackId + "/hq2.jpg" : ""),
                       icon: r.icon || "radio",
                       a: r.kind === "liked" ? Sys.accentDim : page.coverA(r.title),
                       b: page.coverB(r.title) })
        for (const m of page.moodRadios)
            out.push({ src: "mood", item: m, title: m.t, sub: m.s,
                       thumb: "", icon: m.icon || "radio",
                       a: page.moodA(m.t), b: page.moodB(m.t) })
        return out
    }
    readonly property var listItems: page.buildListItems()

    // Opens or plays a compact row through the same paths as the cards.
    function openListItem(row, play) {
        if (!row)
            return
        if (row.src === "rec") {
            page.openRec(row.item, play)
            return
        }
        if (row.src === "mood") {
            page.openListRequested(!!play)
            catalog.openUrl("ytsearch15:" + row.item.q, row.item.t)
            return
        }
        page.openQuickPick(row.item, play)
    }

    // ---- background prefetch of the "For you" radios ---------------------
    // Bringing the list of a radio costs ~1.4 s FIXED of network (two trips
    // to YouTube Music; it does not matter whether you ask for 8 or 25
    // tracks). So that the
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
    // really changes: same content => same model object => the
    // cards are not recycled for free.
    property var recCardsCache: []
    function refreshRecCards() {
        const cur = page.recCards()
        if (!page.sameCards(cur, page.recCardsCache))
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
                return   // as soon as it is free, it resumes
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

    // When Home is shown (and when the history changes, which rebuilds
    // the cards) the prefetch round is started.
    onVisibleChanged: if (visible) {
        refreshSearchHistory(); refreshPicks(); refreshRecCards()
        if (!page.firstShow)
            page.startRecPrefetch()
    }

    Connections {
        target: catalog
        function onLibraryChanged() { if (page.visible) { refreshPicks(); refreshRecCards(); page.startRecPrefetch() } }
        // An artist photo arrived: the card of their radio takes it.
        function onArtistThumbReady(name, thumb) {
            if (page.visible && thumb)
                refreshRecCards()
        }
    }

    // ---- YouTube radios (mood / genre) ------------------------------------
    readonly property var moodRadios: [
        { q: "éxitos pop 2024", t: qsTr("Éxitos pop"), s: qsTr("Lo más escuchado"), icon: "radio" },
        { q: "reggaeton 2024", t: qsTr("Reggaetón"), s: qsTr("Para la fiesta"), icon: "radio" },
        { q: "lofi hip hop", t: qsTr("Lo-fi"), s: qsTr("Para concentrarte"), icon: "radio" },
        { q: "rock clásico", t: qsTr("Rock clásico"), s: qsTr("Clásicos de siempre"), icon: "radio" },
        { q: "electrónica chill", t: qsTr("Electrónica"), s: qsTr("Beats suaves"), icon: "radio" },
        { q: "jazz relax", t: qsTr("Jazz"), s: qsTr("Relájate"), icon: "radio" },
        { q: "música latina", t: qsTr("Latino"), s: qsTr("Ritmo y sabor"), icon: "radio" },
        { q: "indie alternativo", t: qsTr("Indie"), s: qsTr("Descubre algo nuevo"), icon: "radio" },
        { q: "r&b soul", t: qsTr("R&B / Soul"), s: qsTr("Suave y con groove"), icon: "radio" },
        { q: "clásica para estudiar", t: qsTr("Clásica"), s: qsTr("Enfoque"), icon: "radio" }
    ]

    // Section title: icon in the accent colour + label in bold and
    // normalised capitals (the style of the reference repo: the icon
    // presents the section, the size hierarchies it).
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
            color: Theme.accentOn(Sys.accent, Sys.bg)
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
            // Gutter: one consistent inset. On the phone it drops to 12 dp
            // (the page goes almost edge to edge: the outer 6 dp of
            // `panelMargin` already separates the content from the glass).
            x: Theme.touch ? Theme.s3 : Theme.s5
            y: Theme.touch ? Theme.s3 : Theme.s4
            width: pageFlick.width - x * 2
            spacing: Theme.panelGap

            // ---- header: greeting + search box (floating island) ---------
            Island {
                Layout.fillWidth: true
                spacing: Theme.touch ? Theme.s3 : Theme.s4

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s3

                    // Greeting + date: hidden, the page starts with the
                    // search box and the cards.
                    ColumnLayout {
                        visible: false
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: page.greeting
                            color: Sys.text
                            // The phone is 384 dp wide: a 24 dp greeting ate
                            // a whole line of the page for no information.
                            font.pixelSize: Theme.touch ? Theme.tXl : Theme.t2xl
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: page.today + (page.src ? " · " + page.src.name : "")
                            color: Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tSm
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }

                    // Shortcut to Downloads: an action pill. The bottom
                    // navigation already carries "Descargas" on the phone,
                    // so there it would only steal room from the date.
                    Rectangle {
                        visible: !Theme.touch
                        Layout.preferredHeight: Theme.pillH
                        implicitWidth: dlRow.implicitWidth + Theme.pillHPad * 2
                        radius: Theme.rPill
                        antialiasing: true
                        color: dlMa.containsMouse ? Sys.accentDim : Theme.sAlt(Sys.bg, Sys.text)
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                        RowLayout {
                            id: dlRow
                            anchors.centerIn: parent
                            spacing: Theme.s2
                            Glyph {
                                Layout.preferredWidth: 14
                                Layout.preferredHeight: 14
                                kind: "download"
                                color: dlMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                            }
                            Text {
                                text: qsTr("Descargas")
                                color: dlMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
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

                // ---- search: a real field (opens the launcher) ----------
                // Rounded surface + accent icon: it reads as an input, and
                // the "Ctrl+Espacio" shortcut only exists on a desktop.
                Rectangle {
                    id: searchSpot
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.touch ? 42 : 40
                    radius: Theme.rPill
                    antialiasing: true
                    color: spotMouse.containsMouse ? Theme.sHigh(Sys.bg, Sys.text)
                                                 : Theme.sAlt(Sys.bg, Sys.text)
                    border.width: 1
                    border.color: spotMouse.containsMouse
                                  ? Theme.alpha(Theme.accentOn(Sys.accent, Sys.bg), 0.55)
                                  : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    // The field is INSIDE the page's carousel: without this
                    // the wheel over it dragged the whole page.
                    WheelHandler { onWheel: (event) => { event.accepted = true } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s4
                        anchors.rightMargin: Theme.s4
                        spacing: Theme.s2
                        Glyph {
                            Layout.alignment: Qt.AlignVCenter
                            width: 17; height: 17
                            kind: "search"
                            color: spotMouse.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg)
                                                           : Theme.tDim(Sys.bg, Sys.text)
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        }
                        Text {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            text: qsTr("Buscar canciones, artistas, listas…")
                            color: Theme.tDim(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tBase
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: !Theme.touch
                            Layout.alignment: Qt.AlignVCenter
                            text: "Ctrl+K"
                            color: Theme.tFaint(Sys.bg, Sys.text)
                            font.pixelSize: Theme.tXs
                            font.weight: Font.DemiBold
                        }
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

            // ---- recent searches: compact chip row under the search box -
            // Latest queries as pills; tapping re-runs the search (Main
            // opens Search). «Clear» empties the persisted history.
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Theme.pillH
                spacing: Theme.s2
                visible: page.searchHistory.length > 0

                ListView {
                    id: histView
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

                        height: Theme.pillH
                        radius: Theme.rPill
                        antialiasing: true
                        width: Math.min(histTxt.implicitWidth + Theme.pillHPad * 2, 260)
                        color: histChipMa.containsMouse ? Sys.accentDim : Theme.sAlt(Sys.bg, Sys.text)
                        scale: !Theme.touch && histChipMa.pressed ? 0.96
                               : (!Theme.touch && histChipMa.containsMouse ? 1.04 : 1)
                        Behavior on scale {
                            NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
                        }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Theme.s2
                            Glyph {
                                Layout.preferredWidth: 12
                                Layout.preferredHeight: 12
                                kind: "search"
                                color: histChipMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                            }
                            Text {
                                id: histTxt
                                text: histChip.modelData.q
                                color: histChipMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                                font.pixelSize: Theme.tSm
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                                width: Math.min(implicitWidth, 220)
                                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                            }
                        }

                        MouseArea {
                            id: histChipMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.searchRequested(histChip.modelData.q) }
                        }
                    }
                }

                Rectangle {
                    Layout.preferredHeight: Theme.pillH
                    implicitWidth: clearHistBtn.implicitWidth + Theme.pillHPad * 2
                    radius: Theme.rPill
                    antialiasing: true
                    color: clearHistMa.containsMouse ? Sys.accentDim : "transparent"
                    scale: !Theme.touch && clearHistMa.pressed ? 0.96
                           : (!Theme.touch && clearHistMa.containsMouse ? 1.04 : 1)
                    Behavior on scale {
                        NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
                    }
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    Text {
                        id: clearHistBtn
                        anchors.centerIn: parent
                        text: qsTr("Borrar historial")
                        color: clearHistMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
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
                text: qsTr("Todavía no hay búsquedas recientes.")
                color: Theme.tDim(Sys.bg, Sys.text)
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
            }

            // ---- RECENT (island with paginated grid) --------------------
            // Max 5 loose songs + 5 recent lists (quickPicks),
            // spread over 3 columns × 5 rows.
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3
                visible: page.viewMode === 0 && page.picksTotal > 0

                // Without a title: the greeting already presides over the
                // page (like in the reference
                // repo). The page arrows are discreet and only
                // exist if there is more than one page of shortcuts.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2
                    visible: page.picksPages > 1

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        Layout.preferredWidth: Theme.pillH
                        Layout.preferredHeight: Theme.pillH
                        radius: Theme.rPill
                        antialiasing: true
                        color: prevMa.containsMouse && page.picksPage > 0
                               ? Sys.accentDim : "transparent"
                        opacity: page.picksPage > 0 ? 1 : 0.35
                        scale: !Theme.touch && prevMa.pressed ? 0.96
                               : (!Theme.touch && prevMa.containsMouse ? 1.04 : 1)
                        Behavior on scale {
                            NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
                        }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 15
                            height: 15
                            kind: "chevron-left"
                            color: prevMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
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
                        antialiasing: true
                        color: nextMa.containsMouse && page.picksPage < page.picksPages - 1
                               ? Sys.accentDim : "transparent"
                        opacity: page.picksPage < page.picksPages - 1 ? 1 : 0.4
                        scale: !Theme.touch && nextMa.pressed ? 0.96
                               : (!Theme.touch && nextMa.containsMouse ? 1.04 : 1)
                        Behavior on scale {
                            NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
                        }
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Glyph {
                            anchors.centerIn: parent
                            width: 15
                            height: 15
                            kind: "chevron-right"
                            color: nextMa.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
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

                // Grid: 3 columns × 2 rows (filled by columns: with
                // vertical flow the GridLayout groups by ROWS, so the
                // wrap point is rows=2). Phone: 3 columns of photo tiles
                // (two columns left only ~2 rows on screen and turned the
                // shortcuts into a gallery).
                GridLayout {
                    Layout.fillWidth: true
                    rows: Theme.touch ? 0 : Math.ceil(page.picksPerPage / page.picksCols)
                    columns: Theme.touch ? 3 : 0
                    flow: Theme.touch ? GridLayout.LeftToRight
                                      : GridLayout.TopToBottom
                    columnSpacing: Theme.touch ? Theme.panelGap : Theme.s3
                    rowSpacing: Theme.s2

                    Repeater {
                        model: page.picksPageItems()

                        delegate: Rectangle {
                            id: pickRow
                            required property var modelData
                            required property int index

                            Layout.fillWidth: true
                            // Phone tile: square photo + two caption lines
                            // below (the row pills stay on the desktop).
                            Layout.preferredHeight: Theme.touch
                                ? (width + Theme.s2 + 50) : 58
                            // Pill always hinted (like in the reference
                            // repo): the shortcut looks accessible
                            // without passing the mouse over it.
                            radius: Theme.rMd
                            antialiasing: true
                            color: pickMouse.containsMouse
                                   ? Theme.alpha(Sys.text, 0.11) : Theme.alpha(Sys.text, 0.055)
                            scale: !Theme.touch && pickMouse.pressed ? 0.96
                                   : (!Theme.touch && pickMouse.containsMouse ? 1.04 : 1)
                            Behavior on scale {
                                NumberAnimation { duration: Theme.fastMs; easing.type: Easing.OutCubic }
                            }
                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                            // Phone: vertical tile (photo on top).
                            ColumnLayout {
                                visible: Theme.touch
                                anchors.fill: parent
                                anchors.margins: Theme.s1
                                spacing: 0

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: width
                                    radius: Theme.rMd
                                    antialiasing: true
                                    color: Theme.sAlt(Sys.bg, Sys.text)
                                    RoundedArt {
                                        anchors.fill: parent
                                        source: pickRow.modelData.thumb || ""
                                        radiusSpec: Theme.rMd
                                    }
                                    Glyph {
                                        anchors.centerIn: parent
                                        width: 22
                                        height: 22
                                        visible: !pickRow.modelData.thumb
                                        kind: pickRow.modelData.kind === "liked"
                                              ? "heart"
                                              : (pickRow.modelData.kind === "playlist"
                                                 ? "list" : "music")
                                        color: pickMouse.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Theme.s1
                                    text: pickRow.modelData.title || ""
                                    color: Sys.text
                                    font.pixelSize: Theme.tSm
                                    font.weight: Font.DemiBold
                                    // Dos lineas: en 3 columnas un titulo de
                                    // lista no cabe en una sola.
                                    wrapMode: Text.Wrap
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: pickRow.modelData.sub || ""
                                    color: Theme.tDim(Sys.bg, Sys.text)
                                    font.pixelSize: Theme.tXs
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }

                            RowLayout {
                                visible: !Theme.touch
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s2
                                anchors.rightMargin: Theme.s2
                                spacing: Theme.s3

                                Rectangle {
                                    Layout.preferredWidth: 42
                                    Layout.preferredHeight: 42
                                    radius: Theme.rMd
                                    antialiasing: true
                                    color: Theme.sAlt(Sys.bg, Sys.text)
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
                                        color: pickMouse.containsMouse ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
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
                                        color: Theme.tDim(Sys.bg, Sys.text)
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
                                // pre-resolve the stream (a click = it sounds right away).
                                onContainsMouseChanged: if (containsMouse
                                        && pickRow.modelData
                                        && pickRow.modelData.kind === "track"
                                        && pickRow.modelData.url)
                                        if (!catalog.metered)
                                            player.prefetchFront(pickRow.modelData.url)
                                onClicked: { if (typeof sfx !== "undefined") sfx.play("tap"); page.openQuickPick(pickRow.modelData, false) }
                            }
                        }
                    }
                }
            }

            // ---- recommendations (radios of the history) — island -------
            // Right after RECENT: it is the closest at hand (in the style
            // of Spotify's «Made for you»).
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3
                visible: page.viewMode === 0 && page.recCardsCache.length > 0

                SectionTitle {
                    Layout.fillWidth: true
                    icon: "disc"
                    text: qsTr("Recomendado para ti")
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
                        cardWidth: page.deckCardWidth
                        title: modelData.title
                        subtitle: modelData.sub
                        icon: modelData.icon
                        badge: modelData.kind === "liked" ? "YT" : "RADIO"
                        // A radio shows the photo of its artist (its face on
                        // YouTube Music), not the cover of the first track.
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

            // ---- YouTube radios — island --------------------------------
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3
                visible: page.viewMode === 0

                SectionTitle {
                    Layout.fillWidth: true
                    icon: "radio"
                    text: qsTr("Radios de YouTube")
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
                        cardWidth: page.deckCardWidth
                        title: modelData.t
                        subtitle: modelData.s
                        icon: modelData.icon
                        badge: "YT"
                        // Every mood radio gets its own hue (see
                        // moodA/moodB).
                        coverA: page.moodA(modelData.t)
                        coverB: page.moodB(modelData.t)
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
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

            // ---- compact list view --------------------------------------
            Island {
                Layout.fillWidth: true
                spacing: Theme.s3
                visible: page.viewMode === 1 && page.listItems.length > 0

                SectionTitle {
                    Layout.fillWidth: true
                    icon: "list"
                    text: qsTr("Inicio")
                }

                // Not interactive: the page Flickable owns the scroll, so
                // wheel and touch keep working over the whole page.
                ListView {
                    Layout.fillWidth: true
                    implicitHeight: contentHeight
                    model: page.listItems
                    reuseItems: true
                    interactive: false
                    clip: false
                    spacing: Theme.s2

                    delegate: Rectangle {
                        id: listRow
                        required property var modelData
                        width: ListView.view.width
                        height: 64
                        radius: Theme.rLg
                        antialiasing: true
                        color: rowMa.containsMouse ? Theme.sAlt(Sys.bg, Sys.text)
                                                   : Theme.sHigh(Sys.bg, Sys.text)

                        Rectangle {
                            id: art
                            x: Theme.s2
                            y: (listRow.height - 48) / 2
                            width: 48
                            height: 48
                            radius: Theme.rMd
                            antialiasing: true
                            gradient: Gradient {
                                GradientStop { position: 0; color: listRow.modelData.a }
                                GradientStop { position: 1; color: listRow.modelData.b }
                            }
                            RoundedArt {
                                anchors.fill: parent
                                source: listRow.modelData.thumb
                                radiusSpec: Theme.rMd
                                opacity: ready ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }
                            }
                            Glyph {
                                anchors.centerIn: parent
                                width: 22
                                height: 22
                                kind: listRow.modelData.icon
                                color: Theme.alpha(Sys.text, 0.6)
                                visible: !listRow.modelData.thumb
                            }
                        }

                        ColumnLayout {
                            anchors.left: art.right
                            anchors.leftMargin: Theme.s3
                            anchors.right: playBtn.left
                            anchors.rightMargin: Theme.s2
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text {
                                Layout.fillWidth: true
                                text: listRow.modelData.title
                                color: Sys.text
                                font.pixelSize: Theme.tBase
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: listRow.modelData.sub
                                color: Theme.tDim(Sys.bg, Sys.text)
                                font.pixelSize: Theme.tSm
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            z: 1
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (typeof sfx !== "undefined") sfx.play("tap")
                                page.openListItem(listRow.modelData, false)
                            }
                        }

                        Rectangle {
                            id: playBtn
                            z: 2
                            anchors.right: menuBtn.left
                            anchors.rightMargin: Theme.s2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 32
                            height: 32
                            radius: Theme.rPill
                            antialiasing: true
                            color: playMa.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                            Glyph {
                                anchors.centerIn: parent
                                width: 14
                                height: 14
                                kind: "play"
                                color: Theme.accentOn(Sys.accent, Sys.bg)
                            }
                            MouseArea {
                                id: playMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof sfx !== "undefined") sfx.play("tap")
                                    page.openListItem(listRow.modelData, true)
                                }
                            }
                        }

                        Rectangle {
                            id: menuBtn
                            z: 2
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.s2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 32
                            height: 32
                            radius: Theme.rPill
                            antialiasing: true
                            color: menuMa.containsMouse ? Sys.accentDim : "transparent"
                            Glyph {
                                anchors.centerIn: parent
                                width: 16
                                height: 16
                                kind: "ellipsis"
                                color: menuMa.containsMouse
                                       ? Theme.accentOn(Sys.accent, Sys.bg)
                                       : Theme.tDim(Sys.bg, Sys.text)
                            }
                            MouseArea {
                                id: menuMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const p = listRow.mapToItem(page,
                                        menuBtn.x + menuBtn.width,
                                        menuBtn.y + menuBtn.height)
                                    page.itemMenuRequested(listRow.modelData, p.x, p.y)
                                }
                            }
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 1 }
        }
    }
}
