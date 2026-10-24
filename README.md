<p align="center">
  <img src="https://img.shields.io/badge/Qt_6_%2F_QML-141218?style=for-the-badge&logo=qt&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/YouTube_Music-141218?style=for-the-badge&logo=youtubemusic&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/Wayland_%C2%B7_Niri_ready-141218?style=for-the-badge&logo=linux&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/MPRIS_%2B_Discord_RP-141218?style=for-the-badge&logo=discord&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/github/actions/workflow/status/LotsV8pro/lotus-tune/build.yml?style=for-the-badge&logo=githubactions&logoColor=C4A8E2&label=CI"/>
  <img src="https://img.shields.io/badge/MIT_%2B_GPL--3.0-141218?style=for-the-badge&logo=open-source-initiative&logoColor=C4A8E2"/>
</p>

<h1 align="center">◈ LOTUS TUNE ◈</h1>

<p align="center">
  <b>Reproductor de música para YouTube Music — karaoke palabra a palabra</b><br>
  <sub>Qt 6/QML · letras sincronizadas reales · parte del ecosistema Lotus · Linux, Windows y Android</sub>
</p>

## ✦ Overview

Lotus Tune es un reproductor de música construido con **Qt 6 / QML**: busca en YouTube Music y SoundCloud, reproduce y **canta la letra palabra a palabra** (karaoke real, con los tiempos de cada palabra), con portadas en alta resolución y un fondo dinámico pintado con el color de la canción.

- **Karaoke real** — la letra se rellena palabra a palabra con los tiempos de la canción, alineada con el vídeo que suena.
- **Liviano a propósito** — render software sin OpenGL, sin MangoHud, sin drivers de vídeo de más; RAM contenida sin sacrificar fluidez.
- **Sin bloqueos en la UI** — la letra y las portadas se traen fuera del hilo de la ventana: la interfaz nunca se congela.
- **Ecosistema Lotus** — misma estética púrpura que [Lotus-Arch](https://github.com/LotsV8pro/Lotus-Arch), integra MPRIS (controles del sistema) y Discord Rich Presence.

| | |
|---|---|
| **🔎 Búsqueda** | YouTube Music y SoundCloud, por separado o a la vez (agrupado por fuente) |
| **🎤 Karaoke** | Relleno **palabra a palabra** con los tiempos reales de la canción |
| **🖼️ Portadas** | Alta resolución, recortadas y redondeadas en el propio motor |
| **🌄 Fondo** | Portada estirada y difuminada detrás de todo, siguiendo el color de la canción |
| **📥 Descargas** | Con `yt-dlp` a la carpeta que elijas + biblioteca local |
| **🔗 Integraciones** | MPRIS (controles multimedia del sistema) y Discord Rich Presence |
| **📱 Android** | La misma app en APK (ARM64) |

## ✦ El karaoke palabra a palabra

La letra llega de varias fuentes y la app elige **la mejor**:

| Fuente | Qué trae |
|---|---|
| **Musixmatch** | Los tiempos de **cada palabra** (el *richsync*): es la fuente del karaoke |
| **YouTube Music** | La letra **del vídeo que suena**, con tiempos por línea (la referencia) |
| **LRCLIB** | Letra sincronizada por líneas |
| **NetEase** | Su *klyric*, con tiempos por palabra |
| **Caché local** | La letra ya descargada (si trae tiempos por palabra, se usa primero) |

Los tiempos de palabra vienen del **álbum** y la letra del **vídeo**: por eso se alinean entre sí (el desfase se calcula como la mediana de las líneas que coinciden) y por eso la letra mostrada es siempre la del vídeo, nunca la de otra versión.

## ✦ Install

**Linux — un solo comando:**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/LotsV8pro/lotus-tune/master/tools/install.sh)"
```

El instalador detecta tu distro (Arch / Debian / Fedora), pide permiso para instalar las dependencias si faltan (`qt6`, `mpv`, `yt-dlp`…), clona el código, compila y deja la app lista en `~/.local` — con el acceso en el menú de aplicaciones y el icono incluidos. Si algo falla o prefieres controlar cada paso:

```bash
git clone https://github.com/LotsV8pro/lotus-tune.git
cd lotus-tune && ./tools/install.sh
```

Opciones útiles: `./tools/install.sh --prefix ~/.local` (destino), `--system` (a `/usr/local`), `--no-pull`, `--jobs N`. Sintaxis completa con `--help`.

> **Windows / Android** — el CI de cada commit deja el `.exe` y el `.apk` como artefactos en la pestaña [Actions](https://github.com/LotsV8pro/lotus-tune/actions) del repo.

## ✦ Compilar a mano

```
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/lotus-tune
```

Requisitos: `mpv` ≥ 0.40, `yt-dlp`, `python3`, Qt 6.5+ (`Quick`, `Network`, `Sql`, `Multimedia`), `cmake` ≥ 3.19 y `ninja`. Para empaquetar (`.deb`, `.rpm`, `.tar.gz`): `./tools/package-linux.sh`.

## ✦ Descargas

| Sistema | Fichero |
|---|---|
| Linux | `.deb` (Debian/Ubuntu) · `.rpm` (Fedora/openSUSE) · `.AppImage` · `.tar.gz` |
| Windows | `.zip` con el `.exe` y las bibliotecas de Qt al lado |
| Android | APK ARM64 (build de depuración) |

El CI genera `.deb`, `.rpm` y el `.tar.gz` en cada push a `master` y en cada etiqueta `v*` — están como artefactos en [Actions](https://github.com/LotsV8pro/lotus-tune/actions). El `.AppImage` lo produce `./tools/package-linux.sh` localmente. Windows incluye `mpv.exe` y `yt-dlp.exe` en el `PATH`; en Android se configura con `tools/build-android.sh`.

## ✦ Estado

- ✅ Búsqueda y reproducción (YouTube Music + SoundCloud)
- ✅ Karaoke palabra a palabra con alineación con el vídeo
- ✅ Portadas en alta resolución y fondo dinámico
- ✅ Descargas y biblioteca local
- ✅ MPRIS y Discord Rich Presence
- ✅ APK de Android
- 🔜 Inicio de sesión en Android (de momento se importa la sesión del PC)
- 🔜 Búsqueda en Android (el catálogo usa `yt-dlp`, que aún no va embebido)
- 🔜 Menú contextual con pulsación larga en táctil

## ✦ Ecosystem

Lotus Tune forma parte de un ecosistema de escritorio unificado, con la misma estética púrpura:

| App | Theme | Repo |
|---|---|---|
| **Lotus Arch** | Escritorio completo (Niri + iNiR / Hyprland) | [Lotus-Arch](https://github.com/LotsV8pro/Lotus-Arch) |
| **Discord** (Vencord) | Lotus Purple | [lotus-discord](https://github.com/LotsV8pro/lotus-discord) |
| **Spotify** (Spicetify) | Lotus Purple | [lotus-spotify](https://github.com/LotsV8pro/lotus-spotify) |
| **EasyEffects mic chain** | deepfilternet→rnnoise→EQ→limit | [lotus-mic-chain](https://github.com/LotsV8pro/lotus-mic-chain) |

---

## ✦ Credits

Lotus Tune se apoya en proyectos open-source:

| Proyecto | Uso |
|---|---|
| [**mpv**](https://mpv.io) | Motor de reproducción (headless, JSON IPC) |
| [**yt-dlp**](https://github.com/yt-dlp/yt-dlp) | Metadatos y descargas |
| [**Musixmatch**](https://www.musixmatch.com) | Tiempos palabra a palabra (*richsync*) |
| [**LRCLIB**](https://lrclib.net) | Letra sincronizada por líneas |
| [**NetEase**](https://music.163.com) | *Klyric* con tiempos por palabra |
| [**Qt**](https://www.qt.io) | Qt 6 / QML — toda la interfaz |

Partes que enlazan con `mpv` y `yt-dlp` están licenciadas bajo GPL-3.0; el resto del proyecto es MIT.

<p align="center">
  <a href="https://github.com/LotsV8pro/Lotus-Arch"><img src="https://img.shields.io/badge/Lotus_Arch-141218?style=flat-square&logo=arch-linux&logoColor=C4A8E2"/></a>
  <a href="https://github.com/LotsV8pro/lotus-discord"><img src="https://img.shields.io/badge/Lotus_Discord-141218?style=flat-square&logo=discord&logoColor=C4A8E2"/></a>
  <a href="https://github.com/LotsV8pro/lotus-spotify"><img src="https://img.shields.io/badge/Lotus_Spotify-141218?style=flat-square&logo=spotify&logoColor=C4A8E2"/></a>
</p>

<p align="center">
  <sub>MIT · GPL-3.0 — <a href="https://github.com/LotsV8pro">@LotsV8pro</a> 🪷</sub>
</p>
