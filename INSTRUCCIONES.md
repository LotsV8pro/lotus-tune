# Instrucciones de Lotus Tune

## Linux

Necesitas Qt 6, Qt Quick, Qt Multimedia, mpv, yt-dlp y Python 3.

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/lotus-tune
```

Para instalarlo en `~/.local/bin`:

```sh
bash tools/install.sh --no-deps
```

Para generar paquete `.deb` o `.tar.gz`:

```sh
bash tools/package-linux.sh
```

## Windows

Descarga el instalador de la pestaña Releases. Instala para el usuario actual y deja el acceso directo en el menú de inicio. El instalador incluye Qt, mpv, yt-dlp y Python, así que no hay que instalar nada más.

El zip `lotus-tune-windows.zip` es para el actualizador de la app. No hace falta descargarlo a mano.

## Android

Instala el APK arm64 de la release. La app pide permiso para notificaciones y acceso a archivos. Para compilarlo:

```sh
source ~/lotus-android-toolchain/env.sh
bash tools/build-android.sh
adb install -r build-android/android-build/build/outputs/apk/debug/lotus-tune-debug.apk
```

## Primer arranque

1. Abre Ajustes > Cuentas.
2. Pulsa Iniciar sesión con Google.
3. Vuelve a Inicio y busca una canción.

Sin sesión puedes buscar en SoundCloud y reproducir enlaces. YouTube Music necesita la sesión para listas privadas, Me gusta y letras con tiempos.

## Letras

Ajustes > Letras tiene los interruptores de letras sincronizadas, karaoke palabra a palabra, fuentes adicionales y traducción. La compensación de tiempo se guarda para cada canción.

Cuando una frase va adelantada o retrasada, abre Ajustes > Letras y mueve la compensación. El widget del escritorio lee el mismo ajuste.

## Importar de Spotify

Para una playlist pública, pega el enlace en Ajustes > Cuentas o pulsa el icono de enlace en la barra de Biblioteca.

Para el historial de Me gusta, pide el exporte de datos en Spotify > Ajustes > Privacidad. Descomprime el ZIP, busca `LikedSongs1.json` y selecciónalo en Ajustes > Cuentas. Cada canción se marca como Me gusta en YouTube Music.

## Idiomas

Ajustes > Idioma abre un desplegable con español, inglés, francés, alemán, portugués y la opción de seguir el sistema. El cambio se aplica sin reiniciar.

## Discord

En escritorio, Ajustes > Discord permite activar Rich Presence. En Android figura como próximamente.

## Atajos de teclado

Espacio reproduce o pausa; las flechas buscan ±5 s y Ctrl+flechas cambian de canción. Subir y bajar ajustan el volumen, M lo silencia y L (o F) abre la letra a pantalla completa. `[` y `]` corrigen el desfase de la letra, Ctrl+D marca «Me gusta» y Ctrl+R vuelve a buscar la letra. Q muestra la cola, Ctrl+, los ajustes y F11 la pantalla completa.

## Más información

`CHANGELOG.md` tiene los cambios de cada versión. `docs/LYRICS.md` y `docs/I18N.md` explican las fuentes de letras y las traducciones. `archive/legacy/` guarda scripts antiguos que ya no intervienen en el build.
