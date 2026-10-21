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

    // Base size of a lyrics line. NowPlaying raises it for the big view.
    property int lineSize: 16
    // Size bump of the ACTIVE line: it is the one "singing", so it is
    // drawn bigger (desktop karaoke, haku_widgets `lyr-cur` style).
    property int activeBoost: 7
    // Max width of the reading column: in fullscreen the right panel is
    // huge and a 2000 px line is impossible to read.
    property real maxLineWidth: 820
    // Lectura por la izquierda (modo cine, como en el repo de referencia):
    // the column starts at the edge of the area instead of being centred.
    // Panel and Now Playing stay centred (default).
    property bool leftAlign: false
    // Sync pill: top centre (cinema mode) and visible while the controls
    // are around (`pillShown`). By default: bottom right, on hover.
    property bool pillTop: false
    property bool pillShown: false
    // Real background colour of the panel; the edges fade into it.
    property color edgeColor: Sys.surface

    // Guarded references so the view still renders before the backend registers
    // the context properties.
    readonly property var lyr: (typeof lyrics !== "undefined") ? lyrics : null
    readonly property var ply: (typeof player !== "undefined") ? player : null

    // Synced lines already parsed by the backend: [{ time, text }]
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

    // Karaoke: with WORD level timings (Sonora/Apple Music) the active line
    // is filled word by word. When the source only gives line level timings
    // (YTM/LRCLIB/NetEase) the phrase is NOT swept halfway: the whole line
    // lights up when it is sung (less confusing, and it matches the desktop
    // widget). The `karaoke` switch turns the word fill off and always
    // leaves the whole line.
    readonly property bool hasWordSync: {
        for (var i = 0; i < lines.length; i++) {
            var w = lines[i].words
            if (w && w.length > 1)
                return true
        }
        return false
    }
    // Is word level karaoke on? It is turned off from Settings (or by the
    // backend).
    // Lo mantiene `rebuild()` (el binding sobre la `var lyr` no rastrea cambios).
    property bool karaokeOn: true

    // ---- geometry of the reading column --------------------------------
    readonly property real sidePad: 24
    readonly property real colW: Math.max(140, Math.min(width - (leftAlign ? sidePad : sidePad * 2), maxLineWidth))
    readonly property int lineGap: Math.max(10, Math.round(lineSize * 0.72))
    // Half height: that way the first and the last line can be centred
    // too.
    readonly property int edgePad: Math.max(56, Math.floor(height / 2))
    // Sonora anchors the active line at 32 % of the height (not centred).
    // The padding above/below allows pinning any line at that height, and
    // `following` decides whether we follow the singing or respect a manual
    // scroll.
    readonly property real pinFrac: 0.5
    readonly property real pinTop: Math.max(56, Math.floor(height * pinFrac))
    readonly property real pinBottom: Math.max(56, Math.ceil(height * (1 - pinFrac)))
    property bool following: true
    property bool _animating: false

    // ---- relleno progresivo (karaoke) ----------------------------------
    // Position interpolated between the engine's reports.
    // `positionChanged` arrives at most every 240 ms; the fill's front is
    // computed on top of this position, so it moves smoothly instead of
    // jumping every 240 ms.
    property real karaokePos: 0
    property real _posAnchor: 0
    property double _posStamp: 0

    // Fine sync adjustment (Sonora's `positionTrim` equivalent): seconds
    // added to the engine position when the lyrics are matched. Positive
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
        // Track change: jump without animation to the new active line.
        Qt.callLater(function () { scrollToActive(true) })
    }

    // Centres the active line in the viewport with a smooth animation.
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

    // Click on a line: jumps to that moment and goes back to following
    // the singing (like Sonora). The small margin keeps the highlight off
    // the previous line.
    function seekTo(t) {
        if (!ply || typeof ply.seek !== "function")
            return
        ply.seek(Math.max(0, Number(t)) + 0.05)
        following = true
        computeActive()
        Qt.callLater(function () { scrollToActive(true) })
    }

    // Fade by distance to the active line: the active one at 100 % and the
    // ones around it dimming in soft steps. Symmetric: it does not matter if
    // the line was already sung (above) or is still to come (below).
    function lineOpacity(i) {
        if (activeIndex < 0)
            return 0.78
        var d = Math.abs(i - activeIndex)
        if (d === 0)
            return 1
        if (d === 1)
            return 0.62
        if (d === 2)
            return 0.44
        if (d === 3)
            return 0.30
        return 0.20
    }

    // ---- relleno progresivo -------------------------------------------------
    function _rgbaStr(c) {
        var col = (typeof c === "string") ? Qt.color(c) : c
        return "rgba(" + Math.round(col.r * 255) + "," + Math.round(col.g * 255)
            + "," + Math.round(col.b * 255) + ","
            + (Math.round(col.a * 100) / 100) + ")"
    }

    // Colour half way between dimmed and lit. The text right at the front
    // is painted halfway, and that is why you see it eating the line
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

    // The part of the active line not sung yet: the SAME ink as the line
    // but dimmed (low alpha), like the shell widget does. With a separate
    // grey the line looked split in two and the karaoke looked ugly.
    readonly property real _unsungAlpha: 0.34
    readonly property color _sungColor: Sys.text
    readonly property color _unsungColor: Theme.alpha(_sungColor, _unsungAlpha)

    // Paints a line letter by letter: `fill` goes from 0 (just came in,
    // dimmed) to 1 (sung, in full text). Contiguous characters of the same
    // colour are grouped in a single tag: one tag per letter would break
    // the kerning and it would show in the line break.
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
            var css = _mixCss(_unsungColor, _sungColor, isVis ? front - k : 0)
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

    // Fills a line WITH word level timings: every word lights up on its
    // own segment, so the front follows the voice instead of spreading
    // evenly over the whole phrase (which is what the desktop widget
    // does). It reuses `_fillHtml` word by word.
    //
    // Careful with the segments: Apple Music rounds the timings to the
    // second, so several words of the same line share THE SAME instant
    // (and their "end" too). Using each word's time as it comes would
    // light them all at once and the line would appear complete all of a
    // sudden. That is why the segments are CHAINED: word N starts where
    // word N-1 ended, so the front advances word by word (which is what
    // the shell widget does).
    function _wordHtml(words) {
        if (!words || words.length === 0)
            return ""
        var tramos = []
        var prevFin = -1
        for (var i = 0; i < words.length; i++) {
            var w = words[i]
            var t0 = Number(w.t || 0)
            var e = Number(w.e || 0)
            var propio = (e > t0) ? (e - t0) : 0.3
            var ini = t0
            if (prevFin > ini)
                ini = prevFin
            var fin = ini + Math.max(propio, 0.3)
            tramos.push({ ini: ini, fin: fin })
            prevFin = fin
        }
        // The word that is eating the front right now.
        var actual = -1
        for (var j = 0; j < tramos.length; j++) {
            if (karaokePos >= tramos[j].ini)
                actual = j
            else
                break
        }
        var out = ""
        for (var k = 0; k < words.length; k++) {
            var f = 0
            if (k < actual) {
                f = 1
            } else if (k === actual) {
                var tr = tramos[k]
                f = (tr.fin > tr.ini)
                    ? Math.max(0, Math.min(1, (karaokePos - tr.ini) / (tr.fin - tr.ini)))
                    : 0
            }
            out += _fillHtml(String(words[k].text || ""), f)
        }
        return out
    }

    // Re-anchors the interpolated position to the engine's last value.
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
            // compensation or the karaoke: the backend is the shared one,
            // so the offset is brought over and everything is recomputed.
            if (lv.lyr) {
                var o = Number(lv.lyr.offset)
                if (!isNaN(o) && Math.abs(o - lv.offset) > 0.001)
                    lv.offset = o
            }
            lv.rebuild()
        }
    }
    // El motor emite positionChanged como mucho cada 240 ms: ese aviso reancla
    // the interpolated position and recomputes the active line.
    // `stateChanged` covers play/pause/seek, so that when paused the front
    // stays where it sounds and not where the last interpolation left it.
    Connections {
        target: lv.ply
        function onPositionChanged() { lv.syncKaraokePos(); lv.computeActive() }
        function onStateChanged() { lv.syncKaraokePos(); lv.computeActive() }
    }

    // Interpolates the position between the engine's reports so the fill's
    // front moves smoothly. It is always needed with synced lyrics playing:
    // with word level timings it animates the front word by word, and with
    // line level timings it feeds the sweep of the active phrase. The engine
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
            // With the tick the active line changes as soon as it crosses
            // its instant, without waiting for the engine's report (up to
            // 240 ms late).
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
        // The active one grows when it becomes active: the column
        // reorders and the first centring may have been computed before
        // the reflow. This second step (100 ms) smoothly fixes the
        // position.
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

    // Al volverse visible (abrir el cine o el panel de cola): el scroll se
    // had been skipped while it was hidden (`scrollToActive` bails if the
    // Flick is not visible), so on open we re-pin the position and jump
    // WITHOUT animation to the line that sounds. Without this, the cinema
    // opened with the lyrics where the last time left them and did not
    // settle until the line went by.
    onVisibleChanged: {
        if (!lv.visible || !lv.showSynced)
            return
        syncKaraokePos()
        computeActive()
        following = true
        Qt.callLater(function () { scrollToActive(true) })
    }

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

        // Manual scroll: we stop following the song until "Follow the
        // song" is pressed. The animation of its own does not count.
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
                    id: rrow
                    required property var modelData
                    required property int index
                    readonly property bool active: index === lv.activeIndex

                    // Con tiempos por palabra (y karaoke activado): el frente
                    // goes word by word. Without them: the whole line is
                    // ilumina al ser la activa (sin barrido a medias).
                    readonly property var _w: modelData.words ? modelData.words : []
                    readonly property bool karaoke: active && lv.karaokeOn && _w.length > 1


                    // Desvanecido de borde (como en el repo de referencia): la
                    // line fades itself out when it gets near the top or
                    // suelo de la vista. Nada de bandas negras por encima:
                    // sobre el lavado de la portada quedaban horrorosas.
                    readonly property real vfade: {
                        var zone = Math.max(28, lv.height * 0.14)
                        var top = y - syncedFlick.contentY
                        var a = Theme.clamp(top / zone, 0, 1)
                        var b = Theme.clamp((lv.height - top - height) / zone, 0, 1)
                        return Math.min(a, b)
                    }

                    width: lv.colW
                    // En un panel estrecho las frases largas no caben: que
                    // envuelvan en vez de cortarse a media palabra.
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    text: lv.karaoke ? lv._wordHtml(_w) : modelData.text
                    textFormat: lv.karaoke ? Text.RichText : Text.PlainText
                    color: active ? Theme.mix(Sys.text, Sys.accent, 0.14)
                                  : Sys.textDim
                    font.pixelSize: active ? lv.lineSize + lv.activeBoost
                                            : lv.lineSize
                    font.weight: active ? Font.DemiBold : Font.Normal
                    // The opacity goes up on hover: the line under the
                    // cursor se marca como «clicable» (salta a ese momento).
                    // Todo ello, multiplicado por el desvanecido de borde.
                    opacity: Math.min(vfade, lv.lineOpacity(index)
                                      + (lineMa.containsMouse ? 0.22 : 0))
                    horizontalAlignment: lv.leftAlign ? Text.AlignLeft : Text.AlignHCenter
                    lineHeight: 1.32
                    Behavior on opacity { NumberAnimation { duration: Theme.medMs } }
                    Behavior on color { ColorAnimation { duration: Theme.medMs } }

                    // Click on a line: jumps to that moment of the song.
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

    // The edges are no longer padded with colour bands: every line fades
    // on its own (see `vfade` in the delegate). The bands cut the fade and
    // sobre el lavado de la portada quedaban fatal.

    // "Follow the song" button: it shows when the user scrolls and stops
    // following the active line automatically (like Sonora).
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
    // A still icon, a headline and a support line. No boxes.
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

    // ---- fine sync: in the panel it appears on hover; in the cinema
    // mode it moves to the centre of the header (like in the reference repo)
    // and it follows the controls.
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