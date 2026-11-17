#!/usr/bin/env bash
# Regenerates the translation sources (i18n/*.ts) from the code and compiles
# the .qm the build embeds. Run it after touching any qsTr()/tr() string, and
# always after adding a language:
#
#   bash tools/update-translations.sh          # update and compile all
#   bash tools/update-translations.sh en       # only the English one
#
# The CMake build refuses to configure when a .qm is older than its .ts, so a
# forgotten run shows up as a build error and not as an app that silently
# speaks the old language.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LU="$(command -v lupdate6 || command -v lupdate || true)"
LR="$(command -v lrelease6 || command -v lrelease || true)"
[ -n "$LU" ] || { echo "falta lupdate (paquete qttools / qt6-tools)" >&2; exit 1; }
[ -n "$LR" ] || { echo "falta lrelease (paquete qttools / qt6-tools)" >&2; exit 1; }

mkdir -p i18n
if [ $# -gt 0 ]; then
    LANGS="$*"
else
    LANGS=""
    for ts in i18n/*.ts; do
        [ -f "$ts" ] || continue
        base="$(basename "$ts" .ts)"
        LANGS="$LANGS ${base#lotus-tune_}"
    done
fi
[ -n "$LANGS" ] || { echo "no hay ficheros .ts en i18n/" >&2; exit 1; }

for code in $LANGS; do
    ts="i18n/lotus-tune_$code.ts"
    echo "lupdate $ts"
    "$LU" -source-language es -target-language "$code" -no-obsolete \
          qml/ src/ -ts "$ts" >/dev/null
    echo "lrelease $ts"
    "$LR" -silent "$ts" -qm "i18n/lotus-tune_$code.qm"
    # A language with holes is not broken, but it is worth saying out loud:
    # the app falls back to the Spanish source string there. The Spanish file
    # is all holes on purpose (it only carries the plural forms).
    pending="$(grep -c 'type="unfinished"' "$ts" || true)"
    if [ "$code" != "es" ] && [ "${pending:-0}" != "0" ]; then
        echo "  $pending cadenas sin traducir en $ts"
    fi
done
