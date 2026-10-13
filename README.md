# Lotus Tune 🪷

Reproductor de música ligero para Linux construido con Qt 6 y QML. Busca y
reproduce música de **YouTube Music** y **SoundCloud** sin anuncios y sin abrir
un navegador: las consultas las resuelve `yt-dlp` y la reproducción la hace un
`mpv` embebido, todo dentro de una sola ventana.

## Arquitectura

- **UI en QML** (`qml/`): ventanas, barra de búsqueda, biblioteca, barra de
  reproducción y tema en vivo.
- **C++ / Qt 6** (`src/`):
  - `catalog.cpp` — invoca `yt-dlp -J --flat-playlist …` (búsquedas
    `ytsearch15:`/`scsearch15:` o playlists por URL), normaliza las entradas
    `{title, artist, duration, url, source}` y gestiona la biblioteca.
  - `player.cpp` — spawn de `mpv` en modo headless con **JSON IPC**
    (`--input-ipc-server`): observa `pause`, `duration`, `media-title`,
    `time-pos` y `volume`; avanza la cola cuando mpv emite `end-file reason=eof`
    (fin natural) o `reason=error` (fallo de extracción). Un `loadfile … replace`
    (salto manual) llega como `reason=stop` y **no** avanza la cola.
  - `sources.cpp` — fuentes disponibles (activas y pendientes).
  - `theme.cpp` — paleta del sistema (quickshell/iNiR) + overrides por archivo.
- **Sin backend propio**: todo se resuelve localmente con `yt-dlp` + `mpv`.

## Fuentes soportadas

| Fuente | Estado |
|---|---|
| YouTube Music | ✅ activa (búsqueda, playlists, login Google en la app + sync «Me gusta») |
| SoundCloud | ✅ activa (búsqueda y sets públicos) |
| Spotify (Premium) | 🔒 registrada, pendiente (requiere Client ID + backend librespot) |
| Tidal | 🔒 registrada, pendiente (requiere API/credenciales) |

## Requisitos

- `mpv` ≥ 0.40 (probado con 0.41.0)
- `yt-dlp` (probado con 2026.08.19)
- Qt 6.8+ (módulos `Qt6Quick`, `Qt6Network`)
- `cmake` ≥ 3.19 y `ninja` (para compilar)

## Build

```sh
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/lotus-tune
```

## Configuración

Hay **dos** archivos de configuración en `~/.config/lotus-tune/`:

### 1. `config.ini` — tema (leído directamente por `theme.cpp`)

Claves reconocidas (todas opcionales; si `followSystem=true` se toma la paleta
del sistema y solo mandan los overrides):

| Clave | Valor por defecto | Descripción |
|---|---|---|
| `followSystem` | `true` | Seguir la paleta del sistema (quickshell/matugen) |
| `bg` | `#0a0a0d` | Fondo de ventana |
| `surface` | `#101014` | Tarjetas / superficie |
| `surfaceAlt` | `#17171c` | Superficie elevada |
| `border` | `#26262e` | Borde principal |
| `borderSubtle` | `#1e1e25` | Borde sutil |
| `accent` | `#1ed760` | Color de acento |
| `onAccent` | `#0a0a0d` | Texto sobre el acento |
| `text` | `#f4f4f6` | Texto principal |
| `textDim` | `#8e8e99` | Texto secundario |
| `danger` | `#e81123` | Errores / acciones destructivas |

La paleta del sistema se lee desde
`~/.local/state/quickshell/user/generated/app-palette.json` (o `colors.json`).

### 2. `lotus-tune.conf` — ajustes de `QSettings` (leído por `Catalog`)

| Clave | Ejemplo | Descripción |
|---|---|---|
| `ytmOauth` | `true` | Marca la sesión de YouTube Music iniciada desde la app (flujo de dispositivo de Google). |
| `cookiesFromBrowser` | `firefox:/ruta/al/perfil (release)` | **Fallback opcional heredado.** Ya no lo escribe el login; solo se usa si lo defines a mano. |

#### Inicio de sesión de YouTube Music (en la app)

El login es **en la app** mediante el *device flow* de Google (no usa cookies de
navegador). El botón de Ajustes llama a `Catalog.loginYTM()`, que ejecuta
`python3 tools/ytm_oauth.py login`; la UI muestra el código y la URL y el proceso
sigue en segundo plano hasta que autorizas en <https://www.google.com/device>.

El token se guarda (0600) en `~/.config/lotus-tune/ytm_token.json`. El sync de
«Me gusta» usa `python3 tools/ytm_oauth.py liked --limit 500` (lista **Liked
Music**, solo canciones). `tools/ytm_oauth.py` incluye las credenciales públicas
del cliente TV de yt-dlp, que pueden rotarse cambiando las constantes del script.

## Estado

- Biblioteca (playlists guardadas y recientes):
  `~/.local/state/lotus-tune/library.json`
- Geometría de ventana y otros ajustes QML: `~/.config/lotus-tune/lotus-tune.conf`

## Notas de RAM

- `mpv` en reposo (`--idle=yes`, sin ventana): ~40–80 MB RSS.
- Durante la reproducción: el búfer del demuxer está limitado a
  `--demuxer-max-bytes=10MiB` y `--demuxer-max-back-bytes=5MiB`, así que el
  consumo se mantiene bajo ~150 MB incluso con streams de alta tasa.
- `yt-dlp` (Python) consume ~30–60 MB **solo durante** búsquedas/consultas y
  termina después; no queda ningún proceso residente.
- La cola en memoria admite hasta 500 pistas por consulta (pocos MB).

## Atajos de instalación de escritorio

```sh
cp lotustune.desktop ~/.local/share/applications/
mkdir -p ~/.local/share/icons/hicolor/scalable/apps
cp lotustune.svg ~/.local/share/icons/hicolor/scalable/apps/
```

El archivo de escritorio se llama `lotustune.desktop` porque la aplicación
declara `desktopFileName = "lotustune"` (ese es el `app_id` que busca el
compositor).
