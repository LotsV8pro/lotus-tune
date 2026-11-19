# Resolución de problemas

## El teléfono no saca audio o tarda en arrancar la canción

En algunas redes el nodo de vídeo de YouTube (`gvs`) responde `403` a la
descarga de un stream firmado. La app lo reintenta y busca otra versión; si
la red es lenta, el cambio se nota. No es un fallo de la letra ni de la
cola. Comprueba la cobertura y, si persiste, prueba con otra red.

## Una letra aparece pegada («Let uscry»)

La app reconstruye los espacios usando la letra limpia de otra fuente. Si el
proveedor partió una palabra en tres y no hay texto limpio, puede quedar
algún caso suelto. Ajustes > Letras > «Copiar letra» y «Exportar LRC» sirven
para guardar una copia; el editor de la línea (botón lápiz en la letra a
pantalla completa) corrige la frase directamente y la guarda en la caché.

## El fondo no sigue la portada

El fondo se tiñe con la carátula de la pista. En Ajustes > Apariencia puedes
activar o desactivar «Fondo dinámico». Las carátulas en blanco y negro también
se usan; antes se descartaban por parecerse a un marcador de vídeo.

## El widget del escritorio muestra la letra anterior

El widget lee los archivos publicados por la app. Si la canción nueva no
tiene letra, la app publica un estado vacío y el widget limpia la suya. Si
sigue mostrando la anterior, reinicia el shell con `systemctl --user restart
inir.service` (niri no se reinicia).

## La letra se desincroniza

Usa `[` y `]` para mover el desfase ±0,1 s, o los botones de Ajustes > Letras.
El ajuste se guarda por canción. Con `Ctrl+R` se vuelven a consultar las
fuentes sin cambiar de pista.
