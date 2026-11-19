# Integraciones

Lotus Tune se abre a otros programas de tres formas: un archivo de estado,
MPRIS/Discord y la exportación de datos.

## Estado actual en un archivo

Mientras reproduce, la app escribe:

```
$XDG_STATE_HOME/lotus-tune/now-playing.json
```

con `app`, `title`, `artist`, `album`, `art` (URL de la portada), `duration`,
`playing` y `ts` (milisegundos). Una barra de escritorio, un overlay de OBS o
un script pueden leerlo sin abrir un socket ni autenticarse. Se actualiza al
cambiar de pista y al pausar o reanudar.

Las letras publicadas para el widget de iNiR viven junto a él:

```
$XDG_STATE_HOME/lotus-tune/lyrics.json
$XDG_STATE_HOME/lotus-tune/lyrics-runtime.json
```

`docs/LYRICS.md` describe su formato. El widget respeta el ajuste de karaoke
y muestra la traducción cuando la hay.

## Last.fm

Ajustes > Cuentas > Last.fm permite conectar una cuenta con usuario, API key,
secret y contraseña. La app guarda la session key y envía `track.scrobble` al
terminar una pista de más de 30 s reproducida al menos la mitad (o 4 minutos),
y `track.updateNowPlaying` al empezar. Si Last.fm responde error 9, la sesión
se revoca y hay que volver a conectar.

## MPRIS y Discord Rich Presence

En escritorio la app expone MPRIS2 (`org.mpris.MediaPlayer2.lotustune`) y
Discord Rich Presence. Discord se activa en Ajustes > Discord; en Android
figura como próximamente.

## Exportación

- Ajustes > Letras: exportar/importar la letra actual en LRC.
- Ajustes > Biblioteca: copia de la biblioteca (JSON), historial (CSV) e
  importación de la biblioteca.
- Ajustes > Apariencia: copia de todos los ajustes (JSON) e importación.
