#!/bin/bash
# Script de inicio definitivo de Lotus Tune

cd "$(dirname "$0")"

echo "=== INICIANDO LOTUS TUNE ==="

# Limpiar instancias
pkill -9 -f "lotus-tune" 2>/dev/null || true
sleep 1

# Limpiar sockets
rm -f /run/user/1000/lotus-tune.sock /tmp/runtime-lots/lotus-tune.sock 2>/dev/null || true

# Iniciar en Wayland
echo "Iniciando en Wayland..."
unset QT_QPA_PLATFORM
unset DISPLAY
QT_QPA_PLATFORM=wayland ./lotus-tune
