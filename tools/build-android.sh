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
# package with Gradle. The target that Qt adds for the APK fails on a
# missing dep file (a bug of Qt 6.6), but Gradle does the job.
cmake --build "$BUILD" --target lotus-tune
( cd "$BUILD/android-build" && ./gradlew assembleDebug --no-daemon )

APK=$(find "$BUILD" -name "*.apk" | head -1)
if [ -n "$APK" ]; then
    echo
    echo "APK: $APK ($(du -h "$APK" | cut -f1))"
    echo "Para instalarlo en un movil:  adb install -r \"$APK\""
fi
