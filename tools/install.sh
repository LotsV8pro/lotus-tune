#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lotus-tune — instalador de una sola orden (Linux)
#
#   curl -fsSL https://raw.githubusercontent.com/LotsV8pro/lotus-tune/master/tools/install.sh -o install.sh
#   bash install.sh
#
# Opciones:
#   --prefix RUTA   dónde instalar (por defecto ~/.local; el binario acaba en
#                   <prefix>/bin y los accesos en <prefix>/share/...)
#   --system        instalar en /usr/local (necesita sudo)
#   --no-deps       no intentar instalar las dependencias del sistema
#   --deps-only     instalar solo las dependencias y salir
#   --no-pull       no hacer git pull en una copia que ya existe
#   --jobs N        hilos de compilación (por defecto: nproc)
#   --fetch         descargar el tarball de GitHub en vez de clonar con git
#
# Se puede reusar la carpeta: la segunda ejecución compila incrementalmente.
# Variables de entorno equivalentes: PREFIX y JOBS.
# ---------------------------------------------------------------------------

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

# ── Argumentos ───────────────────────────────────────────────────────────────
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

# ── ¿Estamos ya dentro de una copia del repo? ────────────────────────────────
if [ -f ./CMakeLists.txt ] && grep -q 'project(lotus-tune' ./CMakeLists.txt 2>/dev/null; then
    SRC="$(pwd)"
    msg "usando la copia existente: $SRC"
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
    # Sin git (o --fetch): tarball del master
    if [ "$DO_PULL" = 1 ] || [ ! -d "$SRC" ]; then
        msg "descargando tarball del master"
        mkdir -p "$SRC"
        curl -fsSL "$REPO_URL/archive/refs/heads/master.tar.gz" \
            | tar -xz --strip-components=1 -C "$SRC"
    fi
fi
[ -f "$SRC/CMakeLists.txt" ] || die "no hay fuente en $SRC — borra la carpeta y repite"

# ── Dependencias ─────────────────────────────────────────────────────────────
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

# ── Compilar ────────────────────────────────────────────────────────────────
msg "configurando (Release → $PREFIX)…"
cmake -S "$SRC" -B "$SRC/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
msg "compilando con $JOBS hilos…"
cmake --build "$SRC/build" --parallel "$JOBS"

if [ "${DEPS_ONLY:-0}" = 1 ]; then exit 0; fi

# ── Instalar ────────────────────────────────────────────────────────────────
msg "instalando en $PREFIX…"
if [ -w "$PREFIX" ] || [ -w "$(dirname "$PREFIX")" ]; then
    cmake --install "$SRC/build"
else
    sudo_do cmake --install "$SRC/build"
fi

# ── Comprobación y aviso final ──────────────────────────────────────────────
BIN="$PREFIX/bin/lotus-tune"
[ -x "$BIN" ] || die "la instalación no dejó el binario en $BIN"
msg "instalado: $BIN"
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) msg "AVISO: añade $PREFIX/bin al PATH para lanzarlo desde el menú:
     echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
esac
command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
msg "Listo ✅  Lanzamiento: «lotus-tune» en el menú, o directamente: $BIN
     (la primera vez busca «Lotus Tune» en tu lanzador — Super en Niri)"
