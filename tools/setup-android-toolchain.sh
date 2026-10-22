#!/usr/bin/env bash
# Installs everything needed to build the Android flavour of the app:
#   - Qt 6.6.3 for the host (the tools) and for the target (the libraries)
#   - the Android SDK (command line tools, platform, build tools)
#   - the Android NDK 27
#   - a JDK 17 (Gradle 8 does not work with the JDK 27 of the system)
#
#   tools/setup-android-toolchain.sh [destino]
#
# The default destination is ~/lotus-android-toolchain. Afterwards:
#   source ~/lotus-android-toolchain/env.sh
#   tools/build-android.sh
set -euo pipefail

DEST="${1:-$HOME/lotus-android-toolchain}"
QT_VER="6.6.3"
QT_HOST_VER="6.6.3"
NDK_VER="27.0.12077973"
PLATFORM="android-34"
BUILD_TOOLS="34.0.0"
JDK_VER="17"
GRADLE_DIST="https://services.gradle.org/distributions/gradle-8.10.2-all.zip"

mkdir -p "$DEST"
cd "$DEST"

say() { printf '\n=== %s\n' "$*"; }
have_aqt() { python3 -c "import aqtinstall" 2>/dev/null; }

# ---- aqt (the Qt installer) ---------------------------------------------
if ! have_aqt; then
    say "aqtinstall"
    python3 -m pip install --user --break-system-packages "aqtinstall==3.3.0" >/dev/null
fi
PY="$(python3 -c 'import site; print(site.getusersitepackages())')/bin/aqt"
[ -x "$PY" ] || PY="$(command -v aqt)"

# ---- Qt for the host (moc, rcc, androiddeployqt...) ----------------------
if [ ! -x "$DEST/qt-host/$QT_HOST_VER/gcc_64/bin/androiddeployqt" ]; then
    say "Qt $QT_HOST_VER de escritorio (host)"
    "$PY" install-qt linux desktop "$QT_HOST_VER" gcc_64 \
        -m qt_base qtmultimedia -O "$DEST/qt-host"
fi

# ---- Qt for Android ------------------------------------------------------
# The architecture is android_arm64_v8a and the base module is called
# qt_base there (qtbase is the desktop name).
if [ ! -d "$DEST/qt-android/$QT_VER/android_arm64_v8a" ]; then
    say "Qt $QT_VER para Android (arm64)"
    "$PY" install-qt linux android "$QT_VER" android_arm64_v8a \
        -m qt_base qtmultimedia qtnetworkauth qtshadertools -O "$DEST/qt-android"
fi

# ---- JDK 17 --------------------------------------------------------------
if [ ! -d "$DEST/jdk-17" ]; then
    say "JDK 17 (Gradle 8 no funciona con el JDK 27)"
    curl -sL "https://api.adoptium.net/v3/binary/latest/$JDK_VER/ga/linux/x64/jdk/hotspot/normal/eclipse" \
        -o jdk17.tar.gz
    mkdir -p "$DEST/jdk-17"
    tar xzf jdk17.tar.gz -C "$DEST/jdk-17" --strip-components=1
    rm -f jdk17.tar.gz
fi

# ---- Android SDK ---------------------------------------------------------
if [ ! -d "$DEST/android-sdk/cmdline-tools" ]; then
    say "SDK de Android (command line tools)"
    curl -sL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -o cmdline-tools.zip
    mkdir -p "$DEST/android-sdk/cmdline-tools"
    unzip -q cmdline-tools.zip -d "$DEST/android-sdk/cmdline-tools"
    mv "$DEST/android-sdk/cmdline-tools/cmdline-tools" \
       "$DEST/android-sdk/cmdline-tools/latest"
    rm -f cmdline-tools.zip
fi

export ANDROID_SDK_ROOT="$DEST/android-sdk"
export ANDROID_HOME="$DEST/android-sdk"
SDKMAN="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

say "Plataforma, build tools y NDK"
yes | "$SDKMAN" --licenses >/dev/null 2>&1 || true
"$SDKMAN" "platform-tools" "platforms;$PLATFORM" "build-tools;$BUILD_TOOLS" \
          "ndk;$NDK_VER" "cmake;3.22.1" >/dev/null

cat > "$DEST/env.sh" <<EOF
# Source this file before building the Android flavour.
export ANDROID_SDK_ROOT="$DEST/android-sdk"
export ANDROID_HOME="$DEST/android-sdk"
export ANDROID_NDK_ROOT="$DEST/android-sdk/ndk/$NDK_VER"
export QT_PREFIX="$DEST/qt-android/$QT_VER/android_arm64_v8a"
export QT_HOST_PATH="$DEST/qt-host/$QT_HOST_VER/gcc_64"
export JAVA_HOME="$DEST/jdk-17"
export PATH="\$JAVA_HOME/bin:\$PATH"
export CMAKE_PREFIX_PATH="\$QT_PREFIX"
EOF

say "Listo"
cat <<EOF

Para compilar el APK:

  source $DEST/env.sh
  tools/build-android.sh

El APK sale en build-android/android-build/build/outputs/apk/debug/
EOF
