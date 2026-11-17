#!/bin/bash
# Script de lanzamiento para Lotus Tune con logging

cd "$(dirname "$0")"

# Limpiar instancias anteriores
pkill -9 -f "lotus-tune" 2>/dev/null || true
sleep 1

# Configurar logging
export QT_QPA_PLATFORM=wayland
export QT_QPA_PLATFORMTHEME=qt6ct
export QT_STYLE_OVERRIDE=Darkly

# Ejecutar la aplicación y capturar salida
echo "=== Lotus Tune Launch ===" > /tmp/lotus-launch.log
echo "Start time: $(date)" >> /tmp/lotus-launch.log
echo "Display: $DISPLAY" >> /tmp/lotus-launch.log
echo "Wayland: $WAYLAND_DISPLAY" >> /tmp/lotus-launch.log
echo "" >> /tmp/lotus-launch.log

# Ejecutar la aplicación
./lotus-tune 2>&1 | tee -a /tmp/lotus-launch.log

echo "End time: $(date)" >> /tmp/lotus-launch.log
echo "=== End ===" >> /tmp/lotus-launch.log

echo "✅ Aplicación ejecutada. Salida guardada en /tmp/lotus-launch.log"
