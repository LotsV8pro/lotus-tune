#!/usr/bin/env bash
# Builds the Android flavour (APK) of the app.
#
#   source ~/lotus-android-toolchain/env.sh
#   tools/build-android.sh
#
# The APK ends in build-android/android-build/build/outputs/apk/debug/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build-android"

# CI exports the SDK but not the NDK root: take the one the SDK carries so
# the same script works on a runner and on this machine.
if [ -z "${ANDROID_NDK_ROOT:-}" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    ANDROID_NDK_ROOT="$(ls -d "$ANDROID_SDK_ROOT"/ndk/*/ 2>/dev/null | sort -V | tail -1)"
    ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT%/}"
    export ANDROID_NDK_ROOT
fi

if [ -z "${ANDROID_NDK_ROOT:-}" ] || [ -z "${QT_PREFIX:-}" ] || [ -z "${QT_HOST_PATH:-}" ]; then
    echo "Falta el toolchain: ejecuta primero" >&2
    echo "  tools/setup-android-toolchain.sh && source ~/lotus-android-toolchain/env.sh" >&2
    exit 1
fi

# Gradle does not run on the system JDK (27: "Unsupported class file major
# version 71"), and the build failed every time the shell had not exported
# JAVA_HOME by hand. The toolchain brings its own JDK 17: use it when the
# environment does not point anywhere.
JDK17="$(ls -d "$HOME"/lotus-android-toolchain/jdk-17* 2>/dev/null | head -1 || true)"
if [ -n "$JDK17" ] && [ -z "${JAVA_HOME:-}" ]; then
    export JAVA_HOME="$JDK17"
    export PATH="$JAVA_HOME/bin:$PATH"
    echo "JAVA_HOME=$JAVA_HOME"
fi

# ---------------------------------------------------------------------------
# Qt's own QML modules (QtQuick, QtQuick.Window, QtQuick.Controls...).
# androiddeployqt 6.6 only packages the app's own assets and never writes
# assets/qt_qml.rcc, and it deploys no qml/ directory either, so on the phone
# the import fails with `module "QtQuick.Window" is not installed` and the app
# closes. main.cpp registers assets:/qt_qml.rcc when it is there, so build
# that bundle from the Qt install: every file of $QT_PREFIX/qml except the
# plugins, which androiddeployqt already copies to lib/.
QML_SRC="$QT_PREFIX/qml"
if [ -d "$QML_SRC" ]; then
    QRC="$QML_SRC/.lotus-qml-bundle.qrc"
    trap 'rm -f "$QRC"' EXIT
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<RCC version="1.0">'
        echo '<qresource prefix="/">'
        ( cd "$QML_SRC" && find . -type f ! -name '*.so' ! -name '*.o' \
            | sed 's|^\./||' | LC_ALL=C sort ) \
            | sed 's|.*|        <file>&</file>|'
        echo '</qresource>'
        echo '</RCC>'
    } > "$QRC"
    ( cd "$QML_SRC" && "$QT_HOST_PATH/libexec/rcc" --binary --no-compress \
        --root /qt/qml -o "$ROOT/android/assets/qt_qml.rcc" "$QRC" )
    echo "qt_qml.rcc: $(du -h "$ROOT/android/assets/qt_qml.rcc" | cut -f1)"
fi

# Without that bundle the phone dies on the first import (`module
# "QtQuick.Window" is not installed`), and the build looks fine up to the
# install. Stop here instead of shipping an APK that closes on launch.
if [ ! -s "$ROOT/android/assets/qt_qml.rcc" ]; then
    echo "falta android/assets/qt_qml.rcc: revisa QT_PREFIX ($QT_PREFIX)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# The APK packages a COPY of qml/ (android/assets/android_rcc_bundle/qml,
# tracked in git); the desktop binary embeds qml/ directly. Editing qml/ and
# building used to ship the old copy silently, so the two trees must not
# drift: sync them here before packaging.
ASSET_QML="$ROOT/android/assets/android_rcc_bundle/qml/LotusTune"
if [ -d "$ASSET_QML" ]; then
    cp -f "$ROOT"/qml/*.qml "$ROOT"/qml/*.js "$ASSET_QML"/
fi

# androiddeployqt builds assets/android_rcc_bundle.rcc BEFORE copying the
# assets into the build directory, so it bundles the previous build's QML
# (a new file was missing from the APK and the phone kept the old layout).
# The bundle is regenerated below, once the copy is done.

cmake -S "$ROOT" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-34 \
    -DANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" \
    -DQt6_DIR="$QT_PREFIX/lib/cmake/Qt6" \
    -DQT_HOST_PATH="$QT_HOST_PATH" \
    -DCMAKE_FIND_ROOT_PATH="$QT_PREFIX" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH

# The APK is built in two steps: the shared library with CMake and the
# package with Gradle. The "apk" target of Qt writes the Gradle project
# (it fails afterwards on a missing dep file, a bug of Qt 6.6, but Gradle
# does the job).
cmake --build "$BUILD" --target apk || true

# androiddeployqt builds assets/android_rcc_bundle.rcc before it copies
# android/assets into the build tree, so that first bundle carries the
# previous build's QML. The copies are in place now: drop the bundle and let
# a second pass build it from them (the app reads it at startup and a stale
# one keeps the old layout on screen).
rm -f "$BUILD/android-build/assets/android_rcc_bundle.rcc"
cmake --build "$BUILD" --target apk || true

cmake --build "$BUILD" --target lotus-tune
mkdir -p "$BUILD/android-build/libs/arm64-v8a"
cp "$BUILD"/liblotus-tune_*.so "$BUILD/android-build/libs/arm64-v8a/" 2>/dev/null || true
( cd "$BUILD/android-build" && ./gradlew assembleDebug --no-daemon )

APK="$BUILD/android-build/build/outputs/apk/debug/lotus-tune-debug.apk"
if [ -f "$APK" ]; then
    # The two bundles are what the phone loads: Qt's QML modules and the
    # app's own qmldir. An APK without them installs and dies in a second,
    # which is exactly what the release shipped once. The listing is read
    # into a variable: `unzip | grep -q` fails on SIGPIPE with pipefail.
    listing="$(unzip -l "$APK")"
    for entry in assets/qt_qml.rcc assets/android_rcc_bundle/qmldir \
                 assets/android_rcc_bundle.rcc; do
        case "$listing" in
            *"$entry"*) ;;
            *)
                echo "el APK no lleva $entry: no lo instales" >&2
                exit 1
                ;;
        esac
    done
    # A stale rcc installs and runs the previous UI, which looks like "the
    # change did nothing". Names inside the bundle are UTF-16BE and the
    # files are compressed, so grep cannot see them.
    if command -v python3 >/dev/null 2>&1; then
        tmpdir="$(mktemp -d)"
        unzip -q -o "$APK" assets/android_rcc_bundle.rcc -d "$tmpdir"
        if ! python3 - "$tmpdir/assets/android_rcc_bundle.rcc" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
sys.exit(0 if "Main.qml".encode("utf-16-be") in data else 1)
PY
        then
            echo "el bundle QML del APK esta vacio o es viejo" >&2
            rm -rf "$tmpdir"
            exit 1
        fi
        rm -rf "$tmpdir"
    fi
    echo
    echo "APK: $APK ($(du -h "$APK" | cut -f1))"
    echo "Para instalarlo en un movil:  adb install -r \"$APK\""
fi
