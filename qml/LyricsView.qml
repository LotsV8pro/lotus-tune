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
// surroundings are `Theme.tDim(Sys.bg, Sys.text)` dimmed by distance. No boxes, no glow,
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
    // Reading on the left (cinema mode, like in the reference repo):
    // the column starts at the edge of the area instead of being centred.
    // Panel and Now Playing stay centred (default).
    property bool leftAlign: false
    // Dueto (Sonora style): cuando la fuente marca las lineas de la
    // segunda voz (`secondary`), la voz principal se va a la IZQUIERDA y
    // la segunda a la DERECHA, de modo que se ve quien canta cada frase.
    // Sin marcas de dueto nada cambia (todo sigue centrado o alineado a la
    // izquierda segun `leftAlign`).
    property bool duetSides: false
    // Sync pill: top centre (cinema mode) and visible while the controls
    // are around (`pillShown`). By default: bottom right, on hover.
    property bool pillTop: false
    // El ajuste fino de sincronia es util en el panel, pero en el cinema
    // (pantalla completa, sin sitio) sobra: se apaga desde ahi.
    property bool syncAdjustAllowed: true
    property bool pillShown: false
    // Real background colour of the panel; the edges fade into it.
    property color edgeColor: Sys.surface
    // Which third of the blurred wash sits behind this view (0..8,
    // row-major). -1 = the whole artwork's average, which is right for a
    // panel but wrong in the cinema: a cover that is half black and half
    // white made the ink white over the white half and the lyrics vanished.
    property int zone: -1

    // ---- readable ink -------------------------------------------------
    // The REALLY visible colour behind the lines: the panel/veil (with its
    // own opacity) over the blurred artwork. From it the view picks a
    // near-white or a near-black ink, so the lyrics do not vanish into a
    // light cover (before they were always `Sys.text`: invisible over a
    // white wash).
    readonly property color bgBehind: {
        if (typeof wash === "undefined" || !wash.valid)
            return edgeColor
        const a = Math.max(0, Math.min(1, edgeColor.a))
        const base = (lv.zone >= 0 && lv.zone < 9)
                     ? wash.zoneColor(lv.zone) : wash.average
        return Theme.alpha(Theme.mix(base, edgeColor, a), 1)
    }
    readonly property color ink: Theme.onAccent(lv.bgBehind)
    // Soft tone for the lines that are not being sung. It is "dimmed" but
    // never below 5.5:1: over a mid-tone wash a plain tDim turned into
    // grey soup (and the line had no way back once its opacity dropped).
    readonly property color inkDim: Theme.readableOn(Theme.tDim(lv.bgBehind, lv.ink),
                                                     lv.bgBehind, 5.5)
    // Soft halo of the opposite tone: over a mid-tone (washed out) cover it
    // is what keeps every line legible without drawing boxes. It is the
    // "subtitles" trick: a dark rim around light ink (or the reverse) reads
    // even where the artwork and the text share a tone.
    readonly property color inkHalo: Theme.alpha(Theme.onAccent(lv.ink), 0.6)

    // Guarded references so the view still renders before the backend registers
    // the context properties.
    readonly property var lyr: (typeof lyrics !== "undefined") ? lyrics : null
    readonly property var ply: (typeof player !== "undefined") ? player : null

    // Synced lines already parsed by the backend: [{ time, text }]
    property var lines: []
    property int activeIndex: -1
    // The line that is drawn big: the one being sung, or the first one
    // while the song has not reached it yet. Before the first line the
    // cinema showed no active line at all; the first phrase is already
    // on screen, big, but it is not lit until it is sung.
    readonly property int focusedIndex: activeIndex >= 0
                                        ? activeIndex
                                        : (lines.length > 0 ? 0 : -1)

    readonly property bool loading: lyr ? !!lyr.loading : false
    readonly property bool hasLyrics: lyr ? !!lyr.hasLyrics : false
    readonly property bool hasSynced: lyr ? !!lyr.hasSynced : false
    readonly property string plainText: lyr ? String(lyr.plain || "") : ""
    readonly property string errorText: lyr ? String(lyr.error || "") : ""

    readonly property bool showSynced: hasSynced && lines.length > 0
    // Solo se interpola la letra (60 Hz) cuando de verdad se esta viendo.
    // Estas vistas viven siempre (panel derecho, cinema..., abiertas o no)
    // y, con una cancion con letra sonando, sus temporizadores se comian un
    // nucleo entero en el movil aunque el panel estuviera cerrado.
    property bool live: false
    // ¿La cancion tiene dos voces? Solo si la fuente lo dice: se mira si
    // alguna linea viene marcada como `secondary` (segunda voz). Asi el
    // reparto a los lados no se inventa en canciones de un solo cantante.
    readonly property bool duet: {
        if (!duetSides)
            return false
        for (let i = 0; i < lines.length; ++i) {
            if (lines[i] && lines[i].secondary === true)
                return true
        }
        return false
    }
    readonly property bool showPlain: hasLyrics && !showSynced && plainText.length > 0
    readonly property bool showError: !loading && errorText.length > 0 && !showSynced && !showPlain
    readonly property bool showEmpty: !loading && !showSynced && !showPlain && !showError

    // With word timings (Apple Music, Musixmatch, NetEase klyric) the
    // active line fills syllable by syllable; the sources that only give
    // line timings light the whole phrase when it starts.
    // ---- geometry of the reading column --------------------------------
    readonly property real sidePad: 24
    readonly property real colW: Math.max(140, Math.min(width - (leftAlign ? sidePad : sidePad * 2), maxLineWidth))
    // The 3-line window keeps every row at the height of the highlighted
    // line: that way the column does not reflow when the highlight moves
    // (the text grows and a long phrase could even wrap to one more
    // line), which made the change of line look like a jump. The gap
    // gives back the space the reserved line adds.
    readonly property bool steadyRows: visibleLines > 0
    // The lines that are not being sung are a bit smaller: the sounding
    // one is the one that has to stand out (they read as a frame around it,
    // not as more lyrics at the same level).
    property real dimScale: 0.86
    readonly property int lineGap: Math.max(6, Math.round(lineSize * 0.62)
                                            - (steadyRows
                                               ? Math.round(activeBoost * 1.1) : 0))
    // Half height: that way the first and the last line can be centred
    // too.
    readonly property int edgePad: Math.max(56, Math.floor(height / 2))
    // Sonora anchors the active line at 32 % of the height (not centred).
    // The padding above/below allows pinning any line at that height, and
    // `following` decides whether we follow the singing or respect a manual
    // scroll.
    // Altura a la que queda fijada la linea activa (0 = arriba, 0.5 =
    // centrada). El cinema lo baja a ~0.34 para que se vean las que vienen.
    property real pinFrac: 0.5
    readonly property real pinTop: Math.max(56, Math.floor(height * pinFrac))
    readonly property real pinBottom: Math.max(56, Math.ceil(height * (1 - pinFrac)))
    // Maximum number of lyric lines on screen (0 = the whole song). The
    // cinema uses 3 (previous, active, next): with the full list the text
    // ran down to the progress bar of the left column and the screen
    // looked like a wall of text.
    property int visibleLines: 0
    property bool following: true
    property bool _animating: false
    property int _pinTries: 0

    // ---- progressive fill (karaoke) -------------------------------------
    // Position interpolated between the engine's reports.
    // `positionChanged` arrives at most every 240 ms; the fill's front is
    // computed on top of this position, so it moves smoothly instead of
    // jumping every 240 ms.
    property real karaokePos: 0
    property real _posAnchor: 0
    property double _posStamp: 0

    // ---- word level karaoke ---------------------------------------------
    // Same mechanism as the desktop lyrics widget (iNiR, IrisLyricsFace):
    // the active line is laid out by a TextEdit (which can say where every
    // character sits in a wrapped line) and the sung part is drawn by
    // three clipped copies of that same TextEdit. The fill therefore
    // follows the voice word by word, without the half sweeps the old
    // RichText approach produced.
    //
    // Inside a word the front does not move per letter: the widget's maths
    // spread the word evenly over its letters, so a long word ("corazón")
    // took four times longer than a short one ("y") in the same phrase.
    // Here the word's time is shared by its SYLLABLES, which is how it is
    // actually sung; within a syllable the letters still fill one by one.
    readonly property bool karaokeOn: lv.lyr ? lv.lyr.karaoke !== false : true
    // Per line: [{a, b, t, e, syl}] with the characters a..b of the line
    // sung between t and e seconds and `syl` the syllable ends (relative
    // to a). Empty for lines without word timings.
    property var wordSpans: []

    readonly property var activeLineData: (activeIndex >= 0
                                           && activeIndex < lines.length)
                                          ? lines[activeIndex] : null
    readonly property string activeLineText: activeLineData
                                             ? String(activeLineData.text || "") : ""
    readonly property bool activeLineSec: activeLineData
                                          ? activeLineData.secondary === true : false
    readonly property bool activeHasWords: activeIndex >= 0
                                           && activeIndex < wordSpans.length
                                           && wordSpans[activeIndex]
                                           && wordSpans[activeIndex].length > 0
    readonly property real activeSung: (karaokeOn && activeHasWords)
                                       ? sungFor(activeIndex) : 0
    // Ink of the active line: the whole phrase in `activeInk` when it has
    // no word timings; with timings the phrase waits in `activeDimInk`
    // and the sung part lights in `activeInk`.
    readonly property color activeInk: Theme.readableOn(
                                           Theme.mix(lv.ink, Sys.accent, 0.14),
                                           lv.bgBehind)
    readonly property color activeDimInk: Theme.readableOn(
                                              Theme.mix(lv.ink, lv.bgBehind, 0.55),
                                              lv.bgBehind, 4.5)

    // Character offset of the singing front inside line `i` (fractional
    // while a word is being sung).
    function sungFor(i) {
        if (i < 0 || i >= wordSpans.length)
            return 0
        var spans = wordSpans[i]
        if (!spans || spans.length === 0)
            return 0
        var pos = karaokePos
        var at = 0
        for (var k = 0; k < spans.length; ++k) {
            var w = spans[k]
            if (pos < w.t)
                break
            if (!(w.e > w.t)) {
                at = w.b
                continue
            }
            var p = Math.min(1, (pos - w.t) / (w.e - w.t))
            if (w.syl && w.syl.length > 1) {
                // Syllable by syllable: every syllable takes the same
                // slice of the word's time and the letters inside it fill
                // linearly, so the front lands on syllable boundaries.
                var n = w.syl.length
                var local = p * n
                var s = Math.min(n - 1, Math.floor(local))
                var f = Math.min(1, local - s)
                var from = (s === 0) ? 0 : w.syl[s - 1]
                var to = w.syl[s]
                at = w.a + from + (to - from) * f
            } else {
                at = w.a + (w.b - w.a) * p
            }
        }
        return at
    }

    // Maps the backend words ({t,e,text}) onto character ranges of the
    // line. The words may carry their trailing space, so the trimmed text
    // is searched from the previous match: repeated words ("la la la")
    // still land in their own place.
    function _spansFor(text, words) {
        var s = String(text || "")
        var out = []
        var from = 0
        for (var i = 0; i < words.length; ++i) {
            var w = words[i]
            if (!w)
                continue
            var core = String(w.text || "").replace(/^\s+/, "").replace(/\s+$/, "")
            if (core.length === 0)
                continue
            var at = s.indexOf(core, from)
            if (at < 0)
                at = s.indexOf(core)
            if (at < 0)
                at = Math.min(from, s.length)
            var len = Math.min(core.length, s.length - at)
            var t = Number(w.t || 0)
            var e = Number(w.e || 0)
            if (!(e > t))
                e = t + 0.2
            out.push({ a: at, b: at + len, t: t, e: e,
                       syl: _sylCuts(s.substr(at, len)) })
            from = at + Math.max(1, core.length)
        }
        _rebalanceTail(out)
        return out
    }

    // The provider sometimes clips the last syllable of a phrase: it sets
    // its end at the line's end but its begin almost there too, so the
    // last word gets a 20-70 ms slice ("bleed", "dust") and the fill
    // flashes through it at the end of every phrase. The tail of the line
    // is shared again between the last two syllables by their length, so
    // the last word is sung at a believable pace instead of jumping.
    function _rebalanceTail(spans) {
        var n = spans.length
        if (n < 2)
            return
        var last = spans[n - 1]
        var prev = spans[n - 2]
        var dur = last.e - last.t
        if (!(dur > 0) || !(last.e > prev.t))
            return
        var tailDur = last.e - prev.t
        var uLast = (last.syl && last.syl.length > 0) ? last.syl.length
                                                       : Math.max(1, last.b - last.a)
        var uPrev = (prev.syl && prev.syl.length > 0) ? prev.syl.length
                                                       : Math.max(1, prev.b - prev.a)
        var expected = tailDur * uLast / (uLast + uPrev)
        if (dur >= expected * 0.35 && dur >= 0.10)
            return
        var at = prev.t
        prev.t = at
        prev.e = at + tailDur * uPrev / (uLast + uPrev)
        last.t = prev.e
        last.e = at + tailDur
    }

    // ---- syllables ------------------------------------------------------
    // End of each syllable inside `word`, as character offsets (the last
    // one is the word's length). It is a near enough split, not a
    // dictionary: vowel groups are the nuclei and the consonants between
    // them are shared the way Spanish (and most Latin scripts) do it.
    function _isCjk(c) {
        return (c >= 0x3040 && c <= 0x30ff) || (c >= 0x3400 && c <= 0x4dbf)
            || (c >= 0x4e00 && c <= 0x9fff) || (c >= 0xf900 && c <= 0xfaff)
            || (c >= 0xff66 && c <= 0xff9f) || (c >= 0xac00 && c <= 0xd7af)
    }
    function _isSmallKana(c) {
        return "ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ".indexOf(String.fromCharCode(c)) >= 0
    }
    function _isVowel(c) {
        var ch = String.fromCharCode(c).toLowerCase()
        return "aeiouyàáâäãåāăąæèéêëēĕėęěìíîïĩīĭįòóôöõøōŏőœùúûüũūŭůűųýÿ".indexOf(ch) >= 0
            || "аеёиоуыэюяіїє".indexOf(ch) >= 0
            || "αεηιουωάέήίόύώϊϋΐΰ".indexOf(ch) >= 0
    }
    function _isLiquidPair(a, b) {
        // Consonant groups that stay together at the start of a syllable.
        var pair = (a + b).toLowerCase()
        return ["pr", "br", "tr", "dr", "cr", "gr", "fr", "vr", "pl", "bl",
                "cl", "gl", "fl", "ch", "ll", "rr", "qu", "gu"].indexOf(pair) >= 0
    }
    function _sylCuts(word) {
        var s = String(word || "")
        var n = s.length
        if (n <= 1)
            return [n]
        var cjk = 0
        for (var i = 0; i < n; ++i)
            if (_isCjk(s.charCodeAt(i)))
                ++cjk
        if (cjk >= n * 0.6) {
            // Japanese/Chinese/Korean: a character is a syllable (a small
            // kana belongs to the one before it).
            var kana = []
            for (var j = 0; j < n; ++j) {
                if (j + 1 < n && _isSmallKana(s.charCodeAt(j + 1)))
                    continue
                kana.push(j + 1)
            }
            return kana
        }
        // Vowel groups (diphthongs count as one nucleus).
        var groups = []
        var p = 0
        while (p < n) {
            if (_isVowel(s.charCodeAt(p))) {
                var q = p + 1
                while (q < n && _isVowel(s.charCodeAt(q)))
                    ++q
                groups.push([p, q])
                p = q
            } else {
                ++p
            }
        }
        if (groups.length <= 1)
            return [n]
        var cuts = []
        for (var g = 1; g < groups.length; ++g) {
            var prevEnd = groups[g - 1][1]
            var nextStart = groups[g][0]
            var k = nextStart - prevEnd
            var cut = prevEnd
            if (k === 1) {
                cut = prevEnd + 1                 // consonant opens the next
            } else if (k === 2) {
                cut = _isLiquidPair(s.charAt(prevEnd), s.charAt(prevEnd + 1))
                      ? prevEnd : prevEnd + 1     // "ha-blar" vs "can-tar"
            } else if (k >= 3) {
                cut = prevEnd + (k - 2)           // "ins-tan-te"
            }
            if (cut <= 0 || cut >= n)
                continue
            if (cuts.length === 0 || cut > cuts[cuts.length - 1])
                cuts.push(cut)
        }
        cuts.push(n)
        return cuts
    }

    // Fine sync adjustment (Sonora's `positionTrim` equivalent): seconds
    // added to the engine position when the lyrics are matched. Positive
    // = the lyrics run ahead and they are delayed to match the audio. It is
    // stored in the app's config so it survives a restart.
    //
    // It is also stored PER TRACK (artist - title): the offset depends on
    // the recording (the lyrics come from the album while the video may have
    // a longer intro), so a global offset does not work. What you set here
    // sticks to that song, and the desktop widget inherits it (the backend
    // publishes the applied offset).
    property real offset: 0
    function setOffset(v) {
        // The range is wide: a video may have a much longer intro than
        // the album (and the opposite too).
        offset = Math.round(Theme.clamp(v, -180, 180) * 4) / 4    // 250 ms steps
        if (typeof appcfg !== "undefined") {
            appcfg.set("lyricsOffset", offset.toFixed(2))
            // Offset per track: "artist - title" -> seconds.
            const key = String(lv.lyr && lv.lyr.trackKey ? lv.lyr.trackKey : "")
            if (key.length > 0) {
                let map = {}
                try {
                    map = JSON.parse(appcfg.get("lyricsOffsetByTrack") || "{}")
                } catch (e) {
                    map = {}
                }
                map[key] = offset
                appcfg.set("lyricsOffsetByTrack", JSON.stringify(map))
            }
            appcfg.save()
        }
        // The backend publishes this same adjustment in the lyrics state so
        // that the desktop widgets match the audio just like the app.
        if (lv.lyr && typeof lv.lyr.setPublishedOffset === "function")
            lv.lyr.setPublishedOffset(offset)
    }

    // Applies the offset saved for this track (if any) when the lyrics load.
    function applyStoredOffset() {
        if (typeof appcfg === "undefined")
            return
        const key = String(lv.lyr && lv.lyr.trackKey ? lv.lyr.trackKey : "")
        if (key.length === 0)
            return
        let map = {}
        try {
            map = JSON.parse(appcfg.get("lyricsOffsetByTrack") || "{}")
        } catch (e) {
            map = {}
        }
        // Every track has its own offset: when this one has no saved
        // adjust, the offset goes back to 0. Before, the offset of the
        // previous track was kept and every song played after it came out
        // late.
        let v = 0
        if (map[key] !== undefined) {
            const n = Number(map[key])
            if (!isNaN(n))
                v = n
        }
        if (Math.abs(v - offset) < 0.001)
            return
        offset = v
        if (lv.lyr && typeof lv.lyr.setPublishedOffset === "function"
                && Math.abs(Number(lv.lyr.offset || 0) - v) > 0.001)
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
        // Two lines that overlap: the one that was already being sung is
        // still the main one while it has voice left. Before, the new one
        // took over as soon as it started and the main phrase faded out in
        // the middle of a word (the jump to the chorus that could be seen).
        while (idx > 0) {
            var prev = lines[idx - 1]
            var prevEnd = Number(prev && prev.end ? prev.end : 0)
            if (!(prevEnd > pos + 0.20))
                break
            var cur = lines[idx]
            var curStart = Number(cur && cur.time ? cur.time : 0)
            var curEnd = Number(cur && cur.end ? cur.end : 0)
            // The one coming in is a short piece on top of it (an answer,
            // an adlib, the second voice): it does not take the big line.
            if (!(curEnd > curStart && (curEnd - curStart) < (prevEnd - pos)))
                break
            idx = idx - 1
        }
        activeIndex = idx
    }

    function rebuild() {
        var src = (lyr && lyr.lines) ? lyr.lines : []
        lines = (src && src.length) ? src : []
        // Character ranges for the karaoke fill, precomputed once per
        // track: the delegates only read them.
        var spans = []
        for (var i = 0; i < lines.length; ++i) {
            var ln = lines[i]
            var ws = (ln && ln.words) ? ln.words : []
            spans.push((ws && ws.length > 1 && ln.instrumental !== true)
                       ? _spansFor(ln.text, ws) : [])
        }
        wordSpans = spans
        // Every track has its own offset (the video may have a longer intro
        // than the album): the one saved for it is applied here.
        applyStoredOffset()
        // New track: we go back to following the singing from the beginning.
        following = true
        computeActive()
        // Track change: jump without animation to the new active line.
        Qt.callLater(function () { scrollToActive(true) })
    }

    // Pins the line that is sounding at `pinTop` (the middle of the cover
    // by default). The row is measured where the column actually laid it
    // out, so a line that wrapped to two rows is still centred and the
    // highlight never drifts upwards as the song goes on.
    //
    // `instant` jumps without animation (opening the view, resizing, a
    // seek); otherwise the move is animated. It is what keeps the active
    // line fixed in place while the rest of the lyrics scroll under it.
    function scrollToActive(instant) {
        if (!showSynced || !visible || syncedFlick.height <= 0)
            return
        var idx = focusedIndex
        if (idx < 0 || idx >= lines.length)
            return
        var it = lyricRepeater.itemAt(idx)
        if (!it) {
            // The delegates are laid out a frame later: retry, but only a
            // handful of times (a row that never exists would loop).
            if (lv._pinTries < 6) {
                lv._pinTries++
                Qt.callLater(function () { lv.scrollToActive(instant) })
            }
            return
        }
        lv._pinTries = 0
        var center = it.y + it.height / 2
        var maxY = Math.max(0, syncedFlick.contentHeight - syncedFlick.height)
        var target = Math.max(0, Math.min(maxY, center - lv.pinTop))
        if (Math.abs(target - syncedFlick.contentY) < 1) {
            if (scrollAnim.running)
                scrollAnim.stop()
            _animating = false
            return
        }
        if (instant) {
            if (scrollAnim.running)
                scrollAnim.stop()
            _animating = false
            syncedFlick.contentY = target
            return
        }
        // The scroll of the line that just arrived is already running and
        // the layout was corrected in the same frame: only the target is
        // updated. Restarting the animation reset the easing (it slowed
        // down and started again) and the jump was visible.
        if (scrollAnim.running) {
            scrollAnim.to = target
            return
        }
        _animating = true
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

    // Every line stays visible. The old fade by distance to the active line
    // (1 / 0.74 / 0.48 / 0.22 / 0) turned the rest of the lyrics into
    // ghosts: over a washed-out cover you could not read the stanza that
    // was not next to the singing one, and it looked like the background
    // was eating the text. The hierarchy is carried by SIZE, weight and the
    // accent tint of the active line, plus the colour contrast (inkDim is
    // forced to 5.5:1). The top/bottom edge fade (`vfade`) already softens
    // the ends of the view.
    function lineOpacity(i) {
        if (activeIndex < 0)
            return 1
        return i === activeIndex ? 1 : 0.95
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
            // Settings (or another view on screen) may have moved the
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
    // The engine emits positionChanged at most every 240 ms: that notice
    // re-anchors the interpolated position and recomputes the active line.
    // `stateChanged` covers play/pause/seek, so that when paused the front
    // stays where it sounds and not where the last interpolation left it.
    Connections {
        target: lv.ply
        function onPositionChanged() {
            if (!lv.live)
                return
            lv.syncKaraokePos()
            lv.computeActive()
        }
        function onStateChanged() {
            if (!lv.live)
                return
            lv.syncKaraokePos()
            lv.computeActive()
        }
    }

    // Interpolates the position between the engine's reports so the fill's
    // front moves smoothly. It is always needed with synced lyrics playing:
    // with word level timings it animates the front word by word, and with
    // line level timings it feeds the sweep of the active phrase. The engine
    // of the engine arrives at 240 ms; at 50 ms the front moves smoothly.
    Timer {
        // 60 fps: the front is interpolated between the engine's reports,
        // and at 30 fps the fill visibly stepped on a 165 Hz screen. It
        // only runs while a synced song plays.
        interval: 16
        repeat: true
        running: lv.live && lv.showSynced && !!lv.ply && lv.ply.playing
        onTriggered: {
            if (!lv.ply)
                return
            // The position is re-anchored to the engine on EVERY tick (and
            // not only when it reports): if the engine's reports are late
            // (a busy track, a slow source) the interpolated front used to
            // run ahead of the voice by seconds, and the line looked fully
            // lit instead of being sung word by word.
            var now = Date.now()
            var engine = Number(lv.ply.position || 0)
            if (engine !== lv._posAnchor) {
                lv._posAnchor = engine
                lv._posStamp = now
            }
            var est = lv._posAnchor + (now - lv._posStamp) / 1000
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

    // After a manual scroll the lyrics go back to the singing line on
    // their own (2 s without touching the list): a scroll left the active
    // line where it was, off the centre, and it never came back until the
    // "Seguir la canción" pill was pressed.
    Timer {
        id: refollow
        interval: 2000
        onTriggered: {
            if (!lv.showSynced || !lv.live)
                return
            lv.following = true
            lv.scrollToActive(false)
        }
    }

    // The column reflows a frame or two after the active line changes (that
    // row grows and the ones below move): the first scroll was aimed at the
    // box measured BEFORE that, so the line stayed a little off the pin and
    // every change left it a bit further up ("se va para arriba y no se
    // mantiene"). This cheap check (some arithmetic, 20 times per second)
    // looks at the real position and corrects it until it matches.
    Timer {
        id: pinWatch
        interval: 48
        repeat: true
        running: lv.following && lv.showSynced && lv.live
        onTriggered: lv.scrollToActive(false)
    }

    // Re-centre on resize (window <-> fullscreen change).
    onHeightChanged: Qt.callLater(function () { lv.scrollToActive(true) })
    onWidthChanged: Qt.callLater(function () { lv.scrollToActive(true) })

    // When it becomes visible (opening the cinema or the queue panel): the scroll
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

    // Al abrirse el panel/cinema hay que ponerse al dia: mientras estaba
    // cerrado no se interpolaba ni se recalculaba la linea activa.
    onLiveChanged: {
        if (!lv.live || !lv.showSynced)
            return
        syncKaraokePos()
        computeActive()
        following = true
        Qt.callLater(function () { scrollToActive(true) })
    }

    // A bright copy of the active line for the clipped fill layers: it has
    // to lay out exactly like `editBase` in the delegate, or the front
    // would cut between the wrong glyphs.
    component KaraokeText: TextEdit {
        required property string lineText
        required property real textWidth
        required property color inkColor
        required property bool rightAligned
        width: textWidth
        text: lineText
        color: inkColor
        readOnly: true
        enabled: false
        focus: false
        selectByMouse: false
        activeFocusOnPress: false
        textFormat: TextEdit.PlainText
        textMargin: 0
        wrapMode: TextEdit.Wrap
        font.pixelSize: lv.lineSize + lv.activeBoost
        font.weight: Font.DemiBold
        horizontalAlignment: lv.duet
                             ? (rightAligned ? TextEdit.AlignRight : TextEdit.AlignLeft)
                             : (lv.leftAlign ? TextEdit.AlignLeft : TextEdit.AlignHCenter)
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
            color: lv.inkDim
            weight: 1.5
        }
        Text {
            Layout.fillWidth: true
            text: "Buscando letra…"
            color: lv.inkDim
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

        // Manual scroll: the song stops being followed for a moment (so
        // the user can read ahead), but the sounding line is pinned again
        // by itself: it must not stay lost off the middle of the cover
        // because of one scroll. The view's own animation does not count.
        onMovementStarted: {
            if (lv._animating)
                return
            lv.following = false
            refollow.stop()
        }
        onMovementEnded: if (!lv._animating) refollow.restart()
        onFlickEnded: if (!lv._animating) refollow.restart()
        onContentYChanged: if (!lv._animating && syncedFlick.moving
                               && lv.following) lv.following = false

        // Reading column centred and with a bounded width.
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
                delegate: Item {
                    id: rrow
                    required property var modelData
                    required property int index
                    readonly property bool active: index === lv.activeIndex
                    readonly property bool focused: index === lv.focusedIndex
                    // Subtitle window: only the focused line and its
                    // neighbours have ink. The rest stay in the model (the
                    // karaoke needs them) but are fully transparent.
                    readonly property int windowCenter: lv.focusedIndex >= 0
                                                        ? lv.focusedIndex : 0
                    readonly property bool inWindow: lv.visibleLines <= 0
                        || Math.abs(index - rrow.windowCenter)
                           <= Math.floor((lv.visibleLines - 1) / 2)

                    // The instrumental markers ("♪") are shown, but they
                    // are not sung and they keep their dim colour.
                    readonly property bool instrumental: modelData.instrumental === true
                    // The three notes of an instrumental stretch light up
                    // as it goes, like the fill of the lyrics: each note
                    // takes a third of the stretch and brightens through
                    // it (nothing jumps on at a stroke). The timings are
                    // the line's own: nothing is moved.
                    readonly property real instrStart: Number(modelData.time || 0)
                    readonly property real instrEnd: Math.max(instrStart + 0.6,
                                                              Number(modelData.end || 0))
                    readonly property real instrSpan: Math.max(0.6,
                                                               instrEnd - instrStart)
                    function noteFill(k) {
                        var slot = instrSpan / 3
                        var a = instrStart + slot * k
                        return Theme.clamp((lv.karaokePos - a) / Math.max(0.25, slot),
                                           0, 1)
                    }
                    // Segunda voz del dueto: su frase sale desde la derecha.
                    readonly property bool sec: modelData.secondary === true

                    // With word timings the active line is drawn by a
                    // TextEdit (it can say where each character sits) and
                    // the sung part by clipped copies of it.
                    readonly property bool karaokeRow: active && lv.karaokeOn
                                                       && lv.activeHasWords
                                                       && !rrow.instrumental
                    readonly property bool filling: karaokeRow && lv.activeSung > 0

                    // Dueto: la voz principal empieza a la izquierda y la
                    // segunda se pega a la derecha (con un pequeño margen
                    // para que no toque el borde de la columna).
                    readonly property real padL: lv.duet && !rrow.sec ? 6 : 0
                    readonly property real padR: lv.duet && rrow.sec ? 6 : 0
                    readonly property real textW: Math.max(1, rrow.width - padL - padR)
                    readonly property int rowPx: focused
                        ? lv.lineSize + lv.activeBoost
                        : Math.round(lv.lineSize * lv.dimScale)
                    // Row pitch of the TextEdit: the halo Text has to use
                    // the same one or it drifts from the line it outlines.
                    readonly property real editPitch: editBase.lineCount > 0
                                                      ? editBase.contentHeight / editBase.lineCount
                                                      : rowPx * 1.2

                    // The singing front, as a caret inside the active
                    // line: the rows above it are sung whole and its own
                    // row up to here.
                    readonly property rect caret: {
                        void (editBase.text + editBase.contentWidth
                              + editBase.contentHeight + editBase.width
                              + editBase.font.pixelSize + lv.activeSung)
                        if (!rrow.filling)
                            return Qt.rect(0, 0, 0, 0)
                        var i = Math.min(Math.floor(lv.activeSung), editBase.length)
                        var f = lv.activeSung - i
                        var a = editBase.positionToRectangle(i)
                        if (f <= 0 || i >= editBase.length)
                            return a
                        var b = editBase.positionToRectangle(i + 1)
                        // A packed word break: the fractional advance makes
                        // no sense from one row to the next, so the word
                        // stays on the first row until the line moves.
                        return (b.y === a.y)
                               ? Qt.rect(a.x + (b.x - a.x) * f, a.y, 0, a.height)
                               : a
                    }

                    // Edge fade: each line fades itself out near the top
                    // or the bottom of the view. No black bands above:
                    // over the artwork wash they looked horrible.
                    readonly property real vfade: {
                        var zone = Math.max(20, lv.height * 0.09)
                        var top = y - syncedFlick.contentY
                        var a = Theme.clamp(top / zone, 0, 1)
                        var b = Theme.clamp((lv.height - top - height) / zone, 0, 1)
                        return Math.min(a, b)
                    }

                    width: lv.colW
                    height: Math.ceil(lv.steadyRows
                                      ? measure.implicitHeight
                                      : (karaokeRow ? editBase.contentHeight
                                                    : base.implicitHeight))
                    // The opacity goes up on hover: the line under the
                    // cursor is marked as «clickable» (it jumps to that moment).
                    // All of that, multiplied by the edge fade. In the
                    // 3-line window the rows outside it fade out: they
                    // keep their place (the list never reflows) but take
                    // no ink.
                    opacity: !rrow.inWindow ? 0
                             : (rrow.instrumental
                                ? Math.min(vfade, 0.95)
                                : Math.min(vfade, lv.lineOpacity(index)
                                           + (lineMa.containsMouse ? 0.22 : 0)))
                    Behavior on opacity { NumberAnimation { duration: Theme.medMs } }

                    // Invisible ruler: the height of the row is always the
                    // one of the highlighted line (see `steadyRows`), so
                    // the list never reflows when the highlight moves.
                    Text {
                        id: measure
                        visible: false
                        width: rrow.width
                        leftPadding: rrow.padL
                        rightPadding: rrow.padR
                        wrapMode: Text.WordWrap
                        text: rrow.modelData.text || ""
                        textFormat: Text.PlainText
                        font.pixelSize: lv.lineSize + lv.activeBoost
                        font.weight: Font.DemiBold
                        lineHeight: 1.32
                    }

                    // Soft halo in the opposite tone: the last line of
                    // defence when the wash is mid-tone. Only the karaoke
                    // line needs its own (the others carry it on the Text).
                    Text {
                        id: halo
                        visible: rrow.karaokeRow
                        x: rrow.padL
                        width: rrow.textW
                        text: rrow.modelData.text || ""
                        color: "transparent"
                        style: Text.Outline
                        styleColor: lv.inkHalo
                        wrapMode: Text.WordWrap
                        font.pixelSize: rrow.rowPx
                        font.weight: Font.DemiBold
                        lineHeightMode: Text.FixedHeight
                        lineHeight: rrow.editPitch
                        horizontalAlignment: lv.duet
                                             ? (rrow.sec ? Text.AlignRight : Text.AlignLeft)
                                             : (lv.leftAlign ? Text.AlignLeft : Text.AlignHCenter)
                    }

                    // The line as it waits: dimmed until it is sung.
                    Text {
                        id: base
                        // The instrumental stretch has its own three notes.
                        visible: !rrow.karaokeRow && !rrow.instrumental
                        width: rrow.width
                        leftPadding: rrow.padL
                        rightPadding: rrow.padR
                        wrapMode: Text.WordWrap
                        text: rrow.modelData.text || ""
                        textFormat: Text.PlainText
                        // Before the first line the focused phrase is big
                        // but not lit (it is not being sung yet).
                        color: rrow.active
                               ? lv.activeInk
                               : (rrow.focused ? lv.activeDimInk : lv.inkDim)
                        style: Text.Outline
                        styleColor: lv.inkHalo
                        font.pixelSize: rrow.rowPx
                        font.weight: rrow.focused ? Font.DemiBold : Font.Normal
                        horizontalAlignment: lv.duet
                                             ? (rrow.sec ? Text.AlignRight : Text.AlignLeft)
                                             : (lv.leftAlign ? Text.AlignLeft : Text.AlignHCenter)
                        lineHeight: 1.32
                        Behavior on color { ColorAnimation { duration: Theme.medMs } }
                    }

                    // Instrumental stretch: three notes that light up as
                    // it goes. They read the line's own time/end, so the
                    // rest of the timings are untouched.
                    Row {
                        id: noteRow
                        visible: rrow.instrumental
                        x: rrow.padL + (lv.duet
                                        ? (rrow.sec
                                           ? Math.max(0, rrow.textW - width) : 0)
                                        : (lv.leftAlign
                                           ? 0
                                           : Math.max(0, (rrow.textW - width) / 2)))
                        spacing: Math.round(lv.lineSize * 0.40)
                        Repeater {
                            model: 3
                            delegate: Text {
                                required property int index
                                text: "♪"
                                // The note brightens across its third of
                                // the stretch, never in one go.
                                color: Theme.mix(lv.inkDim, lv.activeInk,
                                                 rrow.noteFill(index))
                                style: Text.Outline
                                styleColor: lv.inkHalo
                                font.pixelSize: rrow.rowPx
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    // The active line with word timings: same layout, but
                    // the sung part is drawn bright above the dim one.
                    TextEdit {
                        id: editBase
                        visible: rrow.karaokeRow
                        x: rrow.padL
                        width: rrow.textW
                        text: rrow.modelData.text || ""
                        color: lv.activeDimInk
                        readOnly: true
                        enabled: false
                        focus: false
                        selectByMouse: false
                        activeFocusOnPress: false
                        textFormat: TextEdit.PlainText
                        textMargin: 0
                        wrapMode: TextEdit.Wrap
                        font.pixelSize: rrow.rowPx
                        font.weight: Font.DemiBold
                        horizontalAlignment: lv.duet
                                             ? (rrow.sec ? TextEdit.AlignRight : TextEdit.AlignLeft)
                                             : (lv.leftAlign ? TextEdit.AlignLeft : TextEdit.AlignHCenter)
                    }

                    Item {
                        id: fillLayer
                        x: rrow.padL
                        width: rrow.textW
                        height: rrow.height
                        // The line lights up with a short fade instead of
                        // appearing lit at once when the highlight jumps.
                        visible: rrow.karaokeRow
                        opacity: rrow.filling ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.fastMs } }

                        // Rows above the front: sung whole.
                        Item {
                            width: parent.width
                            height: Math.max(0, rrow.caret.y)
                            clip: true
                            KaraokeText {
                                lineText: rrow.modelData.text || ""
                                textWidth: rrow.textW
                                inkColor: lv.activeInk
                                rightAligned: rrow.sec
                            }
                        }
                        // The front's own row: from its start to the front.
                        Item {
                            y: rrow.caret.y
                            width: Math.max(0, rrow.caret.x)
                            height: Math.max(1, rrow.caret.height)
                            clip: true
                            KaraokeText {
                                lineText: rrow.modelData.text || ""
                                textWidth: rrow.textW
                                inkColor: lv.activeInk
                                rightAligned: rrow.sec
                                y: -rrow.caret.y
                            }
                        }
                        // Soft edge: the word being sung lights as it goes,
                        // not behind a hard cut.
                        Item {
                            x: rrow.caret.x
                            y: rrow.caret.y
                            width: 10
                            height: Math.max(1, rrow.caret.height)
                            clip: true
                            opacity: 0.45
                            visible: rrow.caret.x > 0
                                     && lv.activeSung < rrow.modelData.text.length
                            KaraokeText {
                                lineText: rrow.modelData.text || ""
                                textWidth: rrow.textW
                                inkColor: lv.activeInk
                                rightAligned: rrow.sec
                                x: -rrow.caret.x
                                y: -rrow.caret.y
                            }
                        }
                    }

                    // Click on a line: jumps to that moment of the song.
                    MouseArea {
                        id: lineMa
                        anchors.fill: parent
                        // The rows of the 3-line window are the only ones
                        // that can be clicked (the others are invisible).
                        enabled: rrow.inWindow
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof sfx !== "undefined") sfx.play("tap")
                            lv.seekTo(modelData.time)
                        }
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
    // over the artwork wash they looked awful.

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
        antialiasing: true
        color: followMa.containsMouse
               ? Theme.hover(Sys.surface) : Sys.surface
        border.width: 1
        border.color: Theme.line(Sys.bg, Sys.text)
        Behavior on color { ColorAnimation { duration: Theme.fastMs } }

        RowLayout {
            id: followRow
            anchors.centerIn: parent
            spacing: 6
            Glyph { width: 12; height: 12; kind: "refresh"; color: Sys.accent }
            Text {
                text: "Seguir la canción"
                color: Theme.accentOn(Sys.accent, Sys.bg)
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
                if (typeof sfx !== "undefined") sfx.play("tap")
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
            color: lv.inkDim
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
            color: lv.ink
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
            color: lv.inkDim
            weight: 1.3
        }
        Text {
            Layout.fillWidth: true
            text: lv.showError ? lv.errorText : "Sin letra sincronizada"
            color: lv.showError ? Theme.accentOn(Sys.danger, lv.bgBehind) : lv.ink
            font.pixelSize: Theme.tLg
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        }
        Text {
            Layout.fillWidth: true
            text: lv.showError ? "No encontramos la letra de esta canción." : "Buscando la letra…"
            color: lv.inkDim
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
        visible: lv.showSynced && lv.syncAdjustAllowed
                 && (lv.pillShown || lyricHover.hovered || Theme.touch)
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
        antialiasing: true
        color: Sys.surface
        border.width: 1
        border.color: Theme.line(Sys.bg, Sys.text)
        opacity: 0.95

        RowLayout {
            id: offRow
            anchors.centerIn: parent
            spacing: Theme.s2

            Rectangle {
                width: 22
                height: 22
                radius: 11
                antialiasing: true
                color: offMinus.hovered ? Theme.hover(Theme.sAlt(Sys.bg, Sys.text)) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Text {
                    anchors.centerIn: parent
                    text: "−"
                    color: offMinus.hovered ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tBase
                    font.weight: Font.DemiBold
                }
                HoverHandler { id: offMinus; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    id: minusTap
                    onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); lv.setOffset(lv.offset - 0.1) }
                    // Holding it down repeats the change: a video with a long
                    // intro may need a lot of seconds.
                    onPressedChanged: {
                        minusHold.armed = pressed
                        if (pressed)
                            minusHold.running = true
                    }
                }
                Timer {
                    id: minusHold
                    interval: 90
                    repeat: true
                    running: false
                    property bool armed: false
                    onTriggered: if (armed) lv.setOffset(lv.offset - 0.5)
                }
            }

            Glyph {
                Layout.alignment: Qt.AlignVCenter
                width: 12
                height: 12
                kind: "clock"
                color: Theme.tDim(Sys.bg, Sys.text)
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: (lv.offset > 0 ? "+" : "") + lv.offset.toFixed(1) + " s"
                color: Theme.tDim(Sys.bg, Sys.text)
                font.pixelSize: Theme.tXs
                font.weight: Font.DemiBold
            }

            Rectangle {
                width: 22
                height: 22
                radius: 11
                antialiasing: true
                color: offPlus.hovered ? Theme.hover(Theme.sAlt(Sys.bg, Sys.text)) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.fastMs } }
                Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: offPlus.hovered ? Theme.accentOn(Sys.accent, Sys.bg) : Theme.tDim(Sys.bg, Sys.text)
                    font.pixelSize: Theme.tBase
                    font.weight: Font.DemiBold
                }
                HoverHandler { id: offPlus; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    id: plusTap
                    onTapped: { if (typeof sfx !== "undefined") sfx.play("tap"); lv.setOffset(lv.offset + 0.1) }
                    // Holding it down repeats the change.
                    onPressedChanged: {
                        plusHold.armed = pressed
                        if (pressed)
                            plusHold.running = true
                    }
                }
                Timer {
                    id: plusHold
                    interval: 90
                    repeat: true
                    running: false
                    property bool armed: false
                    onTriggered: if (armed) lv.setOffset(lv.offset + 0.5)
                }
            }
        }
    }
}