.pragma library

// ------------------------------------------------------------------
// Lotus Tune — shared visual tokens and colour helpers.
//
// The palette itself comes from the desktop (context property `Sys`, an
// AppTheme). Here we only keep the *derived* values (hover/active surfaces,
// soft tints) and the small layout rhythm used across the interface.
// ------------------------------------------------------------------

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
var pillH = 30           // standard pill height
var pillHPad = 14        // pill horizontal padding

// ---- floating surfaces -------------------------------------------
// The interface is made of rounded "islands" that float over the window
// background. These tokens govern their radius, the separation with the
// edges, the air between islands and the soft shadow that lifts them off
// the background.
var rPanel = 20          // island radius (sidebar, bar, content...)
var panelMargin = 14     // air with the window edge (leaves room for the shadow)
var panelGap = 10        // air between islands
var panelBorderAlpha = 0.11   // bright edge that separates the island from the background

// Type scale (px). One ramp for the whole app: quiet by default, one clear
// step for the page title and the now-playing title.
var tXs = 10
var tSm = 11
var tMd = 12
var tBase = 13
var tLg = 15
var tXl = 18
var t2xl = 22
var t3xl = 28

// Spacing scale (px). Prefer space over lines: hierarchy comes from air.
var s1 = 4
var s2 = 8
var s3 = 12
var s4 = 16
var s5 = 24
var s6 = 32

// Layout rhythm (px). Slim, air-first chrome.
var rowH = 52
var rowCompact = 46
var rowThin = 32
var topBarH = 52
// La isla de la barra: el transporte (botones 32) + el progreso fino con su
// the air no longer fitted in 56 px and the buttons were glued to the edge.
// It went up
// a 68 para que respiren por arriba y por abajo.
var playerBarH = 60
var sidePanelMin = 300

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

// Soft tint of `c` laid over `base` (used to wash the player bar with the
// current accent without any image sampling).
function tint(base, c, amount) { return mix(base, c, amount) }

function alpha(c, a) {
    var C = _rgba(c)
    if (!C)
        return c
    return Qt.rgba(C[0], C[1], C[2], a)
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