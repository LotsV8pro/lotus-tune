# Lotus Tune

Player de YouTube Music y SoundCloud escrito en Qt 6 y QML. Reproduce con mpv, muestra letras sincronizadas letra a letra y funciona en Linux, Windows y Android.

## Qué hace

Busca canciones, artistas y listas de YouTube Music y SoundCloud. Puedes abrir una lista sin reproducirla o añadirla a la cola.

Las letras se alinean con la canción que suena. Cuando una fuente solo da el tiempo de cada frase, el tiempo se reparte entre las palabras para que el resaltado avance letra a letra. Se guardan en la caché, junto con la compensación que ajustes para cada canción.

La biblioteca guarda listas, descargas y reproducciones recientes. La barra de Biblioteca tiene un botón para importar una playlist pública de Spotify a YouTube Music. Ajustes > Cuentas permite importar también el archivo `LikedSongs1.json` del exporte de datos de Spotify.

La interfaz sale en español, inglés, francés, alemán y portugués. MPRIS funciona en escritorio. Discord Rich Presence funciona en escritorio; en Android figura como próximamente.

## Ejecutar

Linux necesita Qt 6, Qt Quick, Qt Multimedia, mpv, yt-dlp y Python 3.

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/lotus-tune
```

`tools/install.sh` instala el binario en `~/.local/bin`. `tools/package-linux.sh` genera un `.deb` y un `.tar.gz` en `dist/`.

Windows se compila en GitHub Actions. El workflow genera `lotus-tune-windows.zip` para el actualizador y `LotusTune-Setup-<version>.exe` con Inno Setup. El instalador lleva Qt, mpv, yt-dlp y Python.

Android se compila con `tools/build-android.sh` después de cargar `~/lotus-android-toolchain/env.sh`. El resultado es un APK arm64.

## Primer arranque

Abre Ajustes > Cuentas e inicia sesión con Google. Eso permite buscar letras con tiempos, sincronizar Me gusta y crear listas en YouTube Music. SoundCloud funciona sin cuenta.

## Archivos y documentación

- `CHANGELOG.md`: cambios por versión.
- `INSTRUCCIONES.md`: instalación y primeros pasos en español.
- `docs/LYRICS.md`: fuentes de letras y alineación.
- `docs/I18N.md`: cómo añadir o actualizar traducciones.
- `archive/legacy/`: scripts y archivos de versiones anteriores. No se usan en el build.
- `archive/build-root/`: restos de compilaciones en la raíz, fuera del árbol de fuentes. No se usan en el build.

La sesión, la biblioteca y la configuración viven en `~/.local/state/lotus-tune` y `~/.config/lotus-tune` en Linux, y en el directorio privado de la app en Android.
