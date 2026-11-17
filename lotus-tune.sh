#!/bin/bash
# Script de lanzamiento para Lotus Tune
# Usa Xwayland para asegurar compatibilidad con Qt/QML

cd "$(dirname "$0")"

# Limpiar instancias anteriores (excluyendo el propio script)
pkill -9 -f "lotus-tune\$" 2>/dev/null || true
sleep 1
rm -f /tmp/runtime-lots/lotus-tune.sock /tmp/runtime-lots/lotus-tune.pid 2>/dev/null

# Ejecutar con Xwayland para asegurar compatibilidad
env DISPLAY=:1 QT_QPA_PLATFORM=xcb ./lotus-tune
