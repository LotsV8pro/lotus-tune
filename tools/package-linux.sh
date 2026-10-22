#!/usr/bin/env bash
# Packages the app for Linux: a tarball (always), a .deb (needs dpkg-deb)
# and an AppDir/AppImage (needs patchelf and appimagetool).
#
#   tools/package-linux.sh [build-dir]
#
# Everything ends up in dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
DIST="$ROOT/dist"
NAME="lotus-tune"
VERSION="$(sed -n 's/.*project(lotus-tune\s*\(.*\)\s*VERSION \([0-9.]*\).*/\2/p' "$ROOT/CMakeLists.txt" | head -1)"
[ -n "$VERSION" ] || VERSION="1.0.0"

if [ ! -x "$BUILD/lotus-tune" ]; then
    echo "No hay binario en $BUILD. Compila antes:" >&2
    echo "  cmake -S '$ROOT' -B '$BUILD' -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build '$BUILD'" >&2
    exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# ---- staging -------------------------------------------------------------
STAGE="$DIST/stage"
mkdir -p "$STAGE/bin" "$STAGE/share/applications" "$STAGE/share/icons/hicolor/scalable/apps" \
         "$STAGE/share/metainfo" "$STAGE/share/doc/$NAME" "$STAGE/lib"

cp "$BUILD/lotus-tune" "$STAGE/bin/"
[ -f "$ROOT/tools/ytm_login.py" ] && cp "$ROOT/tools/ytm_login.py" "$STAGE/bin/"
[ -f "$ROOT/tools/ytm_api.py" ] && cp "$ROOT/tools/ytm_api.py" "$STAGE/bin/"
cp "$ROOT/packaging/$NAME.desktop" "$STAGE/share/applications/"
cp "$ROOT/packaging/icons/$NAME.svg" "$STAGE/share/icons/hicolor/scalable/apps/"
cp "$ROOT/packaging/$NAME.metainfo.xml" "$STAGE/share/metainfo/"
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$STAGE/share/doc/$NAME/"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$STAGE/share/doc/$NAME/"

# The Qt libraries are taken with the rpath already set by CMake, so the
# app runs from the build tree; for the package the libs are copied next to
# the binary and the loader is pointed at them.
if command -v patchelf >/dev/null 2>&1; then
    echo "==> Copiando las bibliotecas de Qt"
    mkdir -p "$STAGE/lib"
    for lib in $(ldd "$BUILD/lotus-tune" 2>/dev/null | awk '/=> \//{print $3}' | sort -u); do
        case "$lib" in
            /lib/*|/usr/lib/*) continue ;;
        esac
        cp -Ln "$lib" "$STAGE/lib/" 2>/dev/null || true
    done
    patchelf --set-rpath '$ORIGIN/../lib' "$STAGE/bin/$NAME" 2>/dev/null || true
else
    echo "==> patchelf no está: el tarball usa las bibliotecas del sistema"
fi

# ---- tarball (always) ----------------------------------------------------
echo "==> tar.gz"
tar -czf "$DIST/${NAME}-${VERSION}-linux-x86_64.tar.gz" -C "$DIST" stage
rm -rf "$STAGE"

# ---- .deb ----------------------------------------------------------------
if command -v dpkg-deb >/dev/null 2>&1 || command -v ar >/dev/null 2>&1; then
    echo "==> deb"
    DEBROOT="$DIST/debroot"
    mkdir -p "$DEBROOT/DEBIAN"
    cp -r "$DIST/stage" "$DEBROOT/usr" 2>/dev/null || true
    if [ ! -d "$DEBROOT/usr" ]; then
        mkdir -p "$DEBROOT/usr/bin" "$DEBROOT/usr/share"
        cp "$BUILD/$NAME" "$DEBROOT/usr/bin/"
        cp -r "$ROOT/packaging" "$DEBROOT/usr/share/" 2>/dev/null || true
    fi
    cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Section: audio
Priority: optional
Architecture: amd64
Maintainer: LotsV8pro
Depends: libqt6quick6, libqt6network6, libqt6sql6, libqt6multimedia6, qt6-qpa-plugins, mpv, yt-dlp, python3
Description: Reproductor de música para YouTube Music con karaoke palabra a palabra
 Homepage: https://github.com/LotsV8pro/lotus-tune
EOF
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb --build --root-owner-group "$DEBROOT" "$DIST/${NAME}_${VERSION}_amd64.deb" >/dev/null
    else
        # A .deb is an 'ar' archive with the control data and the files.
        ( cd "$DEBROOT" \
          && echo "2.0" > debian-binary \
          && tar --owner=root --group=root --numeric-owner -czf control.tar.gz DEBIAN \
          && tar --owner=root --group=root --numeric-owner -czf data.tar.gz usr \
          && ar rc "$DIST/${NAME}_${VERSION}_amd64.deb" debian-binary control.tar.gz data.tar.gz \
          && rm -f debian-binary control.tar.gz data.tar.gz )
    fi
    rm -rf "$DEBROOT"
else
    echo "==> dpkg-deb no está: no se genera el .deb"
fi

# ---- AppImage ------------------------------------------------------------
if command -v appimagetool >/dev/null 2>&1; then
    echo "==> AppImage"
    APIDIR="$DIST/AppDir"
    mkdir -p "$APIDIR"
    cp -r "$DIST/stage"/* "$APIDIR/" 2>/dev/null || true
    cp "$ROOT/packaging/icons/$NAME.svg" "$APIDIR/$NAME.svg" 2>/dev/null || true
    cat > "$APIDIR/$NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LotusTune
Exec=$NAME
Icon=$NAME
Categories=AudioVideo;Audio;Player;
Terminal=false
EOF
    ( cd "$APIDIR" && appimagetool --no-appstream . "$DIST/${NAME}-${VERSION}-x86_64.AppImage" >/dev/null )
else
    echo "==> appimagetool no está: no se genera el AppImage"
fi

echo
echo "Listo en $DIST:"
ls -1 "$DIST" | sed 's/^/  /'
