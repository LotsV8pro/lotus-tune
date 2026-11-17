#!/bin/bash
# Script de lanzamiento para Lotus Tune
# Ejecuta la aplicación con las variables de entorno correctas

cd "$(dirname "$0")"

# Detectar el entorno gráfico y usar la plataforma correcta
if command -v hyprland &> /dev/null; then
    echo "Detectado Hyprland (Wayland), ejecutando en Wayland..."
    export QT_QPA_PLATFORM=wayland
    exec "$@"
elif command -v xorg &> /dev/null; then
    echo "Detectado X11, ejecutando en X11..."
    export QT_QPA_PLATFORM=xcb
    exec "$@"
else
    echo "Entorno gráfico no detectado, intentando Wayland..."
    export QT_QPA_PLATFORM=wayland
    exec "$@"
fi
