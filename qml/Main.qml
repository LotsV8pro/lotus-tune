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
        root.autoplayRadioPending = false   // ya hay una cola puesta a mano
        queue.append(root.queueRow(t))
        root.toast("Añadido a la cola")
        root.saveSession()
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
        out.push({ label: "Reproducir", icon: "play",
                   action: function() { root.playTracks([t], 0) } })
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
        onActivated: if (root.currentTitle) root.togglePlay()
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
                cliOpen = true   // QA: no restaura la sesión, abre esta URL
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

        // Restaura la última sesión (cola + pista EN PAUSA + volumen + repetición).
        root.restoreSession(cliOpen)
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
    // ---- sesión persistente (se restaura EN PAUSA al arrancar) -----------
    // sessionLoaded evita guardar antes de haber restaurado la sesión.
    property bool sessionLoaded: false
    // Volumen guardado pendiente de aplicar cuando mpv esté listo (-1 = nada).
    property int pendingVolume: -1
    // ¿Hay una radio/autoplay de YT Music en camino para la pista actual?
    property bool autoplayRadioPending: false
    property string autoplayRadioSeed: ""

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
    }

    // ---- sesión persistente ---------------------------------------------
    // Guarda cola + pista en curso + aleatorio/repetir + volumen. Lo llaman
    // los cambios significativos; el volumen, al cambiar, se guarda con
    // rebote para no escribir en disco en cada tick del deslizador.
    function saveSession() {
        if (typeof appcfg === "undefined" || !root.sessionLoaded)
            return
        appcfg.set("playerVolume", String(player.volume))
        if (queue.count > 0) {
            const st = { queue: toTrackList(queue), index: queueIndex,
                         shuffle: shuffle, repeat: repeat }
            appcfg.set("sessionState", JSON.stringify(st))
        }
        appcfg.save()
    }

    // Restaura la última sesión: cola + pista en curso + volumen + aleatorio/
    // repetir. La pista NO se carga en mpv (queda lista pero EN PAUSA): el
    // primer play la arranca. `skipQueue` (QA con --openurl) deja la cola vacía
    // pero sí recupera el volumen.
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
                repeat = st.repeat === true
                mpris.setShuffle(shuffle)
                root.updateNowPlaying()
            }
        }
        // Sin valor guardado no se toca el volumen (mpv arranca con el suyo);
        // "" -> -1 evita caer en 0 y silenciar la app en el primer arranque.
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

    // Primer play tras restaurar la sesión: si no hay nada cargado en mpv,
    // arranca la pista actual; si ya hay algo, solo alterna la pausa.
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
                reshuffleQueue()      // la cola visible pasa a orden aleatorio
            else
                restoreOriginalOrder() // orden estable original
        }
        mpris.setShuffle(shuffle)
        toast(shuffle ? "Aleatorio activado" : "Aleatorio desactivado")
        root.saveSession()
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
        root.saveSession()
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
        startCurrent()
        // Una sola canción: que continúe sola con la radio/autoplay de YouTube
        // Music (las «siguientes» que usaría YouTube Music sin añadirlas a mano).
        root.autoplayRadioPending = false
        root.autoplayRadioSeed = ""
        if (arr.length === 1) {
            const only = queue.get(0)
            const vid = only ? videoIdOf(only.url) : ""
            if (vid && typeof catalog.fetchRadio === "function") {
                root.autoplayRadioPending = true
                root.autoplayRadioSeed = vid
                // Diferido: si venimos de tracksReady el backend aún tiene su
                // operación en curso en este mismo tick; el callLater deja que
                // termine antes de pedir la radio.
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
        root.saveSession()
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
            reshuffleQueue()
        }
        if (queueIndex + 1 < queue.count) {
            queueIndex++
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
        // El volumen cambia a menudo (deslizador/teclas): se guarda con rebote.
        function onVolumeChanged() { sessionSaveTimer.restart() }
        // mpv listo: aplica el volumen recuperado de la última sesión.
        function onReadyChanged() { if (player.ready) root.applyPendingVolume() }
    }

    // Escritura de la sesión con rebote (para el volumen continuo).
    Timer {
        id: sessionSaveTimer
        interval: 700
        onTriggered: root.saveSession()
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
            if (play) {
                // Botón de play: reproduce sin salir de la página actual.
                root.playTracks(tracks, 0)
                return
            }
            // Una lista de una sola pista es, en la práctica, una canción
            // suelta: reprodúcela ya en lugar de abrir una vista de lista.
            if (tracks && tracks.length === 1) {
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
        // Radio/autoplay de YouTube Music: si venía de una sola canción,
        // añade las «siguientes» a la cola (sin duplicar la que ya suena).
        function onRadioReady(seed, tracks) {
            if (!root.autoplayRadioPending || seed !== root.autoplayRadioSeed)
                return
            root.autoplayRadioPending = false
            root.autoplayRadioSeed = ""
            if (!tracks || !tracks.length)
                return
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

                    // Cambio de página inmediato: sin fundido ni transición.
                    onCurrentIndexChanged: {
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
                        onEnqueueRequested: (t) => root.enqueueTrack(t)
                    }
                    LibraryPage {
                        id: libPage
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        onPlayRequested: (list, idx) => root.playTracks(list, idx)
                        onEnqueueRequested: (t) => root.enqueueTrack(t)
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
            onToggle: root.togglePlay()
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
        onToggleRequested: root.togglePlay()
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
    // Panel de Ajustes: secciones en tarjetas planas, una sola forma de hacer
    // cada cosa. Todo se apoya en los tokens de `Theme` y la paleta de `Sys`.
    Rectangle {
        id: settingsOverlay
        anchors.fill: parent
        z: 60
        visible: root.settingsOpen
        color: Sys.bg
        opacity: root.settingsOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

        // ---- componentes reutilizables del panel -------------------------
        // Tarjeta de sección: título discreto + superficie con 1 borde.
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
                color: Sys.surface
                border.width: 1
                border.color: Sys.border

                ColumnLayout {
                    id: body
                    anchors.fill: parent
                    anchors.margins: Theme.s4
                    spacing: Theme.s3
                }
            }
        }

        // Fila: etiqueta + descripción a la izquierda, control a la derecha.
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

        // Bloque: etiqueta + descripción arriba y control a lo ancho debajo.
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

        // Interruptor tipo switch: pista + mando, acento cuando está activo.
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
                onClicked: tg.toggled()
            }
        }

        // Chip de selección única.
        component Chip: Rectangle {
            id: ch
            property string text: ""
            property bool selected: false
            signal picked()
            implicitWidth: chLabel.implicitWidth + Theme.s5
            height: 30
            radius: Theme.rSm
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
                onClicked: ch.picked()
            }
        }

        // Campo de texto con etiqueta y marcador de posición.
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

        // Botón principal (acento).
        component PrimaryButton: Rectangle {
            id: pb
            property string text: ""
            signal clicked()
            implicitWidth: pbLabel.implicitWidth + Theme.s5
            height: 36
            radius: Theme.rMd
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
                onClicked: pb.clicked()
            }
        }

        // Botón secundario; `danger` lo tiñe en rojo para acciones destructivas.
        component GhostButton: Rectangle {
            id: gb
            property string text: ""
            property bool danger: false
            signal clicked()
            implicitWidth: gbLabel.implicitWidth + Theme.s4
            height: 34
            radius: Theme.rMd
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
                onClicked: gb.clicked()
            }
        }

        // Insignia de estado (lista / pendiente, o sesión iniciada).
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

        ColumnLayout {
            id: settingsLayout
            anchors.fill: parent
            anchors.leftMargin: Theme.s4
            anchors.rightMargin: Theme.s4
            anchors.topMargin: Theme.s3
            anchors.bottomMargin: Theme.s3
            spacing: Theme.s3

            // ---- cabecera -----------------------------------------------
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

                Rectangle { // cerrar
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
                        onClicked: root.settingsOpen = false
                    }
                }
            }

            Rectangle { // separador de cabecera
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Sys.borderSubtle
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
                    // Columna centrada con ancho legible: no se estira de borde
                    // a borde en pantallas anchas y nunca desborda en ventanas
                    // pequeñas.
                    width: Math.min(settingsScroll.width, 820)
                    x: Math.max(0, (settingsScroll.width - width) / 2)
                    spacing: Theme.s5

                    // ======================================================
                    // APARIENCIA
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
                    // REPRODUCCIÓN
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
                    }

                    // ======================================================
                    // LETRAS
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
                    // DESCARGAS
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
                    }

                    // ======================================================
                    // CUENTAS
                    // ======================================================
                    SettingSection {
                        title: "Cuentas"

                        Repeater {
                            model: sources.list
                            delegate: ColumnLayout {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                spacing: Theme.s3

                                Rectangle { // divider entre cuentas
                                    Layout.fillWidth: true
                                    Layout.topMargin: Theme.s2
                                    visible: index > 0
                                    height: 1
                                    color: Sys.borderSubtle
                                }

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

                                // ---- YouTube Music (sesión de Google) ------
                                Text {
                                    Layout.fillWidth: true
                                    visible: modelData.id === "ytm"
                                    text: "Inicia sesión con Google y sincroniza tus «Me gusta»."
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    elide: Text.ElideRight
                                }

                                RowLayout { // sesión iniciada
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

                                PrimaryButton { // iniciar sesión
                                    visible: modelData.id === "ytm"
                                             && (root.ytmState() === "" || root.ytmState() === "nologin")
                                    text: "Iniciar sesión con Google"
                                    onClicked: root.ytmLogin()
                                }

                                ColumnLayout { // esperando inicio de sesión
                                    Layout.fillWidth: true
                                    spacing: Theme.s2
                                    visible: modelData.id === "ytm" && root.ytmState() === "waiting"

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.s3
                                        Item { // indicador girando (solo con el panel abierto)
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

                                // ---- SoundCloud (acceso público) -----------
                                Text {
                                    Layout.fillWidth: true
                                    visible: modelData.id === "soundcloud"
                                    text: "Acceso público, sin necesidad de cuenta."
                                    color: Sys.textDim
                                    font.pixelSize: Theme.tSm
                                    elide: Text.ElideRight
                                }

                                // ---- Spotify (credenciales) ----------------
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

                                // ---- Tidal (credenciales) ------------------
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