# Cambios por plataforma — 2.2.3

Este archivo acompaña a `CHANGELOG.md`. La versión 2.2.3 comparte el núcleo
(reproductor, letras, precarga e interfaz) en las tres plataformas, pero cada
build tiene cambios propios. Aquí están separados para que no se mezclen.

## Android

### Específico del teléfono

- El gesto de deslizar en la barra se activó en móvil. Estaba detrás de una condición invertida (`!bar.compact`), por lo que nunca funcionaba en el teléfono.
- Retorno de la barra al soltar el swipe sin animación: antes se quedaba unos instantes en el borde.
- Los botones de la barra tienen feedback de pulsación con el dedo (`fingerPressed`), no sólo con el ratón.
- La sección de atajos de teclado no se muestra en el teléfono; tampoco los textos con «Ctrl+», «Escape» o «Windows».
- Se conservaron `QT_ANDROID_HWUI_MODE=0`, `HWUI_RENDER_MODE=software` y `SKIA_RENDER_MODE=software`, y `android:hardwareAccelerated=false`. Sin ellos el proceso gráfico se abortaba al arrancar en Redmi/MIUI (`SIGABRT` en `hwuiTask1`). Se añadió `QSG_RHI_BACKEND=opengl` explícito.
- Se eliminó el `preventStepping` inválido del Chip que causaba error QML y un cierre del proceso al arrancar.
- Precarga de letras desactivada en móvil: cuatro proveedores por pista lanzaban dieciséis peticiones de red y bloqueaban la interfaz. La pista actual sí busca su letra al empezar.
- Diálogo «Qué hay de nuevo» con notas embebidas y botón para volver a abrirlo desde Ajustes > Personalizar ajustes.

### Compartido con Linux

- Cambio de canción agrupado con debounce de 180 ms.
- Audio desde stream directo mientras se descarga la copia local.
- Blur del fondo en hilo de trabajo (89 ms → 15-17 ms por fotograma).
- Letras: acentos normalizados, artistas con «y»/«,» equivalentes, capitalización rara corregida, `shift` guardado en caché, re-escalado por duración del videoclip y reintento de «sin letra».
- Favoritos: no se marcan localmente si el voto no llega a YouTube Music.
- Velo del cinema y aviso «Cargando la lista…» corregidos.

## Linux (escritorio)

### Específico del escritorio

- El binario instalado se reconstruyó con todos los cambios y se dejó como recién instalado. Hash verificado contra el build.
- `LIBGL_ALWAYS_SOFTWARE=1` y `__GLX_VENDOR_LIBRARY_NAME=mesa` se mantienen fuera del bloque Android, como correspondía.
- Prueba de sincronía de 150 canciones: `OK=150 DESYNC=0 SIN_LETRA=0`. Diferencias entre reproductor y letra de 0,1 a 1,4 s (intervalo de publicación del runtime, no desfase real).
- Se limpió el marcador `whatsNewSeen` para comprobar que el diálogo de novedades se abre al arrancar tras la actualización.
- Botón «Ver novedades de la 2.2.3» en Ajustes > Personalizar ajustes para volver a abrirlo sin reinstalar.

### Compartido con Android

- Igual que la lista «Compartido con Android» de arriba.

## Windows

- No hay cambios específicos de Windows en esta versión: ningún archivo tocado lleva `#ifdef Q_OS_WIN`.
- El código es compartido, por lo que Windows hereda el núcleo de 2.2.3 cuando se compile en CI.
- No se ha podido generar el ejecutable en esta máquina porque no hay Qt para Windows instalado (sólo el compilador mingw).
- Los binarios publicados en GitHub siguen siendo los de 2.2.1. La release de 2.2.3 deberá incluir el zip de Windows compilado desde este mismo source para que las tres plataformas queden realmente iguales.

## Pendiente de implementar (no incluido en 2.2.3)

Estas peticiones quedaron anotadas y **no están en el código**, por lo que no aparecen en el changelog de cambios aplicados:

- Auto-creación de listas propias desde la selección múltiple.
- Fusión de dos listas (merge), manteniendo las originales.
- Recomendaciones de canciones parecidas al final de una lista de 500 para añadir en bloque.
- Mover 200 de 500 canciones a otra lista conservando la original.
