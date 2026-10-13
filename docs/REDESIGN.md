# Lotus Tune — Rediseño minimalista (spec)

> Estado base: `git 23f238e`. Medición PSS: app 126 MB + mpv 92 MB ≈ **218 MB** (límite 200).

## 1. Concepto

Zen: cero ruido, 3 destinos, un solo flujo. Todo secundario vive en overlays ligeros
(no en la pantalla principal). Fluidez > decoración.

## 2. Presupuesto de memoria (target ≤ 200 MB PSS)

| Ítem | Ahora | Acción |
|---|---|---|
| Portada NowPlaying | sin `sourceSize` (full-res) | `sourceSize` ~600px |
| `prefetch()` | encola también `file://` → yt-dlp | saltar esquemas locales |
| Listas | 24 `Repeater` eager | `ListView`/`GridView` con `reuseItems`+`cacheBuffer` |
| Intro de arranque | overlay 1,08 s | eliminar |
| LyricsView | timer 33 ms (30 fps) rebuild HTML | throttle a 100 ms (10 fps) o diff |
| `LotusMark` | pulso infinito ×2 simultáneos | animar solo si visible |

Presupuesto objetivo: app ≤ 110 MB, mpv ≤ 90 MB.

## 3. Navegación (3 secciones máximo)

```
Inicio · Buscar · Biblioteca
```
- Sin submenús anidados. Tabs de Biblioteca en texto: Canciones · Artistas · Álbumes · Playlists · Descargadas.
- Barra inferior flotante ultradelgada (48–56 px): carátula · título · play/prev/next · progreso fino · cola.
- Overlays: cola, letras, ajustes, editor — todos efímeros (`Loader` con `active`).
- Toasts discretos (texto flotante, autodismiss) para estado/errores.

## 4. Sistema visual

Tokens (desde `Sys`, tema vivo del sistema):
`bg` `surface` `surfaceAlt` `border` `borderSubtle` `accent` `onAccent` `text` `textDim` `danger`.

- Tipografía: sans geométrica, jerarquía por peso (Light 300 / Medium 500 / Bold 700).
- Iconos: `Glyph` (canvas), trazo uniforme 1.5px, color heredado de `text`.
- Radios suaves (10–14 px), sombras casi nulas, 1 borde por superficie.
- Movimiento: máx. 3 duraciones (130 / 220 / 420 ms). Prohibido: bucles infinitos visibles y animaciones > 420 ms en superficies grandes.

## 5. Pantallas

**A. Inicio** — saludo 1 línea + acceso a descargas; 2–3 filas: «Recientes», «En local», «Recomendado». Filas virtualizadas-horizontales (Flickable+Repeater con delegate ligero) o ListView horizontal.

**B. Now Playing** — portada centrada (radio 14, `sourceSize`), título/artista, transporte esencial, línea de progreso fina con tiempos, etiqueta discreta `LOCAL`/`STREAM`. Letras como capa conmutable.

**C. Biblioteca / Búsqueda** — tabs de texto; listado vertical virtualizado con título, artista, duración y badge offline.

## 6. Arquitectura funcional (refactor)

Problema: `Main.qml` 3262 líneas (39 % es `settingsOverlay`); `LibraryPage` 1256; transport duplicado en `PlayerBar`/`NowPlaying`.

Objetivo:
```
qml/
  Main.qml            # shell: shell layout, navegación, overlays raíz
  pages/Home.qml pages/Search.qml pages/Library.qml
  overlays/Settings.qml  overlays/Queue.qml  overlays/Lyrics.qml  overlays/NowPlaying.qml
  components/  (Glyph, CoverTile, TrackRow, CardRow, Toasts, Transport)
  theme.js
src/  (sin cambios de API; solo backend)
```
APIs C++ (`catalog`, `player`, `downloads`, `appcfg`, `Sys`) se mantienen.

## 7. Almacenamiento local

- Carpeta dedicada: `~/.local/share/lotus-tune/descargas` (ya existe).
- **Añadir:** escaneo al arrancar + `QFileSystemWatcher` sobre la carpeta → resync automático.
- Reproducción offline ya va por mpv con `file://`.

## 8. Fases de ejecución (subagentes)

| Fase | Alcance | Archivos |
|---|---|---|
| 0 | Seguridad + baseline | git, medición |
| 1 | RAM/perf puro | `player.cpp`, `NowPlaying.qml`, `LyricsView.qml`, `Main.qml` (intro) |
| 2 | Virtualización de listas | `LibraryPage`, `SearchPage`, `HomePage`, `Sidebar` |
| 3 | Refactor shell + tokens | `Main.qml` (extraer Settings), `theme.js` |
| 4 | Pantallas minimalistas | `PlayerBar`, `NowPlaying`, `Home`,`Search`,`Library` |
| 5 | Storage auto-sync | `downloads.cpp` |
| 6 | Limpieza (muerto/duplicado) | varios |
