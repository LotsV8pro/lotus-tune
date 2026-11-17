# Cómo contribuir

Gracias por querer ayudar. Se aceptan correcciones, traducciones, mejoras de interfaz y pruebas en distintos equipos.

## Antes de empezar

Busca si el tema ya está en los issues abiertos o cerrados. Si no está, abre uno con el problema o la idea concreta. Así se evita trabajar dos veces en lo mismo.

## Cambios pequeños

Para corregir un error o una traducción, abre un issue, haz tu cambio y envía un pull request con una descripción corta de qué arregla. Si es una traducción, no hace falta abrir issue antes.

## Cambios grandes

Para cambios que afecten a la reproducción, las letras o la interfaz, comenta primero la idea en un issue. Así se puede acordar el alcance antes de escribir código.

## Preparar el entorno

Necesitas Qt 6 con Qt Quick y Qt Multimedia, mpv, yt-dlp y Python 3.

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

Para compilar el APK se usa el entorno de Android y `tools/build-android.sh`. El workflow de GitHub Actions comprueba Linux, Windows y Android en cada cambio.

## Antes de enviar el pull request

- Que pasen los tests y no haya nuevos avisos al compilar.
- Que los textos visibles estén en español y los comentarios de código en inglés.
- Que el cambio no rompa la compatibilidad con los tres sistemas.
- Que la descripción diga qué ve el usuario, no solo qué archivos cambiaron.

## Idiomas

Las traducciones viven en `i18n/`. Para añadir una lengua o revisar una existente, sigue `docs/I18N.md`. No hace falta tocar el código QML.

## Normas

Participar implica respetar el código de conducta del repositorio.
