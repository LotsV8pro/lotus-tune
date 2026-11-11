# La letra publicada

Lotus Tune escribe dos ficheros JSON mientras reproduce. Sirven para que otros
programas del escritorio enseñen la misma letra sin volver a buscarla ni
adivinar por dónde va la canción.

```
$XDG_STATE_HOME/lotus-tune/lyrics.json          # letra de la pista
$XDG_STATE_HOME/lotus-tune/lyrics-runtime.json  # posición y estado
```

`XDG_STATE_HOME` vale `~/.local/state` si no está definida. Si la variable no
existe y el directorio tampoco, la app usa `~/.local/state/lotus-tune`.

El consumidor de referencia es `LyricsService.qml` del shell iNiR. Lee estos
ficheros antes de pedir letra a Internet y solo busca por su cuenta si la pista
que suena no es la que Lotus Tune está publicando.

## `lyrics.json`

| Campo | Tipo | Qué es |
|---|---|---|
| `v` | número | Versión del formato. Hoy `1`. |
| `app` | texto | `lotus-tune`. Sirve para descartar ficheros de otro programa. |
| `trackKey` | texto | `Artista - Título`. Es la clave para saber si la letra es de la pista que suena. |
| `title`, `artist` | texto | Los metadatos de la pista. |
| `videoId` | texto | El vídeo de YouTube Music. |
| `duration` | número | Duración en segundos. |
| `karaoke` | booleano | Si la letra tiene tiempos por palabra. |
| `offset` | número | Ajuste en segundos que el usuario haya puesto. |
| `status` | texto | `ok` si hay letra con tiempos, `none` si no. |
| `plain` | texto | Letra sin tiempos, cuando no hay otra. Puede faltar. |
| `lines` | lista | Las líneas. Vacía si `status` es `none`. |
| `ts` | número | Momento de escritura, en milisegundos desde la época. |

Cada línea de `lines`:

| Campo | Tipo | Qué es |
|---|---|---|
| `t` | número | Segundo en que empieza. |
| `e` | número | Segundo en que termina. Nunca pasa del final de la pista. |
| `text` | texto | La línea tal cual se canta. |
| `w` | lista | Palabras, si hay tiempos por palabra. Puede faltar. |
| `instrumental` | booleano | Tramo sin voz. Presente y `true` solo en esos tramos. |
| `voice` | texto | `counter` en las líneas de contrapunto. Puede faltar. |

Cada palabra de `w` es `{ "t": inicio, "e": fin, "text": "palabra" }`, en
segundos, como el resto.

Los tramos instrumentales no llevan texto cantable: la app los envía con
`instrumental: true` y su texto es solo una marca. Quien dibuje la letra debe
enseñar puntos o un hueco, no la marca.

## `lyrics-runtime.json`

| Campo | Tipo | Qué es |
|---|---|---|
| `v` | número | Versión del formato. Hoy `1`. |
| `trackKey` | texto | La misma clave que en `lyrics.json`. |
| `pos` | número | Posición del motor en segundos, sin el `offset`. |
| `playing` | booleano | Si está sonando. |
| `karaoke` | booleano | Si la letra tiene tiempos por palabra. |
| `offset` | número | El mismo ajuste que en `lyrics.json`. |
| `ts` | número | Momento de escritura, en milisegundos. |

El segundo que se canta es `pos + offset`. La app separa las dos cosas para que
cambiar el ajuste no obligue a reescribir la letra.

## Cuándo leerlos

Los dos ficheros se reescriben varias veces por segundo mientras suena la
música. Un lector debe:

1. Leer `lyrics.json` y quedarse con `trackKey` y el instante `ts`.
2. Si `ts` es viejo (la app lleva un rato cerrada) o el `trackKey` no es el de
   la pista que suena, ignorar el fichero y buscar la letra por su cuenta.
3. Con la letra en mano, leer `lyrics-runtime.json` para saber por dónde va.
   Mientras recibe las actualizaciones, puede avanzar la posición con su propio
   reloj y corregirla en cada lectura.

Un fichero a medio escribir puede llegar truncado. Si el JSON no se puede
leer, se descarta y se vuelve a intentar en la siguiente lectura; no se cachea
el error.

## Ejemplo

```json
{
  "v": 1,
  "app": "lotus-tune",
  "trackKey": "DragonForce - Symphony Of The Night",
  "title": "Symphony Of The Night",
  "artist": "DragonForce",
  "videoId": "FMUcGYZLpdY",
  "duration": 320,
  "karaoke": true,
  "offset": 0,
  "status": "ok",
  "lines": [
    { "t": 0.33, "e": 2.78, "text": "Hiding in the fog" },
    { "t": 25.91, "e": 32.89, "text": "♪", "instrumental": true },
    {
      "t": 32.89,
      "e": 34.0,
      "text": "Fearless I'm fighting",
      "w": [
        { "t": 32.89, "e": 33.3, "text": "Fearless" },
        { "t": 33.3, "e": 33.6, "text": "I'm" },
        { "t": 33.6, "e": 34.0, "text": "fighting" }
      ]
    }
  ],
  "ts": 1794382470433
}
```
