#!/bin/bash
# Script de lanzamiento para Lotus Tune
# Usa Xwayland para asegurar compatibilidad con Qt/QML

cd "$(dirname "$0")"

# Limpiar instancias anteriores (excluyendo el propio script)
pkill -9 -f "lotus-tune\$" 2>/dev/null || true
sleep 1
rm -f /tmp/runtime-lots/lotus-tune.sock /tmp/runtime-lots/lotus-tune.pid 2>/dev/null

# IMPORTANTE: QT_QPA_PLATFORM debe ser 'xcb' para X11/Xwayland
# NO use 'wayland' cuando DISPLAY=:1 (Xwayland)
echo "Lanzando Lotus Tune en X11 vía Xwayland..."
unset QT_QPA_PLATFORM  # Limpiar cualquier configuración previa
unset WAYLAND_DISPLAY  # Evitar conflictos con Wayland

# Configurar el tamaño inicial de ventana para evitar que se abra fuera de pantalla
export QT_QPA_PLATFORM_PLUGIN=xcb
export QT_QPA_PLATFORM=xcb

# Esperar a que la ventana aparezca y moverla a una posición visible
sleep 2

# Intentar mover la ventana usando xdotool
if command -v xdotool &> /dev/null; then
    WINDOW_ID=$(xdotool search --name "Lotus Tune" | awk '{print $1}')
    if [ -n "$WINDOW_ID" ]; then
        echo "Moviendo ventana a posición 100, 50..."
        # Mover ventana
        xdotool windowmove --sync "$WINDOW_ID" 100 50 2>/dev/null || true
        # Traer al frente
        xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null || true
    fi
fi

echo "Aplicación lista. Verifique si la ventana aparece."

# Detectar el entorno gráfico y usar la plataforma correcta
if command -v hyprland &> /dev/null; then
    echo "Detectado Hyprland (Wayland), ejecutando en Wayland..."
    exec QT_QPA_PLATFORM=wayland "$@"
elif command -v xorg &> /dev/null; then
    echo "Detectado X11, ejecutando en X11..."
    exec QT_QPA_PLATFORM=xcb "$@"
else
    echo "Entorno gráfico no detectado, intentando Wayland..."
    exec QT_QPA_PLATFORM=wayland "$@"
fi
