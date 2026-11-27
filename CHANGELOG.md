# Historial de versiones

Lo que cambia en la version mas reciente. Los paquetes estan en
https://github.com/LotsV8pro/lotus-tune/releases.

## 2.3.2 (2026-11-27)

### Letras y sincronía

Correcciones encontradas revisando la biblioteca cancion por cancion.

- Palabras pegadas: se separan ylos, inits, thisdream, hevisto, lasiesta y decache, entre otras. La reparacion llega tambien a los tiempos de palabra.
- Acentos: la union de fragmentos usa letras Unicode, asi que ya no vuelve a pegar "de cache" ni "en La Sexta".
- Corchetes: se limpia el corchete suelto al principio de las lineas.
- Frases repetidas: se conservan las repeticiones reales separadas mas de 2 s; antes se fusionaban como duplicados.
- Instrumentales: los marcadores tienen tres puntos con tiempos propios y duracion correcta, incluso cuando el proveedor daba un fin menor que el inicio.
- Stamps cortos: las palabras de menos de 20 ms se estiran cuando hay hueco. Las frases comprimidas por el proveedor se acercan a la duracion media de la cancion.
- Sincronía: wordCheck aplica el desplazamiento activo antes de comparar, y los ajustes por cancion se leen con pasos de 50 ms.
- Cache negativa: el reintento de "sin letra" solo se gasta cuando se conoce la duracion real.
- Titulos: un parentesis al principio del nombre, como en (D)eath, ya no se elimina como ruido de marketing.

### Arranque e interfaz

- El arranque en frio ya no lanza cuatro resoluciones de radio a la vez: calienta solo la cancion actual y lo difiere hasta que la ventana esta pintada.
- La caratula del mini usa la cascada de imagenes con el id del video y prueba primero la variante pequena, que responde antes.
- El timeout de descarga de caratulas baja de 4 s a 2,5 s para que una URL lenta no deje el hueco vacio.
- Las opciones de la pantalla completa se abren con pulsacion larga en el telefono: caratula y titulo dan el menu de la pista, el artista abre su pagina.

### Android

- Al desconectar los cascos o el Bluetooth se pausa la musica mediante el aviso del sistema, y no se reanuda sola despues.
- El watchdog ya no termina la cancion cuatro segundos antes: exige el estado real de fin y, si la posicion se congela, fuerza un pequeno retroceso para reconstruir el buffer.
- Cambiar de cancion ya no borra la cola de precarga que se acaba de llenar.

### Windows y Linux

- Sin cambios especificos de plataforma en esta tanda: todo son ramas compartidas.
