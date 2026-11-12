# The published lyrics

Lotus Tune writes two JSON files while it plays. They let other programs on the
desktop show the same lyrics without searching again or guessing where the song
is.

```
$XDG_STATE_HOME/lotus-tune/lyrics.json          # lyrics of the track
$XDG_STATE_HOME/lotus-tune/lyrics-runtime.json  # position and state
```

`XDG_STATE_HOME` is `~/.local/state` when it is not set. If the variable does
not exist and the directory does not either, the app falls back to
`~/.local/state/lotus-tune`.

The reference consumer is `LyricsService.qml` from the iNiR shell. It reads
these files before asking the internet for lyrics and only searches on its own
when the track playing is not the one Lotus Tune is publishing.

## `lyrics.json`

| Field | Type | What it is |
|---|---|---|
| `v` | number | Format version. Today `1`. |
| `app` | text | `lotus-tune`. Lets a reader drop files written by another program. |
| `trackKey` | text | `Artist - Title`. The key to tell whether the lyrics belong to the track playing. |
| `title`, `artist` | text | Metadata of the track. |
| `videoId` | text | The YouTube Music video. |
| `duration` | number | Length in seconds. |
| `karaoke` | boolean | Whether the lyrics carry word timings. |
| `offset` | number | The offset the user has set, in seconds. |
| `status` | text | `ok` when there are timed lyrics, `none` when there are not. |
| `plain` | text | Untimed lyrics, used when there is nothing else. May be absent. |
| `lines` | list | The lines. Empty when `status` is `none`. |
| `ts` | number | Time of writing, in milliseconds since the epoch. |

Each entry in `lines`:

| Field | Type | What it is |
|---|---|---|
| `t` | number | Second it starts at. |
| `e` | number | Second it ends at. Never past the end of the track. |
| `text` | text | The line as sung. |
| `w` | list | Words, when there are word timings. May be absent. |
| `instrumental` | boolean | A stretch with no voice. Present and `true` only in those. |
| `voice` | text | `counter` on the lines of the counterpoint voice. May be absent. |

Each word in `w` is `{ "t": start, "e": end, "text": "word" }`, in seconds like
the rest.

Instrumental stretches carry no singable text: the app sends them with
`instrumental: true` and their text is only a marker. Whoever draws the lyrics
should show dots or a gap, not the marker.

## `lyrics-runtime.json`

| Field | Type | What it is |
|---|---|---|
| `v` | number | Format version. Today `1`. |
| `trackKey` | text | The same key as in `lyrics.json`. |
| `pos` | number | Position of the engine in seconds, without the `offset`. |
| `playing` | boolean | Whether it is playing. |
| `karaoke` | boolean | Whether the lyrics carry word timings. |
| `offset` | number | The same offset as in `lyrics.json`. |
| `ts` | number | Time of writing, in milliseconds. |

The second being sung is `pos + offset`. The app keeps the two apart so that
changing the offset does not force a rewrite of the lyrics.

## When to read them

Both files are rewritten several times per second while music plays. A reader
should:

1. Read `lyrics.json` and keep `trackKey` and the `ts` moment.
2. If `ts` is old (the app has been closed for a while) or `trackKey` is not the
   track playing, ignore the file and search for the lyrics on its own.
3. With the lyrics in hand, read `lyrics-runtime.json` to know where the song
   is. Between updates it can advance the position with its own clock and
   correct it on every read.

A file caught mid write can arrive truncated. When the JSON cannot be read,
drop it and try again on the next read; do not cache the error.

## Consumers in this repo

The Android home-screen widget (`android/src/com/lotustuneremote/app/LyricsWidget.java`)
reads both files so it paints the same lyrics as the app with the app closed.
When the line carries `w`, it lights what is already sung and keeps the rest
dimmed, like the desktop view. Each row is two stacked texts: the dim one
underneath, the bright one on top with its max width set to the singing front.
Moving that width moves the front in whole pixels, so the sweep is the same
one the app paints. It runs at about 12 Hz, which is as fast as the MIUI host
applies a RemoteViews update: each frame carries only the two widths and every
tenth one repeats the whole block, in case the host reinflated the tree. The
frames only run while the song plays and the screen is on.

A widget cannot blur the wallpaper behind it: RemoteViews is painted over the
wallpaper with no access to it. The "glass" is a thin white veil with a 1 dp
border, and the dark ink carries a white halo so it stays legible.

The widget shows nothing but the lyrics: the previous line, the one being sung
and the next one. Tapping it opens the app; the controls stay in the playback
widget.

## Example

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
