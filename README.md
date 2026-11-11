<p align="center">
  <img src="https://img.shields.io/badge/Qt_6_%2F_QML-141218?style=for-the-badge&logo=qt&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/YouTube_Music-141218?style=for-the-badge&logo=youtubemusic&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/Linux_%C2%B7_Windows_%C2%B7_Android-141218?style=for-the-badge&logo=linux&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/MPRIS_%2B_Discord_RP-141218?style=for-the-badge&logo=discord&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/github/actions/workflow/status/LotsV8pro/lotus-tune/build.yml?style=for-the-badge&logo=githubactions&logoColor=C4A8E2&label=CI"/>
  <img src="https://img.shields.io/badge/MIT_%2B_GPL--3.0-141218?style=for-the-badge&logo=open-source-initiative&logoColor=C4A8E2"/>
</p>

<h1 align="center">Lotus Tune</h1>

Reproductor de música para YouTube Music y SoundCloud, escrito en Qt 6/QML. Reproduce con mpv y muestra la letra sincronizada palabra a palabra. Funciona en Linux, Windows y Android.

## Qué hace

- Busca en YouTube Music y SoundCloud, juntos o por separado.
- Canta la letra palabra a palabra con los tiempos reales de la canción.
- Dibuja la portada en alta resolución y un fondo que sigue su color.
- Descarga con `yt-dlp` a la carpeta que elijas y guarda una biblioteca local.
- Publica MPRIS para los controles del sistema y Discord Rich Presence.
- En Android usa la misma interfaz, en un APK ARM64.

## La letra

La letra puede venir de Musixmatch (richsync, con tiempos por palabra), de la pista de YouTube Music, de LRCLIB, de NetEase o de la caché local de Sonora. La app elige la fuente que encaja con la versión que suena, no la primera que encuentra: compara las líneas con la línea de tiempo del vídeo y descarta las de otra toma, otro álbum u otro directo.

Los tiempos de palabra vienen del álbum y la letra del vídeo. Por eso se alinean entre sí y por eso la letra que se ve es la del vídeo. Las palabras y las líneas que faltan se completan desde las otras fuentes ya alineadas.

Los tramos sin voz no llevan texto: la app dibuja tres puntos que se encienden uno a uno. La letra se puede arrastrar y vuelve sola a la línea que suena a los cuatro segundos.

### La letra compartida con iNiR

Si Lotus Tune es quien reproduce, escribe la letra y la posición en:

```
~/.local/state/lotus-tune/lyrics.json
~/.local/state/lotus-tune/lyrics-runtime.json
```

El servicio de letras de iNiR (`LyricsService.qml`) lee esos ficheros antes de buscar por su cuenta. Los widgets y la pantalla de bloqueo usan así los mismos tiempos y las mismas palabras que la app, sin una segunda descarga. El formato está en [docs/LYRICS.md](docs/LYRICS.md).

## Instalación

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/LotsV8pro/lotus-tune/master/tools/install.sh -o install.sh
bash install.sh
```

El instalador detecta la distro (Arch, Debian, Fedora), avisa de las dependencias que faltan (`qt6`, `mpv`, `yt-dlp`), compila y deja la app en `~/.local`, con el acceso en el menú y el icono.

También puedes clonar y ejecutar el mismo script:

```bash
git clone https://github.com/LotsV8pro/lotus-tune.git
cd lotus-tune
./tools/install.sh
```

Opciones: `--prefix ~/.local`, `--system` (instala en `/usr/local`), `--no-pull`, `--jobs N`. `--help` muestra el resto.

En las releases hay un `.deb` para Debian/Ubuntu, un `.rpm` para Fedora/openSUSE y un `.tar.gz` que funciona en cualquier distro.

### Windows

La release trae `lotus-tune-2.0.0-windows-x64.zip` con el `.exe` y las bibliotecas de Qt. Descomprime el zip y deja `mpv.exe` y `yt-dlp.exe` en la misma carpeta o en el `PATH`; la app los llama para reproducir y descargar. El zip lo compila el CI en cada etiqueta y en cada push a `master`. Necesita Windows 10 o superior.

### Android

`lotus-tune-<versión>-arm64.apk`, para teléfonos ARM64. Es una build de depuración.

```bash
adb install -r lotus-tune-2.0.0-arm64.apk
```

## Compilar

Requisitos: Qt 6.5 o superior (`Quick`, `Network`, `Sql`, `Multimedia`), `cmake` 3.19, `ninja`, `mpv` 0.40 o superior, `yt-dlp` y `python3`.

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/lotus-tune
```

Tests:

```bash
./build/lotus-tune-tests
# o
cd build && ctest --output-on-failure
```

Paquetes de Linux:

```bash
./tools/package-linux.sh
```

Deja el `.deb`, el `.rpm` (si `rpmbuild` está instalado) y el `.tar.gz` en `dist/`.

APK:

```bash
source ~/lotus-android-toolchain/env.sh
./tools/build-android.sh
```

El script necesita el SDK, el NDK 27, JDK 17 y Qt 6.6.3 para Android. `tools/setup-android-toolchain.sh` monta ese toolchain.

## Estado

Funciona:

- Búsqueda y reproducción en YouTube Music y SoundCloud.
- Karaoke palabra a palabra y letra compartida con iNiR.
- Portadas, fondo dinámico, descargas y biblioteca local.
- MPRIS, Discord Rich Presence, APK de Android.
- Build de Windows en el CI.

Limitaciones conocidas:

- En Android, el inicio de sesión se importa desde el PC.
- La búsqueda en Android depende de `yt-dlp`, que todavía no va embebido.
- El menú contextual con pulsación larga en táctil está pendiente.
- El zip de Windows lo genera el CI; no se prueba en un Windows físico en cada release.

## Repos relacionados

| Repo | Qué es |
|---|---|
| [Lotus-Arch](https://github.com/LotsV8pro/Lotus-Arch) | Escritorio Arch con Niri e iNiR |
| [lotus-discord](https://github.com/LotsV8pro/lotus-discord) | Tema de Vencord |
| [lotus-spotify](https://github.com/LotsV8pro/lotus-spotify) | Tema de Spicetify |
| [lotus-steam](https://github.com/LotsV8pro/lotus-steam) | Tema de Steam (Millennium) |
| [lotus-mic-chain](https://github.com/LotsV8pro/lotus-mic-chain) | Cadena de micro para EasyEffects |

## Créditos

| Proyecto | Uso |
|---|---|
| [mpv](https://mpv.io) | Reproducción (headless, IPC JSON) |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Metadatos y descargas |
| [Musixmatch](https://www.musixmatch.com) | Tiempos por palabra (richsync) |
| [LRCLIB](https://lrclib.net) | Letra sincronizada por líneas |
| [NetEase](https://music.163.com) | Klyric con tiempos por palabra |
| [Qt](https://www.qt.io) | Interfaz y red |

Las partes que enlazan con mpv y yt-dlp van con GPL-3.0. El resto del proyecto es MIT.
