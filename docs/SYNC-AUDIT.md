# Audio sync audit

`docs/LYRICS.md` describes the `wordCheck` object published with the lyrics.
That object compares two text timelines: the word stamps of the chosen karaoke
source and the line times of the video. It cannot hear the audio. A karaoke can
match the video perfectly and still run ahead of the song being played.

## Tools

`tools/sync-audit/analyze_audio.py` downloads nothing. It reads the audio files
in `LOTUS_AUDIO_DIR`, transcribes them with faster-whisper, and pairs each
transcribed word with the closest word stamp of the same text. The median of
those pairs is the drift against the real audio. Set `LOTUS_ASR_DEVICE=cpu` when
CUDA is unavailable, and `LOTUS_ASR_MODEL` to change the model (default `small`).

`tools/sync-audit/apply_offsets.py` writes the measured drift into
`lyricsOffsetByTrack` in the Qt settings. It uses 50 ms steps, so a 0.2 s drift
is not rounded to the nearest quarter second. Hand-set offsets of 1 s or more,
and the zero entry, are left alone.

```sh
export LOTUS_AUDIO_DIR=/tmp/lotus-sync-audit/audio
export LOTUS_SYNC_REPORT=/tmp/lotus-sync-audit/report.json
python3 tools/sync-audit/analyze_audio.py 80 > /tmp/lotus-sync-audit/analyze.log
python3 tools/sync-audit/apply_offsets.py
```

`qml/Main.qml` reads `lyricsOffsetByTrack` before each fetch. The per-track
value wins over the global `lyricsOffset`, which still applies to tracks with
no calibration. `checkWords()` adds the active offset before pairing, so the
`wordCheck` published in `lyrics.json` reports the drift the listener still
hears, not the raw drift of the saved word stamps.

## Results on this machine

The first pass used the `base` model on CPU and found six tracks with enough
paired words. It corrected four, but the spread inside each line stayed high.
The second pass used `small` on an RTX 4070 and improved the pairing rate from
21.7% to 32.7% on the first track, with another track reaching 86.3% within
0.2 s. Twenty tracks now have a measured offset in the settings.

A negative drift means the karaoke runs ahead of the voice. A positive one
means it runs late. The player activates a word when `pos + offset >= t`, so
the written compensation is the inverse of the drift. Tracks with fewer than
30 paired words, or without a usable key, get no entry and keep the global
offset.

Two source defects were fixed while chasing the remaining spread. Some TTML
entries end the last word at its own start, so the front lit it for 1 ms and
jumped to the next line; 677 cached lines had that shape. Any word shorter
than 20 ms now gets at least 50 ms when the gap before the next word allows
it. `joinSplitWords()` can create new slivers when it splits a glued word, so
`sanitizeWordStamps()` runs again after it in `publishFinal()`. The glued
token `thisdream` was added to the repair list.

## Limits

A chorus sung at the same time as the verse, or words inside parentheses,
makes the transcript start several seconds before or after the word stamps.
That is not a drift. `Vana - Clandestine` looked 7 s early for that reason;
writing that offset made it late. An offset is only written when the paired
words follow the same sequence, not only the same words.

The report measures the offset, not the timing of every word. A track with
many words more than 0.2 s from their stamp still has a spread the global
offset cannot remove. That needs forced alignment against clean audio and a
provider with accurate per-word timings. The tool never writes a correction
from a weak sample.
