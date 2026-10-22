# 🪷 lotus-tune

Reproductor de música para **YouTube Music** y **SoundCloud** construido con **Qt 6 / QML**: busca, reproduce y **canta la letra palabra a palabra** (karaoke real), con las portadas en alta resolución y un fondo que sigue la portada de la canción.

Parte del proyecto **[Lotus-Arch](https://github.com/LotsV8pro/Lotus-Arch)** — Arch Linux + Hyprland, tema morado DedSec.

> ⚠️ **En desarrollo.** La app funciona, pero algunas cosas todavía se rompen (la letra de una canción que no es, el karaoke en un vídeo con un intro largo…). Cada cambio se prueba antes de subirlo.

---

## ✨ Qué hace

| | |
|---|---|
| **🔎 Búsqueda** | YouTube Music y SoundCloud, por separado o a la vez (grupados por fuente) |
| **🎤 Karaoke** | La letra se rellena **palabra a palabra** con los tiempos reales de la canción |
| **🖼️ Portadas** | Se piden en alta resolución y se recortan y redondean en el propio motor |
| **🌄 Fondo** | La portada estirada y difuminada detrás de todo, con el color de la canción |
| **📥 Descargas** | Se descarga con `yt-dlp` a la carpeta que elijas y se reproduce en local |
| **🔗 Integraciones** | MPRIS (controles multimedia del sistema) y Discord Rich Presence |
| **📱 Android** | La misma app en APK (ARM64) |

## 🎤 El karaoke palabra a palabra

La letra sale de varias fuentes y se elige la mejor:

| Fuente | Qué trae |
|---|---|
| **Musixmatch** | Los tiempos de **cada palabra** (el *richsync*): es la fuente del karaoke |
| **YouTube Music** | La letra **del vídeo que suena**, con tiempos por línea (la referencia) |
| **LRCLIB** | Letra sincronizada por líneas |
| **NetEase** | Su *klyric*, con tiempos por palabra |
| **Caché local** | La letra ya descargada (si trae tiempos por palabra, se usa) |

Los tiempos de palabra vienen del **álbumo** y la letra del **vídeo**: por eso se alinean entre sí (el desfase es la mediana de las líneas que coinciden) y por eso la letra que se muestra es siempre la del vídeo, nunca la de otra versión.

## 📥 Descargas

Cada versión publicada en
[Releases](https://github.com/LotsV8pro/lotus-tune/releases) trae los tres formatos:

| Sistema | Fichero | Notas |
|---|---|---|
| Linux | `lotus-tune_<versión>_amd64.deb` | Debian/Ubuntu y derivadas |
| Linux | `lotus-tune-<versión>.x86_64.rpm` | Fedora/openSUSE |
| Linux | `lotus-tune-<versión>-x86_64.AppImage` | No necesita instalar nada |
| Linux | `lotus-tune-<versión>-linux-x86_64.tar.gz` | Binario + ficheros |
| Windows | `lotus-tune-windows.zip` | El `.exe` con las bibliotecas de Qt al lado |
| Android | `lotus-tune-android.apk` | ARM64 (build de depuración: Android la marca como «de prueba») |

En Linux hacen falta `mpv`, `yt-dlp` y `python3`. En Windows, `mpv.exe` y `yt-dlp.exe` en el `PATH`.

## 📦 Requisitos

- `mpv` ≥ 0.40 (probado con 0.41.0)
- `yt-dlp` (probado con 2026.08.19)
- `python3`
- Qt 6.5+ (módulos `Qt6Quick`, `Qt6Network`, `Qt6Sql`, `Qt6Multimedia`, `Qt6DBus`)
- `cmake` ≥ 3.19 y `ninja` (para compilar)

## 🛠️ Compilar

```sh
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/lotus-tune
```

Para empaquetar (`.deb`, `.rpm`, `.AppImage`, `.tar.gz`):

```sh
./tools/package-linux.sh
```

## 📱 Android

```sh
tools/setup-android-toolchain.sh     # Qt host y target, SDK, NDK y JDK 17
source ~/lotus-android-toolchain/env.sh
tools/build-android.sh
```

El APK sale en `build-android/android-build/build/outputs/apk/debug/`.

En Android el motor de audio es **QtMultimedia** (no hay `mpv`) y el stream se pide a la API interna de YouTube Music. **Para que suene hace falta la sesión de la cuenta**: en *Ajustes → Sesión de YouTube Music* se exporta a un fichero y se lleva al móvil (*Importar la sesión*).

## 🐛 Estado

- [x] Búsqueda y reproducción (YouTube Music + SoundCloud)
- [x] Karaoke palabra a palabra con alineación con el vídeo
- [x] Portadas en alta resolución, fondo dinámico
- [x] Descargas y biblioteca local
- [x] MPRIS y Discord Rich Presence
- [x] APK de Android
- [ ] Iniciar sesión en Android (de momento se importa la sesión del PC)
- [ ] Búsqueda en Android (el catálogo usa `yt-dlp`, que aún no va embebido)
- [ ] Menú contextual con pulsación larga en táctil

## 📜 Licencia

MIT · GPL-3.0 (las partes que enlazan con `mpv` y `yt-dlp`).
