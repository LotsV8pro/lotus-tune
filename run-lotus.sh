#!/bin/bash
# Script de lanzamiento para Lotus Tune (Niri Wayland)

cd "$(dirname "$0")"

echo "Reiniciando Lotus Tune..."

# Limpiar instancias anteriores
pkill -9 -f "lotus-tune" 2>/dev/null
pkill -9 -f "mpv.*lotus" 2>/dev/null
sleep 2

# Limpiar sockets huérfanos
rm -f /run/user/1000/lotus-tune.sock /tmp/runtime-lots/lotus-tune.sock /tmp/runtime-lots/lotus-tune.pid 2>/dev/null

echo "Lanzando en Wayland (Niri)..."
unset QT_QPA_PLATFORM
unset DISPLAY
QT_QPA_PLATFORM=wayland ./lotus-tune
