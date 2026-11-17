# Instrucciones de lanzamiento para Lotus Tune

## Problema conocido
La app se ejecuta correctamente pero la ventana no aparece en Wayland/Hyprland. Esto puede deberse a:
- Actualización de Qt o Hyprland
- Configuración de entorno gráfico
- Problemas con Xwayland

## Soluciones

### Método 1: Ejecutar desde el menú de aplicaciones (recomendado)
```bash
cd /home/lots/lotus-tune
./lotus-tune.sh
```
Este script intentará detectar si Hyprland está corriendo y ajustará el entorno gráfico adecuadamente.

### Método 2: Ejecutar directamente
```bash
cd /home/lots/lotus-tune
./lotus-tune
```

### Método 3: Usar Xwayland (fallback)
```bash
cd /home/lots/lotus-tune
DISPLAY=:0 QT_QPA_PLATFORM=xcb ./lotus-tune
```

## Diagnosticar el problema

### Verificar si Hyprland está corriendo
```bash
hyprctl stats 2>&1 | head -1
```
Si dice `HYPRLAND_INSTANCE_SIGNATURE not set`, Hyprland no está corriendo.

### Verificar la ventana de la app
```bash
xdotool search --name "Lotus Tune" 2>/dev/null && echo "Ventana encontrada" || echo "No hay ventana"
```

### Verificar procesos
```bash
ps aux | grep lotus-tune | grep -v grep
```

### Verificar logs
```bash
cd /home/lots/lotus-tune
./lotus-tune 2>&1 | head -50
```

## Instalación del .desktop en el menú de aplicaciones

Copia el archivo `/home/lots/lotus-tune/lotustune.desktop` a:
```bash
cp /home/lots/lotus-tune/lotustune.desktop ~/.local/share/applications/
chmod +x ~/.local/share/applications/lotustune.desktop
```

## Actualizar Hyprland para mostrar ventanas de Qt

Si la ventana aparece pero no es visible, añade esto a tu configuración de Hyprland:
```
bindle = $super, q, exec, env QT_QPA_PLATFORM=xcb /home/lots/lotus-tune/lotus-tune
```
