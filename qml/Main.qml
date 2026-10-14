import QtQuick
import QtQuick.Layouts
import QtQuick.Window
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
    property bool followSys: true
    property var launcherRows: []

    // ---- preferencias nuevas (calidad, letras, Discord, descargas) --------
    property bool lyricsEnabled: true
    property bool discordEnabled: false

    // ---- panel derecho (cola / letra) ------------------------------------
    property bool panelOpen: false
    property int panelTab: 0            // 0 = cola, 1 = letra

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

    // ---- menú contextual (clic derecho) ----------------------------------
    property bool ctxOpen: false
    property var ctxItems: []
    property real ctxX: 0
    property real ctxY: 0

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

    // ---- editor de listas (crear / renombrar / privacidad) ---------------
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

    // ---- confirmación (eliminar lista, etc.) -----------------------------
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

    // ---- portapapeles (copiar enlace) ------------------------------------
    function copyToClipboard(text) {
        const s = String(text || "")
        if (!s)
            return
        clip.text = s
        clip.selectAll()
        clip.copy()
        root.toast("Enlace copiado")
    }

    // ---- cola: reproducir a continuación / añadir a la cola --------------
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
        queue.append(root.queueRow(t))
        root.toast("Añadido a la cola")
    }

    // Reproduce una lista en orden aleatorio (botón «aleatorio» del hero).
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

    // ---- menús: qué entradas tiene cada tipo de elemento -----------------
    // Pista (resultados, listas, cola, descargas). Las acciones de YouTube van
    // sólo si hay sesión y la pista tiene videoId.
    function trackMenuItems(t) {
        t = t || {}
        const url = String(t.url || "")
        const vid = root.videoIdOf(url)
        const canYt = (catalog.loginState === "ok") && vid !== ""
        const liked = (catalog.likedReady === true) ? catalog.isLiked(url)
                                                    : (t.liked === true)
        const out = []
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
        return out
    }

    // Lista (cover de la biblioteca).
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
        return out
    }

    // Lista guardada en la biblioteca local (Barra lateral): reproducir, abrir,
    // copiar enlace y quitarla de la biblioteca.
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
    function pageTitle() {
        if (page === "search")
            return "Buscar"
        if (page === "library")
            // Dentro de una lista/álbum el título es el de la lista: el click
            // lleva directo al contenido, sin pasar por la portada de Biblioteca.
            return (libPage.showingTracks && catalog.tracksTitle)
                   ? catalog.tracksTitle : "Biblioteca"
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

    function toggleSettings() { launcherOpen = false; settingsOpen = !settingsOpen }
    function toggleLauncher() {
        settingsOpen = false
        if (!launcherOpen) {
            root.buildLauncher(launchInput && launchInput.text)
            launcherOpen = true
            // El foco debe ir al campo: así typing() es true y los atajos
            // (F, Space, flechas…) no se disparan mientras se escribe.
            if (launchInput)
                launchInput.forceActiveFocus()
        } else {
            launcherOpen = false
            if (launchInput)
                launchInput.focus = false   // el foco vuelve a la ventana
        }
    }

    // ---- teclado -------------------------------------------------------
    // true mientras el foco está en un campo de texto (para no robar Space,
    // flechas, etc. mientras se escribe).
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
        console.log("[qa] toggleFullscreen -> " + fullscreen)
    }

    // ---- navegación con pila («atrás») ------------------------------------
    // Pila simple de páginas: al abrir una lista/álbum se guarda la página de
    // la que venías (normalmente Inicio), así Esc o el botón «atrás» de la
    // barra superior vuelven ahí y no a la portada de Biblioteca.
    property var navStack: []

    // Navega a `p` guardando la página actual en la pila (force: guarda
    // aunque sea la misma página, p.ej. Biblioteca → vista de pistas).
    function pushPage(p, force) {
        if (p !== page || force) {
            let s = navStack.concat([page])
            if (s.length > 12)
                s = s.slice(s.length - 12)
            navStack = s
        }
        page = p
    }

    // Vuelve a la página anterior. Devuelve false si no hay nada detrás.
    function navBack() {
        if (navStack.length === 0)
            return false
        const prev = navStack[navStack.length - 1]
        navStack = navStack.slice(0, -1)
        page = prev
        if (prev === "library")
            libPage.showingTracks = false
        console.log("[qa] navBack -> " + prev + " stack=" + navStack.join(">"))
        return true
    }

    // Navegación raíz (barra lateral / Inicio): guardamos de dónde venimos.
    function navTo(p) {
        if (p === "library")
            libPage.showingTracks = false
        pushPage(p)
    }

    // Esc "atrás": cierra overlays, el panel lateral, sale de pantalla completa
    // o —al final— vuelve a la página anterior (una lista/álbum → Inicio).
    function goBack() {
        if (root.ctxOpen) { root.ctxOpen = false; return }
        if (root.confirmOpen) { root.confirmOpen = false; return }
        if (root.editorOpen) { root.editorOpen = false; return }
        if (root.playlistPickerOpen) { root.playlistPickerOpen = false; return }
        if (root.launcherOpen) {
            root.launcherOpen = false
            if (launchInput)
                launchInput.focus = false
            return
        }
        if (root.settingsOpen) { root.settingsOpen = false; return }
        if (root.nowPlayingOpen) { root.nowPlayingOpen = false; return }
        if (root.panelOpen) { root.panelOpen = false; return }
        if (root.fullscreen) { root.toggleFullscreen(); return }
        if (navBack())
            return
        // Reserva: una lista/álbum sin pila atrás va a Inicio.
        if (page === "library" && libPage.showingTracks) {
            libPage.showingTracks = false
            page = "home"
        }
    }

    // Al pedir una lista: marca la carga en curso y decide si, al llegar las
    // pistas, hay que reproducirlas (botón de play) o sólo abrirlas (clic en
    // la portada / la lista). Abrir NO reproduce.
    function beginOpenList(play) {
        pendingPlay = !!play
        listLoading = true
        console.log("[qa] beginOpenList play=" + pendingPlay)
        toast(play ? "Cargando la lista para reproducir…" : "Cargando la lista…")
    }

    // Muestra la vista de pistas de la lista abierta. Se llama cuando las
    // pistas YA están cargadas: un solo salto directo al álbum, sin pasar por
    // la portada de Biblioteca.
    function openTracksView() {
        const from = page
        if (!(page === "library" && libPage.showingTracks))
            pushPage("library", true)   // guarda la página de la que venías
        libPage.openTracks()
        console.log("[qa] openTracksView from=" + from + " stack=" + navStack.join(">"))
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
        onActivated: root.toggleSettings()
    }
    Shortcut {
        sequence: "Ctrl+Space"
        onActivated: root.toggleLauncher()
    }
    // Espacio: reproducir / pausar (salvo escribiendo en un campo).
    Shortcut {
        sequence: "Space"
        enabled: !root.typing()
        onActivated: if (root.currentTitle) player.playPause()
    }
    // Flechas: ±5 s de búsqueda; Ctrl+flechas o Media: pista anterior/siguiente.
    Shortcut {
        sequence: "Right"
        enabled: !root.typing() && root.currentTitle !== ""
        onActivated: player.seek(Math.min(player.position + 5, player.duration))
    }
    Shortcut {
        sequence: "Left"
        enabled: !root.typing() && root.currentTitle !== ""
        onActivated: player.seek(Math.max(0, player.position - 5))
    }
    Shortcut {
        sequence: "Ctrl+Right"
        enabled: !root.typing()
        onActivated: root.next()
    }
    Shortcut {
        sequence: "Ctrl+Left"
        enabled: !root.typing()
        onActivated: root.prev()
    }
    // Volumen con arriba/abajo; M silencia.
    Shortcut {
        sequence: "Up"
        enabled: !root.typing()
        onActivated: root.nudgeVolume(5)
    }
    Shortcut {
        sequence: "Down"
        enabled: !root.typing()
        onActivated: root.nudgeVolume(-5)
    }
    Shortcut {
        sequence: "M"
        enabled: !root.typing()
        onActivated: root.toggleMute()
    }
    Shortcut {
        sequence: "S"
        enabled: !root.typing()
        onActivated: root.toggleShuffle()
    }
    Shortcut {
        sequence: "R"
        enabled: !root.typing()
        onActivated: root.toggleRepeat()
    }
    // L: letra (abre "En reproducción"); Q: cola; F11: pantalla completa.
    Shortcut {
        sequence: "L"
        enabled: !root.typing()
        onActivated: root.nowPlayingOpen = true
    }
    Shortcut {
        sequence: "Q"
        enabled: !root.typing()
        onActivated: root.togglePanel(0)
    }
    Shortcut {
        sequence: "F11"
        onActivated: root.toggleFullscreen()
    }
    // F: modo letra / "En reproducción" (igual que L), salvo mientras se
    // escribe en un campo de texto (búsquedas, URLs, etc.). Fullscreen queda
    // en F11 (y Mod+Shift+F a nivel del compositor).
    Shortcut {
        sequence: "F"
        enabled: !root.typing()
        onActivated: root.nowPlayingOpen = !root.nowPlayingOpen
    }

    // ---- launcher data ---------------------------------------------------
    function launcherActivate(row) {
        if (!row)
            return
        if (row.kind === "source") {
            if (row.locked) {
                launcherOpen = false
                settingsOpen = true
            } else {
                sources.select(row.id)
                launcherOpen = false
                page = "search"
            }
        } else if (row.kind === "playlist") {
            root.beginOpenList(false)
            catalog.openPlaylist(row.i)
            launcherOpen = false
        } else if (row.kind === "recent") {
            root.playTracks(catalog.recent, row.i)
            launcherOpen = false
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
                       s: s.status === "ready" ? "Buscar música" : "Bloqueada · abre Ajustes",
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
        launcherRows = out
    }

    // ---- navigation ------------------------------------------------------
    property string page: "home"

    function pageIndex(p) {
        return p === "search" ? 1 : (p === "library" ? 2 : 0)
    }

    // QA: `--page=home|search|library`, `--src=ytm|soundcloud|spotify|tidal`,
    //     `--settings`, `--launcher`, `--accent=#rrggbb` ('' clears the override)
    Component.onCompleted: {
        const args = Qt.application.arguments
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
            } else if (a.startsWith("--panel=")) {
                const t = a.substring(8)
                root.openPanel(t === "letras" || t === "lyrics" ? 1 : 0)
            } else if (a === "--nowplaying") {
                root.nowPlayingOpen = true
            } else if (a === "--shuffle") {
                // QA: activa el aleatorio antes de cargar nada.
                shuffle = true
                mpris.setShuffle(true)
            } else if (a === "--autoplay") {
                // QA: al cargar la lista, reproducirla (botón de play).
                pendingPlay = true
            } else if (a.startsWith("--accent=")) {
                cfgSet("accent", a.substring(9))
            } else if (a.startsWith("--openurl=")) {
                Qt.callLater(function() { catalog.openUrl(a.substring(10), "selftest") })
            }
        }
        followSys = cfgGet("followSystem") !== "false"

        // Preferencias del reproductor, letras, Discord y descargas.
        lyricsEnabled = cfgGet("lyricsEnabled") !== "false"
        discordEnabled = cfgGet("discordRpc") === "true"
        player.setQuality(cfgGet("audioQuality") || "max")
        // El Client ID de la app ya va embebido en el backend; al usuario solo
        // le importa el interruptor de encendido/apagado.
        discord.configure(discordEnabled, "")
        if (cfgGet("downloadFolder"))
            downloads.setFolder(cfgGet("downloadFolder"))
    }

    // Esc "atrás": cierra overlays/panel o sale de pantalla completa.
    Shortcut {
        sequence: "Escape"
        onActivated: root.goBack()
    }

    // ---- queue -----------------------------------------------------------
    // El modelo `queue` es SIEMPRE el orden real de reproducción. Con el
    // aleatorio activo se baraja al cargar la lista y `next()`/`prev()` sólo
    // recorren el modelo de arriba abajo, de modo que la cola del panel derecho
    // muestra exactamente «cómo avanzará» la reproducción.
    ListModel { id: queue }
    property int queueIndex: -1
    property string currentTitle: ""
    property string currentArtist: ""
    property string currentThumb: ""
    // videoId de YouTube de la pista en reproducción ("" si no aplica).
    property string currentVideoId: ""
    // Estado local de "me gusta" de la pista actual (se refresca al cambiarla).
    property bool currentLiked: false
    // setVideoId (fila en su playlist) si la pista se abrió desde una lista YTM.
    property string currentSetId: ""
    // Selector de lista para "añadir a lista".
    property bool playlistPickerOpen: false
    // Pista objetivo del selector (botón + de una fila o de la barra inferior).
    property string pickerVideoId: ""
    property bool shuffle: false
    property bool repeat: false
    property bool nowPlayingOpen: false
    // Orden original de la lista cargada (para restaurar al apagar el aleatorio).
    property var originalOrder: []
    // ¿Refleja ya la cola el orden aleatorio?
    property bool queueShuffled: false
    // Una lista se está cargando / hay que reproducirla en cuanto llegue.
    property bool listLoading: false
    property bool pendingPlay: false
    // Evita repetir la petición de letra de la misma pista+duración.
    property string lyricsKey: ""
    // Evita reenviar metadatos MPRIS/Discord en cada tick de posición.
    property string metaKey: ""

    // Copia normalizada de una pista: conserva title/artist/url/duration/
    // source/cover y, cuando la fuente los trae, album e index.
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

    // Array JS o ListModel (incluida la cola actual) -> lista de copias.
    // Se copia ANTES de vaciar la cola: si la lista «ya viene de la cola»
    // así no se duplica ni se pierde nada.
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

    // (Re)llena el modelo con la lista dada, en ese exacto orden.
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

    // Fisher–Yates in-place.
    function fisherYates(a) {
        for (let i = a.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1))
            const tmp = a[i]
            a[i] = a[j]
            a[j] = tmp
        }
        return a
    }

    // Baraja la cola EN EL SITIO: la pista actual queda donde estaba (no se
    // corta la reproducción) y el resto se reordena alrededor.
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
        console.log("[qa] reshuffle cur=" + cur + " posOrig=["
                    + out.map(function(t) { return arr.indexOf(t) }).join(",") + "]")
    }

    // Vuelve al orden original de la lista. La pista que suena sigue sonando
    // (no se recarga) y sólo se reordena el modelo a su alrededor.
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
            // Residual (p. ej. la cola venía de otra fuente): no se pierde.
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
        console.log("[qa] restoreOrder n=" + order.length + " playingAt=" + idx
                    + " queueIndex=" + queueIndex)
    }

    function toggleShuffle() {
        shuffle = !shuffle
        if (queue.count > 0) {
            if (shuffle)
                reshuffleQueue()      // la cola visible pasa a orden aleatorio
            else
                restoreOriginalOrder() // orden estable original
        }
        mpris.setShuffle(shuffle)
        console.log("[qa] toggleShuffle -> " + shuffle + " queueShuffled=" + queueShuffled)
        toast(shuffle ? "Aleatorio activado" : "Aleatorio desactivado")
    }

    // Extrae el videoId (youtube.com/watch?v= / youtu.be/ / music.youtube.com)
    // de la URL de una pista. Vacío si la pista no es de YouTube.
    function videoIdOf(url) {
        const u = String(url || "")
        var m = /[?&]v=([A-Za-z0-9_-]{6,})/.exec(u)
        if (m)
            return m[1]
        const m2 = u.match(/youtu\.be\/([A-Za-z0-9_-]+)/)
        return m2 ? m2[1] : ""
    }

    // Extrae el id de una URL de playlist de YouTube Music (?list=XXXX).
    function listIdOf(url) {
        const m = /[?&]list=([A-Za-z0-9_-]+)/.exec(String(url || ""))
        return m ? m[1] : ""
    }

    function toggleRepeat() {
        repeat = !repeat
        toast(repeat ? "Repetir activado" : "Repetir desactivado")
    }

    // ---- integraciones (letras / Discord / MPRIS) ------------------------
    // Pide la letra solo cuando ya conocemos la duración real de la pista.
    // Sirve además de reintento: si el intento inmediato (sin duración) no
    // encontró letra, aquí se vuelve a pedir con la duración real en cuanto mpv
    // la reporta. Así no hace falta pausar/reanudar para que «detecte».
    function fetchLyrics() {
        if (!root.lyricsEnabled || !root.currentTitle)
            return
        const dur = player.duration
        if (dur <= 0)
            return
        const key = root.currentArtist + "|" + root.currentTitle
        if (root.lyricsKey === key)
            return
        // Aún hay una petición en curso (el intento inmediato): la dejamos
        // terminar; el siguiente latido (o cambio de estado) decide.
        if (lyrics.loading)
            return
        root.lyricsKey = key
        // El intento inmediato ya trajo letra: no repetimos la petición.
        if (lyrics.hasLyrics || lyrics.hasSynced)
            return
        lyrics.fetch(root.currentArtist, root.currentTitle, dur,
                     root.currentVideoId)
    }

    // Refresca Discord + MPRIS con la posición/estado actuales. Los metadatos
    // (título/artista/portada/duración) sólo se reenvían cuando cambian.
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

    // Carga una lista en la cola. Si el aleatorio está activo, la cola se
    // baraja (Fisher–Yates) ANTES de reproducir y se arranca en una pista
    // aleatoria: la primera canción ya sale en aleatorio y, a partir de ahí,
    // `next()` avanza linealmente por la cola barajada (sin saltos).
    function playTracks(list, idx) {
        const arr = toTrackList(list)
        if (arr.length === 0 || idx < 0 || idx >= arr.length)
            return
        originalOrder = arr            // orden original (copia sin barajar)
        let order = arr
        if (shuffle && arr.length > 1) {
            order = arr.slice()
            fisherYates(order)
            idx = Math.floor(Math.random() * order.length)
        }
        fillQueue(order)
        queueShuffled = shuffle && arr.length > 1
        queueIndex = idx
        console.log("[qa] playTracks n=" + arr.length + " shuffle=" + shuffle
                    + " start=" + idx + " posOrig=["
                    + order.map(function(t) { return arr.indexOf(t) }).join(",") + "]")
        startCurrent()
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
            // Primer intento inmediato. Para pistas de YouTube se usa el vídeo
            // exacto (la letra no depende de la duración). Si este intento no
            // encuentra letra, fetchLyrics() reintentará con la duración real
            // en cuanto mpv la reporte (sin tener que pausar y reanudar).
            lyrics.fetch(root.currentArtist, root.currentTitle, 0,
                         root.currentVideoId)
        }
        player.load(t.url)
        // Pre-resuelve el stream de la siguiente pista en background para que
        // el cambio de canción sea instantáneo (estilo Sonora).
        prefetchAhead(queueIndex, 2)
        catalog.addRecent({ title: t.title, artist: t.artist, url: t.url,
                            duration: t.duration, source: t.source, thumb: t.thumb || "" })
        root.updateNowPlaying()
    }

    // Pre-resuelve hasta `n` pistas a partir de `from` de la cola (en serie,
    // el Player encola; aquí sólo se cuecen las URLs válidas). Se lanza al
    // arrancar cada pista para tener el stream ya resuelto al avanzar.
    function prefetchAhead(from, n) {
        if (!n || from < 0 || from >= queue.count)
            return
        for (let i = from + 1; i <= from + n && i < queue.count; i++) {
            const t = queue.get(i)
            if (t && t.url)
                player.prefetch(t.url)
        }
    }

    function next() {
        // Caso residual: aleatorio activo pero la cola todavía no barajada.
        // En condiciones normales la cola YA es el orden aleatorio y sólo se
        // avanza linealmente (eso es lo que muestra la vista de cola).
        if (shuffle && !queueShuffled && queue.count > 1) {
            console.log("[qa] next: aleatorio activo y cola sin barajar")
            reshuffleQueue()
        }
        if (queueIndex + 1 < queue.count) {
            queueIndex++
            console.log("[qa] next -> " + queueIndex + "/" + queue.count)
            startCurrent()
        } else {
            player.stopPlayback()
            currentTitle = ""
            currentArtist = ""
            currentThumb = ""
            root.lyricsKey = ""
            root.metaKey = ""
            lyrics.clear()
            discord.clear()
            mpris.updatePlayback(false, 0, true)
        }
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

    Connections {
        target: player
        function onEndOfFile(ok) {
            if (!ok)
                console.warn("[queue] pista fallida, avanzando")
            if (root.repeat && root.currentTitle.length > 0) {
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
        // Mantiene al día Discord/MPRIS y afina las letras cuando llega la
        // duración real o cambia el estado de reproducción.
        function onStateChanged() { root.updateNowPlaying() }
    }

    // Latido periódico para el progreso en Discord/MPRIS.
    Timer {
        interval: 1000
        repeat: true
        running: player.playing
        onTriggered: root.updateNowPlaying()
    }

    // Órdenes que llegan del centro multimedia del sistema (MPRIS2).
    Connections {
        target: mpris
        function onPlayRequested() { if (!player.playing) player.playPause() }
        function onPauseRequested() { if (player.playing) player.playPause() }
        function onPlayPauseRequested() { player.playPause() }
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

    // ---- interacción con YouTube Music (me gusta / listas) ---------------
    function toggleLike() {
        if (!root.currentVideoId) {
            root.toast("La pista actual no es de YouTube")
            return
        }
        // catalog.toggleLiked vota y actualiza el conjunto; el corazón (aquí y
        // en las filas) se repinta al subir likedRevision/onLikedChanged.
        catalog.toggleLiked(root.currentVideoId, root.currentLiked)
    }

    // Abre el selector de listas para una pista concreta (botón + de una fila
    // o de la barra inferior). Sin argumento usa la pista actual.
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

    // Quita la pista actual de la lista con la que se abrió (requiere el
    // setVideoId que trae la entrada de la playlist).
    function removeCurrentFromPlaylist(playlistId) {
        root.playlistPickerOpen = false
        if (!root.currentVideoId || !root.currentSetId) {
            root.toast("Esta pista no se puede quitar de la lista")
            return
        }
        catalog.removeFromPlaylist(playlistId, root.currentVideoId,
                                   root.currentSetId)
    }

    // Conexión para el resultado de votar/añadir/quitar de lista.
    Connections {
        target: catalog
        function onInteractionDone(ok, message) {
            root.toast(message)
        }
        // El conjunto de "me gusta" cambió (cargado o tras un voto): refresca
        // el corazón de la pista en reproducción.
        function onLikedChanged() {
            if (root.currentVideoId)
                root.currentLiked = catalog.isLiked(root.currentVideoId)
        }
        // Metadatos de una lista (respuesta a fetchPlaylistInfo): completa el
        // editor con el título y la privacidad reales.
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
    }

    Connections {
        target: catalog
        function onChanged() {
            if (catalog.error) {
                // Una apertura fallida: nada que abrir ni reproducir después.
                root.listLoading = false
                root.pendingPlay = false
                root.toast(catalog.error)
                catalog.dismissError()
            }
        }
        function onTracksReady(tracks, title) {
            const play = root.pendingPlay
            root.pendingPlay = false
            root.listLoading = false
            console.log("[qa] tracksReady n=" + tracks.length + " play=" + play)
            if (play) {
                // Botón de play: reproduce sin salir de la página actual.
                root.playTracks(tracks, 0)
                return
            }
            // Sólo abrir: un salto directo a la lista/álbum (sin reproducir).
            root.openTracksView()
        }
        function onLibraryChanged() {
            if (root.launcherOpen)
                root.buildLauncher(launchInput.text)
        }
    }

    // ---- layout ----------------------------------------------------------
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Item {
                id: sideCol
                Layout.preferredWidth: sidebar.railWidth
                Layout.fillHeight: true

                Sidebar {
                    id: sidebar
                    anchors.fill: parent
                    page: root.page
                    trackTitle: root.currentTitle
                    trackArtist: root.currentArtist
                    trackThumb: root.currentThumb
                    playing: player.playing
                    engineStatus: player.engineStatus
                    onNavigate: (p) => root.navTo(p)
                    onSettingsRequested: root.toggleSettings()
                    onNowPlayingRequested: root.nowPlayingOpen = true
                    // "Me gusta": abre la lista LM de YouTube Music sin reproducir.
                    onLikedRequested: {
                        root.beginOpenList(false)
                        catalog.openUrl("https://music.youtube.com/playlist?list=LM",
                                        "Me gusta")
                    }
                    // "Descargas": Biblioteca con la fuente local seleccionada.
                    onDownloadsRequested: {
                        libPage.selectedSourceId = "local"
                        root.navTo("library")
                    }
                    // Clic en una lista: se abre y, cuando llegue, se muestra
                    // directamente (sin saltar a Biblioteca ni reproducir).
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

            Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Sys.border }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

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

                StackLayout {
                    id: stack
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: root.pageIndex(root.page)
                    opacity: 1
                    Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

                    onCurrentIndexChanged: {
                        // fade-in transition between pages
                        opacity = 0.25
                        opacity = 1
                        // Recarga el historial de búsquedas de Inicio (se
                        // escribe desde Buscar mientras no está visible).
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
                        // Chip del historial: abre Buscar y re-ejecuta la query.
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
                    }
                    LibraryPage {
                        id: libPage
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        onPlayRequested: (list, idx) => root.playTracks(list, idx)
                        // Cover: abrir (false) o abrir y reproducir (true).
                        onOpenListRequested: (play) => root.beginOpenList(play)
                        onTrackContextRequested: (t, x, y) => root.showTrackMenu(t, x, y)
                        onCoverContextRequested: (c, x, y) => root.showPlaylistMenu(c, x, y)
                        onShuffleListRequested: root.shuffleTracks(catalog.tracks)
                    }
                }
            }

            Rectangle {
                visible: root.panelOpen
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                color: Sys.border
            }

            RightPanel {
                id: rightPanel
                visible: root.panelOpen
                Layout.preferredWidth: 360
                Layout.fillHeight: true
                tab: root.panelTab
                queueModel: queue
                queueIndex: root.queueIndex
                onCloseRequested: root.panelOpen = false
                onTrackActivated: (i) => {
                    root.queueIndex = i
                    root.startCurrent()
                }
                onTrackContextRequested: (t, x, y) => root.showTrackMenu(t, x, y)
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Sys.border }

        PlayerBar {
            Layout.fillWidth: true
            playing: player.playing
            position: player.position
            duration: player.duration
            title: root.currentTitle
            artist: root.currentArtist
            currentThumb: root.currentThumb
            volume: player.volume
            shuffle: root.shuffle
            repeat: root.repeat
            onToggle: player.playPause()
            onNextRequested: root.next()
            onPrevRequested: root.prev()
            onShuffleToggled: root.toggleShuffle()
            onRepeatToggled: root.toggleRepeat()
            onLyricsRequested: root.nowPlayingOpen = true
            onQueueRequested: root.togglePanel(0)
            onLyricsPanelRequested: root.togglePanel(1)
            onSeekRequested: (secs) => player.seek(secs)
            onVolumeWanted: (v) => player.setVolume(v)
            videoId: root.currentVideoId
            liked: root.currentLiked
            canInteract: catalog.loginState === "ok"
            onLikeRequested: root.toggleLike()
            onAddToPlaylistRequested: root.openPlaylistPicker(root.currentVideoId)
        }
    }

    // ---- "En reproduccion" (portada grande + letra) ----------------------
    NowPlaying {
        id: nowPlaying
        anchors.fill: parent
        z: 65
        open: root.nowPlayingOpen
        title: root.currentTitle
        artist: root.currentArtist
        thumb: root.currentThumb
        playing: player.playing
        position: player.position
        duration: player.duration
        shuffle: root.shuffle
        repeat: root.repeat
        onCloseRequested: root.nowPlayingOpen = false
        onToggleRequested: player.playPause()
        onNextRequested: root.next()
        onPrevRequested: root.prev()
        onShuffleToggled: root.toggleShuffle()
        onRepeatToggled: root.toggleRepeat()
        onSeekRequested: (secs) => player.seek(secs)
    }

    // ---- selector de lista (añadir a playlist) ---------------------------
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

                // Crear una lista nueva y añadir ahí la pista objetivo.
                Rectangle {
                    Layout.fillWidth: true
                    height: Theme.rowThin
                    radius: Theme.rMd
                    color: newPick.hovered ? Theme.hover(Sys.bg) : "transparent"
                    HoverHandler { id: newPick; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.openCreatePlaylist(root.pickerVideoId) }
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
                                    onTapped: root.addCurrentToPlaylist(
                                        root.listIdOf(modelData.url))
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

                // Quitar la pista actual de la lista con la que se abrió.
                // Solo aplica si la pista vino de una playlist de YouTube Music
                // por la vía rápida (lleva su setVideoId consigo).
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
                        onTapped: root.removeCurrentFromPlaylist(catalog.openPlaylistId)
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
                    TapHandler { onTapped: root.playlistPickerOpen = false }
                }
            }
        }
    }

    // ---- menú contextual (clic derecho) ----------------------------------
    ContextMenu {
        id: ctxMenu
        anchors.fill: parent
        items: root.ctxItems
        at: Qt.point(root.ctxX, root.ctxY)
        open: root.ctxOpen
        onClosed: root.ctxOpen = false
    }

    // ---- editor de listas (crear / editar) -------------------------------
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

    // ---- confirmación ----------------------------------------------------
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
                        TapHandler { onTapped: root.confirmOpen = false }
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
                        TapHandler { onTapped: root.runConfirm() }
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

    // ---- settings panel (full-window modal) ------------------------------
    Rectangle {
        id: settingsOverlay
        anchors.fill: parent
        z: 60
        visible: root.settingsOpen
        color: Sys.bg
        opacity: root.settingsOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

        ColumnLayout {
            id: settingsLayout
            anchors.fill: parent
            anchors.leftMargin: Theme.s4
            anchors.rightMargin: Theme.s4
            anchors.topMargin: Theme.s3
            anchors.bottomMargin: Theme.s3
            spacing: Theme.s3

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
                    color: closeX.containsMouse ? Sys.surfaceAlt : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 16
                        height: 16
                        kind: "x"
                        color: closeX.containsMouse ? Sys.accent : Sys.textDim
                    }
                    MouseArea {
                        id: closeX
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.settingsOpen = false
                    }
                }
            }

            Rectangle { // separador bajo la cabecera
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Sys.borderSubtle
                opacity: 1
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
                    // Columna centrada con ancho máximo: en pantallas anchas
                    // (2560 px) los controles no se estiran de borde a borde y
                    // en ventanas pequeñas vuelve al ancho disponible sin
                    // desbordar (nunca mayor que el Flickable).
                    width: Math.min(settingsScroll.width, 1120)
                    x: Math.max(0, (settingsScroll.width - width) / 2)
                    spacing: Theme.s3

                    // ---- CUENTAS --------------------------------------
                    Text {
                        text: "CUENTAS"
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                    }

                    Repeater {
                        model: sources.list

                        delegate: Rectangle {
                            required property var modelData
                            id: block
                            Layout.fillWidth: true
                            radius: Theme.rMd
                            color: "transparent"
                            border.width: 0
                            implicitHeight: blockCol.implicitHeight + 20

                            Rectangle {
                                anchors { left: parent.left; right: parent.right; top: parent.top }
                                height: 1
                                color: Sys.borderSubtle
                            }

                            ColumnLayout {
                                id: blockCol
                                anchors.fill: parent
                                anchors.leftMargin: Theme.s3
                                anchors.rightMargin: Theme.s3
                                anchors.topMargin: Theme.s3
                                anchors.bottomMargin: Theme.s2
                                spacing: Theme.s2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.s2

                                    Text {
                                        text: block.modelData.name
                                        color: Sys.text
                                        font.pixelSize: Theme.tBase
                                        font.bold: true
                                    }
                                    Rectangle {
                                        height: Theme.s4
                                        radius: Theme.rSm
                                        color: block.modelData.status === "ready"
                                               ? Sys.accentDim : Theme.alpha(Sys.danger, 0.14)
                                        implicitWidth: badgeLabel.implicitWidth + 12
                                        Text {
                                            id: badgeLabel
                                            anchors.centerIn: parent
                                            text: block.modelData.status === "ready"
                                                  ? "Lista" : "Bloqueada · backend pendiente"
                                            color: block.modelData.status === "ready"
                                                   ? Sys.accent : Sys.danger
                                            font.pixelSize: Theme.tXs
                                            font.bold: true
                                        }
                                    }
                                    Item { Layout.fillWidth: true }
                                }

                                // ---- YouTube Music (Google login) ----
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: block.modelData.id === "ytm"
                                    spacing: 10

                                    Text {
                                        Layout.fillWidth: true
                                        text: "Inicia sesión en una ventana de Google integrada y sincroniza «Me gusta». Tu navegador personal no se toca."
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tSm
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        lineHeight: 1.3
                                    }

                                    // ---- ok: sesión iniciada ----
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        visible: root.ytmState() === "ok"

                                        Rectangle {
                                            height: 20
                                            radius: 10
                                            color: Sys.accentDim
                                            implicitWidth: okLabel.implicitWidth + 14
                                            Text {
                                                id: okLabel
                                                anchors.centerIn: parent
                                                text: "Sesión iniciada"
                                                color: Sys.accent
                                                font.pixelSize: Theme.tXs
                                                font.bold: true
                                            }
                                        }

                                        Rectangle {
                                            implicitWidth: ytmSyncBtn.implicitWidth + 26
                                            height: 34
                                            radius: Theme.rMd
                                            color: ytmSyncMouse.containsMouse ? Theme.hover(Sys.surfaceAlt) : Sys.surfaceAlt
                                            border.width: 0
                                            scale: ytmSyncMouse.pressed ? 0.96 : 1
                                            Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                            Text {
                                                id: ytmSyncBtn
                                                anchors.centerIn: parent
                                                text: "Sincronizar Me gusta"
                                                color: ytmSyncMouse.containsMouse ? Sys.accent : Sys.text
                                                font.pixelSize: Theme.tMd
                                                font.bold: true
                                            }
                                            MouseArea {
                                                id: ytmSyncMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: catalog.syncLiked()
                                            }
                                        }

                                        Rectangle {
                                            implicitWidth: ytmLogoutBtn.implicitWidth + 20
                                            height: 34
                                            radius: Theme.rMd
                                            color: ytmLogoutMouse.containsMouse ? Theme.alpha(Sys.danger, 0.12) : "transparent"
                                            border.width: 0
                                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                            Text {
                                                id: ytmLogoutBtn
                                                anchors.centerIn: parent
                                                text: "Cerrar sesión"
                                                color: ytmLogoutMouse.containsMouse ? Sys.danger : Sys.textDim
                                                font.pixelSize: Theme.tSm
                                            }
                                            MouseArea {
                                                id: ytmLogoutMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: catalog.logoutYTM()
                                            }
                                        }
                                        Item { Layout.fillWidth: true }
                                    }

                                    // ---- idle (or backend missing) ----
                                    Rectangle {
                                        visible: root.ytmState() === "" || root.ytmState() === "nologin"
                                        implicitWidth: ytmLoginBtn.implicitWidth + 30
                                        height: 36
                                        radius: Theme.rMd
                                        color: ytmLoginMouse.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                                        scale: ytmLoginMouse.pressed ? 0.96 : 1
                                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                        Text {
                                            id: ytmLoginBtn
                                            anchors.centerIn: parent
                                            text: "Iniciar sesión con Google"
                                            color: Sys.onAccent
                                            font.pixelSize: Theme.tMd
                                            font.bold: true
                                        }
                                        MouseArea {
                                            id: ytmLoginMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.ytmLogin()
                                        }
                                    }

                                    // ---- waiting ----
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 10
                                        visible: root.ytmState() === "waiting"

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.s3
                                            Item {
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
                                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            }
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: "Se abrió una ventana de Google integrada. Escribe tu cuenta y contraseña ahí; la app detecta la sesión y la ventana se cierra sola."
                                            color: Sys.textDim
                                            font.pixelSize: Theme.tXs
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        }

                                        Rectangle {
                                            implicitWidth: ytmCancelBtn.implicitWidth + 22
                                            height: 34
                                            radius: Theme.rMd
                                            color: ytmCancelMouse.containsMouse ? Theme.alpha(Sys.danger, 0.12) : "transparent"
                                            border.width: 0
                                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                            Text {
                                                id: ytmCancelBtn
                                                anchors.centerIn: parent
                                                text: "Cancelar"
                                                color: ytmCancelMouse.containsMouse ? Sys.danger : Sys.textDim
                                                font.pixelSize: Theme.tSm
                                            }
                                            MouseArea {
                                                id: ytmCancelMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: catalog.logoutYTM()
                                            }
                                        }
                                    }

                                    // ---- error ----
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        visible: root.ytmState() === "error"

                                        Text {
                                            Layout.fillWidth: true
                                            text: root.ytmError()
                                            color: Sys.danger
                                            font.pixelSize: Theme.tSm
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        }
                                        Rectangle {
                                            implicitWidth: ytmRetryBtn.implicitWidth + 26
                                            height: 34
                                            radius: Theme.rMd
                                            color: ytmRetryMouse.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                                            scale: ytmRetryMouse.pressed ? 0.96 : 1
                                            Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                            Text {
                                                id: ytmRetryBtn
                                                anchors.centerIn: parent
                                                text: "Reintentar"
                                                color: Sys.onAccent
                                                font.pixelSize: Theme.tMd
                                                font.bold: true
                                            }
                                            MouseArea {
                                                id: ytmRetryMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.ytmLogin()
                                            }
                                        }
                                    }
                                }

                                // ---- SoundCloud ----
                                Text {
                                    Layout.fillWidth: true
                                    visible: block.modelData.id === "soundcloud"
                                    text: "Acceso público, sin login: búsqueda y playlists públicas de SoundCloud."
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    lineHeight: 1.3
                                }

                                // ---- Spotify ----
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: block.modelData.id === "spotify"
                                    spacing: Theme.s3

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        ColumnLayout { // Client ID
                                            Layout.fillWidth: true
                                            spacing: Theme.s1
                                            Text {
                                                text: "Client ID"
                                                color: Sys.textDim
                                                font.pixelSize: Theme.tXs
                                            }
                                            Rectangle {
                                                Layout.fillWidth: true
                                                height: 34
                                                radius: Theme.rMd
                                                color: Sys.bg
                                                border.width: 1
                                                border.color: cidInput.activeFocus ? Sys.accent : Sys.borderSubtle
                                                Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                                                TextInput {
                                                    id: cidInput
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    anchors.rightMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    color: Sys.text
                                                    font.pixelSize: Theme.tMd
                                                    clip: true
                                                }
                                                Text {
                                                    visible: cidInput.text.length === 0
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: "developer.spotify.com"
                                                    color: Sys.textDim
                                                    font.pixelSize: Theme.tSm
                                                }
                                            }
                                        }
                                        ColumnLayout { // Usuario
                                            Layout.fillWidth: true
                                            spacing: Theme.s1
                                            Text {
                                                text: "Usuario"
                                                color: Sys.textDim
                                                font.pixelSize: Theme.tXs
                                            }
                                            Rectangle {
                                                Layout.fillWidth: true
                                                height: 34
                                                radius: Theme.rMd
                                                color: Sys.bg
                                                border.width: 1
                                                border.color: userInput.activeFocus ? Sys.accent : Sys.borderSubtle
                                                Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                                                TextInput {
                                                    id: userInput
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    anchors.rightMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    color: Sys.text
                                                    font.pixelSize: Theme.tMd
                                                    clip: true
                                                }
                                                Text {
                                                    visible: userInput.text.length === 0
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: "cuenta Premium"
                                                    color: Sys.textDim
                                                    font.pixelSize: Theme.tSm
                                                }
                                            }
                                        }
                                        ColumnLayout { // Contraseña
                                            Layout.fillWidth: true
                                            spacing: Theme.s1
                                            Text {
                                                text: "Contraseña"
                                                color: Sys.textDim
                                                font.pixelSize: Theme.tXs
                                            }
                                            Rectangle {
                                                Layout.fillWidth: true
                                                height: 34
                                                radius: Theme.rMd
                                                color: Sys.bg
                                                border.width: 1
                                                border.color: passInput.activeFocus ? Sys.accent : Sys.borderSubtle
                                                Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                                                TextInput {
                                                    id: passInput
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    anchors.rightMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    color: Sys.text
                                                    font.pixelSize: Theme.tMd
                                                    clip: true
                                                    echoMode: TextInput.Password
                                                }
                                                Text {
                                                    visible: passInput.text.length === 0
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: "••••••••"
                                                    color: Sys.textDim
                                                    font.pixelSize: Theme.tSm
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        implicitWidth: spotSave.implicitWidth + 26
                                        height: 34
                                        radius: Theme.rMd
                                        color: spotSaveMouse.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                                        scale: spotSaveMouse.pressed ? 0.96 : 1
                                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                        Text {
                                            id: spotSave
                                            anchors.centerIn: parent
                                            text: "Guardar"
                                            color: Sys.onAccent
                                            font.pixelSize: Theme.tMd
                                            font.bold: true
                                        }
                                        MouseArea {
                                            id: spotSaveMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.cfgLogin("spotify", cidInput.text,
                                                              userInput.text, passInput.text)
                                                root.toast("Guardado en la configuración")
                                            }
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: "Se activa cuando el backend librespot esté listo; guardamos tus credenciales. Requiere cuenta Premium y un Client ID de developer.spotify.com."
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tSm
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        lineHeight: 1.3
                                    }
                                }

                                // ---- Tidal ----
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: block.modelData.id === "tidal"
                                    spacing: Theme.s3

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s2
                                        ColumnLayout { // Usuario
                                            Layout.fillWidth: true
                                            spacing: Theme.s1
                                            Text {
                                                text: "Usuario"
                                                color: Sys.textDim
                                                font.pixelSize: Theme.tXs
                                            }
                                            Rectangle {
                                                Layout.fillWidth: true
                                                height: 34
                                                radius: Theme.rMd
                                                color: Sys.bg
                                                border.width: 1
                                                border.color: tidalUserInput.activeFocus ? Sys.accent : Sys.borderSubtle
                                                Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                                                TextInput {
                                                    id: tidalUserInput
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    anchors.rightMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    color: Sys.text
                                                    font.pixelSize: Theme.tMd
                                                    clip: true
                                                }
                                                Text {
                                                    visible: tidalUserInput.text.length === 0
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: "cuenta Tidal"
                                                    color: Sys.textDim
                                                    font.pixelSize: Theme.tSm
                                                }
                                            }
                                        }
                                        ColumnLayout { // Contraseña
                                            Layout.fillWidth: true
                                            spacing: Theme.s1
                                            Text {
                                                text: "Contraseña"
                                                color: Sys.textDim
                                                font.pixelSize: Theme.tXs
                                            }
                                            Rectangle {
                                                Layout.fillWidth: true
                                                height: 34
                                                radius: Theme.rMd
                                                color: Sys.bg
                                                border.width: 1
                                                border.color: tidalPassInput.activeFocus ? Sys.accent : Sys.borderSubtle
                                                Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                                                TextInput {
                                                    id: tidalPassInput
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    anchors.rightMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    color: Sys.text
                                                    font.pixelSize: Theme.tMd
                                                    clip: true
                                                    echoMode: TextInput.Password
                                                }
                                                Text {
                                                    visible: tidalPassInput.text.length === 0
                                                    anchors.fill: parent
                                                    anchors.leftMargin: Theme.s3
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: "••••••••"
                                                    color: Sys.textDim
                                                    font.pixelSize: Theme.tSm
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        implicitWidth: tidalSave.implicitWidth + 26
                                        height: 34
                                        radius: Theme.rMd
                                        color: tidalSaveMouse.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                                        scale: tidalSaveMouse.pressed ? 0.96 : 1
                                        Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                        Text {
                                            id: tidalSave
                                            anchors.centerIn: parent
                                            text: "Guardar"
                                            color: Sys.onAccent
                                            font.pixelSize: Theme.tMd
                                            font.bold: true
                                        }
                                        MouseArea {
                                            id: tidalSaveMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.cfgLogin("tidal", tidalUserInput.text,
                                                              tidalPassInput.text, "")
                                                root.toast("Guardado en la configuración")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---- REPRODUCTOR ------------------------------------
                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.s2
                        text: "REPRODUCTOR"
                        color: Sys.textDim
                        font.pixelSize: Theme.tXs
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.4
                    }

                    ColumnLayout {
                        id: playerCol
                        Layout.fillWidth: true
                        spacing: Theme.s3

                            Rectangle { // bloque de ajuste: fuente por defecto
                                Layout.fillWidth: true
                                radius: Theme.rMd
                                color: "transparent"
                                border.width: 0
                                implicitHeight: pref1.implicitHeight + 20

                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    height: 1
                                    color: Sys.borderSubtle
                                }

                                ColumnLayout {
                                    id: pref1
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    anchors.topMargin: Theme.s3
                                    anchors.bottomMargin: Theme.s2
                                    spacing: Theme.s2

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s2
                                Text {
                                    text: "Fuente por defecto"
                                    color: Sys.text
                                    font.pixelSize: Theme.tMd
                                    font.bold: true
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    Repeater {
                                        model: sources.list
                                        delegate: Rectangle {
                                            required property var modelData
                                            id: chip
                                            readonly property bool cur: sources.activeId === chip.modelData.id
                                            Layout.fillWidth: true
                                            height: 30
                                            radius: Theme.rSm
                                            color: cur ? Sys.accentDim : (chipMouse.containsMouse ? Sys.bg : "transparent")
                                            border.width: 0
                                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                            Text {
                                                anchors.centerIn: parent
                                                text: chip.modelData.name
                                                color: cur ? Sys.accent : (chipMouse.containsMouse ? Sys.text : Sys.textDim)
                                                font.pixelSize: Theme.tSm
                                                font.bold: cur
                                                elide: Text.ElideRight
                                            }
                                            MouseArea {
                                                id: chipMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.pickSource(chip.modelData.id)
                                                    root.cfgSet("defaultSource", chip.modelData.id)
                                                    root.toast("Guardado en la configuración")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                                }
                            }

                            Rectangle { // bloque de ajuste: tema del sistema
                                Layout.fillWidth: true
                                radius: Theme.rMd
                                color: "transparent"
                                border.width: 0
                                implicitHeight: pref2.implicitHeight + 20

                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    height: 1
                                    color: Sys.borderSubtle
                                }

                                ColumnLayout {
                                    id: pref2
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    anchors.topMargin: Theme.s3
                                    anchors.bottomMargin: Theme.s2
                                    spacing: Theme.s2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s3
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text {
                                        text: "Seguir el tema del sistema"
                                        color: Sys.text
                                        font.pixelSize: Theme.tMd
                                        font.bold: true
                                    }
                                    Text {
                                        text: "Paleta de iNiR/matugen (sincronizada con el escritorio)"
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tXs
                                    }
                                }
                                Rectangle { // toggle
                                    width: 40
                                    height: 22
                                    radius: 11
                                    color: root.followSys ? Sys.accent : Theme.mix(Sys.surface, Sys.text, 0.16)
                                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                    Rectangle {
                                        width: 18
                                        height: 18
                                        radius: 9
                                        color: Sys.onAccent
                                        x: root.followSys ? 20 : 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        Behavior on x { NumberAnimation { duration: Theme.fastMs } }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.followSys = !root.followSys
                                            root.cfgSet("followSystem", root.followSys ? "true" : "false")
                                            root.toast("Guardado en la configuración")
                                        }
                                    }
                                }
                            }
                                }
                            }

                            Rectangle { // bloque de ajuste: color de acento
                                Layout.fillWidth: true
                                radius: Theme.rMd
                                color: "transparent"
                                border.width: 0
                                implicitHeight: pref3.implicitHeight + 20

                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    height: 1
                                    color: Sys.borderSubtle
                                }

                                ColumnLayout {
                                    id: pref3
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    anchors.topMargin: Theme.s3
                                    anchors.bottomMargin: Theme.s2
                                    spacing: Theme.s2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s2
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.s1
                                    Text {
                                        text: "Color de acento (hex)"
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tXs
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 34
                                        radius: Theme.rMd
                                        color: Sys.bg
                                        border.width: 1
                                        border.color: accentInput.activeFocus ? Sys.accent : Sys.borderSubtle
                                        Behavior on border.color { ColorAnimation { duration: Theme.fastMs } }
                                        TextInput {
                                            id: accentInput
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.s3
                                            anchors.rightMargin: Theme.s3
                                            verticalAlignment: Text.AlignVCenter
                                            color: Sys.text
                                            font.pixelSize: Theme.tMd
                                            clip: true
                                            text: root.cfgGet("accent")
                                        }
                                        Text {
                                            visible: accentInput.text.length === 0
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.s3
                                            verticalAlignment: Text.AlignVCenter
                                            text: "#e3bae5"
                                            color: Sys.textDim
                                            font.pixelSize: Theme.tSm
                                        }
                                    }
                                }
                                Rectangle {
                                    implicitWidth: accentSave.implicitWidth + 26
                                    height: 34
                                    radius: Theme.rMd
                                    color: accentSaveMouse.containsMouse ? Qt.lighter(Sys.accent, 1.12) : Sys.accent
                                    scale: accentSaveMouse.pressed ? 0.96 : 1
                                    Behavior on scale { NumberAnimation { duration: Theme.fastMs } }
                                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                    Text {
                                        id: accentSave
                                        anchors.centerIn: parent
                                        text: "Guardar"
                                        color: Sys.onAccent
                                        font.pixelSize: Theme.tMd
                                        font.bold: true
                                    }
                                    MouseArea {
                                        id: accentSaveMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const v = accentInput.text.trim()
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
                            }

                            // ---- Calidad de audio ----------------------------
                            Rectangle { // bloque de ajuste: calidad de audio
                                Layout.fillWidth: true
                                radius: Theme.rMd
                                color: "transparent"
                                border.width: 0
                                implicitHeight: pref4.implicitHeight + 20

                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    height: 1
                                    color: Sys.borderSubtle
                                }

                                ColumnLayout {
                                    id: pref4
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    anchors.topMargin: Theme.s3
                                    anchors.bottomMargin: Theme.s2
                                    spacing: Theme.s2

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s2
                                Text {
                                    text: "Calidad de audio"
                                    color: Sys.text
                                    font.pixelSize: Theme.tMd
                                    font.bold: true
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: "Máxima por defecto (sin recodificar). Bájala para ahorrar datos."
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tXs
                                    wrapMode: Text.WordWrap
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    Repeater {
                                        model: [
                                            { id: "max", label: "Máxima" },
                                            { id: "alta", label: "Alta" },
                                            { id: "media", label: "Media" },
                                            { id: "baja", label: "Baja" }
                                        ]
                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property bool cur: player.quality === modelData.id
                                            Layout.fillWidth: true
                                            height: 30
                                            radius: Theme.rSm
                                            color: cur ? Sys.accentDim : (qTag.containsMouse ? Sys.bg : "transparent")
                                            border.width: 0
                                            Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData.label
                                                color: cur ? Sys.accent : (qTag.containsMouse ? Sys.text : Sys.textDim)
                                                font.pixelSize: Theme.tSm
                                                font.bold: cur
                                            }
                                            MouseArea {
                                                id: qTag
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    player.setQuality(modelData.id)
                                                    root.cfgSet("audioQuality", modelData.id)
                                                    root.toast("Calidad: " + modelData.label)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                                }
                            }

                            // ---- Letras --------------------------------------
                            Rectangle { // bloque de ajuste: letras
                                Layout.fillWidth: true
                                radius: Theme.rMd
                                color: "transparent"
                                border.width: 0
                                implicitHeight: pref5.implicitHeight + 20

                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    height: 1
                                    color: Sys.borderSubtle
                                }

                                ColumnLayout {
                                    id: pref5
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    anchors.topMargin: Theme.s3
                                    anchors.bottomMargin: Theme.s2
                                    spacing: Theme.s2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s2
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text {
                                        text: "Letras"
                                        color: Sys.text
                                        font.pixelSize: Theme.tMd
                                        font.bold: true
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: "Busca la letra sincronizada de cada canción."
                                        color: Sys.textDim
                                        font.pixelSize: Theme.tXs
                                        wrapMode: Text.WordWrap
                                    }
                                }
                                Rectangle {
                                    width: 40
                                    height: 22
                                    radius: 11
                                    color: root.lyricsEnabled ? Sys.accent : Theme.mix(Sys.surface, Sys.text, 0.16)
                                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                    Rectangle {
                                        width: 18
                                        height: 18
                                        radius: 9
                                        color: Sys.onAccent
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: root.lyricsEnabled ? parent.width - width - 3 : 3
                                        Behavior on x { NumberAnimation { duration: Theme.fastMs } }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
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
                            }
                                }
                            }

                            // ---- Discord Rich Presence -----------------------
                            Rectangle { // bloque de ajuste: discord rich presence
                                Layout.fillWidth: true
                                radius: Theme.rMd
                                color: "transparent"
                                border.width: 0
                                implicitHeight: pref6.implicitHeight + 20

                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    height: 1
                                    color: Sys.borderSubtle
                                }

                                ColumnLayout {
                                    id: pref6
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    anchors.topMargin: Theme.s3
                                    anchors.bottomMargin: Theme.s2
                                    spacing: Theme.s2

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s2
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text {
                                            text: "Discord Rich Presence"
                                            color: Sys.text
                                            font.pixelSize: Theme.tMd
                                            font.bold: true
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: "Muestra lo que suena en tu perfil. Ya viene configurado."
                                            color: Sys.textDim
                                            font.pixelSize: Theme.tXs
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                    Text {
                                        text: discord.connected ? "Conectado"
                                              : (root.discordEnabled ? "Sin conexión" : "Desactivado")
                                        color: discord.connected ? Sys.accent : Sys.textDim
                                        font.pixelSize: Theme.tXs
                                        font.bold: true
                                    }
                                    Rectangle {
                                        width: 40
                                        height: 22
                                        radius: 11
                                        color: root.discordEnabled ? Sys.accent : Theme.mix(Sys.surface, Sys.text, 0.16)
                                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                        Rectangle {
                                            width: 18
                                            height: 18
                                            radius: 9
                                            color: Sys.onAccent
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: root.discordEnabled ? parent.width - width - 3 : 3
                                            Behavior on x { NumberAnimation { duration: Theme.fastMs } }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.discordEnabled = !root.discordEnabled
                                                root.cfgSet("discordRpc", root.discordEnabled)
                                                discord.configure(root.discordEnabled, "")
                                            }
                                        }
                                    }
                                }
                            }
                                }
                            }

                            // ---- Carpeta de descargas ------------------------
                            Rectangle { // bloque de ajuste: carpeta de descargas
                                Layout.fillWidth: true
                                radius: Theme.rMd
                                color: "transparent"
                                border.width: 0
                                implicitHeight: pref7.implicitHeight + 20

                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; top: parent.top }
                                    height: 1
                                    color: Sys.borderSubtle
                                }

                                ColumnLayout {
                                    id: pref7
                                    anchors.fill: parent
                                    anchors.leftMargin: Theme.s3
                                    anchors.rightMargin: Theme.s3
                                    anchors.topMargin: Theme.s3
                                    anchors.bottomMargin: Theme.s2
                                    spacing: Theme.s2

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s2
                                Text {
                                    text: "Carpeta de descargas"
                                    color: Sys.text
                                    font.pixelSize: Theme.tBase
                                    font.bold: true
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
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
                                    Rectangle {
                                        implicitWidth: dlOpenLabel.implicitWidth + 24
                                        height: 34
                                        radius: Theme.rMd
                                        color: dlOpenMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : Sys.surfaceAlt
                                        border.width: 0
                                        Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                                        Text {
                                            id: dlOpenLabel
                                            anchors.centerIn: parent
                                            text: "Abrir carpeta"
                                            color: dlOpenMa.containsMouse ? Sys.accent : Sys.text
                                            font.pixelSize: Theme.tMd
                                            font.bold: true
                                        }
                                        MouseArea {
                                            id: dlOpenMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: downloads.openFolder()
                                        }
                                    }
                                }
                            }
                                }
                            }
                        }
                }
            }

        }

        // ---- indicador de scroll propio -------------------------------
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
            onClicked: root.launcherOpen = false
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
                            onTextChanged: root.buildLauncher(text)
                            Keys.onEscapePressed: root.launcherOpen = false
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

}