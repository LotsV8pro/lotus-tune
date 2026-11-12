<p align="center">
  <img src="https://img.shields.io/badge/Qt_6_%2F_QML-141218?style=for-the-badge&logo=qt&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/YouTube_Music-141218?style=for-the-badge&logo=youtubemusic&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/Linux_%C2%B7_Windows_%C2%B7_Android-141218?style=for-the-badge&logo=linux&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/badge/MPRIS_%2B_Discord_RP-141218?style=for-the-badge&logo=discord&logoColor=C4A8E2"/>
  <img src="https://img.shields.io/github/actions/workflow/status/LotsV8pro/lotus-tune/build.yml?style=for-the-badge&logo=githubactions&logoColor=C4A8E2&label=CI"/>
  <img src="https://img.shields.io/badge/MIT_%2B_GPL--3.0-141218?style=for-the-badge&logo=open-source-initiative&logoColor=C4A8E2"/>
</p>

<h1 align="center">Lotus Tune</h1>

Music player for YouTube Music and SoundCloud, written in Qt 6/QML. Plays through mpv and sings the synced lyrics word by word. Runs on Linux, Windows and Android.

## What it does

- Searches YouTube Music and SoundCloud, together or one at a time.
- Lights the lyrics word by word with the timings of the actual song.
- Draws the cover at full resolution and a background that follows its colour.
- Downloads with `yt-dlp` into the folder you pick and keeps a local library.
- Publishes MPRIS for the system controls and Discord Rich Presence.
- On Android it is the same interface, in an ARM64 APK.

## Lyrics

A lyric can come from Musixmatch (richsync, with a time per word), from the YouTube Music track itself, from LRCLIB, from NetEase or from the local Sonora cache. The app picks the source that matches the version playing, not the first one it finds: it compares the lines against the video timeline and drops the ones from another take, another album or a live recording.

Word timings come from the album and the text from the video, so they line up, and the lyric you see is the one of the video. Missing words and lines are filled from the other sources once they are aligned.

Stretches with no voice carry no text: the app draws three dots that light up one at a time. The lyrics can be dragged and they return to the line being sung after four seconds.

### The lyrics shared with iNiR

When Lotus Tune is the one playing, it writes the lyric and the position to:

```
~/.local/state/lotus-tune/lyrics.json
~/.local/state/lotus-tune/lyrics-runtime.json
```

The iNiR lyrics service (`LyricsService.qml`) reads those files before going out on its own. Widgets and the lock screen then use the same timings and the same words as the app, without a second download. The format is described in [docs/LYRICS.md](docs/LYRICS.md).

## Installation

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/LotsV8pro/lotus-tune/master/tools/install.sh -o install.sh
bash install.sh
```

The installer detects the distro (Arch, Debian, Fedora), warns about missing dependencies (`qt6`, `mpv`, `yt-dlp`), builds the app and installs it into `~/.local`, with the menu entry and the icon.

You can also clone and run the same script:

```bash
git clone https://github.com/LotsV8pro/lotus-tune.git
cd lotus-tune
./tools/install.sh
```

Options: `--prefix ~/.local`, `--system` (installs into `/usr/local`), `--no-pull`, `--jobs N`. `--help` lists the rest.

The releases also carry a `.deb` for Debian/Ubuntu, a `.rpm` for Fedora/openSUSE and a `.tar.gz` that works on any distro.

### Windows

The release carries `lotus-tune-2.0.0-windows-x64.zip` with the `.exe` and the Qt libraries. Unzip it and leave `mpv.exe` and `yt-dlp.exe` in the same folder or in the `PATH`; the app calls them to play and to download. CI builds the zip on every tag and on every push to `master`. Windows 10 or newer.

### Android

`lotus-tune-<version>-arm64.apk`, for ARM64 phones. It is a debug build.

```bash
adb install -r lotus-tune-2.0.0-arm64.apk
```

The APK needs two resource bundles inside: `assets/qt_qml.rcc` with Qt's own QML modules and `assets/android_rcc_bundle` with the app's QML. A build without them installs and closes on the first import. `tools/build-android.sh` writes both and refuses to leave an APK that lacks them.

## Building

Requirements: Qt 6.5 or newer (`Quick`, `Network`, `Sql`, `Multimedia`), `cmake` 3.19, `ninja`, `mpv` 0.40 or newer, `yt-dlp` and `python3`.

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/lotus-tune
```

Tests:

```bash
./build/lotus-tune-tests
# or
cd build && ctest --output-on-failure
```

Linux packages:

```bash
./tools/package-linux.sh
```

Leaves the `.deb`, the `.rpm` (when `rpmbuild` is installed) and the `.tar.gz` in `dist/`.

APK:

```bash
source ~/lotus-android-toolchain/env.sh
./tools/build-android.sh
```

The script needs the SDK, NDK 27, JDK 17 and Qt 6.6.3 for Android. `tools/setup-android-toolchain.sh` sets that toolchain up.

## Status

Working:

- Search and playback on YouTube Music and SoundCloud.
- Word by word karaoke and the lyrics shared with iNiR.
- Covers, dynamic background, downloads and the local library.
- MPRIS, Discord Rich Presence, Android APK.
- Windows build in CI.

Known limitations:

- On Android the login is imported from the PC.
- Search on Android depends on `yt-dlp`, which is not embedded yet.
- The long press context menu on touch screens is still missing.
- CI builds the Windows zip; it is not tried on a real Windows machine on every release.

## Related repositories

| Repo | What it is |
|---|---|
| [Lotus-Arch](https://github.com/LotsV8pro/Lotus-Arch) | Arch desktop with Niri and iNiR |
| [lotus-discord](https://github.com/LotsV8pro/lotus-discord) | Vencord theme |
| [lotus-spotify](https://github.com/LotsV8pro/lotus-spotify) | Spicetify theme |
| [lotus-steam](https://github.com/LotsV8pro/lotus-steam) | Steam theme (Millennium) |
| [lotus-mic-chain](https://github.com/LotsV8pro/lotus-mic-chain) | Microphone chain for EasyEffects |

## Credits

| Project | Used for |
|---|---|
| [mpv](https://mpv.io) | Playback (headless, JSON IPC) |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Metadata and downloads |
| [Musixmatch](https://www.musixmatch.com) | Word timings (richsync) |
| [LRCLIB](https://lrclib.net) | Line synced lyrics |
| [NetEase](https://music.163.com) | Klyric with word timings |
| [Qt](https://www.qt.io) | Interface and network |

The parts that link against mpv and yt-dlp are GPL-3.0. The rest of the project is MIT.
