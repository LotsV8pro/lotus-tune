import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Buscar: consulta la fuente activa (yt-dlp) y reproduce al clic.
// Minimalista: campo de una sola superficie, estado en texto y una lista
// VIRTUALIZADA (ListView) para no materializar todos los resultados de golpe.
Item {
    id: page

    signal playRequested(var list, int index)
    // Clic derecho: pide el menú contextual para esa pista (x/y en ventana).
    signal trackContextRequested(var track, real x, real y)
    // Deslizar una fila a la izquierda: añadir la pista a la cola.
    signal enqueueRequested(var track)

    // La rueda que sobra (lista al borde o puntero sobre el campo) se queda en
    // la página: nunca arrastra a un contenedor padre.
    WheelHandler { onWheel: (event) => { event.accepted = true } }

    function sourceEntry(id) {
        const l = sources.list
        for (var i = 0; i < l.length; i++)
            if (l[i].id === id)
                return l[i]
        return null
    }
    readonly property var src: sourceEntry(sources.activeId)
    readonly property bool locked: !src || src.status !== "ready"

    readonly property int rowHeight: Theme.rowH

    // ---- búsqueda predictiva (search-as-you-type) -------------------------
    // Al teclear, tras una pausa breve se busca sola (sin pulsar Enter). El
    // motor (Catalog) es un QProcess único: si ya hay una operación en curso
    // una nueva búsqueda FALLA con «Espera a que termine la operación actual».
    // Por eso, antes de buscar se comprueba catalog.busy y, si lo está, se
    // programa un reintento corto en vez de llamar directamente.
    property int debounceMs: 300        // pausa de tecleo antes de buscar
    property int minQuery: 2            // longitud mínima para buscar solo
    property int retryMs: 250           // espera entre reintentos (backend ocupado)
    property int retryMax: 40           // tope de reintentos (≈10 s): nunca en bucle
    property int retryCount: 0
    property string lastQuery: ""       // última búsqueda enviada (evita repetirla)
    property string pendingQuery: ""    // búsqueda en espera de que el backend libre

    // Único punto que llama a catalog.search(): centralizar aquí el control de
    // busy evita el error de «operación en curso». Si el backend está ocupado
    // guarda la consulta y reintenta en breve (con tope de reintentos).
    function dispatchSearch(q) {
        q = String(q || "").trim()
        if (q.length === 0)
            return
        if (catalog.busy) {
            if (retryCount >= retryMax) {   // demasiado tiempo ocupado: desiste
                pendingQuery = ""
                retryCount = 0
                return
            }
            retryCount++
            pendingQuery = q
            retryTimer.restart()
            return
        }
        retryCount = 0
        pendingQuery = ""
        page.lastQuery = q
        results.positionViewAtBeginning()   // toda búsqueda nueva empieza arriba
        catalog.search(q)
    }

    // Búsqueda explícita: Enter, chip del Historial o «Buscar el artista».
    // Sí pasa por el historial de búsquedas recientes (como hasta ahora).
    function runSearch() {
        const q = String(input.text || "").trim()
        if (q.length === 0)
            return
        page.lastQuery = ""       // Enter relanza aunque repita la consulta
        pushHistory(q)
        dispatchSearch(q)
    }

    // Búsqueda predictiva (la dispara el debounce). NO toca el historial: se
    // guardaría cada prefijo que se teclea. El historial sigue reservado a las
    // búsquedas explícitas (Enter / chips) y no relanza la MISMA consulta.
    function autoSearch() {
        const q = String(input.text || "").trim()
        if (q.length < minQuery || q === lastQuery)
            return
        dispatchSearch(q)
    }

    // Pausa de tecleo: cada pulsación la reinicia, así sólo se busca cuando el
    // usuario para (una búsqueda por pausa, no por carácter).
    Timer {
        id: debounceTimer
        interval: page.debounceMs
        repeat: false
        onTriggered: page.autoSearch()
    }

    // Reintento mientras el backend está ocupado: una sola vez por disparo y se
    // reprograma sólo si sigue ocupado, con tope en retryMax (nada de bucles).
    Timer {
        id: retryTimer
        interval: page.retryMs
        repeat: false
        onTriggered: page.dispatchSearch(page.pendingQuery)
    }

    // API externa (chips del Historial en Inicio): rellena el campo y busca.
    function startSearch(q) {
        input.text = String(q || "")
        runSearch()
        input.forceActiveFocus()
        input.selectAll()
    }

    // ---- historial de búsquedas (appcfg, clave "searchHistory") -----------
    // JSON: [{ "q": texto, "t": timestamp }…], máx. 20, sin duplicados.
    function pushHistory(q) {
        if (typeof appcfg === "undefined")
            return
        var arr = []
        try {
            arr = JSON.parse(String(appcfg.get("searchHistory") || "[]")) || []
        } catch (e) {
            arr = []
        }
        var out = [{ q: q, t: Date.now() }]
        for (var i = 0; i < arr.length && out.length < 20; i++) {
            const e = arr[i]
            if (!e || typeof e.q !== "string" || e.q.length === 0)
                continue
            if (e.q === q)          // sin duplicados (se mueve arriba)
                continue
            out.push({ q: e.q, t: Number(e.t || 0) })
        }
        try {
            appcfg.set("searchHistory", JSON.stringify(out))
            appcfg.save()
        } catch (e2) {
            // sin historial persistente: la búsqueda sigue funcionando
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.s5
        spacing: Theme.s3

        LockedPanel {
            visible: page.locked
            Layout.alignment: Qt.AlignHCenter
            sourceName: page.src ? page.src.name : ""
            note: page.src ? page.src.note : ""
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !page.locked
            spacing: Theme.s3

            // ---- campo de búsqueda (isla flotante) ------------------------
            // Una superficie redondeada que flota sobre la página, con borde
            // sutil (acento al enfocar) y relleno interior holgado. El radio
            // `rLg` mantiene la escala: aquí nada es pastilla salvo los "slots".
            Panel {
                id: field
                Layout.fillWidth: true
                Layout.preferredHeight: 52
                radius: Theme.rLg
                color: Sys.surfaceAlt
                borderColor: input.activeFocus ? Sys.accent
                                               : Theme.alpha(Sys.text, Theme.panelBorderAlpha)
                Behavior on borderColor { ColorAnimation { duration: Theme.fastMs } }

                Glyph {
                    id: searchIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.s4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16
                    height: 16
                    kind: "search"
                    color: input.activeFocus ? Sys.accent : Sys.textDim
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                }

                TextInput {
                    id: input
                    anchors.left: searchIcon.right
                    anchors.leftMargin: Theme.s2
                    anchors.right: clearBtn.left
                    anchors.rightMargin: Theme.s2
                    anchors.verticalCenter: parent.verticalCenter
                    color: Sys.text
                    font.pixelSize: Theme.tBase
                    clip: true
                    selectByMouse: true
                    Keys.onReturnPressed: { event.accepted = true; page.runSearch() }
                    Keys.onEnterPressed: { event.accepted = true; page.runSearch() }
                    // Búsqueda predictiva: cada cambio reinicia la pausa; si aún
                    // no hay letras suficientes no se busca (se cancela la espera).
                    onTextChanged: {
                        if (input.text.trim().length < page.minQuery) {
                            debounceTimer.stop()
                            page.pendingQuery = ""
                            return
                        }
                        debounceTimer.restart()
                    }
                }
                Text {
                    visible: input.text.length === 0
                    anchors.left: input.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: input.width
                    text: "¿Qué quieres escuchar en "
                          + (page.src ? page.src.name : "") + "?"
                    color: Sys.textDim
                    font.pixelSize: Theme.tBase
                    elide: Text.ElideRight
                }
                Rectangle {
                    id: clearBtn
                    visible: input.text.length > 0
                    width: Theme.rowThin
                    height: Theme.rowThin
                    radius: width / 2
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.s2
                    anchors.verticalCenter: parent.verticalCenter
                    color: clearMa.containsMouse ? Theme.hover(Sys.surfaceAlt) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                    Glyph {
                        anchors.centerIn: parent
                        width: 11
                        height: 11
                        kind: "x"
                        color: clearMa.containsMouse ? Sys.accent : Sys.textDim
                    }
                    MouseArea {
                        id: clearMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { input.text = ""; input.forceActiveFocus() }
                    }
                }
            }

            // ---- estado ----------------------------------------------------
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.s1
                visible: catalog.busy
                text: "Buscando…"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
            }
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.s1
                visible: !catalog.busy && catalog.results.length > 0
                text: catalog.results.length + " resultados para «"
                      + catalog.resultsQuery + "»"
                color: Sys.textDim
                font.pixelSize: Theme.tSm
                elide: Text.ElideRight
            }

            // ---- resultados (lista virtualizada) --------------------------
            ListView {
                id: results
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: catalog.results
                spacing: Theme.s1
                boundsBehavior: Flickable.StopAtBounds
                reuseItems: true
                cacheBuffer: 600
                // Al llegar resultados nuevos, cuece las primeras pistas: un
                // clic en la cabecera de la lista suena al instante. Se cuecen
                // unas cuantas (no sólo la primera) porque, al no descartar ya
                // el hover la precarga en vuelo, terminan todas y la lista
                // entera responde rápido.
                onCountChanged: {
                    const arr = catalog.results
                    const n = Math.min(8, arr ? arr.length : 0)
                    for (let i = 0; i < n; i++) {
                        const t = arr[i]
                        if (t && t.url)
                            player.prefetch(t.url)
                    }
                }

                delegate: Rectangle {
                    id: rrow
                    required property int index
                    required property var modelData

                    width: ListView.view.width
                    height: Theme.rowH
                    radius: Theme.rLg
                    color: rrowMouse.containsMouse ? Theme.hover(Sys.surface) : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.fastMs } }

                    readonly property real dx: swipe.active ? swipe.activeTranslation.x : 0
                    readonly property bool willEnqueue: dx <= -80

                    // Indicación discreta al deslizar: "Encolar".
                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.s4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.s2
                        opacity: Math.min(1, -rrow.dx / 80)
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

                    MouseArea {
                        id: rrowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // Al pasar el ratón, pre-resuelve esa pista con
                        // prioridad: si el clic cae enseguida, ya suena.
                        onContainsMouseChanged: if (containsMouse && rrow.modelData
                                                     && rrow.modelData.url)
                                                    player.prefetchFront(rrow.modelData.url)
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                page.trackContextRequested(rrow.modelData, p.x, p.y)
                            } else {
                                page.playRequested(catalog.results, rrow.index)
                            }
                        }
                    }

                    // Deslizar a la izquierda para añadir a la cola.
                    DragHandler {
                        id: swipe
                        xAxis.enabled: true
                        yAxis.enabled: false
                        target: null
                        onActiveChanged: if (!active && rrow.willEnqueue)
                                             page.enqueueRequested(rrow.modelData)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.s3
                        anchors.rightMargin: Theme.s3
                        spacing: Theme.s3
                        transform: Translate { x: rrow.dx }

                        Rectangle {
                            Layout.preferredWidth: 34
                            Layout.preferredHeight: 34
                            Layout.alignment: Qt.AlignVCenter
                            radius: Theme.rMd
                            clip: true
                            color: Sys.surfaceAlt

                            Image {
                                anchors.fill: parent
                                source: rrow.modelData.thumb || ""
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
                                visible: !rrow.modelData.thumb
                                kind: rrowMouse.containsMouse ? "play" : "music"
                                color: rrowMouse.containsMouse ? Sys.accent : Sys.textDim
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.s1
                                Text {
                                    Layout.fillWidth: true
                                    text: rrow.modelData.title || ""
                                    color: Sys.text
                                    font.pixelSize: Theme.tBase
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                LikeButton {
                                    id: rrowLike
                                    interactive: catalog.loginState === "ok"
                                                 && catalog.videoIdOf(
                                                        rrow.modelData.url) !== ""
                                    revealed: rrowMouse.containsMouse
                                    liked: {
                                        const rev = catalog.likedRevision
                                        if (!rrow.modelData)
                                            return false
                                        if (catalog.likedReady)
                                            return catalog.isLiked(rrow.modelData.url)
                                        return rrow.modelData.liked === true
                                    }
                                    onToggled: {
                                        if (rrow.modelData)
                                            catalog.toggleLiked(rrow.modelData.url,
                                                                rrowLike.liked)
                                    }
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: rrow.modelData.artist || ""
                                color: Sys.textDim
                                font.pixelSize: Theme.tSm
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter
                            text: Theme.mmss(rrow.modelData.duration)
                            color: Sys.textDim
                            font.pixelSize: Theme.tSm
                        }
                    }
                }
            }

            // ---- vacío / ayuda --------------------------------------------
            // Estado vacío: un texto centrado y con aire, sin caja. Es la misma
            // voz silenciosa que el estado "bloqueado": la jerarquía es el aire.
            Text {
                Layout.fillWidth: true
                Layout.maximumWidth: 520
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.s5
                visible: !catalog.busy && catalog.results.length === 0
                text: "Escribe al menos " + page.minQuery + " letras y los "
                      + "resultados aparecen solos (también puedes pulsar Enter). "
                      + "Se usa la extracción directa de la fuente: sin anuncios, "
                      + "sin navegador."
                color: Sys.textDim
                font.pixelSize: Theme.tMd
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                lineHeight: 1.35
            }
        }
    }
}
