# Cambios por plataforma - 2.3.2

Este archivo acompana a CHANGELOG.md. La version 2.3.2 comparte el nucleo
(reproductor, letras, cola e interfaz) en las tres plataformas.

## Compartido por las tres plataformas

- Correcciones de letras y sincronía descritas en CHANGELOG.md.
- Arranque en frio mas ligero: solo se calienta la cancion actual y se difiere.
- Caratula del mini con cascada de imagenes y timeout mas corto.
- Pulsacion larga en pantalla completa para abrir opciones en el telefono.

## Windows

Sin cambios especificos de Windows. Todo son ramas compartidas, sin ifdefs nuevos.

## Android

- Pausa al desconectar cascos o Bluetooth mediante ACTION_AUDIO_BECOMING_NOISY.
- Watchdog corregido para no saltar la cancion antes de tiempo.
- La cola de precarga se conserva al cambiar de pista.

## Linux

Sin cambios especificos de Linux. Todo son ramas compartidas.
