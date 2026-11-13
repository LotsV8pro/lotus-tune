#!/usr/bin/env bash
#  ---------------------------------------------------------------------------
#  lotus-tune: one command installer (Linux)
#
#    curl -fsSL https://raw.githubusercontent.com/LotsV8pro/lotus-tune/master/tools/install.sh -o install.sh
#    bash install.sh
#
#  Options:
#    --prefix PATH   where to install (default ~/.local; the binary ends in
#                    <prefix>/bin and the entries in <prefix>/share/...)
#    --system        install into /usr/local (needs sudo)
#    --no-deps       do not try to install the system dependencies
#    --deps-only     install only the dependencies and exit
#    --no-pull       do not run git pull on a copy that already exists
#    --jobs N        build threads (default: nproc)
#    --fetch         download the GitHub tarball instead of cloning with git
#
#  The folder can be reused: a second run builds incrementally.
#  Environment variables with the same effect: PREFIX and JOBS.
#  ---------------------------------------------------------------------------

set -euo pipefail

REPO_URL="https://github.com/LotsV8pro/lotus-tune"
RAW_URL="https://raw.githubusercontent.com/LotsV8pro/lotus-tune/master/tools/install.sh"
SRC="${LOTUS_TUNE_DIR:-$HOME/.local/src/lotus-tune}"
PREFIX="${PREFIX:-$HOME/.local}"
JOBS="${JOBS:-$(nproc)}"
DO_DEPS=1 DO_PULL=1 CLONE_GIT=1
ARCH_DEPS="base-devel cmake ninja qt6-base qt6-declarative qt6-multimedia mpv yt-dlp"
APTY="cmake ninja-build g++ qt6-base-dev qt6-declarative-dev qt6-multimedia-dev \
      libgl1-mesa-dev libglx-dev libegl1-mesa-dev mpv yt-dlp python3"
DNFY="gcc-c++ cmake ninja-build qt6-qtbase-devel qt6-qtdeclarative-devel \
      qt6-qtmultimedia-devel mesa-libGL-devel mpv yt-dlp python3"

msg()  { printf '\033[1;35m[loto]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[loto] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
sudo_do() {  # sólo pide contraseña si de verdad hay que instalar
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# -- Arguments ---------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)    PREFIX="$2"; shift 2 ;;
        --system)    PREFIX="/usr/local"; shift ;;
        --no-deps)   DO_DEPS=0; shift ;;
        --deps-only) DO_DEPS=1; DEPS_ONLY=1; shift ;;
        --no-pull)   DO_PULL=0; shift ;;
        --jobs)      JOBS="$2"; shift 2 ;;
        --fetch)     CLONE_GIT=0; shift ;;
        -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
        *)           die "opción desconocida: $1 (mira --help)" ;;
    esac
done

# -- Are we already inside a copy of the repo? -------------------------------
if [ -f ./CMakeLists.txt ] && grep -q 'project(lotus-tune' ./CMakeLists.txt 2>/dev/null; then
    SRC="$(pwd)"
    msg "usando la copia existente: $SRC"
    # The copy may be behind the repository, and then the build comes out
    # with week-old code. It is only reported: the folder may hold changes
    # of the user, so it is not pulled or reset here.
    if [ "$DO_PULL" = 1 ] && [ -d "$SRC/.git" ] && command -v git >/dev/null 2>&1; then
        if git -C "$SRC" fetch -q --depth=1 origin master 2>/dev/null; then
            BEHIND="$(git -C "$SRC" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 0)"
            if [ "${BEHIND:-0}" != "0" ]; then
                msg "AVISO: esta copia va $BEHIND commits por detrás de master y se
     compila tal cual. Para traer lo último:  git -C \"$SRC\" pull --ff-only"
            fi
        fi
    fi
elif [ "$CLONE_GIT" = 1 ] && command -v git >/dev/null 2>&1; then
    if [ -d "$SRC" ] && [ "$DO_PULL" = 1 ]; then
        msg "actualizando copia existente en $SRC"
        git -C "$SRC" fetch --depth=1 origin master
        git -C "$SRC" reset --hard FETCH_HEAD
    elif [ ! -d "$SRC" ]; then
        msg "descargando el código en $SRC"
        mkdir -p "$(dirname "$SRC")"
        git clone --depth=1 "$REPO_URL" "$SRC"
    fi
else
    # Without git (or with --fetch): tarball of master
    if [ "$DO_PULL" = 1 ] || [ ! -d "$SRC" ]; then
        msg "descargando tarball del master"
        mkdir -p "$SRC"
        curl -fsSL "$REPO_URL/archive/refs/heads/master.tar.gz" \
            | tar -xz --strip-components=1 -C "$SRC"
    fi
fi
[ -f "$SRC/CMakeLists.txt" ] || die "no hay fuente en $SRC — borra la carpeta y repite"

# -- Dependencies ------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
NEED=""
if ! have cmake || ! have ninja || ! have g++ || ! have mpv || ! have yt-dlp; then
    NEED=1
fi
if [ "${NEED:-0}" = 1 ]; then
    if [ "$DO_DEPS" = 0 ]; then
        die "faltan dependencias y se pidió --no-deps"
    elif [ -t 0 ]; then
        msg "instalando dependencias (puede pedir tu contraseña)…"
        if have pacman;      then sudo_do pacman -S --needed --noconfirm $ARCH_DEPS
        elif have apt-get;   then sudo_do apt-get update; sudo_do apt-get install -y $APTY
        elif have dnf;       then sudo_do dnf install -y $DNFY
        elif have zypper;    then sudo_do zypper install -y $DNFY
        else die "distro no reconocida; instala manualmente: $APTY o $ARCH_DEPS"
        fi
    else
        die "faltan dependencias y no hay terminal para sudo.
Instálalas y vuelve a lanzar (Arch):  sudo pacman -S --needed $ARCH_DEPS
(Debian/Ubuntu):                      sudo apt-get install $APTY
O relanza el instalador en una terminal."
    fi
elif [ "${DEPS_ONLY:-0}" = 1 ]; then
    msg "dependencias completas; nada que hacer"
    exit 0
fi

# -- Build -------------------------------------------------------------------
msg "configurando (Release → $PREFIX)…"
cmake -S "$SRC" -B "$SRC/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
msg "compilando con $JOBS hilos…"
cmake --build "$SRC/build" --parallel "$JOBS"

if [ "${DEPS_ONLY:-0}" = 1 ]; then exit 0; fi

# -- Install -----------------------------------------------------------------
msg "instalando en $PREFIX…"
if [ -w "$PREFIX" ] || [ -w "$(dirname "$PREFIX")" ]; then
    cmake --install "$SRC/build"
else
    sudo_do cmake --install "$SRC/build"
fi

# -- Check and final notice --------------------------------------------------
BIN="$PREFIX/bin/lotus-tune"
[ -x "$BIN" ] || die "la instalación no dejó el binario en $BIN"

# The version is read from the binary itself (--version), not from the dates
# of the files: that is the only way to know which build is installed.
VER="$("$BIN" --version 2>/dev/null | awk '{print $2}')"

# No qt.conf is installed next to the binary: the QML of the app is compiled
# into it under :/LotusTune and the binary adds that root to the engine's
# import path (src/main.cpp). A qt.conf here used to point at the source tree
# of the machine that built it, which is why the .deb only worked there.

# The entry of the menu has to launch THIS binary. With `Exec=lotus-tune` the
# name goes through the PATH and an older copy (a distro package in /usr/bin,
# a binary left in the source tree) can end up being the one that opens. The
# path is written in full.
DESKTOP_DIR="$PREFIX/share/applications"
for desk in "$DESKTOP_DIR/lotus-tune.desktop" "$DESKTOP_DIR/lotustune.desktop"; do
    [ -f "$desk" ] || continue
    sed -i "s|^Exec=.*|Exec=\"$BIN\" %u|" "$desk"
    msg "menú: $(basename "$desk") abre $BIN"
done

# Other copies on the machine: they are the usual reason for the menu opening
# an older build after a rebuild. Reported, never deleted.
OLD=""
for cand in /usr/bin/lotus-tune /usr/local/bin/lotus-tune "$SRC/lotus-tune"; do
    [ -f "$cand" ] || continue
    [ "$(readlink -f "$cand")" = "$(readlink -f "$BIN")" ] && continue
    OLD="$OLD
       $cand"
done
if [ -n "$OLD" ]; then
    msg "AVISO: hay otra copia de la app instalada:$OLD
     el menú ya abre la nueva; esa copia solo se usa si la lanzas a mano."
fi

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) msg "AVISO: añade $PREFIX/bin al PATH para lanzarlo desde una terminal:
     echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
esac
command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
msg "Listo: ${VER:-lotus-tune} instalado en $BIN
     Lanzamiento: «Lotus Tune» en el menú, o directamente: $BIN"
