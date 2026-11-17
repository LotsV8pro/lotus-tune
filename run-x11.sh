#!/bin/bash
# Script para ejecutar Lotus Tune con X11 backend
# Esto es necesario porque Wayland no muestra la ventana correctamente

cd "$(dirname "$0")"

# Verificar si ya hay una instancia
if [ -e "/tmp/runtime-lots/lotus-tune.sock" ]; then
    # Intentar levantar la ventana
    xdotool search --name "Lotus Tune" window --only-one 2>/dev/null | xdotool windowraise 2>/dev/null
    exit 0
fi

# Ejecutar en X11
env DISPLAY=:0 QT_QPA_PLATFORM=xcb ./lotus-tune
