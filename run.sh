#!/bin/bash
# Script de lanzamiento para Lotus Tune

cd "$(dirname "$0")"

# Limpiar instancias anteriores
pkill -9 -f "lotus-tune" 2>/dev/null || true
sleep 1

# Detectar el entorno gráfico
if [ -n "$WAYLAND_DISPLAY" ]; then
    # Estamos en Wayland
    echo "Wayland detected, using native Wayland..."
    export QT_QPA_PLATFORM=wayland
    export QT_QPA_PLATFORM_PLUGIN=
    export DISPLAY=$DISPLAY
else
    # Wayland no está disponible, intentar X11
    echo "Using X11..."
    export QT_QPA_PLATFORM=xcb
    export DISPLAY=:0
    export QT_QPA_PLATFORM_PLUGIN=xcb
fi

# Ejecutar la aplicación
./lotus-tune "$@"
