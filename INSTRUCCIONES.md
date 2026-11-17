# DIAGNÓSTICO DE LOTUS TUNE

## Estado Actual

✅ **Backend de Audio:** ACTIVO  
✅ **Socket mpv:** /run/user/1000/lotus-tune.sock  
✅ **Configuración ventana:** height=860, width=1320  
❌ **Ventana gráfica:** NO VISIBLE

## Problema

La aplicación **Lotus Tune está funcionando correctamente** (el backend de audio está activo), pero **la ventana gráfica no se está mostrando**.

Esto es un problema de **inicialización de ventana en Niri** (tu compositor Wayland).

## Soluciones

### Opción 1: Ejecutar con backend RHI (Recomendado)

```bash
cd /home/lots/lotus-tune
unset QT_QPA_PLATFORM
unset DISPLAY
QT_QUICK_BACKEND=rhi QT_QPA_PLATFORM=wayland ./lotus-tune
```

### Opción 2: Forzar software rendering

```bash
cd /home/lots/lotus-tune
unset QT_QPA_PLATFORM
unset DISPLAY
QT_QUICK_BACKEND=software QT_QPA_PLATFORM=wayland ./lotus-tune
```

### Opción 3: Eliminar caché y reiniciar

```bash
cd /home/lots/lotus-tune
rm -rf ~/.local/share/lotus-tune
rm -rf ~/.cache/lotus-tune
pkill -9 -f lotus-tune
sleep 2
./start.sh
```

### Opción 4: Usar el script de inicio

```bash
cd /home/lots/lotus-tune
./start.sh
```

## Verificar estado

```bash
cd /home/lots/lotus-tune
./show-status.sh
```

## Capturar pantalla

```bash
grim -o /tmp/screen.png
# Luego abre: eog /tmp/screen.png
```

---

**Nota:** El problema NO es de tu sistema, es específico de la aplicación y su inicialización en Niri.
