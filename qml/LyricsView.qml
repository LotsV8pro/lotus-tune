import QtQuick
import QtQuick.Layouts
import "theme.js" as Theme

// Lyrics panel driven by the backend `lyrics` context property.
// - hasSynced: renders the parsed lines, highlights the active one and
//   auto-scrolls so it always sits in the middle of the view.
// - otherwise: shows the plain text with a scroll fallback.
//
// The line list comes pre-parsed from the backend (`lyrics.lines`), so the
// index returned by `lineIndexAt()` and the row drawn on screen can never
// drift apart (that used to happen because the LRC was parsed twice).
//
// Minimalism: only the active line gets `Sys.text` at full weight; the
// surroundings are `Sys.textDim` dimmed by distance. No boxes, no glow,
// just the two edge washes tying into `edgeColor`.
Item {
    id: lv
    clip: true

    // Tamaño base de la línea de letra. NowPlaying lo sube para la vista grande.
    property int lineSize: 16
    // Incremento de la línea ACTIVA: es la que «canta», así que se dibuja
    // más grande (karaoke de escritorio, estilo haku_widgets `lyr-cur`).
    property int activeBoost: 7
    // Ancho máximo de la columna de lectura: en pantalla completa el panel
    // derecho es gigante y una línea de 2000 px es imposible de leer.
    property real maxLineWidth: 820
    // Lectura por la izquierda (modo cine, como en el repo de referencia):
    // la columna arranca en el borde del área en vez de centrarse. Panel y
    // Now Playing siguen centrados (valor por defecto).
    property bool leftAlign: false
    // Pastilla de sincronía: arriba al centro (modo cine) y visible mientras
    // los mandos están a la vista (`pillShown`). Por defecto: abajo a la
    // derecha, al pasar el ratón.
    property bool pillTop: false
    property bool pillShown: false
    // Color real del fondo del panel; con él se difuminan los bordes.
    property color edgeColor: Sys.surface

    // Guarded references so the view still renders before the backend registers
    // the context properties.
    readonly property var lyr: (typeof lyrics !== "undefined") ? lyrics : null
    readonly property var ply: (typeof player !== "undefined") ? player : null

    // Líneas sincronizadas ya parseadas por el backend: [{ time, text }]
    property var lines: []
    property int activeIndex: -1

    readonly property bool loading: lyr ? !!lyr.loading : false
    readonly property bool hasLyrics: lyr ? !!lyr.hasLyrics : false
    readonly property bool hasSynced: lyr ? !!lyr.hasSynced : false
    readonly property string plainText: lyr ? String(lyr.plain || "") : ""
    readonly property string errorText: lyr ? String(lyr.error || "") : ""

    readonly property bool showSynced: hasSynced && lines.length > 0
    readonly property bool showPlain: hasLyrics && !showSynced && plainText.length > 0
    readonly property bool showError: !loading && errorText.length > 0 && !showSynced && !showPlain
    readonly property bool showEmpty: !loading && !showSynced && !showPlain && !showError

    // Karaoke: con tiempos POR PALABRA (Sonora/Apple Music) la línea activa se
    // rellena palabra a palabra. Cuando la fuente sólo da tiempos por línea
    // (YTM/LRCLIB/NetEase) NO se barre la frase a medias: la línea entera se
    // ilumina al cantarla (menos confuso, y coincide con el widget del
    // escritorio). El conmutador `karaoke` apaga el relleno por palabra y deja
    // siempre la línea entera.
    readonly property bool hasWordSync: {
        for (var i = 0; i < lines.length; i++) {
            var w = lines[i].words
            if (w && w.length > 1)
                return true
        }
        return false
    }
    // ¿Karaoke por palabra activo? Se apaga desde Ajustes (o por el backend).
    // Lo mantiene `rebuild()` (el binding sobre la `var lyr` no rastrea cambios).
    property bool karaokeOn: true

    // ---- geometry of the reading column --------------------------------
    readonly property real sidePad: 24
    readonly property real colW: Math.max(140, Math.min(width - (leftAlign ? sidePad : sidePad * 2), maxLineWidth))
    readonly property int lineGap: Math.max(10, Math.round(lineSize * 0.72))
    // Media altura: así la primera y la última línea también pueden centrarse.
    readonly property int edgePad: Math.max(56, Math.floor(height / 2))
    // Sonora ancla la línea activa al 32 % de la altura (no centrada). El
    // relleno de arriba/abajo permite fijar cualquier línea a esa altura, y
    // `following` controla si seguimos al canto o respetamos el scroll manual.
    readonly property real pinFrac: 0.5
    readonly property real pinTop: Math.max(56, Math.floor(height * pinFrac))
    readonly property real pinBottom: Math.max(56, Math.ceil(height * (1 - pinFrac)))
    property bool following: true
    property bool _animating: false

    // ---- relleno progresivo (karaoke) ----------------------------------
    // Posición interpolada entre los avisos del motor. `positionChanged` llega
    // como mucho cada 240 ms; sobre esta posición se calcula el frente del
    // relleno, que así avanza fluido en lugar de a saltos de 240 ms.
    property real karaokePos: 0
    property real _posAnchor: 0
    property double _posStamp: 0

    // Ajuste fino de sincronía (equivalente al `positionTrim` de Sonora):
    // segundos que se suman a la posición del motor al casar la letra. Positivo
    // = la letra va adelantada y se retrasa para cuadrar con el audio. Se
    // persiste en la config de la app para que sobreviva al reinicio.
    property real offset: 0
    function setOffset(v) {
        offset = Math.round(Theme.clamp(v, -10, 10) * 20) / 20   // pasos de 50 ms
        if (typeof appcfg !== "undefined") {
            appcfg.set("lyricsOffset", offset.toFixed(2))
            appcfg.save()
        }
        // El backend publica este mismo ajuste en el estado de letras para que
        // los widgets del escritorio cuadren con el audio igual que la app.
        if (lv.lyr && typeof lv.lyr.setPublishedOffset === "function")
            lv.lyr.setPublishedOffset(offset)
    }

    // ---- active line ---------------------------------------------------
    function localIndex(pos) {
        var lo = 0
        var hi = lines.length - 1
        var res = -1
        while (lo <= hi) {
            var mid = (lo + hi) >> 1
            if (lines[mid].time <= pos) {
                res = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return res
    }

    function computeActive() {
        if (lines.length === 0) {
            activeIndex = -1
            return
        }
        var pos = lv.karaokePos
        var idx = -1
        if (lyr && typeof lyr.lineIndexAt === "function") {
            var r = lyr.lineIndexAt(pos)
            if (typeof r === "number" && r >= 0 && r < lines.length)
                idx = r
        }
        if (idx < 0)
            idx = localIndex(pos)
        activeIndex = idx
    }

    function rebuild() {
        var src = (lyr && lyr.lines) ? lyr.lines : []
        lines = (src && src.length) ? src : []
        if (lyr)
            karaokeOn = lyr.karaoke !== false
        // Pista nueva: volvemos a seguir el canto desde el principio.
        following = true
        computeActive()
        // Cambio de pista: saltamos sin animación a la nueva línea activa.
        Qt.callLater(function () { scrollToActive(true) })
    }

    // Centra la línea activa en el viewport con una animación suave.
    function scrollToActive(instant) {
        if (!syncedFlick.visible)
            return
        if (activeIndex < 0 || activeIndex >= lines.length)
            return
        var item = lyricRepeater.itemAt(activeIndex)
        if (!item)
            return
        // La activa se fija al 32 % de la altura (estilo Sonora), no centrada.
        var target = item.y + item.height / 2 - syncedFlick.height * pinFrac
        var maxY = Math.max(0, syncedFlick.contentHeight - syncedFlick.height)
        target = Math.max(0, Math.min(target, maxY))
        _animating = true
        if (instant) {
            scrollAnim.stop()
            syncedFlick.contentY = target
            _animating = false
            return
        }
        if (Math.abs(target - syncedFlick.contentY) < 1) {
            _animating = false
            return
        }
        scrollAnim.from = syncedFlick.contentY
        scrollAnim.to = target
        scrollAnim.restart()
    }

    // Clic en una línea: salta a ese momento y vuelve a seguir el canto (como
    // Sonora). El pequeño margen evita que el resaltado caiga en la anterior.
    function seekTo(t) {
        if (!ply || typeof ply.seek !== "function")
            return
        ply.seek(Math.max(0, Number(t)) + 0.05)
        following = true
        computeActive()
        Qt.callLater(function () { scrollToActive(true) })
    }

    // Degradado por distancia a la línea activa: la activa al 100 % y las de
    // alrededor apagándose en escalones suaves. Simétrico: da igual si la línea
    // ya se cantó (arriba) o está por venir (abajo).
    function lineOpacity(i) {
        if (activeIndex < 0)
            return 0.6
        var d = Math.abs(i - activeIndex)
        if (d === 0)
            return 1
        if (d === 1)
            return 0.40
        if (d === 2)
            return 0.25
        if (d === 3)
            return 0.16
        return 0.1
    }

    // ---- relleno progresivo -------------------------------------------------
    function _rgbaStr(c) {
        var col = (typeof c === "string") ? Qt.color(c) : c
        return "rgba(" + Math.round(col.r * 255) + "," + Math.round(col.g * 255)
            + "," + Math.round(col.b * 255) + ","
            + (Math.round(col.a * 100) / 100) + ")"
    }

    // Color a medio camino entre el apagado y el encendido. La letra que está
    // justo en el frente se pinta a medias, y por eso se ve comerse la línea
    // de forma continua en vez de encenderse de golpe.
    function _mixCss(a, b, f) {
        var t = Math.max(0, Math.min(1, f))
        var A = (typeof a === "string") ? Qt.color(a) : a
        var B = (typeof b === "string") ? Qt.color(b) : b
        if (t <= 0) return _rgbaStr(A)
        if (t >= 1) return _rgbaStr(B)
        var r = A.r + (B.r - A.r) * t
        var g = A.g + (B.g - A.g) * t
        var bl = A.b + (B.b - A.b) * t
        var al = A.a + (B.a - A.a) * t
        return "rgba(" + Math.round(r * 255) + "," + Math.round(g * 255) + ","
            + Math.round(bl * 255) + "," + (Math.round(al * 100) / 100) + ")"
    }

    // La parte aún no cantada de la línea activa: una versión tenue de la
    // letra (texto apagado hacia el fondo). Sin acento: solo el blanco de la
    // voz marca la línea que canta, el resto se desvanece en `Sys.textDim`.
    readonly property real _unsungAlpha: 0.55
    readonly property color _unsungColor: {
        var a = edgeColor
        var b = Sys.textDim
        var t = _unsungAlpha
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, 1)
    }

    // Pinta una línea letra a letra: `fill` va de 0 (recién entró, apagada) a 1
    // (cantada, en texto a pleno). Los caracteres contiguos del mismo color
    // se agrupan en una sola etiqueta: una por letra rompería el kerning y se
    // notaría en el salto de línea.
    function _fillHtml(str, fill) {
        var s = String(str || "")
        if (s.length === 0)
            return ""
        var vis = 0
        for (var i = 0; i < s.length; i++) {
            var ch = s.charAt(i)
            if (ch !== " " && ch !== "\t")
                vis++
        }
        var front = Math.max(0, Math.min(1, fill)) * vis
        var out = ""
        var run = ""
        var runCss = null
        var k = 0
        for (var j = 0; j < s.length; j++) {
            var c = s.charAt(j)
            var isVis = (c !== " " && c !== "\t")
            var css = _mixCss(_unsungColor, Sys.text, isVis ? front - k : 0)
            if (isVis)
                k++
            if (css !== runCss) {
                if (run.length > 0)
                    out += '<span style="color:' + runCss + '">' + run + "</span>"
                run = ""
                runCss = css
            }
            run += (c === "&") ? "&amp;" : (c === "<") ? "&lt;" : (c === ">") ? "&gt;" : c
        }
        if (run.length > 0)
            out += '<span style="color:' + runCss + '">' + run + "</span>"
        return out
    }

    // Rellena una línea CON tiempos por palabra: cada palabra se enciende
    // sobre su propio tramo, así el frente sigue la voz en lugar de repartirse
    // uniformemente por toda la frase (que es lo que hace el widget de
    // escritorio). Reutiliza `_fillHtml` palabra a palabra.
    function _wordHtml(words) {
        if (!words || words.length === 0)
            return ""
        var out = ""
        for (var i = 0; i < words.length; i++) {
            var w = words[i]
            var t = Number(w.t || 0)
            var e = Number(w.e || 0)
            if (!(e > t))
                e = t + 0.3
            var f = Math.max(0, Math.min(1, (karaokePos - t) / (e - t)))
            out += _fillHtml(String(w.text || ""), f)
        }
        return out
    }

    // Reancla la posición interpolada al último valor que dio el motor.
    function syncKaraokePos() {
        if (!ply)
            return
        _posAnchor = Number(ply.position || 0)
        _posStamp = Date.now()
        karaokePos = _posAnchor + offset
    }

    Connections {
        target: lv.lyr
        function onChanged() {
            // Ajustes (u otra vista en pantalla) pueden haber movido la
            // compensación o el karaoke: el backend es el común, se trae el
            // desfase y se recalcula todo.
            if (lv.lyr) {
                var o = Number(lv.lyr.offset)
                if (!isNaN(o) && Math.abs(o - lv.offset) > 0.001)
                    lv.offset = o
            }
            lv.rebuild()
        }
    }
    // El motor emite positionChanged como mucho cada 240 ms: ese aviso reancla
    // la posición interpolada y recalcula la línea activa. `stateChanged`
    // cubre play/pausa/seek, para que al pausar el frente quede justo donde
    // suena y no donde lo dejó la última interpolación.
    Connections {
        target: lv.ply
        function onPositionChanged() { lv.syncKaraokePos(); lv.computeActive() }
        function onStateChanged() { lv.syncKaraokePos(); lv.computeActive() }
    }

    // Interpola la posición entre avisos del motor para que el frente del
    // relleno avance fluido. Hace falta siempre que haya letra sincronizada
    // sonando: con tiempos por palabra anima el frente palabra a palabra, y
    // con tiempos por línea alimenta el barrido de la frase activa. El aviso
    // del motor llega a 240 ms; a 50 ms el frente se mueve suave.
    Timer {
        interval: 50
        repeat: true
        running: lv.showSynced && !!lv.ply && lv.ply.playing
        onTriggered: {
            if (!lv.ply)
                return
            var est = lv._posAnchor + (Date.now() - lv._posStamp) / 1000
            var dur = Number(lv.ply.duration || 0)
            if (dur > 0)
                est = Math.min(est, dur)
            lv.karaokePos = est + lv.offset
            // Con el tick la línea activa cambia en cuanto cruza su instante,
            // sin esperar al aviso del motor (hasta 240 ms antes).
            lv.computeActive()
        }
    }

    Component.onCompleted: {
        if (typeof appcfg !== "undefined") {
            var v = parseFloat(appcfg.get("lyricsOffset"))
            if (!isNaN(v))
                offset = v
        }
        if (lv.lyr && typeof lv.lyr.setPublishedOffset === "function")
            lv.lyr.setPublishedOffset(offset)
        rebuild()
    }
    onLinesChanged: computeActive()
    onActiveIndexChanged: {
        Qt.callLater(function () { if (lv.following) lv.scrollToActive(false) })
        // La activa crece de tamaño al volverse activa: la columna se
        // reordena y el primer centrado puede haberse calculado antes del
        // reflow. Este segundo paso (100 ms) corrige la posición suavemente.
        if (lv.following)
            settleScroll.restart()
    }

    Timer {
        id: settleScroll
        interval: 100
        onTriggered: lv.scrollToActive(false)
    }
    // Re-centramos al redimensionar (cambio de ventana <-> pantalla completa).
    onHeightChanged: Qt.callLater(function () { lv.scrollToActive(true) })
    onWidthChanged: Qt.callLater(function () { lv.scrollToActive(true) })

    // ---- loading ------------------------------------------------------
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 320)
        spacing: Theme.s3
        visible: lv.loading

        // Quiet static marker: no spinner, no infinite loops.
        Glyph {
            Layout.alignment: Qt.AlignHCenter
            width: 24
            height: 24
            kind: "disc"
            color: Sys.textDim
            weight: 1.5
        }
        Text {
            Layout.fillWidth: true
            text: "Buscando letra…"
            color: Sys.textDim
            font.pixelSize: Theme.tBase
            horizontalAlignment: Text.AlignHCenter
        }
    }

    // ---- synced -------------------------------------------------------
    Flickable {
        id: syncedFlick
        anchors.fill: parent
        visible: lv.showSynced
        contentWidth: width
        contentHeight: lyricCol.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        // Scroll manual: dejamos de seguir la canción hasta que se pulse
        // «Seguir la canción». La animación propia no cuenta.
        onMovementStarted: if (!lv._animating) lv.following = false
        onContentYChanged: if (!lv._animating && syncedFlick.moving
                               && lv.following) lv.following = false

        // Columna de lectura centrada y de ancho acotado.
        Column {
            id: lyricCol
            width: lv.colW
            x: lv.leftAlign ? lv.sidePad : Math.max(0, (syncedFlick.width - width) / 2)
            topPadding: lv.pinTop
            bottomPadding: lv.pinBottom
            spacing: lv.lineGap

            Repeater {
                id: lyricRepeater
                model: lv.lines
                delegate: Text {
                    required property var modelData
                    required property int index
                    readonly property bool active: index === lv.activeIndex

                    // Con tiempos por palabra (y karaoke activado): el frente
                    // va palabra a palabra. Sin ellos: la línea entera se
                    // ilumina al ser la activa (sin barrido a medias).
                    readonly property var _w: modelData.words ? modelData.words : []
                    readonly property bool karaoke: active && lv.karaokeOn && _w.length > 1

                    width: lv.colW
                    text: lv.karaoke ? lv._wordHtml(_w) : modelData.text
                    textFormat: lv.karaoke ? Text.RichText : Text.PlainText
                    // Solo la activa canta: texto a pleno y con más peso; el
                    // resto se apaga en `Sys.textDim` según la distancia. La
                    // frase activa lleva un leve matiz de acento para subrayar
                    // que es la que suena.
                    color: active ? Theme.mix(Sys.text, Sys.accent, 0.14)
                                  : Sys.textDim
                    font.pixelSize: active ? lv.lineSize + lv.activeBoost
                                            : lv.lineSize
                    font.weight: active ? Font.DemiBold : Font.Normal
                    // La opacidad sube al pasar el ratón: la línea bajo el
                    // cursor se marca como «clicable» (salta a ese momento).
                    opacity: Math.min(1, lv.lineOpacity(index)
                                         + (lineMa.containsMouse ? 0.22 : 0))
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    horizontalAlignment: lv.leftAlign ? Text.AlignLeft : Text.AlignHCenter
                    lineHeight: 1.32
                    Behavior on opacity { NumberAnimation { duration: Theme.medMs } }
                    Behavior on color { ColorAnimation { duration: Theme.medMs } }

                    MouseArea {
                        id: lineMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: lv.seekTo(modelData.time)
                    }
                }
            }
        }

        NumberAnimation {
            id: scrollAnim
            target: syncedFlick
            property: "contentY"
            duration: Theme.slowMs
            easing.type: Easing.InOutCubic
            onStopped: lv._animating = false
        }
    }

    // Difuminado superior/inferior. Van fuera del Flickable para que no se
    // desplacen con el texto. Una sola «lavada» sutil, sin brillos.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Math.min(56, Math.max(24, lv.edgePad * 0.5))
        visible: !lv.loading && lv.showSynced
        gradient: Gradient {
            GradientStop { position: 0.0; color: lv.edgeColor }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(56, Math.max(24, lv.edgePad * 0.5))
        visible: !lv.loading && lv.showSynced
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: lv.edgeColor }
        }
    }

    // Botón «Seguir la canción»: aparece cuando el usuario se desplaza y deja
    // de seguir automáticamente la línea activa (como Sonora).
    Rectangle {
        id: followBtn
        visible: !lv.following && lv.showSynced
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        width: followRow.implicitWidth + Theme.pillHPad * 2
        height: Theme.pillH
        radius: Theme.rPill
        color: followMa.containsMouse
               ? Theme.hover(Sys.surface) : Sys.surface
        border.width: 1
        border.color: Sys.borderSubtle
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

        RowLayout {
            id: followRow
            anchors.centerIn: parent
            spacing: 6
            Glyph { width: 12; height: 12; kind: "refresh"; color: Sys.accent }
            Text {
                text: "Seguir la canción"
                color: Sys.accent
                font.pixelSize: Theme.tMd
                font.weight: Font.Medium
            }
        }
        MouseArea {
            id: followMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                lv.following = true
                lv.scrollToActive(true)
            }
        }
    }

    // ---- plain --------------------------------------------------------
    Flickable {
        id: plainFlick
        anchors.fill: parent
        visible: lv.showPlain
        contentWidth: width
        contentHeight: plainLabel.implicitHeight + 84
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Text {
            id: plainNote
            x: plainLabel.x
            y: 12
            width: plainLabel.width
            text: "SIN LETRA SINCRONIZADA"
            color: Sys.textDim
            font.pixelSize: Theme.tXs
            font.bold: true
            font.letterSpacing: 1.4
        }

        Text {
            id: plainLabel
            width: Math.min(plainFlick.width - 48, lv.maxLineWidth)
            x: Math.max(24, (plainFlick.width - width) / 2)
            y: 36
            text: lv.plainText
            color: Sys.text
            font.pixelSize: Math.max(15, lv.lineSize - 1)
            lineHeight: 1.55
            horizontalAlignment: Text.AlignLeft
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }
    }

    // ---- empty / error ------------------------------------------------
    // Un icono quieto, un titular y una línea de apoyo. Sin cajas.
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 360)
        spacing: Theme.s2
        visible: lv.showEmpty || lv.showError

        Glyph {
            Layout.alignment: Qt.AlignHCenter
            width: 28
            height: 28
            kind: "mic"
            color: Sys.textDim
            weight: 1.3
        }
        Text {
            Layout.fillWidth: true
            text: lv.showError ? lv.errorText : "Sin letra sincronizada"
            color: lv.showError ? Sys.danger : Sys.text
            font.pixelSize: Theme.tLg
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }
        Text {
            Layout.fillWidth: true
            text: lv.showError ? "Intentando con la siguiente pista." : "No encontramos la letra de esta canción."
            color: Sys.textDim
            font.pixelSize: Theme.tMd
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }
    }

    // ---- sincronía fina: en el panel aparece al pasar el ratón; en el -----
    // modo cine sube al centro del encabezado (como en el repo de referencia)
    // y acompaña a los mandos.
    HoverHandler { id: lyricHover }

    Rectangle {
        visible: lv.showSynced && (lv.pillShown || lyricHover.hovered)
        anchors.horizontalCenter: lv.pillTop ? parent.horizontalCenter : undefined
        anchors.top: lv.pillTop ? parent.top : undefined
        anchors.topMargin: Theme.s4
        anchors.right: lv.pillTop ? undefined : parent.right
        anchors.bottom: lv.pillTop ? undefined : parent.bottom
        anchors.rightMargin: Theme.s3
        anchors.bottomMargin: Theme.s3
        height: Theme.pillH
        width: offRow.implicitWidth + Theme.s4
        radius: Theme.rPill
        color: Sys.surface
        border.width: 1
        border.color: Sys.borderSubtle
        opacity: 0.95

        RowLayout {
            id: offRow
            anchors.centerIn: parent
            spacing: Theme.s2

            Rectangle {
                width: 22
                height: 22
                radius: 11
                color: offMinus.hovered ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Text {
                    anchors.centerIn: parent
                    text: "−"
                    color: offMinus.hovered ? Sys.accent : Sys.textDim
                    font.pixelSize: Theme.tBase
                    font.weight: Font.DemiBold
                }
                HoverHandler { id: offMinus; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); lv.setOffset(lv.offset - 0.1) } }
            }

            Glyph {
                Layout.alignment: Qt.AlignVCenter
                width: 12
                height: 12
                kind: "clock"
                color: Sys.textDim
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: (lv.offset > 0 ? "+" : "") + lv.offset.toFixed(1) + " s"
                color: Sys.textDim
                font.pixelSize: Theme.tXs
                font.weight: Font.DemiBold
            }

            Rectangle {
                width: 22
                height: 22
                radius: 11
                color: offPlus.hovered ? Theme.hover(Sys.surfaceAlt) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: offPlus.hovered ? Sys.accent : Sys.textDim
                    font.pixelSize: Theme.tBase
                    font.weight: Font.DemiBold
                }
                HoverHandler { id: offPlus; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); lv.setOffset(lv.offset + 0.1) } }
            }
        }
    }
}