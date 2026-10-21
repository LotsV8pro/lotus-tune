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
// subió un peldaño para que portadas, filas, paneles e islas compartan la
// misma sensación blanda (antes cada cual usaba su radio y se veía suelto).
var rSm = 8
var rMd = 14
var rLg = 18
var rXl = 22

// Pills: control cápsula (radio = alto/2). Chips, toggles, pestañas y
// botones de acción/navegación. Úsese siempre con un `height` fijo.
var rPill = 999          // radio "píldora"
var pillH = 30           // alto estándar de una píldora
var pillHPad = 14        // relleno horizontal de una píldora

// ---- superficies flotantes ------------------------------------------
// La interfaz se compone de "islas" redondeadas que flotan sobre el fondo de
// la ventana. Estos tokens gobiernan su radio, la separación con los bordes y
// entre islas, y la sombra suave que las despega del fondo.
var rPanel = 20          // radio de las islas (sidebar, barra, contenido…)
var panelMargin = 14     // aire con el borde de la ventana (deja sitio a la sombra)
var panelGap = 10        // aire entre islas
var panelBorderAlpha = 0.11   // filo luminoso que separa la isla del fondo

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
// aire ya no cabían en 56 px y los botones quedaban pegados al borde. Subida
// a 68 para que respiren por arriba y por abajo.
var playerBarH = 58
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