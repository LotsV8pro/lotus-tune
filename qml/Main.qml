import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Dialogs
import QtCore
import "theme.js" as Theme

Window {
    id: root

    width: 1320
    height: 860
    minimumWidth: 880
    minimumHeight: 560
    visible: true
    title: "Lotus Tune"
    color: Sys.bg

    Settings {
        category: "window"
        property alias width: root.width
        property alias height: root.height
    }

    // ---- app config (backend `appcfg` context property; guarded until it lands)
    function cfgGet(k) {
        if (typeof appcfg === "undefined")
            return ""
        return String(appcfg.get(k) || "")
    }
    function cfgSet(k, v) {
        if (typeof appcfg === "undefined")
            return
        appcfg.set(k, String(v))
        appcfg.save()
    }
    function cfgLogin(src, a, b, c) {
        if (typeof appcfg === "undefined")
            return
        appcfg.saveLogin(src, String(a || ""), String(b || ""), String(c || ""))
    }
    function hexOk(s) {
        return /^#?[0-9a-fA-F]{6}$/.test(String(s || "").trim())
    }

    // ---- YouTube Music Google login (guarded until the Catalog API lands) ----
    function ytmState() {
        if (typeof catalog.loginState === "undefined")
            return "nologin"                 // backend without the login API yet
        return String(catalog.loginState || "")   // "" idle | "waiting" | "ok" | "error"
    }
    function ytmCode() {
        return (typeof catalog.loginCode !== "undefined") ? String(catalog.loginCode || "") : ""
    }
    function ytmUrl() {
        return (typeof catalog.loginUrl !== "undefined") ? String(catalog.loginUrl || "") : ""
    }
    function ytmError() {
        if (typeof catalog.loginError !== "undefined" && catalog.loginError)
            return String(catalog.loginError)
        return "No se pudo iniciar sesión. Inténtalo de nuevo."
    }
    function ytmOpen() {
        if (root.ytmUrl())
            Qt.openUrlExternally(root.ytmUrl())
    }
    function ytmLogin() {
        if (typeof catalog.loginYTM !== "function") {
            root.toast("Actualiza la app")
            return
        }
        catalog.loginYTM()
    }

    // ---- overlays ------------------------------------------------------
    property bool settingsOpen: false
    property bool launcherOpen: false
    // Remote results of the launcher: typing 3+ characters starts a real
    // search in the active source and the best songs show up in their
    // own block, under "MUSIC". `launcherQ` is the query in flight.
    property var launcherMusic: []
    property string launcherQ: ""
    property bool followSys: true
    property var launcherRows: []

    // ---- new preferences (quality, lyrics, Discord, downloads) ------------
    property bool lyricsEnabled: true
    property bool discordEnabled: false
    // Autoplay: when the queue runs out, YouTube Music is asked for the
    // continuation (a radio seeded with the last track) so the music does
    // not stop. On by default; remembered between sessions.
    property bool autoplayEnabled: true

    // ---- right panel (queue / lyrics) -------------------------------------
    property bool panelOpen: false
    property int panelTab: 0            // 0 = queue, 1 = lyrics

    function openPanel(tab) {
        panelTab = tab
        panelOpen = true
    }
    function togglePanel(tab) {
        if (panelOpen && panelTab === tab)
            panelOpen = false
        else
            openPanel(tab)
    }

    // ---- context menu (right click) ----------------------------------
    property bool ctxOpen: false
    property var ctxItems: []
    property real ctxX: 0
    property real ctxY: 0

    // The focus of the text fields is dropped by itself on an outside
    // click, like on the web: MouseNavFilter does it in C++ (Item's
    // containsMousePressed signal does not exist in Qt 6.12). That way the
    // shortcuts (F, L, M, Space...) do not die by staying "typing" in a
    // search box that was already forgotten.

    function showContextMenu(items, x, y) {
        const out = []
        for (var i = 0; items && i < items.length; i++)
            if (items[i])
                out.push(items[i])
        if (out.length === 0)
            return
        root.ctxItems = out
        root.ctxX = x
        root.ctxY = y
        root.ctxOpen = true
    }
    function showTrackMenu(t, x, y) {
        root.showContextMenu(root.trackMenuItems(t), x, y)
    }
    function showPlaylistMenu(c, x, y) {
        root.showContextMenu(root.playlistMenuItems(c), x, y)
    }

    // Menu (...) of a downloaded list opened as a playlist.
    function showDownloadMenu(folder, name, x, y) {
        const f = String(folder || "")
        const n = String(name || f)
        root.showContextMenu([
            { label: "Reproducir", icon: "play",
              action: function() {
                  const arr = libPage.openDownloadTracks
                  if (arr && arr.length > 0)
                      root.playTracks(arr, 0)
              } },
            { separator: true },
            { label: "Desinstalar descarga", icon: "trash", danger: true,
              action: function() { root.confirmRemoveDownload(f, n) } }
        ], x, y)
    }

    // ---- list editor (create / rename / privacy) ---------------------------
    property bool editorOpen: false
    property bool editorCreate: true
    property string editorId: ""
    property string editorInfoId: ""
    property string editorTitle: ""
    property bool editorPrivate: false
    property string editorVideoId: ""

    function openCreatePlaylist(videoId) {
        root.editorCreate = true
        root.editorId = ""
        root.editorInfoId = ""
        root.editorTitle = ""
        root.editorPrivate = false
        root.editorVideoId = String(videoId || "")
        root.playlistPickerOpen = false
        root.ctxOpen = false
        root.editorOpen = true
    }

    function openEditPlaylist(id, currentTitle) {
        if (!id)
            return
        root.editorCreate = false
        root.editorId = String(id)
        root.editorInfoId = String(id)
        root.editorTitle = String(currentTitle || "")
        root.editorPrivate = false
        root.editorVideoId = ""
        root.ctxOpen = false
        root.editorOpen = true
        catalog.fetchPlaylistInfo(id)
    }

    function submitPlaylistEditor(data) {
        if (!data)
            return
        if (data.create)
            catalog.createPlaylist(data.title, data.isPrivate, data.videoId || "")
        else
            catalog.updatePlaylist(data.id, data.title, data.isPrivate)
    }

    // ---- confirmation (delete list, etc.) -----------------------------
    property bool confirmOpen: false
    property string confirmText: ""
    property string confirmLabel: "Eliminar"
    property var confirmAction: null

    function askConfirm(text, label, action) {
        root.confirmText = String(text || "")
        root.confirmLabel = String(label || "Eliminar")
        root.confirmAction = action
        root.confirmOpen = true
    }

    function runConfirm() {
        const fn = root.confirmAction
        root.confirmOpen = false
        root.confirmAction = null
        if (typeof fn === "function")
            fn()
    }

    function confirmDeletePlaylist(id, title) {
        root.editorOpen = false
        root.askConfirm("¿Eliminar la lista «" + (title || "") + "»? Esto no se puede deshacer.",
                        "Eliminar", function() {
                            if (catalog.openPlaylistId === id)
                                libPage.showPlaylists()
                            catalog.deletePlaylist(id)
                        })
    }

    // ---- clipboard (copy link) ---------------------------------------------
    function copyToClipboard(text) {
        const s = String(text || "")
        if (!s)
            return
        clip.text = s
        clip.selectAll()
        clip.copy()
        root.toast("Enlace copiado")
    }

    // ---- queue: play next / add to the queue --------------
    function queueRow(t) {
        t = trackObj(t)
        return { title: t.title, artist: t.artist, url: t.url,
                 duration: t.duration, source: t.source, thumb: t.thumb,
                 cover: t.cover, album: t.album, liked: t.liked, setId: t.setId }
    }

    function playNextTrack(t) {
        if (!t || !String(t.url || ""))
            return
        if (queue.count === 0 || root.queueIndex < 0) {
            root.playTracks([t], 0)
            return
        }
        queue.insert(Math.min(queue.count, root.queueIndex + 1), root.queueRow(t))
        root.toast("Se reproducirá a continuación")
    }

    function enqueueTrack(t) {
        if (!t || !String(t.url || ""))
            return
        if (queue.count === 0) {
            root.playTracks([t], 0)
            return
        }
        root.autoplayRadioPending = false   // there is already a queue set by hand
        root.radioResumePending = false
        queue.append(root.queueRow(t))
        root.toast("Añadido a la cola")
        root.saveSession()
    }

    // Plays a list in random order (the "shuffle" button of the hero).
    function shuffleTracks(list) {
        const arr = []
        if (list)
            for (var i = 0; i < list.length; i++)
                arr.push(list[i])
        for (var j = arr.length - 1; j > 0; j--) {
            const k = Math.floor(Math.random() * (j + 1))
            const tmp = arr[j]
            arr[j] = arr[k]
            arr[k] = tmp
        }
        if (arr.length > 0)
            root.playTracks(arr, 0)
    }

    // ---- menus: which entries each kind of item has -------------------
    // Track (results, lists, queue, downloads). The YouTube actions only
    // show if there is a session and the track has a videoId.
    function trackMenuItems(t) {
        t = t || {}
        const url = String(t.url || "")
        const vid = root.videoIdOf(url)
        const canYt = (catalog.loginState === "ok") && vid !== ""
        const liked = (catalog.likedReady === true) ? catalog.isLiked(url)
                                                    : (t.liked === true)
        const out = []
        out.push({ label: "Reproducir", icon: "play",
                   action: function() { root.playTracks([t], 0) } })
        // Radio in YouTube Music's style (YouTube tracks only): the one of
        // the song itself and the one of the artist, each seeded with its
        // top track.
        if (vid !== "") {
            out.push({ label: "Escuchar radio de esta canción", icon: "radio",
                       action: function() { root.startSongRadio(t) } })
            const artistName = String(t.artist || "")
            if (artistName)
                out.push({ label: "Radio de " + artistName, icon: "radio",
                           action: function() { root.startArtistRadio(t) } })
        }
        if (canYt)
            out.push({ label: "Añadir a lista de reproducción…", icon: "plus",
                       action: function() { root.openPlaylistPicker(vid) } })
        if (canYt)
            out.push({ label: liked ? "Quitar de la biblioteca"
                                    : "Añadir a la biblioteca",
                       icon: liked ? "heart" : "heart-outline",
                       checked: liked,
                       action: function() { catalog.toggleLiked(url, liked) } })
        if (canYt)
            out.push({ separator: true })
        out.push({ label: "Reproducir a continuación", icon: "next",
                   action: function() { root.playNextTrack(t) } })
        out.push({ label: "Añadir a la cola", icon: "queue",
                   action: function() { root.enqueueTrack(t) } })
        // Own list open: remove the track and reorder it. It is pushed to
        // YouTube Music. It needs the list to belong to the user and the
        // track to carry its setVideoId (it came from the list through the
        // fast path).
        const plId = String(catalog.openPlaylistId || "")
        const plSet = String(t.setId || "")
        const plOwned = (typeof libPage !== "undefined") ? libPage.currentOwned() : false
        if (plId !== "" && plSet !== "" && plOwned) {
            out.push({ separator: true })
            out.push({ label: "Quitar de esta lista", icon: "trash", danger: true,
                       action: function() { root.removeTrackFromOpenPlaylist(t) } })
            out.push({ label: "Mover arriba", icon: "arrow-up",
                       action: function() { catalog.moveOpenPlaylistTrack(plSet, -1) } })
            out.push({ label: "Mover abajo", icon: "arrow-down",
                       action: function() { catalog.moveOpenPlaylistTrack(plSet, 1) } })
        }
        if (String(t.artist || "")) {
            out.push({ separator: true })
            out.push({ label: "Buscar el artista", icon: "search",
                       action: function() {
                           root.navTo("search")
                           searchPage.startSearch(String(t.artist || ""))
                       } })
        }
        if (url) {
            if (!String(t.artist || ""))
                out.push({ separator: true })
            out.push({ label: "Copiar enlace", icon: "link",
                       action: function() { root.copyToClipboard(url) } })
        }
        // Downloaded track inside a list: allows uninstalling the whole
        // list (it deletes the download folder).
        if (String(t.source || "") === "local" && String(t.folder || "")) {
            out.push({ separator: true })
            out.push({ label: "Desinstalar descarga", icon: "trash", danger: true,
                       action: function() {
                           root.confirmRemoveDownload(String(t.folder || ""),
                                                      String(t.folder || ""))
                       } })
        }
        return out
    }

    // List (library cover).
    function playlistMenuItems(c) {
        c = c || {}
        const url = String(c.url || "")
        const owned = (c.owned === true) && (catalog.loginState === "ok")
        const out = []
        out.push({ label: "Reproducir", icon: "play",
                   action: function() { libPage.activateCover(c, true) } })
        out.push({ label: "Abrir", icon: "list",
                   action: function() { libPage.activateCover(c, false) } })
        if (owned || url) {
            out.push({ separator: true })
        }
        if (owned)
            out.push({ label: "Editar lista…", icon: "pencil",
                       action: function() { root.openEditPlaylist(c.id, c.name) } })
        if (owned)
            out.push({ label: "Eliminar lista", icon: "trash", danger: true,
                       action: function() { root.confirmDeletePlaylist(c.id, c.name) } })
        if (url)
            out.push({ label: "Copiar enlace", icon: "link",
                       action: function() { root.copyToClipboard(url) } })
        // If the list is downloaded it can be uninstalled (it deletes the
        // files).
        const dlFolder = root.downloadedFolderFor(url, c.name)
        if (dlFolder) {
            out.push({ separator: true })
            out.push({ label: "Desinstalar descarga", icon: "trash", danger: true,
                       action: function() { root.confirmRemoveDownload(dlFolder, c.name) } })
        }
        return out
    }

    // Download folder (first level) that belongs to a list, matched by its
    // URL (metadata) or, as a fallback, by its sanitised name.
    function downloadedFolderFor(url, name) {
        if (typeof downloads === "undefined")
            return ""
        const fs = downloads.folders
        const u = String(url || "")
        if (u !== "") {
            for (var i = 0; i < fs.length; i++)
                if (String(fs[i].url || "") === u)
                    return String(fs[i].folder || "")
        }
        const nm = String(name || "")
        if (nm !== "") {
            const want = downloads.listFolderName(nm)
            for (var j = 0; j < fs.length; j++)
                if (String(fs[j].folder || "") === want)
                    return String(fs[j].folder || "")
        }
        return ""
    }

    function confirmRemoveDownload(folder, name) {
        const f = String(folder || "")
        if (!f)
            return
        root.askConfirm("¿Desinstalar la descarga de «" + (name || f)
                        + "»? Se borrarán los archivos descargados.",
                        "Desinstalar", function() {
                            if (typeof libPage !== "undefined"
                                    && libPage.openDownloadFolder === f)
                                libPage.openDownloadFolder = ""
                            if (typeof downloads !== "undefined")
                                downloads.removeList(f)
                            root.toast("Descarga desinstalada")
                        })
    }

    // List saved in the local library (side rail): play, open, copy link
    // and remove it from the library.
    function savedPlaylistMenuItems(item, index) {
        item = item || {}
        const out = [
            { label: "Reproducir", icon: "play",
              action: function() { root.beginOpenList(true); catalog.openPlaylist(index) } },
            { label: "Abrir", icon: "list",
              action: function() { root.beginOpenList(false); catalog.openPlaylist(index) } }
        ]
        if (item.url)
            out.push({ separator: true })
        if (item.url)
            out.push({ label: "Copiar enlace", icon: "link",
                       action: function() { root.copyToClipboard(item.url) } })
        out.push({ separator: true })
        out.push({ label: "Quitar de la biblioteca", icon: "trash", danger: true,
                   action: function() { catalog.removePlaylist(index) } })
        return out
    }
    TextEdit {
        id: clip
        width: 1
        height: 1
        opacity: 0
    }

    function activeSourceName() {
        for (var i = 0; i < sources.list.length; i++)
            if (sources.list[i].id === sources.activeId)
                return sources.list[i].name
        return ""
    }
    // Active destination of the side rail. The "library" page covers two
    // entries: "Library" (lists/collection) and "Downloads" (local
    // source or the Downloaded tab). Without this, pressing "Downloads"
    // lit up "Library" and the rail entry looked like it did nothing.
    function activeNavId() {
        if (page !== "library")
            return page
        if (libPage.showingTracks)
            // Downloaded list opened as a playlist: highlights
            // "Downloads". The "Liked" list (LM) open highlights its
            // own rail entry.
            return libPage.localPlaylistOpen ? "downloads"
                 : (catalog.openPlaylistId === "LM" ? "liked" : "library")
        if (libPage.libraryTab === 4)
            return "downloads"
        return "library"
    }

    function pageTitle() {
        if (page === "search")
            return "Buscar"
        if (page === "library")
            // Inside a list/album the title is the list's: the click goes
            // straight to the content, without passing through the Library
            // cover.
            return (libPage.showingTracks && libPage.viewTitle())
                   ? libPage.viewTitle() : "Biblioteca"
        return "Inicio"
    }
    function pageSubtitle() {
        if (root.listLoading)
            return "Cargando la lista…"
        if (page === "search")
            return activeSourceName() ? "Buscando en " + activeSourceName() : ""
        if (page === "library")
            return activeSourceName() ? "Fuente activa: " + activeSourceName() : "Tus listas y descargas"
        return ""
    }

    function toggleSettings() { closeLauncher(); settingsOpen = !settingsOpen }
    // Closes the launcher for real: the focus must leave the field ALWAYS.
    // If it stays, `typing()` keeps returning true and the window
    // shortcuts (F, L, Space, M, arrows...) stay dead until the launcher
    // is opened and closed again the right way. That is why EVERY exit of
    // the launcher goes through here.
    function closeLauncher() {
        launcherOpen = false
        launcherMusic = []
        launcherQ = ""
        launcherSearch.stop()
        if (launchInput)
            launchInput.focus = false
    }
    function toggleLauncher() {
        settingsOpen = false
        if (!launcherOpen) {
            root.buildLauncher(launchInput && launchInput.text)
            launcherOpen = true
            // The focus must go to the field: that way typing() is true
            // and the shortcuts (F, Space, arrows...) do not fire while
            // typing.
            if (launchInput)
                launchInput.forceActiveFocus()
            if (root.qaLauncherSearch.length > 0) {
                launchInput.text = root.qaLauncherSearch
                root.qaLauncherSearch = ""
            }
            if (launchInput.text.trim().length >= 3)
                launcherSearch.restart()
        } else {
            closeLauncher()
        }
    }

    // ---- keyboard -------------------------------------------------------
    // true while the focus is in a text field (so Space, arrows, etc. are
    // not stolen while typing).
    function typing() {
        var f = root.activeFocusItem
        if (!f)
            return false
        var s = String(f)
        return s.indexOf("TextInput") >= 0 || s.indexOf("TextField") >= 0
                || s.indexOf("TextArea") >= 0 || s.indexOf("TextEdit") >= 0
    }

    property bool fullscreen: false
    function toggleFullscreen() {
        fullscreen = !fullscreen
        root.visibility = fullscreen ? Window.FullScreen : Window.Windowed
    }

    // Opens the lyrics fullscreen (cinema mode). If the window was not
    // already fullscreen in the compositor, this one only covers the app
    // window: in niri the real "fullscreen" is the compositor's, and the
    // overlay already covers the whole window.
    function openFullscreenLyrics() {
        if (!root.currentTitle) {
            root.toast("No hay ninguna canción sonando")
            return
        }
        // The cinema mode takes the whole window; there is only one
        // fullscreen lyrics view: the two column one.
        root.fsLyricsOpen = true
    }
    // Toggles the cinema mode (same logic for L, F and Ctrl+L).
    function toggleFullscreenLyrics() {
        if (root.fsLyricsOpen)
            root.fsLyricsOpen = false
        else
            root.openFullscreenLyrics()
    }
    function closeFullscreenLyrics() {
        root.fsLyricsOpen = false
    }

    // ---- navigation with a stack ("back") --------------------------------
    // Simple page stack: opening a list/album stores the page you came
    // from (usually Home), so Esc or the top bar's "back" button go
    // there and not to the Library cover.
    property var navStack: []
    // "Forward" stack (the mouse side button): it fills when going back
    // and empties as soon as you navigate somewhere else.
    property var forwardStack: []

    // Current navigable state (page + whether it is the library tracks
    // view).
    function curState() {
        return { p: page,
                 t: (page === "library" ? libPage.showingTracks : false),
                 f: (page === "library" ? libPage.openDownloadFolder : "") }
    }
    function applyState(s) {
        if (!s) return
        page = s.p
        if (s.p === "library") {
            libPage.openDownloadFolder = String(s.f || "")
            libPage.showingTracks = !!s.t
        }
    }

    // Navigates to `p` storing the current page in the stack (force: store
    // even if it is the same page, e.g. Library -> tracks view).
    function pushPage(p, force) {
        if (p !== page || force) {
            let s = navStack.concat([curState()])
            if (s.length > 12)
                s = s.slice(s.length - 12)
            navStack = s
            forwardStack = []
        }
        page = p
    }

    // Goes back to the previous page. Returns false if there is nothing
    // behind.
    function navBack() {
        if (navStack.length === 0)
            return false
        const prev = navStack[navStack.length - 1]
        navStack = navStack.slice(0, -1)
        forwardStack = forwardStack.concat([curState()])
        applyState(prev)
        return true
    }

    // Goes to the next page (the mouse "forward" side button).
    function navForward() {
        if (forwardStack.length === 0)
            return false
        const nxt = forwardStack[forwardStack.length - 1]
        forwardStack = forwardStack.slice(0, -1)
        navStack = navStack.concat([curState()])
        applyState(nxt)
        return true
    }

    // Mouse side buttons (4 = back, 5 = forward): the window's event
    // filter calls them (MouseNavFilter in main.cpp).
    function mouseNavBack() {
        if (typeof sfx !== "undefined") sfx.play("tap")
        goBack()
    }
    function mouseNavForward() {
        if (typeof sfx !== "undefined") sfx.play("tap")
        navForward()
    }

    // Root navigation (side rail / Home): we store where we came from.
    function navTo(p) {
        if (p === "library")
            libPage.showPlaylists()
        pushPage(p)
    }

    // Esc "back": closes overlays, the side panel, leaves fullscreen or
    // - at the end - goes back to the previous page (a list/album ->
    // Home).
    function goBack() {
        if (root.ctxOpen) { root.ctxOpen = false; return }
        if (root.fsLyricsOpen) { root.fsLyricsOpen = false; return }
        if (root.confirmOpen) { root.confirmOpen = false; return }
        if (root.editorOpen) { root.editorOpen = false; return }
        if (root.playlistPickerOpen) { root.playlistPickerOpen = false; return }
        if (root.launcherOpen) { root.closeLauncher(); return }
        if (root.settingsOpen) { root.settingsOpen = false; return }
        if (root.artistOpen) { root.closeArtist(); return }
        if (root.panelOpen) { root.panelOpen = false; return }
        if (root.fullscreen) { root.toggleFullscreen(); return }
        if (navBack())
            return
        // Fallback: a list/album with no back stack goes to Home.
        if (page === "library" && libPage.showingTracks) {
            libPage.showPlaylists()
            page = "home"
        }
    }

    // When asking for a list: it marks the load as running and decides
    // whether, once the tracks arrive, they have to be played (play
    // button) or only opened (click on the cover / the list). Opening does
    // NOT play.
    function beginOpenList(play) {
        pendingPlay = !!play
        listLoading = true
        toast(play ? "Cargando la lista para reproducir…" : "Cargando la lista…")
    }

    // Shows the tracks view of the open list. It is called when the
    // tracks are ALREADY loaded: a single jump to the album, without
    // going through the Library cover.
    function openTracksView() {
        const from = page
        if (!(page === "library" && libPage.showingTracks))
            pushPage("library", true)   // it stores the page you came from
        libPage.openTracks()
    }

    property int preMuteVolume: 70
    function toggleMute() {
        if (player.volume > 0) {
            root.preMuteVolume = player.volume
            player.setVolume(0)
        } else {
            player.setVolume(root.preMuteVolume > 0 ? root.preMuteVolume : 70)
        }
    }
    function nudgeVolume(delta) {
        player.setVolume(Math.max(0, Math.min(150, player.volume + delta)))
    }

    function pickSource(id) {
        sources.select(id)
        for (var i = 0; i < sources.list.length; i++) {
            if (sources.list[i].id === id) {
                if (sources.list[i].status !== "ready")
                    root.toast(sources.list[i].name + ": " + sources.list[i].note)
                else
                    root.toast("Fuente activa: " + sources.list[i].name)
                return
            }
        }
    }

    Shortcut {
        sequence: "Ctrl+,"
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.toggleSettings() }
    }
    Shortcut {
        sequence: "Ctrl+Space"
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.toggleLauncher() }
    }
    // Space: play / pause (unless typing in a field).
    Shortcut {
        sequence: "Space"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("play"); if (root.currentTitle) root.togglePlay() }
    }
    // Arrows: ±5 s of seeking; Ctrl+arrows or Media: previous/next track.
    Shortcut {
        sequence: "Right"
        enabled: !root.typing() && root.currentTitle !== ""
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); player.seek(Math.min(player.position + 5, player.duration)) }
    }
    Shortcut {
        sequence: "Left"
        enabled: !root.typing() && root.currentTitle !== ""
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); player.seek(Math.max(0, player.position - 5)) }
    }
    Shortcut {
        sequence: "Ctrl+Right"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.next() }
    }
    Shortcut {
        sequence: "Ctrl+Left"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.prev() }
    }
    // Volume with up/down; M mutes.
    Shortcut {
        sequence: "Up"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.nudgeVolume(5) }
    }
    Shortcut {
        sequence: "Down"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.nudgeVolume(-5) }
    }
    Shortcut {
        sequence: "M"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.toggleMute() }
    }
    Shortcut {
        sequence: "S"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("toggle"); root.toggleShuffle() }
    }
    Shortcut {
        sequence: "R"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("toggle"); root.toggleRepeat() }
    }
    // L, F and Ctrl+L: fullscreen lyrics, the two column cinema mode.
    // Q: queue; F11: fullscreen. (The old "Now playing" with the cover
    // on top and the lyrics below is gone: the cinema mode replaces
    // it.)
    Shortcut {
        sequence: "L"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.toggleFullscreenLyrics() }
    }
    Shortcut {
        sequence: "Q"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.togglePanel(0) }
    }
    Shortcut {
        sequence: "F11"
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.toggleFullscreen() }
    }
    // F: two column cinema mode, as long as it is not being typed in a
    // text field (searches, URLs...). Fullscreen stays on F11 (and
    // Mod+Shift+F at the compositor level).
    Shortcut {
        sequence: "F"
        enabled: !root.typing()
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.toggleFullscreenLyrics() }
    }
    // Ctrl+L: same as L and F. This one IS allowed with the search box
    // focused: Ctrl+L writes nothing, so it does not interfere.
    Shortcut {
        sequence: "Ctrl+L"
        enabled: true
        onActivated: {
            if (typeof sfx !== "undefined") sfx.play("tap")
            root.toggleFullscreenLyrics()
        }
    }

    // ---- launcher data ---------------------------------------------------
    function launcherActivate(row) {
        if (!row)
            return
        if (row.kind === "source") {
            if (row.locked) {
                closeLauncher()
                settingsOpen = true
            } else {
                // The search already goes to every source: here only the
                // default source is changed. It does NOT redirect to Search.
                sources.select(row.id)
                closeLauncher()
            }
        } else if (row.kind === "playlist") {
            root.beginOpenList(false)
            catalog.openPlaylist(row.i)
            closeLauncher()
        } else if (row.kind === "recent") {
            root.playTracks(catalog.recent, row.i)
            closeLauncher()
        } else if (row.kind === "music") {
            // Queues the pressed result and the ones after it in the SAME
            // source, like a normal list (the group headers are not
            // tracks).
            const list = []
            for (let i = 0; i < launcherMusic.length; i++) {
                const e = launcherMusic[i]
                if (e.h)
                    continue
                if (e.src && row.src && e.src !== row.src)
                    continue
                list.push(e)
            }
            let idx = 0
            for (let i = 0; i < launcherMusic.length; i++) {
                const e = launcherMusic[i]
                if (e.h)
                    continue
                if (e.src && row.src && e.src !== row.src)
                    continue
                if (e.i === row.i) {
                    idx = list.length
                    break
                }
            }
            root.playTracks(list, idx)
            closeLauncher()
        }
    }

    function buildLauncher(q) {
        q = String(q || "").trim().toLowerCase()
        const out = []
        const l = sources.list
        for (let i = 0; i < l.length; i++) {
            const s = l[i]
            if (q && s.name.toLowerCase().indexOf(q) < 0)
                continue
            out.push({ h: false, kind: "source", id: s.id, t: s.name,
                       s: s.status === "ready" ? "Fuente por defecto" : "Bloqueada · abre Ajustes",
                       locked: s.status !== "ready" })
        }
        if (out.length && out[0].kind === "source")
            out.unshift({ h: true, t: "FUENTES" })
        let plFirst = -1
        for (let i = 0; i < catalog.playlists.length; i++) {
            const p = catalog.playlists[i]
            if (q && (p.name || "").toLowerCase().indexOf(q) < 0)
                continue
            if (plFirst < 0) {
                out.push({ h: true, t: "PLAYLISTS" })
                plFirst = out.length
            }
            out.push({ h: false, kind: "playlist", i: i, t: p.name || "Sin nombre", s: p.url || "" })
        }
        let recFirst = -1
        for (let i = 0; i < catalog.recent.length; i++) {
            const r = catalog.recent[i]
            if (q && (r.title || "").toLowerCase().indexOf(q) < 0)
                continue
            if (recFirst < 0) {
                out.push({ h: true, t: "RECIENTES" })
                recFirst = out.length
            }
            out.push({ h: false, kind: "recent", i: i, t: r.title || "", s: r.artist || "" })
        }
        if (q) {
            // MUSIC: the results of the search across ALL the sources,
            // grouped by source (YouTube Music first). Every group has
            // its own header.
            for (let i = 0; i < launcherMusic.length; i++) {
                const g = launcherMusic[i]
                if (g.h) {
                    out.push({ h: true, t: String(g.t || "").toUpperCase() })
                    continue
                }
                out.push({ h: false, kind: "music", i: g.i,
                           t: g.title || "", s: g.artist || "" })
            }
        }
        launcherRows = out
    }

    // Launcher debounce: 450 ms after the last keystroke the remote
    // search is fired (it avoids one API call per letter).
    Timer {
        id: launcherSearch
        interval: 450
        onTriggered: {
            if (!root.launcherOpen)
                return
            const q = launchInput.text.trim()
            if (q.length < 3) {
                root.launcherMusic = []
                return
            }
            root.launcherQ = q
            // All the sources at once: there is no need to pick one
            // before searching (and the launcher does not redirect to
            // Search: it searches right here).
            catalog.searchAll(q)
        }
    }

    // The results of that search arrive: we keep the first songs of each
    // source (podcasts and lists are dropped) and group them by source,
    // with a header for each.
    Connections {
        target: catalog
        function onChanged() {
            if (!root.launcherOpen || root.launcherQ.length < 3)
                return
            if (String(catalog.resultsQuery) !== root.launcherQ)
                return
            if (catalog.busy)
                return
            const groups = catalog.resultsBySource
            const out = []
            for (let gi = 0; gi < groups.length; gi++) {
                const g = groups[gi]
                const items = g.items || []
                if (items.length === 0)
                    continue
                const songs = []
                for (let i = 0; i < items.length && songs.length < 5; i++) {
                    const e = items[i]
                    // The multi source search returns the NORMALISED tracks
                    // (title/artist/thumb), not the old "channel" format: the
                    // launcher used to filter by channel and it dropped
                    // EVERY result, so it always said "no results".
                    const title = String(e.title || "")
                    if (title.length === 0)
                        continue
                    songs.push({ title: title, artist: String(e.artist || ""),
                                 thumb: e.thumbnail || e.thumb || "",
                                 url: e.url || "" })
                }
                if (!songs.length)
                    continue
                out.push({ h: true, t: String(g.name || "") })
                for (let i = 0; i < songs.length; i++)
                    out.push({ h: false, i: i, title: songs[i].title,
                               artist: songs[i].artist, thumb: songs[i].thumb,
                               url: songs[i].url, src: String(g.id || "") })
            }
            root.launcherMusic = out
            if (launchInput)
                root.buildLauncher(launchInput.text)
        }
    }

    // ---- navigation ------------------------------------------------------
    property string page: "home"
    // QA query (--search=): it is fired on startup.
    property string cliSearch: ""

    function pageIndex(p) {
        return p === "search" ? 1 : (p === "library" ? 2 : 0)
    }

    // QA: `--page=home|search|library`, `--src=ytm|soundcloud|spotify|tidal`,
    //     `--settings`, `--launcher`, `--accent=#rrggbb` ('' clears the override)
    Component.onCompleted: {
        // The new versions of the app are looked up in the repository.
        if (typeof updates !== "undefined")
            updateTimer.start()
        const args = Qt.application.arguments
        let cliOpen = false
        for (let i = 1; i < args.length; i++) {
            const a = args[i]
            if (a.startsWith("--page=")) {
                const p = a.substring(7)
                if (p === "home" || p === "search" || p === "library")
                    page = p
            } else if (a.startsWith("--src=")) {
                const s = a.substring(6)
                for (let j = 0; j < sources.list.length; j++)
                    if (sources.list[j].id === s)
                        sources.select(s)
            } else if (a === "--settings") {
                settingsOpen = true
            } else if (a === "--launcher") {
                root.toggleLauncher()
            } else if (a.startsWith("--search=")) {
                // QA: opens Search and runs the query (multi source).
                const q = a.substring(9)
                page = "search"
                cliSearch = q
            } else if (a.startsWith("--panel=")) {
                const t = a.substring(8)
                root.openPanel(t === "letras" || t === "lyrics" ? 1 : 0)
            } else if (a.startsWith("--launchersearch=")) {
                // QA: opens the launcher with a query already typed (the
                // launcher search is a different path from the page one).
                root.qaLauncherSearch = a.substring(17)
            } else if (a === "--fslyrics" || a === "--nowplaying") {
                // QA: opens the fullscreen lyrics directly.
                // (--nowplaying is the old name of the same mode.)
                // It waits for the track to be there: the cinema mode needs
                // one to open.
                root.qaFsLyrics = true
            } else if (a === "--shuffle") {
                // QA: turns the shuffle on before loading anything.
                shuffle = true
                mpris.setShuffle(true)
            } else if (a === "--autoplay") {
                // QA: plays the list once it is loaded (play button).
                pendingPlay = true
            } else if (a.startsWith("--accent=")) {
                cfgSet("accent", a.substring(9))
            } else if (a.startsWith("--openurl=")) {
                cliOpen = true   // QA: it does not restore the session, it opens this URL
                Qt.callLater(function() { catalog.openUrl(a.substring(10), "selftest") })
            }
        }
        // The QA launcher query: the launcher is opened with it typed in.
        if (root.qaLauncherSearch.length > 0)
            Qt.callLater(root.toggleLauncher)
        // The QA query is fired once the page is already mounted.
        if (cliSearch.length > 0)
            Qt.callLater(function() { catalog.searchAll(cliSearch) })
        followSys = cfgGet("followSystem") !== "false"

        // Player, lyrics, Discord and download preferences.
        lyricsEnabled = cfgGet("lyricsEnabled") !== "false"
        discordEnabled = cfgGet("discordRpc") === "true"
        autoplayEnabled = cfgGet("autoplay") !== "false"
        Sys.dynamicBg = cfgGet("dynamicBg") !== "false"
        // First wash computation: if the restored session already brings a
        // track, its thumbnail is blurred now (if not, the track change will
        // do it).
        if (Sys.dynamicBg && root.currentThumb)
            wash.setSource(root.currentThumb)
        // Repeat mode (0/1/2) and word level karaoke. They are pushed to
        // the backend so the published state starts with the right value.
        {
            const rm = parseInt(cfgGet("repeatMode"))
            root.repeatMode = (rm >= 1 && rm <= 2) ? rm : 0
            mpris.setLoopStatus(root.repeatMode === 1 ? "Playlist"
                                  : root.repeatMode === 2 ? "Track" : "None")
        }
        root.karaokeWords = cfgGet("karaokeWords") !== "false"
        if (typeof lyrics !== "undefined")
            lyrics.karaoke = root.karaokeWords
        // Saved compensation: the backend publishes it as is so the
        // desktop widgets match the audio from the first second.
        {
            const lo = parseFloat(cfgGet("lyricsOffset"))
            if (!isNaN(lo) && typeof lyrics !== "undefined")
                lyrics.setPublishedOffset(Math.round(lo * 4) / 4)
        }
        player.setQuality(cfgGet("audioQuality") || "max")
        // The app's Client ID is already embedded in the backend; the user
        // only cares about the on/off switch.
        discord.configure(discordEnabled, "")
        if (cfgGet("downloadFolder"))
            downloads.setFolder(cfgGet("downloadFolder"))

        // Restores the last session (queue + track PAUSED + volume + repeat).
        root.restoreSession(cliOpen)
    }

    // Esc "back": closes overlays/panel or leaves fullscreen.
    Shortcut {
        sequence: "Escape"
        onActivated: { if (typeof sfx !== "undefined") sfx.play("tap"); root.goBack() }
    }

    // ---- mouse side buttons (4 = back, 5 = forward) --------------------
    // It goes to the back (z:-1) and only accepts those two buttons, so
    // it does not bother the rest of the interface: normal clicks reach
    // the items on top.
    MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.BackButton | Qt.ForwardButton
        onPressed: (mouse) => {
            if (mouse.button === Qt.BackButton)
                root.mouseNavBack()
            else if (mouse.button === Qt.ForwardButton)
                root.mouseNavForward()
        }
    }

    // ---- queue -----------------------------------------------------------
    // The `queue` model is ALWAYS the real playback order. With the
    // shuffle on it is shuffled when the list is loaded and
    // `next()`/`prev()` just walk the model up and down, so the queue in
    // the side panel shows exactly "how the playback will go".
    ListModel { id: queue }
    property int queueIndex: -1
    property string currentTitle: ""
    property string currentArtist: ""
    property string currentThumb: ""
    // The background wash is recomputed with the current track's
    // thumbnail: the backend downloads it, blurs it in the CPU and
    // publishes it through its provider ("image://wash"). Without the
    // dynamic background no network is used.
    onCurrentThumbChanged: if (Sys.dynamicBg) wash.setSource(root.currentThumb)
    // YouTube videoId of the playing track ("" if it does not apply).
    property string currentVideoId: ""
    // Local "liked" state of the current track (refreshed on change).
    property bool currentLiked: false
    // setVideoId (row in its playlist) if the track was opened from a YTM list.
    property string currentSetId: ""
    // List picker for "add to list".
    property bool playlistPickerOpen: false
    // Target track of the picker (+ button of a row or of the bottom bar).
    property string pickerVideoId: ""
    property bool shuffle: false
    // Repeat in three states (button cycle): 0 = off, 1 = repeat the LIST
    // (when it runs out it goes back to the first track), 2 = repeat the
    // current TRACK. It used to be a boolean that only meant "repeat the
    // track".
    property int repeatMode: 0
    // Fullscreen lyrics (cinema mode, Liner style): an overlay on top of
    // everything.
    property bool fsLyricsOpen: false
    // QA: open the cinema mode as soon as there is a track playing.
    property bool qaFsLyrics: false
    // QA: open the launcher with a query already in the field.
    property string qaLauncherSearch: ""

    Timer {
        running: root.qaFsLyrics && root.currentTitle.length > 0
        interval: 400
        repeat: false
        onTriggered: { root.qaFsLyrics = false; root.openFullscreenLyrics() }
    }
    // Word level karaoke for the views that bring word level timings; if
    // it is off (or there are no timings) the whole line lights up when
    // it is sung.
    property bool karaokeWords: true
    // Lyrics compensation in seconds (+ advances, - delays). The backend
    // publishes it for the widgets; the views share it that way.
    // The compensation that is applied: the backend is the one that holds
    // it (the view of the lyrics and the settings write there).
    readonly property real lyricsOffset: (typeof lyrics !== "undefined")
        ? Number(lyrics.offset || 0) : 0
    // Original order of the loaded list (to restore it when the shuffle is
    // turned off).
    property var originalOrder: []
    // Does the queue already reflect the shuffled order?
    property bool queueShuffled: false
    // A list is loading / it has to be played as soon as it arrives.
    property bool listLoading: false
    property bool pendingPlay: false
    // Avoids repeating the lyrics request for the same track+duration.
    property string lyricsKey: ""
    // Avoids resending the MPRIS/Discord metadata on every position
    // tick.
    property string metaKey: ""
    // ---- persistent session (restored PAUSED on startup) ---------------
    // sessionLoaded avoids saving before the session has been restored.
    property bool sessionLoaded: false
    // Saved volume waiting to be applied when mpv is ready (-1 = none).
    property int pendingVolume: -1
    // Is a YouTube Music radio/autoplay on the way for the current track?
    property bool autoplayRadioPending: false
    property string autoplayRadioSeed: ""
    // The queue ran out while waiting for that radio: when it arrives the
    // playback has to start with the first new track (not just add it to
    // the queue).
    property bool radioResumePending: false
    // Radio asked by hand from the track menu (not by autoplay): the
    // queue grows the same way, but nothing is resumed when the seed
    // ends. The retry lives in manualRadioTimer: fetchRadio is
    // best-effort and it is ignored while the catalogue is still busy
    // with the previous request.
    property bool manualRadioPending: false
    property string manualRadioSeed: ""
    // Name of the artist whose radio is being built ("Radio of X" menu);
    // empty when no request is running.
    property string artistRadioPending: ""
    // Attempts made for the manual radio request (see tryManualRadio).
    property int manualRadioTries: 0
    // ---- replacing a failed track ----------------------------------------
    // A YouTube track may come from a list whose video no longer exists
    // (deleted, blocked): after the engine's retries another version of
    // the SAME song is looked up in YouTube Music and it replaces the
    // row. If there is none, it moves on with a notice. It is only tried
    // once per track.
    property string swapVideoId: ""

    // "Play radio of this song": the track plays right away and the radio
    // arrives as "up next" entries. If the autoplay is on, playTracks
    // already asks for the radio with that same seed; if not, we ask for
    // it explicitly and retry it while the catalogue is busy.
    function startSongRadio(t) {
        const vid = root.videoIdOf(String((t || {}).url || ""))
        if (!vid)
            return
        root.playTracks([t], 0)
        if (!root.autoplayEnabled)
            root.requestManualRadio(vid)
    }

    // "Radio of the artist": first their main track has to be resolved
    // (the most played one), which sounds as the seed, and then their
    // radio arrives.
    function startArtistRadio(t) {
        const name = String((t || {}).artist || "")
        if (!name)
            return
        root.artistRadioPending = name
        root.toast("Montando la radio de " + name + "…")
        catalog.resolveArtistRadio(name)
    }

    // Request (with retry) of the radio of a seed already in the queue.
    function requestManualRadio(vid) {
        root.manualRadioPending = true
        root.manualRadioSeed = vid
        root.manualRadioTries = 0
        manualRadioTimer.restart()
        root.tryManualRadio()
    }

    function tryManualRadio() {
        if (!root.manualRadioPending)
            return
        root.manualRadioTries++
        // fetchRadio does nothing while the catalogue is busy; the timer
        // retries every second up to 12 attempts and then gives up.
        catalog.fetchRadio(root.manualRadioSeed)
        if (root.manualRadioTries >= 12) {
            root.manualRadioPending = false
            root.manualRadioSeed = ""
            root.toast("La radio no responde, inténtalo otra vez")
        }
    }

    // Normalised copy of a track: it keeps title/artist/url/duration/
    // source/cover and, when the source provides them, album and index.
    function trackObj(t) {
        t = t || {}
        const thumb = String(t.thumb || "")
        const cover = String(t.cover || "")
        return {
            title: String(t.title || ""),
            artist: String(t.artist || ""),
            url: String(t.url || ""),
            duration: Number(t.duration || 0),
            source: String(t.source || ""),
            thumb: thumb || cover,
            cover: cover || thumb,
            album: String(t.album || ""),
            liked: t.liked === true || t.liked === "true",
            setId: String(t.setId || ""),
            index: (typeof t.index === "number") ? t.index : -1
        }
    }

    // JS array or ListModel (including the current queue) -> list of copies.
    // It is copied BEFORE emptying the queue: if the list "already comes
    // from the queue" nothing is duplicated or lost that way.
    function toTrackList(list) {
        const out = []
        if (!list)
            return out
        if (typeof list.get === "function" && typeof list.count === "number") {
            for (let i = 0; i < list.count; i++)
                out.push(trackObj(list.get(i)))
        } else {
            const n = Number(list.length || 0)
            for (let i = 0; i < n; i++)
                out.push(trackObj(list[i]))
        }
        return out
    }

    // (Re)fills the model with the given list, in that exact order.
    function fillQueue(arr) {
        queue.clear()
        for (let i = 0; i < arr.length; i++) {
            const t = trackObj(arr[i])
            queue.append({ title: t.title, artist: t.artist, url: t.url,
                           duration: t.duration, source: t.source,
                           thumb: t.thumb, cover: t.cover, album: t.album,
                           liked: t.liked, setId: t.setId })
        }
    }

    // Fisher-Yates, in place.
    function fisherYates(a) {
        for (let i = a.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1))
            const tmp = a[i]
            a[i] = a[j]
            a[j] = tmp
        }
        return a
    }

    // Shuffles the queue IN PLACE: the current track stays where it was
    // (the playback is not cut) and the rest is reordered around it.
    function reshuffleQueue() {
        const arr = toTrackList(queue)
        if (arr.length < 2) {
            queueShuffled = arr.length > 0
            return
        }
        const cur = queueIndex
        const rest = []
        for (let i = 0; i < arr.length; i++)
            if (i !== cur)
                rest.push(arr[i])
        fisherYates(rest)
        const out = []
        let k = 0
        for (let i = 0; i < arr.length; i++)
            out.push(i === cur ? arr[i] : rest[k++])
        fillQueue(out)
        queueIndex = cur
        queueShuffled = true
        // The playback order changed: what was pre-fetched is useless now.
        player.clearPrefetch()
    }

    // Goes back to the original order of the list. The playing track keeps
    // playing (it is not reloaded) and only the model around it is
    // reordered.
    function restoreOriginalOrder() {
        const cur = toTrackList(queue)
        const playing = (queueIndex >= 0 && queueIndex < cur.length)
                        ? cur[queueIndex] : null
        const order = (originalOrder && originalOrder.length)
                      ? originalOrder.slice() : cur.slice()
        let idx = -1
        if (playing) {
            for (let i = 0; i < order.length; i++)
                if (order[i].url === playing.url
                        && order[i].title === playing.title) {
                    idx = i
                    break
                }
            // Leftover (e.g. the queue came from another source): it is not
            // lost.
            if (idx < 0) {
                order.unshift(playing)
                idx = 0
            }
        }
        fillQueue(order)
        if (idx >= 0)
            queueIndex = idx
        else if (queueIndex >= order.length)
            queueIndex = order.length - 1
        queueShuffled = false
        // The playback order changed: what was pre-fetched is useless now.
        player.clearPrefetch()
    }

    // ---- Artist (search, discography and "play all") ---------------------
    // Full artist page: their discography arrives from the newest to the
    // oldest. "Play all" starts with the first album and asks for the
    // others one by one, adding their tracks to the queue on the fly; the
    // shuffle shuffles the whole queue once it is complete.
    property bool artistOpen: false
    property var artistCur: null           // { name, browseId, thumb }
    property var artistAlbums: []
    property bool artistBusy: false
    // What the app expects from the albums: "" none, "all", "shuffle",
    // "album".
    property string artistWant: ""
    property string artistWantBrowse: ""   // browseId requested in flight
    property var artistFetchQueue: []      // browseIds still missing
    property bool artistStarted: false     // the first track already played
    property int artistAdded: 0            // tracks added from the batch

    // Opens an artist's page and asks for their discography.
    function openArtist(a) {
        if (!a || !a.browseId)
            return
        root.artistCur = a
        root.artistAlbums = []
        root.artistBusy = true
        root.artistOpen = true
        catalog.fetchArtist(a.browseId)
    }

    // Info of the playing track for the context menus of the bar and of
    // the cinema mode: it is built with what the player and the app
    // publish.
    function nowPlayingTrack() {
        const vid = String(root.currentVideoId || "")
        return {
            title: String(root.currentTitle || ""),
            artist: String(root.currentArtist || ""),
            url: vid !== "" ? "https://www.youtube.com/watch?v=" + vid
                             : String(player.currentUrl()),
            thumb: String(root.currentThumb || ""),
            cover: String(root.currentThumb || ""),
            duration: Number(player.duration || 0),
            liked: root.currentLiked === true,
            source: ""
        }
    }

    // The loose artist names (bar, cinema) have no browseId: the artist is
    // looked up and the closest one is opened - the first results of the
    // search - preferring the one with exactly the same name.
    property string artistNavPending: ""
    function openArtistByName(name) {
        const n = String(name || "").trim()
        if (n === "" || root.artistNavPending !== "")
            return
        root.artistNavPending = n
        catalog.searchArtists(n)
    }

    // The searched artists arrive: open the chosen one and forget the
    // wait.
    Connections {
        target: catalog
        function onArtistsReady(artists) {
            const n = root.artistNavPending
            if (n === "")
                return
            root.artistNavPending = ""
            const list = artists || []
            if (list.length === 0) {
                root.toast("No encuentro a " + n)
                return
            }
            const ln = n.toLowerCase()
            let pick = null
            for (const a of list) {
                if (String(a.name || "").trim().toLowerCase() === ln) {
                    pick = a
                    break
                }
            }
            if (!pick)
                pick = list[0]
            root.openArtist(pick)
        }
    }

    function closeArtist() {
        root.artistOpen = false
    }

    // "Play all" / "Shuffle" over the loaded discography.
    function artistPlayAll(albums, random) {
        const list = albums || []
        if (list.length === 0) {
            root.toast("Este artista no tiene discos que reproducir")
            return
        }
        root.artistWant = random ? "aleatorio" : "todo"
        root.artistStarted = false
        root.artistAdded = 0
        root.artistFetchQueue = list.slice(1).map(a => String(a.browseId || ""))
        root.artistWantBrowse = String(list[0].browseId || "")
        root.toast("Añadiendo la discografía de "
                   + String(root.artistCur ? root.artistCur.name : "") + "…")
        catalog.fetchAlbumTracks(root.artistWantBrowse)
    }

    // Play only one album: the queue becomes that album.
    function artistPlayAlbum(album) {
        if (!album || !album.browseId)
            return
        root.artistWant = "album"
        root.artistWantBrowse = String(album.browseId)
        root.artistStarted = false
        root.artistAdded = 0
        catalog.fetchAlbumTracks(root.artistWantBrowse)
    }

    // Goes on with the album batch: asks for the next pending one or
    // closes the operation (shuffling the whole queue if it was the
    // shuffle).
    function artistAdvance() {
        const nextBid = root.artistFetchQueue.length > 0
                        ? root.artistFetchQueue.shift() : ""
        if (nextBid) {
            root.artistWantBrowse = nextBid
            catalog.fetchAlbumTracks(nextBid)
            return
        }
        const wasRandom = root.artistWant === "aleatorio"
        const added = root.artistAdded
        const who = root.artistCur ? String(root.artistCur.name) : ""
        root.artistWant = ""
        root.artistWantBrowse = ""
        root.artistFetchQueue = []
        if (wasRandom && queue.count > 1)
            reshuffleQueue()
        if (added > 0)
            root.toast(added + " temas de " + who + " en la cola")
    }

    // Appends tracks to the end of the queue without repeating any that is
    // already there (by url). Returns how many really went in.
    function appendTracksUnique(tracks) {
        const have = {}
        for (let i = 0; i < queue.count; i++) {
            const q = queue.get(i)
            if (q && q.url)
                have[q.url] = true
        }
        let added = 0
        for (let j = 0; j < tracks.length; j++) {
            const t = tracks[j]
            if (!t || !t.url || have[t.url])
                continue
            have[t.url] = true
            queue.append(root.queueRow(t))
            added++
        }
        return added
    }

    // ---- persistent session ---------------------------------------------
    // Stores queue + playing track + shuffle/repeat + volume. The
    // significant changes call it; the volume, when it changes, is saved
    // with a debounce so it does not write to disk on every slider tick.
    function saveSession() {
        if (typeof appcfg === "undefined" || !root.sessionLoaded)
            return
        appcfg.set("playerVolume", String(player.volume))
        if (queue.count > 0) {
            const st = { queue: toTrackList(queue), index: queueIndex,
                         shuffle: shuffle, repeatMode: repeatMode }
            appcfg.set("sessionState", JSON.stringify(st))
        }
        appcfg.save()
    }

    // Restores the last session: queue + playing track + volume +
    // shuffle/repeat. The track is NOT loaded in mpv (it is ready but
    // PAUSED): the first play starts it. `skipQueue` (QA with --openurl)
    // leaves the queue empty but still recovers the volume.
    function restoreSession(skipQueue) {
        root.sessionLoaded = true
        if (!skipQueue) {
            const raw = cfgGet("sessionState")
            var st = null
            if (raw) {
                try {
                    st = JSON.parse(raw)
                } catch (e) {
                    st = null
                }
            }
            if (st && st.queue && st.queue.length) {
                const arr = toTrackList(st.queue)
                originalOrder = arr
                fillQueue(arr)
                let idx = Number(st.index)
                if (!(idx >= 0 && idx < arr.length))
                    idx = 0
                queueIndex = idx
                const t = queue.get(idx)
                if (t) {
                    currentTitle = t.title
                    currentArtist = t.artist
                    currentThumb = t.thumb || ""
                    root.currentVideoId = videoIdOf(t.url)
                    root.currentSetId = t.setId || ""
                    root.currentLiked = catalog.likedReady
                        ? catalog.isLiked(root.currentVideoId)
                        : (t.liked === true)
                }
                shuffle = st.shuffle === true
                // repeatMode (number) or the old boolean `repeat`: both
                // are accepted. With nothing repeatable in the queue it
                // turns off.
                if (typeof st.repeatMode === "number")
                    root.repeatMode = Math.max(0, Math.min(2, st.repeatMode))
                else if (st.repeat === true)
                    root.repeatMode = 2
                else
                    root.repeatMode = 0
                mpris.setLoopStatus(root.repeatMode === 1 ? "Playlist"
                                      : root.repeatMode === 2 ? "Track" : "None")
                // The stored queue is ALREADY in playback order (if the
                // shuffle was on it comes shuffled): marking it as such
                // stops the first next() from shuffling it again and
                // changing the order (which invalidated the pre-fetched
                // tracks).
                queueShuffled = shuffle && arr.length > 1
                mpris.setShuffle(shuffle)
                root.updateNowPlaying()
            }
        }
        // Without a stored value the volume is not touched (mpv starts
        // with its own); "" -> -1 avoids falling to 0 and muting the
        // app on the first startup.
        const pv = cfgGet("playerVolume")
        root.pendingVolume = pv === "" ? -1 : Number(pv)
        if (player.ready)
            root.applyPendingVolume()
    }

    function applyPendingVolume() {
        if (root.pendingVolume < 0)
            return
        const v = root.pendingVolume
        root.pendingVolume = -1
        if (v >= 0 && v <= 150)
            player.setVolume(v)
    }

    // First play after restoring the session: if mpv has nothing loaded
    // it starts the current track; if there is something, it only
    // toggles the pause.
    function togglePlay() {
        if (!player.hasFile && root.currentTitle.length > 0
                && root.queueIndex >= 0 && root.queueIndex < queue.count) {
            root.startCurrent()
            return
        }
        player.playPause()
    }

    function requestPlay() {
        if (!player.hasFile && root.currentTitle.length > 0
                && root.queueIndex >= 0 && root.queueIndex < queue.count) {
            root.startCurrent()
        } else if (!player.playing) {
            player.playPause()
        }
    }

    function toggleShuffle() {
        shuffle = !shuffle
        if (queue.count > 0) {
            if (shuffle)
                reshuffleQueue()      // the visible queue goes to random order
            else
                restoreOriginalOrder() // original stable order
        }
        mpris.setShuffle(shuffle)
        toast(shuffle ? "Aleatorio activado" : "Aleatorio desactivado")
        root.saveSession()
    }

    // Extracts the videoId (youtube.com/watch?v= / youtu.be/ /
    // music.youtube.com) from a track's URL. Empty if the track is not
    // from YouTube.
    function videoIdOf(url) {
        const u = String(url || "")
        var m = /[?&]v=([A-Za-z0-9_-]{6,})/.exec(u)
        if (m)
            return m[1]
        const m2 = u.match(/youtu\.be\/([A-Za-z0-9_-]+)/)
        return m2 ? m2[1] : ""
    }

    // Extracts the id from a YouTube Music playlist URL (?list=XXXX).
    function listIdOf(url) {
        const m = /[?&]list=([A-Za-z0-9_-]+)/.exec(String(url || ""))
        return m ? m[1] : ""
    }

    function toggleRepeat() {
        // Repeat button cycle: off -> list -> track -> off.
        root.repeatMode = (root.repeatMode + 1) % 3
        cfgSet("repeatMode", root.repeatMode)
        mpris.setLoopStatus(root.repeatMode === 1 ? "Playlist"
                              : root.repeatMode === 2 ? "Track" : "None")
        toast(root.repeatMode === 0 ? "Repetición desactivada"
            : root.repeatMode === 1 ? "Repetir la lista" : "Repetir la canción")
        root.saveSession()
    }

    // Lyrics compensation (seconds). It is saved in the config, sent to
    // the backend - which publishes it for the desktop widgets - and the
    // on screen views pick it up when the notice arrives.
    function setLyricsOffset(v) {
        // The same range as the view of the lyrics.
        const x = Math.round(Theme.clamp(v, -180, 180) * 4) / 4    // 250 ms steps
        cfgSet("lyricsOffset", x.toFixed(2))
        if (typeof lyrics !== "undefined") {
            // The backend is the one that holds the value: the panel and
            // the view of the lyrics read it from there (so they never
            // show a stale one).
            lyrics.setPublishedOffset(x)
        }
    }

    // ---- integrations (lyrics / Discord / MPRIS) ------------------------
    // Asks for the lyrics only once the real duration of the track is
    // known. It also serves as a retry: if the immediate attempt
    // (without duration) found no lyrics, here it is asked again with
    // the real duration as soon as mpv reports it. That way there is no
    // need to pause/resume for it to "detect".
    function fetchLyrics() {
        if (!root.lyricsEnabled || !root.currentTitle)
            return
        const dur = player.duration
        if (dur <= 0)
            return
        const key = root.currentArtist + "|" + root.currentTitle
        if (root.lyricsKey === key)
            return
        // Which track the lyrics in memory belong to. If they are not
        // from THIS one, the lyrics on screen (and the ones the desktop
        // widget reads) are from the PREVIOUS song: the new ones have to be
        // asked for.
        const want = root.currentArtist + " - " + root.currentTitle
        const sameTrack = String(lyrics.trackKey || "") === want
        // A request in flight for THIS track is left to finish; if it is
        // for another one, it is cancelled: the new track wins.
        if (sameTrack && lyrics.loading)
            return
        root.lyricsKey = key
        // The immediate attempt already brought the lyrics of THIS track: no repeat.
        if (sameTrack && (lyrics.hasLyrics || lyrics.hasSynced))
            return
        lyrics.fetch(root.currentArtist, root.currentTitle, dur,
                     root.currentVideoId)
    }

    // Refreshes Discord + MPRIS with the current position/state. The
    // metadata (title/artist/cover/duration) is only resent when it
    // changes.
    function updateNowPlaying() {
        const dur = player.duration
        const key = root.currentTitle + "|" + root.currentArtist + "|"
                    + Math.round(dur) + "|" + root.currentThumb
        if (key !== root.metaKey) {
            root.metaKey = key
            mpris.updateMetadata(root.currentTitle, root.currentArtist, "", dur, root.currentThumb)
        }
        discord.setActivity(root.currentTitle, root.currentArtist, "", root.currentThumb,
                            player.position, dur, player.playing)
        mpris.updatePlayback(player.playing, player.position)
        mpris.updateVolume(player.volume)
        root.fetchLyrics()
    }

    // Loads a list into the queue. If the shuffle is on, the song that
    // was pressed plays FIRST and the rest of the queue is shuffled
    // (Fisher-Yates); from then on `next()` walks the queue linearly (no
    // jumps).
    function playTracks(list, idx) {
        const arr = toTrackList(list)
        if (arr.length === 0 || idx < 0 || idx >= arr.length)
            return
        originalOrder = arr            // original order (copy without shuffling)
        let order = arr
        if (shuffle && arr.length > 1) {
            // The pressed track goes first; the rest, shuffled.
            const first = arr[idx]
            const rest = arr.slice()
            rest.splice(idx, 1)
            fisherYates(rest)
            order = [first].concat(rest)
            idx = 0
        }
        fillQueue(order)
        queueShuffled = shuffle && arr.length > 1
        queueIndex = idx
        startCurrent()
        // A single song: it goes on alone with YouTube Music's
        // radio/autoplay (the "next" songs YouTube Music would use
        // without adding them by hand).
        root.autoplayRadioPending = false
        root.autoplayRadioSeed = ""
        root.radioResumePending = false
        // Any radio asked by hand for the previous queue no longer
        // makes sense: its request and its retry are dropped.
        root.manualRadioPending = false
        root.manualRadioSeed = ""
        root.artistRadioPending = ""
        manualRadioTimer.stop()
        if (arr.length === 1 && root.autoplayEnabled) {
            const only = queue.get(0)
            const vid = only ? videoIdOf(only.url) : ""
            if (vid && typeof catalog.fetchRadio === "function") {
                root.autoplayRadioPending = true
                root.autoplayRadioSeed = vid
                // Deferred: if we come from tracksReady the backend still
                // has its operation running in this same tick; the
                // callLater lets it finish before asking for the radio.
                Qt.callLater(function() {
                    if (root.autoplayRadioPending
                            && root.autoplayRadioSeed === vid)
                        catalog.fetchRadio(vid)
                })
            }
        }
    }

    function startCurrent() {
        if (queueIndex < 0 || queueIndex >= queue.count)
            return
        const t = queue.get(queueIndex)
        if (!t || !t.url)
            return
        currentTitle = t.title
        currentArtist = t.artist
        currentThumb = t.thumb || ""
        root.currentVideoId = videoIdOf(t.url)
        root.currentSetId = t.setId || ""
        root.currentLiked = catalog.likedReady
                            ? catalog.isLiked(root.currentVideoId)
                            : t.liked === true
        root.lyricsKey = ""
        if (root.lyricsEnabled && root.currentTitle) {
            // First immediate attempt. For YouTube tracks the exact
            // video is used (the lyrics do not depend on the duration).
            // If this attempt finds no lyrics, fetchLyrics() retries with
            // the real duration as soon as mpv reports it (without
            // having to pause and resume).
            lyrics.fetch(root.currentArtist, root.currentTitle, 0,
                         root.currentVideoId)
        }
        player.load(t.url)
        // Pre-resolves the stream of the next tracks in the background so
        // the song change is instant (Sonora style). Whatever was left
        // pending from a previous context (another list or another
        // position) is dropped first, so it does not block the ones that
        // are going to play.
        player.clearPrefetch()
        prefetchAhead(queueIndex, 6)
        catalog.addRecent({ title: t.title, artist: t.artist, url: t.url,
                            duration: t.duration, source: t.source, thumb: t.thumb || "",
                            setId: t.setId || "" })
        root.updateNowPlaying()
        root.saveSession()
    }

    // Pre-resolves up to `n` tracks from `from` in the queue (in series,
    // the Player enqueues them; here only the valid URLs are pre-resolved).
    // It is fired when each track starts, to have the stream already
    // resolved when moving on.
    function prefetchAhead(from, n) {
        if (!n || from < 0 || from >= queue.count)
            return
        for (let i = from + 1; i <= from + n && i < queue.count; i++) {
            const t = queue.get(i)
            if (t && t.url)
                player.prefetch(t.url)
        }
    }

    // Pre-resolves the first `n` tracks of a freshly shown list (open
    // list or search results). That way a click on any of the first rows
    // already finds the stream resolved and sounds instantly.
    function prefetchHead(list, n) {
        if (!list || !list.length)
            return
        n = n || 4
        const total = Math.min(n, list.length)
        for (let i = 0; i < total; i++) {
            const t = list[i]
            if (t && t.url)
                player.prefetch(t.url)
        }
    }

    function next() {
        // Leftover case: the shuffle is on but the queue is not shuffled
        // yet. In normal conditions the queue IS the shuffled order and
        // it just walks linearly (that is what the queue view shows).
        if (shuffle && !queueShuffled && queue.count > 1) {
            reshuffleQueue()
        }
        if (queueIndex + 1 < queue.count) {
            queueIndex++
            startCurrent()
            return
        }
        // End of the queue with the LIST on repeat: it goes back to the
        // first track without asking for autoplay (the music returns on
        // its own).
        if (root.repeatMode === 1 && queue.count > 0) {
            queueIndex = 0
            startCurrent()
            return
        }
        // End of the queue. With the autoplay on it does not stop: YouTube
        // Music is asked to continue from the last track (it arrives in
        // ~1.4 s with prefetchRadio). While it arrives, the last song
        // stays on screen; the radioWaitTimer silences it if the network
        // does not answer.
        const inRange = queueIndex >= 0 && queueIndex < queue.count
        const vid = (root.autoplayEnabled && queue.count > 0 && inRange)
                    ? videoIdOf(queue.get(queueIndex).url) : ""
        if (vid && typeof catalog.prefetchRadio === "function") {
            root.autoplayRadioPending = true
            root.autoplayRadioSeed = vid
            root.radioResumePending = true
            radioWaitTimer.restart()
            catalog.prefetchRadio(vid, currentTitle)
            return
        }
        root.stopAndClear()
    }

    // Silence and clean up when the queue runs out without autoplay: it
    // stops the engine, the caption, the lyrics and the external
    // routers. The queue is kept (going back with "prev" still has a
    // way in).
    function stopAndClear() {
        player.stopPlayback()
        currentTitle = ""
        currentArtist = ""
        currentThumb = ""
        // The videoId too: otherwise the cinema mode would keep asking
        // for the sharp artwork of the previous video and show the wrong
        // cover.
        root.currentVideoId = ""
        root.lyricsKey = ""
        root.metaKey = ""
        lyrics.clear()
        discord.clear()
        mpris.updatePlayback(false, 0, true)
    }

    function prev() {
        if (player.position > 4) {
            player.seek(0)
            return
        }
        if (queueIndex > 0) {
            queueIndex--
            startCurrent()
        } else {
            player.seek(0)
        }
    }

    // Dead video replacement: it starts the search for another version
    // of the SAME song (the original video is deleted or blocked). It
    // returns true if the replacement has to be waited for; the result
    // takes care of the row in onAlternateResolved. The `swapTriedKey`
    // mark is the "artist|title", so the same song only tries the
    // replacement once: if the replacement video fails too, it moves on
    // (it does not loop).
    property string swapTriedKey: ""
    function trySwap() {
        if (!root.currentTitle)
            return false
        const key = root.currentArtist + "|" + root.currentTitle
        if (root.swapTriedKey === key)
            return false
        const idx = root.queueIndex
        const row = idx >= 0 && idx < queue.count ? queue.get(idx) : null
        const vid = row ? root.videoIdOf(String(row.url || "")) : ""
        if (!vid)
            return false
        root.swapTriedKey = key
        root.swapVideoId = vid
        console.warn("[queue] vídeo no disponible, buscando otra versión:", vid)
        catalog.resolveAlternate(root.currentArtist, root.currentTitle, vid,
                                 player.duration)
        swapWaitTimer.restart()
        return true
    }

    // Replacement valve: if the search does not answer in 12 s (no YTM
    // session, cut network...), it moves on to the next track.
    Timer {
        id: swapWaitTimer
        interval: 12000
        onTriggered: root.swapGiveUp()
    }

    // The replacement did not arrive (or there was none): notice and next
    // track.
    function swapGiveUp() {
        if (root.swapVideoId.length === 0)
            return
        root.swapVideoId = ""
        swapWaitTimer.stop()
        toast("«" + root.currentTitle + "» no está disponible; avanzando")
        root.next()
    }

    Connections {
        target: player
        function onEndOfFile(ok) {
            if (!ok) {
                // Failed track (after the engine's two retries): before
                // moving on, another version of the same song is looked
                // up, in case the original video no longer exists.
                if (root.trySwap())
                    return
                console.warn("[queue] pista fallida, avanzando")
                if (root.currentTitle.length > 0)
                    root.toast("No se pudo reproducir «" + root.currentTitle + "»")
                root.next()
                return
            }
            // Repeat ONLY the song: the same track starts again.
            if (root.repeatMode === 2 && root.currentTitle.length > 0) {
                root.startCurrent()
                return
            }
            root.next()
        }
        function onEngineStatusChanged() {
            if (player.engineStatus && player.engineStatus !== "ready"
                    && player.engineStatus !== "starting") {
                root.toast("Motor de audio: " + player.engineStatus)
            }
        }
        // Keeps Discord/MPRIS up to date and fine tunes the lyrics when
        // the real duration arrives or the playback state changes.
        function onStateChanged() { root.updateNowPlaying() }
        // The volume changes often (slider/keys): it is saved with a
        // debounce.
        function onVolumeChanged() { sessionSaveTimer.restart() }
        // mpv ready: applies the volume recovered from the last session.
        function onReadyChanged() { if (player.ready) root.applyPendingVolume() }
    }

    // Session write with debounce (for the continuous volume).
    Timer {
        id: sessionSaveTimer
        interval: 700
        onTriggered: root.saveSession()
    }

    // Autoplay valve: if, when the queue runs out, the YouTube Music
    // continuation does not arrive in 12 s (cut network, blocked
    // extractor), it silences instead of leaving the interface waiting
    // for nothing.
    Timer {
        id: radioWaitTimer
        interval: 12000
        repeat: false
        onTriggered: {
            if (!root.autoplayRadioPending)
                return
            root.autoplayRadioPending = false
            root.autoplayRadioSeed = ""
            root.radioResumePending = false
            root.stopAndClear()
        }
    }

    // Retry of the radio asked by hand (track menu): every second it is
    // fired again until the catalogue is free or the attempts run out
    // (see tryManualRadio).
    Timer {
        id: manualRadioTimer
        interval: 1000
        repeat: true
        running: false
        onTriggered: root.tryManualRadio()
    }

    // Periodic beat for the progress in Discord/MPRIS.
    Timer {
        interval: 1000
        repeat: true
        running: player.playing
        onTriggered: root.updateNowPlaying()
    }

    // Commands coming from the system media centre (MPRIS2).
    Connections {
        target: mpris
        function onPlayRequested() { root.requestPlay() }
        function onPauseRequested() { if (player.playing) player.playPause() }
        function onPlayPauseRequested() { root.togglePlay() }
        function onNextRequested() { root.next() }
        function onPreviousRequested() { root.prev() }
        function onStopRequested() { player.stopPlayback() }
        function onSeekRequested(seconds) { player.seek(seconds) }
        function onSetPositionRequested(seconds) { player.seek(seconds) }
        function onVolumeRequested(v) { player.setVolume(Math.round(v * 100)) }
        function onOpenUriRequested(uri) {
            root.playTracks([ { title: "", artist: "", url: uri, duration: 0, source: "" } ], 0)
        }
        function onQuitRequested() { Qt.quit() }
    }

    // The session of YouTube Music can be imported from the file that was
    // exported in the other device.
    property string sessionPath: (downloads.folder || "") + "/lotus-tune-sesion.json"
    property bool sessionExported: false
    FileDialog {
        id: sessionDialog
        title: "Importar la sesión de YouTube Music"
        nameFilters: ["Sesión de LotusTune (*.json)"]
        onAccepted: {
            if (catalog.importSession(selectedFile.toString().replace("file://", "")))
                root.toast("Sesión importada")
            else
                root.toast("No se pudo importar la sesión")
        }
    }

    // The new versions of the app are looked up in the repository when it
    // starts (and when the user asks for it in the settings).
    Timer {
        id: updateTimer
        interval: 4000
        onTriggered: {
            if (typeof updates === "undefined")
                return
            updates.check()
        }
    }
    Connections {
        target: typeof updates !== "undefined" ? updates : null
        function onChanged() {
            if (typeof updates === "undefined" || !updates.available)
                return
            root.toast("Hay una versión nueva: " + updates.latestVersion)
        }
    }

    // ---- toast -----------------------------------------------------------
    property string toastText: ""

    function toast(msg) {
        if (!msg)
            return
        toastText = msg
        toastTimer.restart()
    }

    Timer {
        id: toastTimer
        interval: 4200
        onTriggered: root.toastText = ""
    }

    // ---- YouTube Music interaction (like / lists) -------------------
    function toggleLike() {
        if (!root.currentVideoId) {
            root.toast("La pista actual no es de YouTube")
            return
        }
        // catalog.toggleLiked votes and updates the set; the heart (here
        // and in the rows) repaints when likedRevision/onLikedChanged
        // goes up.
        catalog.toggleLiked(root.currentVideoId, root.currentLiked)
    }

    // Opens the list picker for a specific track (+ button of a row or
    // of the bottom bar). Without an argument it uses the current track.
    function openPlaylistPicker(videoId) {
        root.pickerVideoId = videoId || root.currentVideoId
        root.playlistPickerOpen = true
    }

    function addCurrentToPlaylist(playlistId) {
        const vid = root.pickerVideoId || root.currentVideoId
        root.playlistPickerOpen = false
        if (!vid) {
            root.toast("La pista actual no es de YouTube")
            return
        }
        catalog.addToPlaylist(playlistId, vid)
    }

    // Removes a specific track (right click on a row) from the open list.
    function removeTrackFromOpenPlaylist(t) {
        t = t || {}
        const vid = root.videoIdOf(String(t.url || ""))
        const sid = String(t.setId || "")
        if (!catalog.openPlaylistId || !vid || !sid) {
            root.toast("Esta pista no se puede quitar de la lista")
            return
        }
        catalog.removeOpenPlaylistTrack(vid, sid)
    }

    // Removes the current track from the list it was opened with (it
    // needs the setVideoId the playlist entry carries).
    function removeCurrentFromPlaylist(playlistId) {
        root.playlistPickerOpen = false
        if (!root.currentVideoId || !root.currentSetId) {
            root.toast("Esta pista no se puede quitar de la lista")
            return
        }
        catalog.removeFromPlaylist(playlistId, root.currentVideoId,
                                   root.currentSetId)
    }

    // Connection for the result of voting/adding/removing from a list.
    Connections {
        target: catalog
        function onInteractionDone(ok, message) {
            root.toast(message)
        }
        // The "liked" set changed (loaded or after a vote): refreshes the
        // heart of the playing track.
        function onLikedChanged() {
            if (root.currentVideoId)
                root.currentLiked = catalog.isLiked(root.currentVideoId)
        }
        // Metadata of a list (answer to fetchPlaylistInfo): it completes
        // the editor with the real title and privacy.
        function onPlaylistInfoReady(info) {
            if (!root.editorOpen || root.editorCreate)
                return
            if (!info || !info.id || String(info.id) !== root.editorInfoId)
                return
            if (info.title)
                root.editorTitle = String(info.title)
            if (info.privacy)
                root.editorPrivate = (String(info.privacy).toUpperCase() === "PRIVATE")
        }
        // Answer to the replacement search of a track whose video died:
        // the queue row is replaced with the new video and that same row
        // is played. The user's queue is fixed in place (their local
        // playlist stops failing on that song).
        function onAlternateResolved(key, track) {
            if (!root.swapVideoId || String(key) !== root.swapVideoId)
                return
            swapWaitTimer.stop()
            const idx = root.queueIndex
            let row = idx >= 0 && idx < queue.count ? queue.get(idx) : null
            const t = track || {}
            // The queue changed while searching (the user moved on): the
            // replacement is dropped, replacing that row is pointless
            // now.
            if (row && root.videoIdOf(String(row.url || "")) !== root.swapVideoId)
                row = null
            if (!row || !t.url) {
                root.swapVideoId = ""
                if (row)
                    root.toast("«" + row.title + "» no está disponible")
                root.next()
                return
            }
            const newVid = root.videoIdOf(String(t.url))
            if (newVid === root.swapVideoId) {
                // The search returned the same broken video: there is
                // nothing left to try; it moves to the next.
                root.swapVideoId = ""
                root.toast("«" + row.title + "» no está disponible")
                root.next()
                return
            }
            console.warn("[queue] vídeo muerto " + root.swapVideoId
                         + " -> recambio " + newVid)
            queue.set(idx, { title: row.title, artist: row.artist,
                             url: String(t.url),
                             duration: Number(t.duration) > 0 ? t.duration : row.duration,
                             source: row.source, thumb: t.thumb || row.thumb,
                             cover: row.cover, album: row.album,
                             liked: row.liked, setId: row.setId })
            root.swapVideoId = ""
            root.toast("Suena otra versión de «" + row.title + "»")
            root.startCurrent()
        }
    }

    Connections {
        target: catalog
        function onChanged() {
            if (catalog.error) {
                // A failed opening: nothing to open or play afterwards.
                root.listLoading = false
                root.pendingPlay = false
                // A backend failure leaves without effect the
                // radio/autoplay that was on its way: there is no need
                // to wait for it any more.
                if (root.autoplayRadioPending) {
                    root.autoplayRadioPending = false
                    root.autoplayRadioSeed = ""
                    if (root.radioResumePending) {
                        root.radioResumePending = false
                        root.stopAndClear()
                    }
                }
                root.toast(catalog.error)
                catalog.dismissError()
            }
        }
        function onTracksReady(tracks, title) {
            const play = root.pendingPlay
            root.pendingPlay = false
            root.listLoading = false
            if (play) {
                // Play button: it plays without leaving the current page.
                root.playTracks(tracks, 0)
                return
            }
            // A list of a single track is, in practice, a loose song:
            // play it now instead of opening a list view.
            if (tracks && tracks.length === 1) {
                root.playTracks(tracks, 0)
                return
            }
            // Only open: a direct jump to the list/album (without playing).
            root.openTracksView()
            // It pre-resolves the first tracks right away: when the user
            // presses one of them, the stream is already resolved and it
            // sounds instantly.
            root.prefetchHead(tracks, 4)
        }
        function onLibraryChanged() {
            if (root.launcherOpen)
                root.buildLauncher(launchInput.text)
        }
        // YouTube Music radio/autoplay: if it came from a single song, it
        // adds the "next" songs to the queue (without duplicating the
        // one already playing). If the queue had also run out (autoplay at
        // the end), it starts with the first of the new ones as soon as
        // they arrive. The radios asked by hand from the track menu arrive
        // through the same signal and grow the same way, but without
        // resuming anything.
        function onRadioReady(seed, tracks) {
            const isAuto = root.autoplayRadioPending
                           && seed === root.autoplayRadioSeed
            const isManual = root.manualRadioPending
                             && seed === root.manualRadioSeed
            if (!isAuto && !isManual)
                return
            root.autoplayRadioPending = false
            root.autoplayRadioSeed = ""
            root.manualRadioPending = false
            root.manualRadioSeed = ""
            manualRadioTimer.stop()
            radioWaitTimer.stop()
            const resume = root.radioResumePending
            root.radioResumePending = false
            if (!tracks || !tracks.length) {
                if (resume)
                    root.stopAndClear()
                return
            }
            const have = {}
            const cur = toTrackList(queue)
            for (let i = 0; i < cur.length; i++) {
                have[cur[i].url] = true
                have[String(cur[i].title).toLowerCase() + "|"
                     + String(cur[i].artist).toLowerCase()] = true
            }
            for (let j = 0; j < tracks.length; j++) {
                const t = tracks[j]
                if (!t || !t.url)
                    continue
                const k = String(t.title || "").toLowerCase() + "|"
                          + String(t.artist || "").toLowerCase()
                if (have[t.url] || have[k])
                    continue
                have[t.url] = true
                have[k] = true
                queue.append(root.queueRow(t))
            }
            root.saveSession()
            if (resume && queueIndex + 1 < queue.count) {
                queueIndex++
                startCurrent()
            }
        }
        // Discography received: only the one of the open artist counts.
        function onArtistReady(browseId, albums) {
            if (!root.artistCur || browseId !== String(root.artistCur.browseId))
                return
            root.artistBusy = false
            root.artistAlbums = albums || []
        }
        // An artist's main track resolved ("Radio of X" menu): it is
        // used as the seed and its radio arrives as "up next" through
        // the same path as the song radio.
        function onArtistTopTrackResolved(name, track) {
            if (name !== root.artistRadioPending)
                return
            root.artistRadioPending = ""
            if (!track || !String(track.url || "")) {
                root.toast("No se pudo montar la radio de " + name)
                return
            }
            root.playTracks([track], 0)
            if (!root.autoplayEnabled)
                root.requestManualRadio(root.videoIdOf(String(track.url)))
        }
        // Album tracks: the playback starts with the first batch and the
        // rest are added without cutting what sounds (see artistAdvance).
        function onAlbumTracksReady(browseId, tracks) {
            if (root.artistWant === "" || browseId !== root.artistWantBrowse)
                return   // answer of an already cancelled request
            if (!tracks || !tracks.length) {
                if (root.artistWant === "album") {
                    root.artistWant = ""
                    root.artistWantBrowse = ""
                    root.toast("Ese álbum no trae pistas reproducibles")
                } else {
                    root.artistAdvance()
                }
                return
            }
            if (!root.artistStarted) {
                // First batch: the music starts right away, without
                // waiting for the rest.
                root.playTracks(tracks, 0)
                root.artistStarted = true
                root.artistAdded += tracks.length
            } else {
                root.artistAdded += root.appendTracksUnique(tracks)
            }
            if (root.artistWant === "album") {
                root.artistWant = ""
                root.artistWantBrowse = ""
                return
            }
            root.artistAdvance()
        }
    }

    // ---- dynamic background (Liner style wash) ---------------------------
    // The current track's artwork tinted as the background: it is loaded
    // at a tiny size (56 px) and softly stretched over the whole window,
    // which is a cheap blur with no GPU (the backend is software and niri
    // has no compositor blur). The Panel islands go on top: opaque
    // without the dynamic background, frosted with it (see Panel.qml). It
    // is dimmed so it does not eat the text's contrast.
    Item {
        id: bgWash
        anchors.fill: parent
        visible: Sys.dynamicBg
        opacity: washImg.status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 500 } }

        Image {
            id: washImg
            anchors.fill: parent
            // The blur is done by the backend in the CPU ("wash"): a
            // 480 px veil so soft that stretching it over the whole screen
            // shows no block at all. The serial breaks the cache when the
            // track changes.
            source: Sys.dynamicBg && root.currentThumb && wash.valid
                    ? "image://wash/" + wash.serial : ""
            // STRETCHED, not cropped: the veil adapts to the window and the
            // whole artwork is seen. Cropped (PreserveAspectCrop) in a
            // tall window it was blown up x5 and only the middle of the
            // art was visible, with dark edges on the sides.
            fillMode: Image.Stretch
            smooth: true
            asynchronous: true
            cache: false
        }

        // The wash has to let you RECOGNISE the artwork (not be a blob):
        // the veil lowers the light at the top, where the greeting and
        // the titles go, and lets a lot of colour through at the
        // bottom.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.alpha(Sys.bg, 0.60) }
                GradientStop { position: 1.0; color: Theme.alpha(Sys.bg, 0.34) }
            }
        }
    }

    // ---- layout ----------------------------------------------------------
    // "Floating islands" interface: the window background (Sys.bg) is
    // the desktop and every zone - rail, header, content, panel and
    // playback bar - is a rounded surface separated by `panelGap`.
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.panelMargin
        spacing: Theme.panelGap

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.panelGap

            Item {
                id: sideCol
                Layout.preferredWidth: sidebar.railWidth
                Layout.fillHeight: true

                Sidebar {
                    id: sidebar
                    anchors.fill: parent
                    page: root.activeNavId()
                    trackTitle: root.currentTitle
                    trackArtist: root.currentArtist
                    trackThumb: root.currentThumb
                    playing: player.playing
                    engineStatus: player.engineStatus
                    onNavigate: (p) => {
                        // "Library" leaves "Downloads" behind: it goes
                        // back to the "Songs" tab so the click really
                        // takes you to the Library.
                        if (p === "library") {
                            if (libPage.libraryTab === 4)
                                libPage.libraryTab = 0
                        }
                        root.navTo(p)
                    }
                    onSettingsRequested: root.toggleSettings()
                    onNowPlayingRequested: root.openFullscreenLyrics()
                    // "Liked": opens YouTube Music's LM list without
                    // playing it.
                    onLikedRequested: {
                        root.beginOpenList(false)
                        catalog.openUrl("https://music.youtube.com/playlist?list=LM",
                                        "Me gusta")
                    }
                    // "Downloads": the Library with the "Downloaded" tab
                    // active (it is clear you are in Downloads).
                    onDownloadsRequested: {
                        libPage.libraryTab = 4
                        root.navTo("library")
                    }
                    // Click on a list: it opens and, when it arrives, it
                    // is shown directly (without jumping to the Library
                    // nor playing it).
                    onPlaylistRequested: (i) => {
                        root.beginOpenList(false)
                        catalog.openPlaylist(i)
                    }
                    onYtmlistRequested: (url, name) => {
                        root.beginOpenList(false)
                        catalog.openUrl(url, name)
                    }
                    onYtmlistContextRequested: (item, x, y) => {
                        root.showContextMenu(root.playlistMenuItems({
                            id: item.id || root.listIdOf(item.url),
                            name: item.name || "",
                            url: item.url || "",
                            owned: item.owned === true
                        }), x, y)
                    }
                    onPlaylistContextRequested: (item, x, y) => {
                        root.showContextMenu(root.savedPlaylistMenuItems(item, item.index), x, y)
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Theme.panelGap

                TopBar {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.topBarH
                    title: root.pageTitle()
                    subtitle: root.pageSubtitle()
                    showBack: root.navStack.length > 0
                    onBackRequested: root.navBack()
                    onLauncherRequested: root.toggleLauncher()
                    onSettingsRequested: root.toggleSettings()
                }

                // FLAT content like the reference repo: no box of its
                // own - the pages go straight on the washed background
                // and only the dialogs (settings, side panel) keep a
                // surface.
                Panel {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clipContent: true
                    color: "transparent"

                    StackLayout {
                        id: stack
                        anchors.fill: parent
                        currentIndex: root.pageIndex(root.page)

                        // Immediate page change: no fade nor transition.
                        onCurrentIndexChanged: {
                            // Reloads the home search history (it is
                            // written from Search while it is not visible).
                            homePage.refreshSearchHistory()
                        }

                        HomePage {
                            id: homePage
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            onPlayRequested: (list, idx) => root.playTracks(list, idx)
                            onNavigateRequested: (p) => root.navTo(p)
                            onOpenListRequested: (play) => root.beginOpenList(play)
                            onOpenSettingsRequested: {
                                root.listLoading = false
                                root.pendingPlay = false
                                root.settingsOpen = true
                            }
                            onOpenLauncherRequested: root.toggleLauncher()
                            // History chip: opens Search and re-runs the
                            // query.
                            onSearchRequested: (q) => {
                            root.navTo("search")
                            searchPage.startSearch(q)
                            }
                        }
                        SearchPage {
                            id: searchPage
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            onPlayRequested: (list, idx) => root.playTracks(list, idx)
                            onTrackContextRequested: (t, x, y) => root.showTrackMenu(t, x, y)
                            onEnqueueRequested: (t) => root.enqueueTrack(t)
                            // Artists mode: the page opens fullscreen.
                            onArtistRequested: (a) => root.openArtist(a)
                        }
                        LibraryPage {
                            id: libPage
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            onPlayRequested: (list, idx) => root.playTracks(list, idx)
                            onEnqueueRequested: (t) => root.enqueueTrack(t)
                            // Cover: open (false) or open and play (true).
                            onOpenListRequested: (play) => root.beginOpenList(play)
                            onTrackContextRequested: (t, x, y) => root.showTrackMenu(t, x, y)
                            onCoverContextRequested: (c, x, y) => root.showPlaylistMenu(c, x, y)
                            onShuffleListRequested: root.shuffleTracks(libPage.viewTracks())
                            onUninstallListRequested: (folder, name) => root.confirmRemoveDownload(folder, name)
                            onDownloadMenuRequested: (folder, name, x, y) => root.showDownloadMenu(folder, name, x, y)
                            onDownloadOpenRequested: (folder) => {
                                // Opens the downloaded list as a playlist
                                // keeping the back step (the Downloads list
                                // view).
                                root.pushPage("library", true)
                                libPage.openDownloadPlaylist(folder)
                            }
                        }
                    }
                }
            }

            RightPanel {
                id: rightPanel
                visible: root.panelOpen
                Layout.preferredWidth: 360
                Layout.fillHeight: true
                tab: root.panelTab
                onTabRequested: (t) => root.panelTab = t
                queueModel: queue
                queueIndex: root.queueIndex
                onCloseRequested: root.panelOpen = false
                onTrackActivated: (i) => {
                    root.queueIndex = i
                    root.startCurrent()
                }
                onTrackContextRequested: (t, x, y) => root.showTrackMenu(t, x, y)
                onFullscreenLyricsRequested: root.openFullscreenLyrics()
            }
        }

        PlayerBar {
            Layout.fillWidth: true
            playing: player.playing
            loading: player.loading
            position: player.position
            duration: player.duration
            title: root.currentTitle
            artist: root.currentArtist
            currentThumb: root.currentThumb
            volume: player.volume
            shuffle: root.shuffle
            repeatMode: root.repeatMode
            onToggle: root.togglePlay()
            onNextRequested: root.next()
            onPrevRequested: root.prev()
            onShuffleToggled: root.toggleShuffle()
            onRepeatToggled: root.toggleRepeat()
            onLyricsRequested: root.openFullscreenLyrics()
            onQueueRequested: root.togglePanel(0)
            onLyricsPanelRequested: root.togglePanel(1)
            onSeekRequested: (secs) => player.seek(secs)
            onVolumeWanted: (v) => player.setVolume(v)
            videoId: root.currentVideoId
            liked: root.currentLiked
            canInteract: catalog.loginState === "ok"
            onLikeRequested: root.toggleLike()
            onAddToPlaylistRequested: root.openPlaylistPicker(root.currentVideoId)
            onTrackMenuRequested: (x, y) => root.showTrackMenu(root.nowPlayingTrack(), x, y)
            onArtistRequested: (name) => root.openArtistByName(name)
        }
    }

    // ---- fullscreen lyrics (cinema mode) ----------------------------
    FullscreenLyrics {
        id: fsLyrics
        open: root.fsLyricsOpen
        title: root.currentTitle
        artist: root.currentArtist
        thumb: root.currentThumb
        videoId: root.currentVideoId
        playing: player.playing
        position: player.position
        duration: player.duration
        shuffleOn: root.shuffle
        repeatVal: root.repeatMode
        liked: root.currentLiked
        onCloseRequested: root.fsLyricsOpen = false
        onToggleRequested: root.togglePlay()
        onNextRequested: root.next()
        onPrevRequested: root.prev()
        onSeekRequested: (secs) => player.seek(secs)
        onShuffleRequested: root.toggleShuffle()
        onRepeatRequested: root.toggleRepeat()
        onLikeRequested: root.toggleLike()
        onTrackMenuRequested: (x, y) => root.showTrackMenu(root.nowPlayingTrack(), x, y)
        onArtistRequested: (name) => {
            root.closeFullscreenLyrics()
            root.openArtistByName(name)
        }
    }

    // ---- list picker (add to playlist) ---------------------------
    Item {
        id: playlistPicker
        anchors.fill: parent
        z: 68
        visible: root.playlistPickerOpen
        opacity: root.playlistPickerOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.45)
            MouseArea {
                anchors.fill: parent
                onClicked: root.playlistPickerOpen = false
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(380, root.width - 60)
            height: Math.min(pickerCol.implicitHeight + 32, root.height - 120)
            radius: Theme.rLg
            color: Sys.surface
            border.width: 0

            ColumnLayout {
                id: pickerCol
                anchors.fill: parent
                anchors.margins: Theme.s4
                spacing: Theme.s3

                Text {
                    text: "Añadir a lista"
                    color: Sys.text
                    font.pixelSize: Theme.tLg
                    font.bold: true
                }

                // Creates a new list and adds the target track there.
                Rectangle {
                    Layout.fillWidth: true
                    height: Theme.rowThin
                    radius: Theme.rMd
                    color: newPick.hovered ? Theme.hover(Sys.bg) : "transparent"
                    HoverHandler { id: newPick; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); root.openCreatePlaylist(root.pickerVideoId) } }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        spacing: Theme.s2
                        Glyph {
                            width: 15; height: 15; kind: "plus"
                            color: Sys.accent
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Nueva lista"
                            color: newPick.hovered ? Sys.accent : Sys.text
                            font.pixelSize: Theme.tBase
                            font.bold: true
                        }
                    }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: Math.min(pickerRepeater.implicitHeight, 360)
                    contentHeight: pickerRepeater.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        width: parent.width
                        spacing: Theme.s1

                        Repeater {
                            id: pickerRepeater
                            model: catalog.ytmLibrary
                            delegate: Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                height: Theme.rowThin
                                radius: Theme.rMd
                                color: pickHover.hovered ? Theme.hover(Sys.bg) : "transparent"
                                HoverHandler { id: pickHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); root.addCurrentToPlaylist(root.listIdOf(modelData.url)) }
                                }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    spacing: Theme.s2
                                    Glyph {
                                        width: 15; height: 15; kind: "list"
                                        color: pickHover.hovered ? Sys.accent : Sys.textDim
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name || "Sin nombre"
                                        color: pickHover.hovered ? Sys.text : Sys.textDim
                                        font.pixelSize: Theme.tBase
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }
                                }
                            }
                        }
                        Text {
                            visible: catalog.ytmLibrary.length === 0
                            text: "No hay listas en tu cuenta de YouTube Music"
                            color: Sys.textDim
                            font.pixelSize: Theme.tMd
                        }
                    }
                }

                // Removes the current track from the list it was opened
                // with. It only applies if the track came from a YouTube
                // Music playlist through the fast path (it carries its
                // setVideoId).
                Rectangle {
                    visible: catalog.openPlaylistId.length > 0
                             && root.currentSetId.length > 0
                             && (root.pickerVideoId === root.currentVideoId
                                 || root.pickerVideoId === "")
                    Layout.fillWidth: true
                    height: Theme.rowThin
                    radius: Theme.rMd
                    color: pickHover2.hovered ? Theme.hover(Sys.bg) : "transparent"
                    HoverHandler { id: pickHover2; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); root.removeCurrentFromPlaylist(catalog.openPlaylistId) }
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        spacing: Theme.s2
                        Glyph {
                            width: 15; height: 15; kind: "x"
                            color: pickHover2.hovered ? Sys.accent : Sys.textDim
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "Quitar de la lista actual"
                            color: pickHover2.hovered ? Sys.text : Sys.textDim
                            font.pixelSize: Theme.tBase
                        }
                    }
                }

                Rectangle {
                    Layout.alignment: Qt.AlignRight
                    width: 32; height: 32; radius: Theme.rMd
                    color: closePick.hovered ? Theme.hover(Sys.bg) : "transparent"
                    HoverHandler { id: closePick; cursorShape: Qt.PointingHandCursor }
                    Glyph {
                        anchors.centerIn: parent
                        width: 14; height: 14
                        kind: "x"
                        color: closePick.hovered ? Sys.accent : Sys.textDim
                    }
                    TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); root.playlistPickerOpen = false } }
                }
            }
        }
    }

    // ---- context menu (right click) ----------------------------------
    ContextMenu {
        id: ctxMenu
        anchors.fill: parent
        items: root.ctxItems
        at: Qt.point(root.ctxX, root.ctxY)
        open: root.ctxOpen
        onClosed: root.ctxOpen = false
    }

    // ---- list editor (create / edit) -------------------------------
    PlaylistEditor {
        id: playlistEditor
        anchors.fill: parent
        z: 97
        open: root.editorOpen
        createMode: root.editorCreate
        playlistId: root.editorId
        initialTitle: root.editorTitle
        initialPrivate: root.editorPrivate
        pendingVideoId: root.editorVideoId
        onSubmitted: (data) => root.submitPlaylistEditor(data)
        onDeleteRequested: (id, title) => root.confirmDeletePlaylist(id, title)
        onCanceled: root.editorOpen = false
    }

    // ---- confirmation ----------------------------------------------------
    Rectangle {
        id: confirmOverlay
        anchors.fill: parent
        z: 98
        visible: root.confirmOpen
        color: Qt.rgba(0, 0, 0, 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: root.confirmOpen = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(400, root.width - 60)
            height: confirmCol.implicitHeight + 40
            radius: Theme.rLg
            color: Sys.surface
            border.width: 0

            ColumnLayout {
                id: confirmCol
                anchors.fill: parent
                anchors.margins: Theme.s5
                spacing: Theme.s4

                Text {
                    Layout.fillWidth: true
                    text: root.confirmText
                    color: Sys.text
                    font.pixelSize: Theme.tBase
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s2
                    Item { Layout.fillWidth: true }

                    Rectangle {
                        Layout.preferredHeight: Theme.rowThin
                        implicitWidth: cCancel.implicitWidth + 32
                        radius: Theme.rMd
                        color: cCancelHov.hovered ? Theme.hover(Sys.surfaceAlt) : Sys.surfaceAlt
                        border.width: 0
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Text {
                            id: cCancel
                            anchors.centerIn: parent
                            text: "Cancelar"
                            color: Sys.text
                            font.pixelSize: Theme.tMd
                        }
                        HoverHandler { id: cCancelHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); root.confirmOpen = false } }
                    }

                    Rectangle {
                        Layout.preferredHeight: Theme.rowThin
                        implicitWidth: cOk.implicitWidth + 36
                        radius: Theme.rMd
                        color: cOkHov.hovered ? Qt.lighter(Sys.danger, 1.12) : Sys.danger
                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                        Text {
                            id: cOk
                            anchors.centerIn: parent
                            text: root.confirmLabel
                            color: Sys.onAccent
                            font.pixelSize: Theme.tMd
                            font.bold: true
                        }
                        HoverHandler { id: cOkHov; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); root.runConfirm() } }
                    }
                }
            }
        }
    }

    // ---- toast overlay ---------------------------------------------------
    Rectangle {
        id: toastBubble
        visible: root.toastText.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 84
        z: 70
        width: Math.min(toastLabel.implicitWidth + 30, root.width - 60)
        height: toastLabel.implicitHeight + 18
        radius: Theme.rMd
        color: Sys.surfaceAlt
        border.width: 0
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.medMs } }
        scale: visible ? 1 : 0.94
        Behavior on scale { NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutBack } }

        Text {
            id: toastLabel
            anchors.centerIn: parent
            width: Math.min(root.width - 90, 560)
            text: root.toastText
            color: Sys.text
            font.pixelSize: Theme.tMd
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            horizontalAlignment: Text.AlignHCenter
            maximumLineCount: 3
            elide: Text.ElideMiddle
        }
    }

    // ---- settings panel (full window modal) ------------------------------
    // Settings panel: sections in flat cards, one way of doing each
    // thing. Everything leans on the `Theme` tokens and the `Sys`
    // palette.
    Rectangle {
        id: settingsOverlay
        anchors.fill: parent
        z: 60
        visible: root.settingsOpen
        // Dimmed background (like the rest of the modals): Settings is
        // also ONE more floating island over the shell.
        color: Qt.rgba(0, 0, 0, 0.5)
        opacity: root.settingsOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

        // Blocks the click towards the shell while Settings is open.
        MouseArea { anchors.fill: parent }

        // ---- reusable panel components -------------------------
        // Section card: discreet title + surface with a 1 px border.
        component SettingSection: ColumnLayout {
            id: sec
            property string title: ""
            default property alias content: body.data
            Layout.fillWidth: true
            spacing: Theme.s2

            Text {
                Layout.fillWidth: true
                text: sec.title.toUpperCase()
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                font.weight: Font.DemiBold
                font.letterSpacing: 1.4
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: body.implicitHeight + Theme.s4 * 2
                radius: Theme.rLg
                // A shade lighter than the island, so the card reads as a
                // card on top of it (like the rest of the app).
                color: Sys.surfaceAlt
                // The same faint edge as the islands: the hierarchy is
                // marked by the air, not by a hard line.
                border.width: 1
                border.color: Theme.alpha(Sys.text, Theme.panelBorderAlpha)

                ColumnLayout {
                    id: body
                    anchors.fill: parent
                    anchors.margins: Theme.s4
                    spacing: Theme.s3
                }
            }
        }

        // Row: label + description on the left, control on the right.
        component SettingRow: RowLayout {
            id: row
            property string label: ""
            property string desc: ""
            default property alias control: slot.data
            Layout.fillWidth: true
            implicitHeight: Theme.rowH
            spacing: Theme.s3

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    text: row.label
                    color: Sys.text
                    font.pixelSize: Theme.tMd
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: row.desc !== ""
                    text: row.desc
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }
            RowLayout {
                id: slot
                Layout.alignment: Qt.AlignVCenter
                spacing: Theme.s2
            }
        }

        // Block: label + description on top and the control full width
        // below.
        component SettingBlock: ColumnLayout {
            id: blk
            property string label: ""
            property string desc: ""
            default property alias content: inner.data
            Layout.fillWidth: true
            spacing: Theme.s2

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    text: blk.label
                    color: Sys.text
                    font.pixelSize: Theme.tMd
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: blk.desc !== ""
                    text: blk.desc
                    color: Sys.textDim
                    font.pixelSize: Theme.tXs
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }
            RowLayout {
                id: inner
                Layout.fillWidth: true
                spacing: Theme.s2
            }
        }

        // Switch style: track + knob, accent when it is on.
        component Toggle: Rectangle {
            id: tg
            property bool checked: false
            signal toggled()
            width: 40
            height: 22
            radius: 11
            color: tg.checked ? Sys.accent : Theme.mix(Sys.surface, Sys.text, 0.16)
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            Rectangle {
                width: 18
                height: 18
                radius: 9
                color: Sys.onAccent
                anchors.verticalCenter: parent.verticalCenter
                x: tg.checked ? parent.width - width - 3 : 3
                Behavior on x { NumberAnimation { duration: Theme.fastMs } }
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("toggle")
                    tg.toggled()
                }
            }
        }

        // Single choice chip.
        component Chip: Rectangle {
            id: ch
            property string text: ""
            property bool selected: false
            signal picked()
            implicitWidth: chLabel.implicitWidth + Theme.pillHPad * 2
            height: Theme.pillH
            radius: Theme.rPill
            color: ch.selected ? Sys.accentDim
                               : (chHover.containsMouse ? Theme.hover(Sys.surface) : "transparent")
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            Text {
                id: chLabel
                anchors.centerIn: parent
                text: ch.text
                color: ch.selected ? Sys.accent
                                   : (chHover.containsMouse ? Sys.text : Sys.textDim)
                font.pixelSize: Theme.tSm
                font.weight: ch.selected ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
            }
            MouseArea {
                id: chHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("toggle")
                    ch.picked()
                }
            }
        }

        // Text field with label and placeholder.
        component Field: ColumnLayout {
            id: fld
            property string label: ""
            property string placeholder: ""
            property bool password: false
            property alias text: input.text
            spacing: Theme.s1

            Text {
                visible: fld.label !== ""
                text: fld.label
                color: Sys.textDim
                font.pixelSize: Theme.tXs
            }
            Rectangle {
                Layout.fillWidth: true
                height: 34
                radius: Theme.rMd
                color: Sys.bg
                border.width: 1
                border.color: input.activeFocus ? Sys.accent : Sys.borderSubtle
                Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.leftMargin: Theme.s3
                    anchors.rightMargin: Theme.s3
                    verticalAlignment: Text.AlignVCenter
                    color: Sys.text
                    font.pixelSize: Theme.tMd
                    clip: true
                    echoMode: fld.password ? TextInput.Password : TextInput.Normal
                }
                Text {
                    visible: input.text.length === 0
                    anchors.fill: parent
                    anchors.leftMargin: Theme.s3
                    verticalAlignment: Text.AlignVCenter
                    text: fld.placeholder
                    color: Sys.textDim
                    font.pixelSize: Theme.tSm
                }
            }
        }

        // Primary button (accent).
        component PrimaryButton: Rectangle {
            id: pb
            property string text: ""
            signal clicked()
            implicitWidth: pbLabel.implicitWidth + Theme.s5
            height: 36
            radius: Theme.rPill
            color: pbHover.containsMouse ? Theme.active(Sys.accent) : Sys.accent
            scale: pbHover.pressed ? 0.97 : 1
            Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            Text {
                id: pbLabel
                anchors.centerIn: parent
                text: pb.text
                color: Sys.onAccent
                font.pixelSize: Theme.tMd
                font.weight: Font.DemiBold
            }
            MouseArea {
                id: pbHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("tap")
                    pb.clicked()
                }
            }
        }

        // Secondary button; `danger` tints it red for destructive
        // actions.
        component GhostButton: Rectangle {
            id: gb
            property string text: ""
            property bool danger: false
            signal clicked()
            implicitWidth: gbLabel.implicitWidth + Theme.s4
            height: 34
            radius: Theme.rPill
            color: gbHover.containsMouse
                   ? (gb.danger ? Theme.alpha(Sys.danger, 0.12) : Theme.hover(Sys.surfaceAlt))
                   : (gb.danger ? "transparent" : Sys.surfaceAlt)
            Behavior on color { ColorAnimation { duration: Theme.fastMs } }

            Text {
                id: gbLabel
                anchors.centerIn: parent
                text: gb.text
                color: gb.danger
                       ? (gbHover.containsMouse ? Sys.danger : Sys.textDim)
                       : (gbHover.containsMouse ? Sys.accent : Sys.text)
                font.pixelSize: Theme.tMd
                font.weight: Font.DemiBold
            }
            MouseArea {
                id: gbHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (typeof sfx !== "undefined") sfx.play("tap")
                    gb.clicked()
                }
            }
        }

        // Status badge (list / pending, or session signed in).
        component StatusBadge: Rectangle {
            id: sb
            property bool ok: false
            property string okText: "Lista"
            property string offText: "Pendiente"
            implicitWidth: sbLabel.implicitWidth + Theme.s3
            height: 20
            radius: 10
            color: sb.ok ? Sys.accentDim : Theme.alpha(Sys.danger, 0.14)

            Text {
                id: sbLabel
                anchors.centerIn: parent
                text: sb.ok ? sb.okText : sb.offText
                color: sb.ok ? Sys.accent : Sys.danger
                font.pixelSize: Theme.tXs
                font.weight: Font.DemiBold
            }
        }

        // The Settings island: the same rounded surface and the same faint
        // edge as the rest of the shell (the rail, the bar, the panels), but
        // nearly opaque because it is a modal. The content goes on top with
        // its own padding, exactly like the other islands.
        Panel {
            id: settingsIsland
            anchors.fill: parent
            anchors.margins: Theme.panelMargin
            radius: Theme.rPanel
            color: Theme.alpha(Sys.surface, 0.97)
            clipContent: true
        }

        ColumnLayout {
            id: settingsLayout
            anchors.fill: parent
            anchors.leftMargin: Theme.panelMargin + Theme.s4
            anchors.rightMargin: Theme.panelMargin + Theme.s4
            anchors.topMargin: Theme.panelMargin + Theme.s3
            anchors.bottomMargin: Theme.panelMargin + Theme.s3
            spacing: Theme.s3

            // ---- header -----------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s3

                Text {
                    text: "Ajustes"
                    color: Sys.text
                    font.pixelSize: Theme.tXl
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }

                Rectangle { // close
                    width: 32
                    height: 32
                    radius: Theme.rMd
                    color: closeMa.containsMouse ? Sys.surfaceAlt : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 16
                        height: 16
                        kind: "x"
                        color: closeMa.containsMouse ? Sys.accent : Sys.textDim
                    }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            root.settingsOpen = false
                        }
                    }
                }
            }

            Flickable {
                id: settingsScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: settingsCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: settingsCol
                    // Centred column with a readable width: it does not
                    // stretch edge to edge on wide screens and never
                    // overflows on small windows.
                    width: Math.min(settingsScroll.width, 820)
                    x: Math.max(0, (settingsScroll.width - width) / 2)
                    spacing: Theme.s5

                    // ======================================================
                    // APPEARANCE
                    // ======================================================
                    SettingSection {
                        title: "Apariencia"

                        SettingRow {
                            label: "Seguir el tema del sistema"
                            desc: "Usa la paleta del escritorio (iNiR/matugen)"
                            Toggle {
                                checked: root.followSys
                                onToggled: {
                                    root.followSys = !root.followSys
                                    root.cfgSet("followSystem", root.followSys ? "true" : "false")
                                    root.toast("Guardado en la configuración")
                                }
                            }
                        }

                        // Wash of the current artwork as background
                        // (Liner style): pseudo blur with no GPU +
                        // frosted islands.
                        SettingRow {
                            label: "Fondo dinámico"
                            desc: "La portada de la pista tiñe el fondo y esmerila los paneles"
                            Toggle {
                                checked: Sys.dynamicBg
                                onToggled: {
                                    Sys.dynamicBg = !Sys.dynamicBg
                                    root.cfgSet("dynamicBg", Sys.dynamicBg)
                                    // When it is switched on mid session,
                                    // the wash is computed with the current
                                    // track right away.
                                    if (Sys.dynamicBg && root.currentThumb)
                                        wash.setSource(root.currentThumb)
                                    root.toast("Guardado en la configuración")
                                }
                            }
                        }

                        SettingRow {
                            label: "Color de acento"
                            desc: "Hexadecimal, por ejemplo #e3bae5"
                            RowLayout {
                                spacing: Theme.s2
                                Field {
                                    id: accentField
                                    Layout.preferredWidth: 150
                                    placeholder: "#e3bae5"
                                    text: root.cfgGet("accent")
                                }
                                PrimaryButton {
                                    text: "Aplicar"
                                    onClicked: {
                                        const v = accentField.text.trim()
                                        if (!root.hexOk(v)) {
                                            root.toast("Color inválido: usa #rrggbb")
                                            return
                                        }
                                        root.cfgSet("accent", v.charAt(0) === "#" ? v : "#" + v)
                                        root.toast("Guardado en la configuración")
                                    }
                                }
                            }
                        }
                    }

                    // ======================================================
                    // PLAYBACK
                    // ======================================================
                    SettingSection {
                        title: "Reproducción"

                        SettingBlock {
                            label: "Fuente por defecto"
                            desc: "Con qué servicio empieza la app"
                            Repeater {
                                model: sources.list
                                delegate: Chip {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    text: modelData.name
                                    selected: sources.activeId === modelData.id
                                    onPicked: {
                                        root.pickSource(modelData.id)
                                        root.cfgSet("defaultSource", modelData.id)
                                        root.toast("Guardado en la configuración")
                                    }
                                }
                            }
                        }

                        SettingBlock {
                            label: "Calidad de audio"
                            desc: "Máxima sin recodificar; bájala para ahorrar datos"
                            Repeater {
                                model: [
                                    { id: "max", label: "Máxima" },
                                    { id: "alta", label: "Alta" },
                                    { id: "media", label: "Media" },
                                    { id: "baja", label: "Baja" }
                                ]
                                delegate: Chip {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    text: modelData.label
                                    selected: player.quality === modelData.id
                                    onPicked: {
                                        player.setQuality(modelData.id)
                                        root.cfgSet("audioQuality", modelData.id)
                                        root.toast("Calidad: " + modelData.label)
                                    }
                                }
                            }
                        }

                        // When the queue runs out, YouTube Music plays
                        // the "next song" (a radio seeded with the last
                        // one).
                        SettingRow {
                            label: "Reproducción automática"
                            desc: "Al terminar la cola, sigue con canciones parecidas"
                            Toggle {
                                checked: root.autoplayEnabled
                                onToggled: {
                                    root.autoplayEnabled = !root.autoplayEnabled
                                    root.cfgSet("autoplay", root.autoplayEnabled)
                                    if (!root.autoplayEnabled) {
                                        root.autoplayRadioPending = false
                                        root.autoplayRadioSeed = ""
                                        radioWaitTimer.stop()
                                    }
                                }
                            }
                        }
                    }

                    // ======================================================
                    // LYRICS
                    // ======================================================
                    SettingSection {
                        title: "Letras"

                        SettingRow {
                            label: "Letras sincronizadas"
                            desc: "Busca la letra de cada canción"
                            Toggle {
                                checked: root.lyricsEnabled
                                onToggled: {
                                    root.lyricsEnabled = !root.lyricsEnabled
                                    root.cfgSet("lyricsEnabled", root.lyricsEnabled)
                                    if (!root.lyricsEnabled)
                                        lyrics.clear()
                                    else {
                                        root.lyricsKey = ""
                                        root.fetchLyrics()
                                    }
                                }
                            }
                        }
                        SettingRow {
                            label: "Karaoke palabra a palabra"
                            desc: "Enciende cada palabra al cantarla; si no hay tiempos, frase entera"
                            Toggle {
                                checked: root.karaokeWords
                                onToggled: {
                                    root.karaokeWords = !root.karaokeWords
                                    root.cfgSet("karaokeWords", root.karaokeWords)
                                    lyrics.karaoke = root.karaokeWords
                                }
                            }
                        }
                        SettingRow {
                            label: "Compensación de tiempo"
                            desc: "Adelanta (+) o retrasa (−) la letra respecto al audio"
                            RowLayout {
                                spacing: Theme.s2
                                Text {
                                    text: (root.lyricsOffset > 0 ? "+" : "")
                                          + root.lyricsOffset.toFixed(1) + " s"
                                    color: Math.abs(root.lyricsOffset) > 0.001
                                           ? Sys.accent : Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    font.weight: Font.DemiBold
                                }
                                GhostButton {
                                    text: "−"
                                    onClicked: root.setLyricsOffset(root.lyricsOffset - 0.1)
                                }
                                GhostButton {
                                    text: "+"
                                    onClicked: root.setLyricsOffset(root.lyricsOffset + 0.1)
                                }
                            }
                        }
                        SettingRow {
                            label: "Letra a pantalla completa"
                            desc: "Modo cine de dos columnas; también con L, F o Ctrl+L"
                            GhostButton {
                                text: "Abrir"
                                onClicked: root.openFullscreenLyrics()
                            }
                        }
                    }

                    // ======================================================
                    // DISCORD
                    // ======================================================
                    SettingSection {
                        title: "Discord"

                        SettingRow {
                            label: "Discord Rich Presence"
                            desc: "Muestra lo que suena en tu perfil"
                            RowLayout {
                                spacing: Theme.s2
                                Text {
                                    text: discord.connected ? "Conectado"
                                          : (root.discordEnabled ? "Sin conexión" : "Desactivado")
                                    color: discord.connected ? Sys.accent : Sys.textDim
                                    font.pixelSize: Theme.tXs
                                    font.weight: Font.DemiBold
                                }
                                Toggle {
                                    checked: root.discordEnabled
                                    onToggled: {
                                        root.discordEnabled = !root.discordEnabled
                                        root.cfgSet("discordRpc", root.discordEnabled)
                                        discord.configure(root.discordEnabled, "")
                                    }
                                }
                            }
                        }
                    }

                    // ======================================================
                    // DOWNLOADS
                    // ======================================================
                    SettingSection {
                        title: "Descargas"

                        SettingBlock {
                            label: "Carpeta de descargas"
                            desc: "Dónde se guardan las canciones descargadas"
                            Rectangle {
                                Layout.fillWidth: true
                                height: 34
                                radius: Theme.rMd
                                color: Sys.bg
                                border.width: 1
                                border.color: Sys.borderSubtle
                                Text {
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    verticalAlignment: Text.AlignVCenter
                                    text: downloads.folder
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    elide: Text.ElideMiddle
                                }
                            }
                            GhostButton {
                                text: "Abrir carpeta"
                                onClicked: downloads.openFolder()
                            }
                        }

                        SettingBlock {
                            label: "Actualizaciones"
                            desc: "Se busca la última versión publicada en el repositorio"
                            Text {
                                Layout.fillWidth: true
                                text: updates.available
                                      ? "Hay una versión nueva: " + updates.latestVersion
                                      : "Versión actual: " + updates.currentVersion
                                color: updates.available ? Sys.accent : Sys.textDim
                                font.pixelSize: Theme.tSm
                                elide: Text.ElideRight
                            }
                            GhostButton {
                                text: "Buscar actualizaciones"
                                onClicked: {
                                    updates.check()
                                }
                            }
                            GhostButton {
                                text: "Ver la versión publicada"
                                visible: updates.url !== ""
                                onClicked: updates.openDownload()
                            }
                        }

                        SettingBlock {
                            label: "Sesión de YouTube Music"
                            desc: "Las cookies de la cuenta: hacen falta para las listas privadas y, en Android, para que suene el audio. Se puede exportar aquí y llevarla a otro dispositivo"
                            GhostButton {
                                text: "Exportar la sesión"
                                onClicked: {
                                    root.sessionExported = catalog.exportSession(root.sessionPath)
                                    root.toast(root.sessionExported
                                               ? "Sesión exportada a " + root.sessionPath
                                               : "No se pudo exportar la sesión")
                                }
                            }
                            GhostButton {
                                text: "Importar la sesión"
                                onClicked: sessionDialog.open()
                            }
                        }
                    }

                    // ======================================================
                    // ACCOUNTS
                    // ======================================================
                    SettingSection {
                        title: "Cuentas"

                        Repeater {
                            model: sources.list
                            delegate: ColumnLayout {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                // Air between the accounts instead of a
                                // dividing line.
                                Layout.topMargin: index > 0 ? Theme.s5 : 0
                                spacing: Theme.s3

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    Text {
                                        text: modelData.name
                                        color: Sys.text
                                        font.pixelSize: Theme.tMd
                                        font.weight: Font.DemiBold
                                    }
                                    StatusBadge {
                                        ok: modelData.status === "ready"
                                    }
                                    Item { Layout.fillWidth: true }
                                }

                                // ---- YouTube Music (Google sign in) ------
                                Text {
                                    Layout.fillWidth: true
                                    visible: modelData.id === "ytm"
                                    text: "Inicia sesión con Google y sincroniza tus «Me gusta»."
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    elide: Text.ElideRight
                                }

                                RowLayout { // session signed in
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    visible: modelData.id === "ytm" && root.ytmState() === "ok"
                                    StatusBadge { ok: true; okText: "Sesión iniciada" }
                                    GhostButton {
                                        text: "Sincronizar Me gusta"
                                        onClicked: catalog.syncLiked()
                                    }
                                    GhostButton {
                                        text: "Cerrar sesión"
                                        danger: true
                                        onClicked: catalog.logoutYTM()
                                    }
                                    Item { Layout.fillWidth: true }
                                }

                                PrimaryButton { // sign in
                                    visible: modelData.id === "ytm"
                                             && (root.ytmState() === "" || root.ytmState() === "nologin")
                                    text: "Iniciar sesión con Google"
                                    onClicked: root.ytmLogin()
                                }

                                ColumnLayout { // waiting for the sign in
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    visible: modelData.id === "ytm" && root.ytmState() === "waiting"

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s3
                                        Item { // spinning indicator (only with the panel open)
                                            width: 18
                                            height: 18
                                            Rectangle {
                                                width: 2
                                                height: 8
                                                radius: 1
                                                color: Sys.accent
                                                anchors.top: parent.top
                                                anchors.topMargin: 1
                                                anchors.horizontalCenter: parent.horizontalCenter
                                            }
                                            RotationAnimator on rotation {
                                                from: 0
                                                to: 360
                                                duration: 900
                                                loops: Animation.Infinite
                                                running: root.settingsOpen
                                                         && root.ytmState() === "waiting"
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: "Esperando a que inicies sesión en la ventana de Google…"
                                            color: Sys.text
                                            font.pixelSize: Theme.tMd
                                            elide: Text.ElideRight
                                        }
                                        GhostButton {
                                            text: "Cancelar"
                                            danger: true
                                            onClicked: catalog.logoutYTM()
                                        }
                                    }
                                }

                                ColumnLayout { // error
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    visible: modelData.id === "ytm" && root.ytmState() === "error"

                                    Text {
                                        Layout.fillWidth: true
                                        text: root.ytmError()
                                        color: Sys.danger
                                        font.pixelSize: Theme.tSm
                                        wrapMode: Text.WordWrap
                                    }
                                    PrimaryButton {
                                        text: "Reintentar"
                                        onClicked: root.ytmLogin()
                                    }
                                }

                                // ---- SoundCloud (public access) -----------
                                Text {
                                    Layout.fillWidth: true
                                    visible: modelData.id === "soundcloud"
                                    text: "Acceso público, sin necesidad de cuenta."
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    elide: Text.ElideRight
                                }

                                // ---- Spotify (credentials) ----------------
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: modelData.id === "spotify"
                                    spacing: Theme.s3

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        Field {
                                            id: spotCid
                                            Layout.fillWidth: true
                                            label: "Client ID"
                                            placeholder: "developer.spotify.com"
                                        }
                                        Field {
                                            id: spotUser
                                            Layout.fillWidth: true
                                            label: "Usuario"
                                            placeholder: "cuenta Premium"
                                        }
                                        Field {
                                            id: spotPass
                                            Layout.fillWidth: true
                                            label: "Contraseña"
                                            placeholder: "••••••••"
                                            password: true
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        PrimaryButton {
                                            text: "Guardar"
                                            onClicked: {
                                                root.cfgLogin("spotify", spotCid.text,
                                                              spotUser.text, spotPass.text)
                                                root.toast("Guardado en la configuración")
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: "Se activará cuando el backend librespot esté listo."
                                            color: Sys.textDim
                                            font.pixelSize: Theme.tXs
                                            elide: Text.ElideRight
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                }

                                // ---- Tidal (credentials) ------------------
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: modelData.id === "tidal"
                                    spacing: Theme.s3

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        Field {
                                            id: tidalUser
                                            Layout.fillWidth: true
                                            label: "Usuario"
                                            placeholder: "cuenta Tidal"
                                        }
                                        Field {
                                            id: tidalPass
                                            Layout.fillWidth: true
                                            label: "Contraseña"
                                            placeholder: "••••••••"
                                            password: true
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        PrimaryButton {
                                            text: "Guardar"
                                            onClicked: {
                                                root.cfgLogin("tidal", tidalUser.text,
                                                              tidalPass.text, "")
                                                root.toast("Guardado en la configuración")
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: "Se activará cuando el backend esté listo."
                                            color: Sys.textDim
                                            font.pixelSize: Theme.tXs
                                            elide: Text.ElideRight
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- own scroll indicator -------------------------------
        Rectangle {
            id: settingsBar
            visible: settingsScroll.contentHeight > settingsScroll.height + 1
            width: 3
            radius: 1.5
            color: Sys.accent
            opacity: 0.4
            x: settingsLayout.x + settingsScroll.x + settingsScroll.width - 8
            y: settingsLayout.y + settingsScroll.y
               + Math.max(0, settingsScroll.height - height)
                 * (settingsScroll.contentHeight > settingsScroll.height
                    ? settingsScroll.contentY
                      / (settingsScroll.contentHeight - settingsScroll.height)
                    : 0)
            height: Math.max(24, settingsScroll.height
                             * settingsScroll.height
                             / Math.max(1, settingsScroll.contentHeight))
            Behavior on y { NumberAnimation { duration: Theme.fastMs } }
        }
    }

    // ---- launcher (command palette) ---------------------------------------
    Rectangle {
        id: launcherOverlay
        anchors.fill: parent
        z: 55
        visible: root.launcherOpen
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: root.launcherOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

        MouseArea { // click outside closes
            anchors.fill: parent
            onClicked: root.closeLauncher()
        }

        Rectangle {
            id: launcherPanel
            anchors.centerIn: parent
            width: Math.min(520, root.width - 70)
            height: Math.min(launcherCol.implicitHeight + 18, root.height - 90)
            radius: Theme.rLg
            color: Sys.surface
            border.width: 0
            scale: root.launcherOpen ? 1 : 0.97
            Behavior on scale { NumberAnimation { duration: Theme.medMs; easing.type: Easing.OutCubic } }

            // The wheel that is left over (over the field) stays in the
            // panel: it does not drag the list below or the window.
            WheelHandler { onWheel: (event) => { event.accepted = true } }

            ColumnLayout {
                id: launcherCol
                anchors.fill: parent
                anchors.margins: Theme.s2
                spacing: Theme.s2

                Rectangle { // search bar
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    radius: Theme.rMd
                    color: Sys.bg
                    border.width: 1
                    border.color: launchInput.activeFocus ? Sys.accent : Sys.borderSubtle
                    Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        spacing: Theme.s2
                        Glyph {
                            width: 16
                            height: 16
                            kind: "search"
                            color: Sys.textDim
                        }
                        TextInput {
                            id: launchInput
                            Layout.fillWidth: true
                            verticalAlignment: Text.AlignVCenter
                            color: Sys.text
                            font.pixelSize: Theme.tBase
                            clip: true
                            text: ""
                            onTextChanged: { root.buildLauncher(text); launcherSearch.restart() }
                            Keys.onEscapePressed: root.closeLauncher()
                        }
                        Text {
                            text: "Esc"
                            color: Sys.textDim
                            font.pixelSize: Theme.tXs
                            font.bold: true
                            opacity: 0.6
                        }
                    }
                }

                Flickable {
                    id: launcherFlick
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(400, Math.max(120, rowsCol.implicitHeight + 10))
                    contentHeight: rowsCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: rowsCol
                        width: launcherFlick.width
                        spacing: Theme.s1

                        Text {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.s2
                            visible: root.launcherRows.length === 0
                            text: "Sin resultados"
                            color: Sys.textDim
                            font.pixelSize: Theme.tMd
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Repeater {
                            model: root.launcherRows

                            delegate: Item {
                                required property var modelData
                                id: lrow
                                Layout.fillWidth: true
                                height: modelData.h ? 22 : 36

                                Text { // group header
                                    visible: modelData.h
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.s2
                                    text: modelData.t
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tXs
                                    font.letterSpacing: 1.4
                                }

                                Rectangle { // item row
                                    visible: !modelData.h
                                    anchors.fill: parent
                                    radius: Theme.rSm
                                    color: rowHover.containsMouse ? Sys.bg : "transparent"
                                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.s2
                                        anchors.rightMargin: Theme.s2
                                        spacing: Theme.s2

                                        Glyph {
                                            width: 15
                                            height: 15
                                            kind: lrow.modelData.kind === "source"
                                                  ? (lrow.modelData.locked ? "lock" : "search")
                                                  : (lrow.modelData.kind === "playlist" ? "library" : "play")
                                            color: rowHover.containsMouse ? Sys.accent : Sys.textDim
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            Text {
                                                Layout.fillWidth: true
                                                text: lrow.modelData.t
                                                color: Sys.text
                                                font.pixelSize: Theme.tMd
                                                font.bold: lrow.modelData.kind === "source" && !lrow.modelData.locked
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                visible: (lrow.modelData.s || "").length > 0
                                                text: lrow.modelData.h ? "" : (lrow.modelData.s || "")
                                                color: Sys.textDim
                                                font.pixelSize: Theme.tXs
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }

                                    MouseArea {
                                        id: rowHover
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.launcherActivate(lrow.modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- artist page (full screen layer) ----------------------
    // Discography of the artist opened from the artist search. Below
    // the popups and the toasts (z 97/98) so the "N tracks in the
    // queue" notice stays readable with the page open.
    ArtistPage {
        id: artistOverlay
        anchors.fill: parent
        z: 64
        visible: root.artistOpen
        artist: root.artistCur
        albums: root.artistAlbums
        busy: root.artistBusy
        onBackRequested: root.closeArtist()
        onPlayAllRequested: (random) => root.artistPlayAll(root.artistAlbums, random)
        onAlbumPlayRequested: (album) => root.artistPlayAlbum(album)
    }

    // ---- startup splash ------------------------------------------------
    // The lotus fades in with a slight growth, holds, and fades out. An
    // Item inside the window (no second window: zero RAM cost) that also
    // swallows the clicks while it lasts (~1.3 s).
    Item {
        id: splashOverlay
        anchors.fill: parent
        z: 200
        property bool done: false
        visible: !done
        transformOrigin: Item.Center

        Rectangle {
            anchors.fill: parent
            color: Sys.bg
        }

        MouseArea {
            anchors.fill: parent
        }

        Column {
            anchors.centerIn: parent
            spacing: Theme.s4

            LotusMark {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 132
                height: 120
                petalColor: Sys.accent
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Lotus Tune"
                color: Sys.text
                font.pixelSize: Theme.tXl
                font.weight: Font.DemiBold
                font.letterSpacing: 2.5
            }
        }

        SequentialAnimation {
            id: splashAnim
            ParallelAnimation {
                NumberAnimation {
                    target: splashOverlay
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: 430
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: splashOverlay
                    property: "scale"
                    from: 0.86
                    to: 1
                    duration: 430
                    easing.type: Easing.OutCubic
                }
            }
            PauseAnimation { duration: 480 }
            ParallelAnimation {
                NumberAnimation {
                    target: splashOverlay
                    property: "opacity"
                    from: 1
                    to: 0
                    duration: 420
                    easing.type: Easing.InQuad
                }
                NumberAnimation {
                    target: splashOverlay
                    property: "scale"
                    from: 1
                    to: 1.06
                    duration: 420
                    easing.type: Easing.InQuad
                }
            }
            PropertyAction { target: splashOverlay; property: "done"; value: true }
        }

        Component.onCompleted: splashAnim.start()
    }

}
