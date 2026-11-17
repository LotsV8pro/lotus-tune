#!/bin/bash
# Script de lanzamiento para Lotus Tune
# Intenta ejecutar en X11 si Wayland falla

cd "$(dirname "$0")"

# Detectar el entorno gráfico
if command -v hyprland &> /dev/null && [ -n "$WAYLAND_DISPLAY" ]; then
    # Wayland activo - intentar ejecutar en X11 vía Xwayland
    echo "Wayland detectado, intentando ejecutar en X11 vía Xwayland..."
    export QT_QPA_PLATFORM=xcb
    export DISPLAY=:0
    export QT_QPA_PLATFORM_PLUGIN=xcb
    ./lotus-tune "$@"
else
    # Default - intentar con la plataforma disponible
    echo "Iniciando Lotus Tune..."
    if [ -n "$WAYLAND_DISPLAY" ]; then
        export QT_QPA_PLATFORM=wayland
    else
        export QT_QPA_PLATFORM=xcb
        export DISPLAY=:0
    fi
    ./lotus-tune "$@"
fi
