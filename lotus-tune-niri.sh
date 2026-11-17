#!/bin/bash
# Script de lanzamiento para Lotus Tune con Niri (Wayland)

cd "$(dirname "$0")"

# Limpiar instancias anteriores
pkill -9 -f "lotus-tune" 2>/dev/null || true
sleep 1

echo "Lanzando Lotus Tune en Wayland..."

# Ejecutar con Wayland (no X11)
unset QT_QPA_PLATFORM
unset DISPLAY
unset WAYLAND_DISPLAY

# Esperar a que Niri detecte la nueva ventana
sleep 2

# Intentar traer la ventana al frente usando niri
if command -v niri-wl-info &> /dev/null; then
    echo "Moviendo ventana..."
    niri-wl-info --move-window 100 50
    niri-wl-info --raise-window
fi

echo "Aplicación iniciada. Espera unos segundos para que la ventana aparezca..."
echo "Si no aparece, intenta: hyprctl dispatch moveactive 100 50"

./lotus-tune
