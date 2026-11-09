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

if [ -z "${ANDROID_NDK_ROOT:-}" ] || [ -z "${QT_PREFIX:-}" ] || [ -z "${QT_HOST_PATH:-}" ]; then
    echo "Falta el toolchain: ejecuta primero" >&2
    echo "  tools/setup-android-toolchain.sh && source ~/lotus-android-toolchain/env.sh" >&2
    exit 1
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

# ---------------------------------------------------------------------------
# The APK packages a COPY of qml/ (android/assets/android_rcc_bundle/qml,
# tracked in git); the desktop binary embeds qml/ directly. Editing qml/ and
# building used to ship the old copy silently, so the two trees must not
# drift: sync them here before packaging.
ASSET_QML="$ROOT/android/assets/android_rcc_bundle/qml/LotusTune"
if [ -d "$ASSET_QML" ]; then
    cp -f "$ROOT"/qml/*.qml "$ROOT"/qml/*.js "$ASSET_QML"/
fi

# androiddeployqt skips "Create rcc bundle" when the .rcc is already there, so
# a QML edit never made it into the APK (the phone kept running the old UI).
# Delete it and let the deploy step rebuild it from the synced copy.
rm -f "$BUILD/android-build/assets/android_rcc_bundle.rcc"

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
cmake --build "$BUILD" --target lotus-tune
mkdir -p "$BUILD/android-build/libs/arm64-v8a"
cp "$BUILD"/liblotus-tune_*.so "$BUILD/android-build/libs/arm64-v8a/" 2>/dev/null || true
( cd "$BUILD/android-build" && ./gradlew assembleDebug --no-daemon )

APK=$(find "$BUILD" -name "*.apk" | head -1)
if [ -n "$APK" ]; then
    echo
    echo "APK: $APK ($(du -h "$APK" | cut -f1))"
    echo "Para instalarlo en un movil:  adb install -r \"$APK\""
fi
