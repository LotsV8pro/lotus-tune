.pragma library

// ------------------------------------------------------------------
// Lotus Tune — shared visual tokens and colour helpers.
//
// The palette itself comes from the desktop (context property `Sys`, an
// AppTheme). Here we only keep the *derived* values (hover/active surfaces,
// soft tints) and the small layout rhythm used across the interface.
//
// IMPORTANT about the palette: the C++ side fails to resolve the camelCase
// keys of its default table (`surfaceAlt`, `borderSubtle`, `onAccent`,
// `textDim`), so those four `Sys.*` values arrive INVALID and QML paints
// them black — that is what made the secondary text unreadable and the
// pills look like black holes. The interface therefore never uses them:
// they are derived here from the three tokens that do resolve
// (`Sys.bg`, `Sys.surface`, `Sys.text`, `Sys.accent`):
//
//   tDim(bg, text)   secondary text (≈ #8e8e99 over the dark bg)
//   tFaint(bg, text) tertiary text / very quiet labels
//   sAlt(bg, text)   raised surface (cards, pills, artwork placeholders)
//   sHigh(bg, text)  one more step up (menus, hovered rows)
//   line(bg, text)   hairlines / soft borders
//   onAccent(accent) readable ink ON an accent-filled surface
//   accentOn(accent, bg)  the accent itself, lifted until it reads on bg
//
// Everything is derived with `mix`, so the whole interface follows a
// light palette too (light bg + dark text) instead of assuming "dark".
// ------------------------------------------------------------------

// Is it a touch screen? There is no hover and no right button there, so
// the controls that only show up with the mouse have to be always on and
// the context menus are opened with a long press.
var touch = (typeof Qt !== "undefined")
    && (Qt.platform.os === "android" || Qt.platform.os === "ios")

// Animation durations (ms). Short and cheap on purpose: the app is meant to
// stay light in RAM, so no per-row shaders or MultiEffects. Hard cap: 280 ms.
var fastMs = 120
var medMs = 180
var slowMs = 280

// Corner radii (px). Todo redondeado, sin esquinas vivas: la escala entera
// went up a step so that artworks, rows, panels and islands share the same
// soft feeling (before each one used its own radius and it looked loose).
var rSm = 8
var rMd = 14
var rLg = 18
var rXl = 22

// Pills: capsule control (radius = height/2). Chips, toggles, tabs and
// action/navigation buttons. Always use it with a fixed `height`.
var rPill = 999          // "pill" radius
var pillH = touch ? 34 : 30    // standard pill height
var pillHPad = touch ? 16 : 14 // pill horizontal padding

// ---- floating surfaces -------------------------------------------
// The interface is made of rounded "islands" that float over the window
// background. These tokens govern their radius, the separation with the
// edges, the air between islands and the soft shadow that lifts them off
// the background.
var rPanel = 20          // island radius (sidebar, bar, content...)
var panelMargin = touch ? 6 : 14   // air with the window edge (room for shadow)
var panelGap = touch ? 6 : 10      // air between islands
var panelBorderAlpha = 0.11   // bright edge that separates the island from the background

// Type scale (px = dp on Android). One ramp for the whole app: quiet by
// default, one clear step for the page title and the now-playing title.
// On the phone every step is bigger: at 10-12 dp the secondary text was
// unreadable on a 6" screen (Android asks for 12 sp minimum for body text).
var tXs = touch ? 11 : 10
var tSm = touch ? 12 : 11
var tMd = touch ? 13 : 12
var tBase = touch ? 14 : 13
var tLg = touch ? 16 : 15
var tXl = touch ? 20 : 18
var t2xl = touch ? 24 : 22
var t3xl = touch ? 28 : 28

// Spacing scale (px). Prefer space over lines: hierarchy comes from air.
var s1 = 4
var s2 = 8
var s3 = 12
var s4 = 16
var s5 = 24
var s6 = 32

// ---- Layout rhythm (px). Slim, air-first chrome. ------------------
// On the phone everything compresses: the margins of the floating
// islands and the rows shrink so the 1320-px-wide desktop layout
// holds together in a 4xx-px-wide screen without cutting content.
var rowH = touch ? 54 : 52
var rowCompact = touch ? 48 : 46
var rowThin = touch ? 36 : 32
// Text block of a rail card (HomeCard): two title lines + one subtitle
// line + the padding. The rail MUST use this same value as its extra
// height under the artwork, or the last line gets cut in half (it did:
// rowHeight reserved 42 px for a 54 px block).
var cardLineH = function(px) { return Math.ceil(px * 1.35) }
var cardTextH = cardLineH(tBase) * 2 + cardLineH(tSm) + s1 + 2
var topBarH = touch ? 52 : 52
// The player island: the progress line with its times + one content row
// (cover 40, transport 44). It needs 70 dp on the phone so nothing is
// glued to the edges; the swipe-up gesture leaves no visual trace.
// Phone bar: two rows (cover/title/heart + transport). The height has to
// fit 20 (progress) + 44 (cover/title row) + 44 (play button) + 4 (bottom
// margin) = 112; with 104 the play button was left half cut by the island.
var playerBarH = touch ? 112 : 64
var sidePanelMin = touch ? 252 : 300

// Bottom padding for the system gesture zone. Android's
// navigationBars inset comes back 0 with the hidden handle some ROMs
// use (MIUI/HyperOS), so a floor is applied on touch: the tab bar was
// drawn inside the swipe-up zone.
function safeBottom(sysBottom) {
    return Math.max(sysBottom || 0, touch ? 16 : 0)
}

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v))
}

// Parse a QML colour value ("#rrggbb", "#aarrggbb" or "#rgb") to [r,g,b,a],
// each 0..1. Returns null when the input is not a hex colour.
function _rgba(c) {
    var s = String(c || "")
    if (s.charAt(0) !== "#")
        return null
    var hex = s.substring(1)
    if (hex.length === 3)
        hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]
    if (hex.length === 6) {
        return [parseInt(hex.substr(0, 2), 16) / 255,
                parseInt(hex.substr(2, 2), 16) / 255,
                parseInt(hex.substr(4, 2), 16) / 255, 1]
    }
    if (hex.length === 8) {
        // Qt stores colours as #AARRGGBB.
        return [parseInt(hex.substr(2, 2), 16) / 255,
                parseInt(hex.substr(4, 2), 16) / 255,
                parseInt(hex.substr(6, 2), 16) / 255,
                parseInt(hex.substr(0, 2), 16) / 255]
    }
    return null
}

// Linear blend of two colours. t=0 -> a, t=1 -> b.
function mix(a, b, t) {
    var A = _rgba(a)
    var B = _rgba(b)
    if (!A || !B)
        return a
    return Qt.rgba(A[0] + (B[0] - A[0]) * t,
                   A[1] + (B[1] - A[1]) * t,
                   A[2] + (B[2] - A[2]) * t,
                   A[3] + (B[3] - A[3]) * t)
}

// Derive the hover / active surfaces from a base surface (+6% / +12%).
function hover(c) { return Qt.lighter(c, 1.10) }
function active(c) { return Qt.lighter(c, 1.20) }

// ---- readable derived tokens (see the header note) ----------------------
// Secondary text. 0.56 of the way from the background to the text colour
// is the "quiet but readable" point (≈ 6:1 contrast on the dark palette).
function tDim(bg, text) { return mix(bg, text, 0.56) }
// Subtitle of a CARD (the line under the title of a cover). It sits over a
// surface tinted with the artwork colour, where 0.56 disappeared: it goes
// one step further (≈ 8:1 on the dark palette) so it reads on any tint.
function tSub(bg, text) { return mix(bg, text, 0.72) }
// Tertiary: timestamps, counters, hints that must NOT compete.
function tFaint(bg, text) { return mix(bg, text, 0.40) }
// Raised surface: cards, pills, artwork placeholders.
function sAlt(bg, text) { return mix(bg, text, 0.075) }
// One step higher: menus, hovered rows, pressed pills.
function sHigh(bg, text) { return mix(bg, text, 0.13) }

// ---- palette tinted surfaces -------------------------------------------
// The desktop palette defines its raised surface as the ACCENT mixed over
// the background (its surface_container is exactly bg + accent at ~0.155,
// a warm tone). Mixing bg + TEXT instead gives a neutral grey, which is
// why the playback bar and the cinema view stopped following the theme
// and looked plain grey. These two tokens reproduce the palette.
function sAccent(bg, accent, amount) {
    return mix(bg, accent, amount === undefined ? 0.155 : amount)
}
// Hover of a palette tinted surface: one small step brighter.
function sAccentHi(bg, accent, amount) {
    return mix(bg, accent, (amount === undefined ? 0.155 : amount) + 0.07)
}
// Hairline: separators and soft borders.
function line(bg, text) { return mix(bg, text, 0.16) }

// ---- WCAG helpers -------------------------------------------------------
function _lin(v) {
    v /= 255
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function luminance(c) {
    var C = _rgba(c)
    if (!C)
        return 0
    return 0.2126 * _lin(C[0] * 255)
         + 0.7152 * _lin(C[1] * 255)
         + 0.0722 * _lin(C[2] * 255)
}

// WCAG contrast ratio between two colours (1..21).
function contrast(a, b) {
    var la = luminance(a)
    var lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

// Text —or icon— ON a filled surface (play button, active pill, chips,
// badges): near-white when the fill is dark, near-black when it is light.
// Never returns the same tone as the fill, so it can never "eat" the glyph.
function onAccent(bg) {
    var la = luminance(bg)
    var light = "#ffffff"
    var dark = "#0b0b0f"
    return contrast(bg, light) >= contrast(bg, dark) ? light : dark
}

// The accent used as TEXT or as a thin line over `bg`: the raw accent is
// whatever the wallpaper gave (often a deep, muted red) and it simply does
// not read on a dark surface, so it is lifted (or deepened on a light bg)
// in small steps until it clears 4.5:1. Same hue, readable weight.
function accentOn(accent, bg) {
    var A = _rgba(accent)
    if (!A)
        return accent
    var base = luminance(bg) > 0.5 ? 0.72 : 1.45
    var c = accent
    for (var i = 0; i < 6; i++) {
        if (contrast(c, bg) >= 4.5)
            break
        var f = base > 1 ? Math.min(3.0, Math.pow(base, i + 1))
                         : Math.max(0.15, Math.pow(base, i + 1))
        c = Qt.rgba(A[0] * f > 1 ? 1 : A[0] * f,
                    A[1] * f > 1 ? 1 : A[1] * f,
                    A[2] * f > 1 ? 1 : A[2] * f, A[3])
        // Mixing with white/black is what actually keeps the hue: a plain
        // multiply saturates the dominant channel and the colour turns
        // "hot". Lift halfway towards white instead on dark backgrounds.
        if (base > 1)
            c = mix(accent, "#ffffff", Math.min(0.72, 0.16 * (i + 1)))
        else
            c = mix(accent, "#000000", Math.min(0.72, 0.20 * (i + 1)))
    }
    return c
}

// Soft tint of `c` laid over `base` (used to wash the player bar with the
// current accent without any image sampling).
function tint(base, c, amount) { return mix(base, c, amount) }

function alpha(c, a) {
    var C = _rgba(c)
    if (!C)
        return c
    return Qt.rgba(C[0], C[1], C[2], a)
}

// Kept for callers that only have the accent: lifts it on the assumption
// of a dark background.
function accentText(c) { return accentOn(c, "#0a0a0d") }

// Text —or icon— ON an accent surface with an explicit base tone. Kept
// from the original API: it now resolves through the same contrast rule.
function onAccentOf(bg, base) {
    if (!_rgba(bg))
        return "#f4f4f6"
    var want = onAccent(bg)
    var F = _rgba(base)
    if (!F)
        return want
    return contrast(base, bg) >= 4.5 ? base : want
}

// Seconds -> "m:ss" (or "h:mm:ss").
function mmss(s) {
    s = Math.max(0, Math.floor(s || 0))
    var m = Math.floor(s / 60)
    var r = s % 60
    var rs = (r < 10 ? "0" : "") + r
    if (m >= 60)
        return Math.floor(m / 60) + ":" + ((m % 60) < 10 ? "0" : "") + (m % 60) + ":" + rs
    return m + ":" + rs
}
