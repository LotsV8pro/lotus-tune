#!/bin/bash
# Wrapper para obtener la lista de canciones de "Me Gusta" (Liked Music) usando yt-dlp

OUTPUT_FILE=$(mktemp)
ERROR_FILE=$(mktemp)

# Usar yt-dlp directamente para obtener la lista LM
# Usar el archivo de cookies directamente
COOKIES_FILE="/home/lots/.config/lotus-tune/cookies.txt"

if [ ! -f "$COOKIES_FILE" ]; then
    echo "Error: Archivo de cookies no encontrado: $COOKIES_FILE" >&2
    exit 1
fi

yt-dlp \
    --cookies "$COOKIES_FILE" \
    --flat-playlist \
    --no-playlist \
    --no-warnings \
    --extractor-args "youtubetab:skip=authcheck" \
    --print "%(id)s\t%(title)s\t%(uploader)s\t%(url)s" \
    "https://music.youtube.com/playlist?list=PLi1I6OF7y2coHtOdaGsVHTnPpXSNwS-kM" \
    > "$OUTPUT_FILE" 2> "$ERROR_FILE"

EXIT_CODE=$?

# Copiar los archivos a un lugar permanente
cp "$OUTPUT_FILE" /tmp/liked_fetch_output.txt
cp "$ERROR_FILE" /tmp/liked_fetch_error.log

rm -f "$OUTPUT_FILE" "$ERROR_FILE"

exit $EXIT_CODE
