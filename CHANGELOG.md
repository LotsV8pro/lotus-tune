# Historial de versiones

Lo que cambia en cada versión, de la más nueva a la más vieja. Los paquetes de
cada una están en https://github.com/LotsV8pro/lotus-tune/releases.

## 2.0.7

La app se puede poner en inglés o en español, y cuando la biblioteca no carga dice por qué en vez de quedarse vacía.

- Ajustes tiene un apartado de idioma: español, inglés o el del sistema. El cambio se aplica al momento, sin reiniciar.
- Los textos propios de Android (nombre de la app, aviso de versión nueva) y los mensajes del actualizador también cambian de idioma.
- Si la petición de tus listas falla, la Biblioteca enseña el motivo: sesión sin iniciar, sesión rechazada por YouTube, ayudante que falta o el error de red concreto.
- Ajustes tiene Copiar diagnóstico, debajo de Actualizaciones. Copia un bloque con la versión, el modelo del teléfono, la versión de Android, el estado de la sesión, si el ayudante está y el último error. En el escritorio, lo mismo con lotus-tune --diagnostics.
- El versionCode y el versionName del APK salen de la versión del proyecto. Antes podían quedarse atrás y Android no dejaba actualizar encima.
- Los paquetes de Linux generan la entrada del menú con la ruta del binario instalado, no con la primera copia que encuentre el PATH.

## 2.0.6 (2026-11-12)

El widget de letra de la pantalla de inicio ya barre al ritmo de la voz, y el cristal deja ver el fondo.

- La parte iluminada de la línea avanza poco a poco en vez de saltar de letra en letra.
- El cristal es más transparente: se ve el fondo y la letra oscura se sigue leyendo por el halo blanco que la rodea.
- Al pasar de una línea a otra la tarjeta no se queda en blanco un instante y el texto no se mueve de sitio.
- La letra queda encajada con el texto al píxel: el barrido empieza y acaba donde empieza y acaba la frase.
- Los paquetes de Linux dicen ya 2.0.6. Antes ponían 2.0.5 aunque el código fuera el nuevo.
- En Android, si vienes de la 2.0.1 o anterior, desinstala una vez antes de instalar: cambió la clave de firma. De la 2.0.2 en adelante se instala encima sin perder nada.

## 2.0.2 (2026-11-12)

La 2.0.1 abría, pero Me gusta no hacía nada: al APK le faltaban tres piezas.

- El APK vuelve a llevar el asistente que habla con YouTube Music. Sin él fallaban al instante Me gusta, la biblioteca, las descargas y marcar el corazón con sesión.
- Lleva también las dos bibliotecas de cifrado que Qt abre en el teléfono en tiempo de ejecución y no empaqueta. Sin ellas no hay HTTPS: ni portadas, ni comprobación de versión, ni asistente.
- El script de Android las descarga y las copia antes de empaquetar, y la revisión final falla si falta alguna, en vez de publicar un APK que arranca vacío.
- La 1.2.24 funcionaba porque se subió desde un build local que tenía esas piezas en la carpeta.
- Si vienes de la 2.0.1, la actualización entra encima. Solo la 2.0.0 pide desinstalar una vez, porque se firmó con otra clave.

## 2.0.1 (2026-11-12)

La 2.0.0 de Android no abría: el APK salía sin las bibliotecas de interfaz de Qt. Esta lo arregla y pone la letra en medio de la pantalla del cine.

- La app ya no se cierra al segundo en el móvil. El APK vuelve a llevar el paquete de interfaz de Qt y el de la propia app.
- Al compilar se comprueba que los dos paquetes están dentro y que el de la app trae de verdad las pantallas, en vez de darlo por hecho.
- En el móvil, el cine en vertical pone la portada arriba, la letra en el centro y el transporte abajo. En el escritorio no cambia nada.
- Todas las builds salen firmadas con la misma clave, así que una versión se instala encima de la anterior sin desinstalar y sin perder la sesión. Si vienes de la 2.0.0 hay que desinstalar una vez: se firmó con otra clave.

## 2.0.0 (2026-11-11)

Windows, Linux y Android en la misma entrega. La letra que escribe la app la usan también los widgets de iNiR.

- Primera vez que sale Windows: un zip con el .exe y las bibliotecas de Qt al lado. Hay que dejar mpv.exe y yt-dlp.exe en esa carpeta o en el PATH.
- Linux sale en .deb, en .rpm y en un .tar.gz que funciona en cualquier distribución.
- Android sale en APK para teléfonos ARM64.
- Un tramo instrumental que la fuente escribe como notas ya no se dibuja como un ♪ suelto: es una racha sin voz con los tres puntos.
- Dos marcas de instrumental seguidas se funden en una sola racha, en vez de dibujar dos filas de puntos para el mismo silencio.
- Los widgets del shell no repiten las notas debajo de los puntos.
- La app publica la letra y la posición en ~/.local/state/lotus-tune/. El servicio de letras de iNiR las lee antes de buscar por su cuenta, así que los widgets y la pantalla de bloqueo usan los mismos tiempos sin una segunda descarga.

## 1.2.24 (2026-11-11)

Si el vídeo marca el mismo silencio dos veces, ahora se ve una sola racha de puntos.

- Dos marcas de instrumental seguidas se dibujan como una racha única, con los tres puntos encendiéndose de principio a fin.
- Los widgets que leen la letra del reproductor ya no enseñan las notas ♪ debajo de los puntos: la racha sin voz es solo puntos, igual que en la app.
- Mientras Lotus Tune reproduce, la letra de los widgets de iNiR y de la pantalla de bloqueo es la misma que la de la app, con los mismos tiempos y sin segunda descarga.

## 1.2.23 (2026-11-11)

Los silencios de la letra ya no se dibujan con notas ♪: son tres puntos que se encienden mientras dura el tramo.

- La racha instrumental usa el tiempo propio de la línea, así que el resto de la letra no se mueve.
- Si Lotus Tune es quien reproduce, los widgets de iNiR enseñan la misma letra que la app. El servicio de letras del shell lee el archivo que publica el reproductor y solo busca por su cuenta cuando ese archivo no es la canción que suena.

## 1.2.22 (2026-11-11)

La letra se puede arrastrar y el cambio de canción ya no la hace bailar.

- La ventana de tres líneas va atada a la fila que cae bajo el centro de la portada, no a la línea que suena. Al arrastrar o con la rueda las líneas entran y salen por esa ventana, así que siempre se lee lo que viene.
- Si el dedo llega mientras la letra se recoloca sola, la animación se para y manda el arrastre.
- La letra vuelve sola a la línea que suena cuatro segundos después de dejar de tocar. Antes eran dos y no daba tiempo a leer una estrofa.
- Cada fila reserva la altura del texto que dibuja. Antes reservaba la de la línea activa y quedaban huecos de un renglón entero.
- Al cambiar de canción la lista vuelve arriba en el mismo frame y los primeros movimientos son saltos, no animaciones.
- El gesto de la barra de reproducción empieza más tarde y pide más recorrido: un clic con pulso tembloroso ya no cambia de pista ni abre el cine.
- El área invisible del arrastre de la barra deja de comer clics de la lista por encima.
- La app no aplica ningún boost: la reproducción arranca al 70 % (unos -3 dB) y por encima del 100 % del deslizador sí suma ganancia.

## 1.2.21 (2026-11-11)

Arregla la sincronía de la letra cuando dos fuentes traen tiempos distintos, y deja la línea que se canta fija en el centro.

- Cuando Apple Music y Musixmatch traen tiempos por palabra, gana Apple Music. El richsync de Musixmatch estiraba palabras dentro de la frase y algunas sonaban casi un segundo y medio después de cantadas.
- La última palabra de una fuente musical ya no se estira hasta la marca de silencio del vídeo.
- El filtro de créditos de la cabecera ya no tira las líneas de una sola palabra con marcas de tiempo, así que vuelven los susurros del principio.
- Las líneas que le faltan a la fuente elegida se completan con las otras ya alineadas, y solo si hay algo a menos de dos segundos.
- En LRCLIB se puntúan todos los resultados y gana el que encaja en duración y trae marcas de silencio.
- La línea que suena queda fijada en el centro de la portada y vuelve sola a su sitio dos segundos después de un arrastre.
- Las líneas de arriba y de abajo son algo más pequeñas y con menos margen, para que destaque la que se canta.
- El corazón de las listas pasa a 30 px, sigue visible con el puntero encima y el clic ya no se lo come la fila.

## 1.2.19 (2026-11-09)

El sonido de silencio que la app dejaba en bucle ya no sigue sonando con la app de fondo. Casi todo el consumo en pausa viene de ahí.

- La app mantiene un silencio en bucle para que el primer clic de la interfaz no se pierda. Ese bucle seguía con la app en segundo plano o en pausa y mantenía despiertos el servidor de audio y el controlador del teléfono.
- Ahora solo funciona con la app delante: al salir se apaga y al volver se enciende. Los sonidos de la interfaz siguen igual de inmediatos.
- Medido en el teléfono, con la app de fondo: en pausa baja de 6,5 % a 1,8 % de un núcleo, y sonando de 15,6 % a 11 %.
- El escritorio no cambia, sigue en 1.2.13.

## 1.2.18 (2026-11-09)

Remate del arreglo de consumo de la 1.2.17: con el panel de letra abierto y la app de fondo, el karaoke seguía animando por dentro.

- La animación de la letra solo corre cuando la letra está en pantalla y la app está delante.
- Medido en el teléfono con la letra cargada y el panel abierto: con la app de fondo, de 66 % a 16,8 % de un núcleo.
- Al volver a la app, la letra retoma el karaoke palabra a palabra donde va la canción, sin saltos.
- Recordatorio de la 1.2.17: la letra ya no se come un núcleo con el panel cerrado, y el APK vuelve a llevar las pantallas buenas.
- El escritorio no cambia, sigue en 1.2.13.

## 1.2.17 (2026-11-09)

La letra deja de comerse un núcleo del teléfono aunque no se esté viendo, y los cambios de interfaz llegan por fin al APK.

- La vista de letra calculaba el karaoke 60 veces por segundo siempre, con el panel cerrado o con la app de fondo, y eso hacía que el móvil se sintiera lento.
- Ahora solo lo hace cuando la letra está en pantalla. Al abrirla se pone al día sola con la línea que toca.
- Medido en el teléfono con la letra cargada y la app de fondo: de 108 % a 15,8 % de un núcleo.
- El APK empaquetaba una copia antigua de las pantallas, así que había cambios que no llegaban a instalarse. Ahora el build copia siempre la versión buena.
- El escritorio no cambia, sigue en 1.2.13.

## 1.2.15 (2026-11-09)

La letra del widget de la pantalla de inicio sale del mismo estado que la app, y el widget ya no se puede dejar enano.

- El widget lee la letra y la posición que publica el reproductor, así que enseña la misma línea que la app en ese instante, con el mismo desfase y los mismos puntos en los tramos instrumentales. Mientras busca, el mismo "Cargando letra…".
- Si lo publicado no es de la canción que suena, se usa lo que empuja la app desde su interfaz. Nunca se mezclan letras de dos canciones.
- La letra del widget ya no depende de que la ventana de la app esté abierta.
- La altura mínima pasa de 60 dp a 180 dp. Con 60 el launcher lo colocaba en dos filas, la cabecera ocupaba todo y la letra salía recortada.
- Si ya lo tienes puesto pequeño, mantén pulsado el widget, elige Ajustar tamaño y estíralo hacia abajo.
- El escritorio no cambia, sigue en 1.2.13.

## 1.2.14 (2026-11-09)

El APK de la 1.2.13 se cerraba al abrirlo. Este lo arregla.

- El paquete de pantallas se guardaba un nivel más adentro de donde la app lo busca, así que no encontraba su propia interfaz y se salía.
- Faltaban los módulos de interfaz de Qt, y el arranque se paraba con "module QtQuick.Window is not installed". Ahora el script de compilación los mete en el APK.
- No era cosa de Android 16: la app arrancaba y moría al no encontrar su interfaz.
- El escritorio no cambia, sigue en 1.2.13, con la letra del cine en tres líneas, el karaoke y los puntos del instrumental.

## 1.2.13 (2026-11-09)

El cine se queda en tres líneas, la letra elige la versión que suena y el .deb vuelve a llevar los asistentes.

- Aviso: el APK de esta versión se cerraba al abrirlo y ya no está publicado aquí. Para Android usa el de la 1.2.14. El escritorio de 1.2.13 funciona bien.
- El cine enseña tres líneas: la anterior, la que se canta y la siguiente. La letra ya no baja hasta la barra de progreso.
- Antes de cantar, la primera frase ya se ve grande y apagada, así se sabe cuál viene.
- La intro instrumental muestra los tres puntos que se encienden poco a poco.
- Si el disco trae una toma acústica o el vídeo es otro corte, se descarta la letra de la versión de estudio y se usa la que coincide con la duración real.
- La última palabra de una frase ya no se queda encendida de más.
- La columna reserva la altura de la línea activa, así que el cambio de línea no reajusta el texto a mitad de camino.
- Las descargas van por secciones, se pueden reanudar y comparten los trozos repetidos sin ocupar dos veces.
- El chequeo de sesión ya no mezcla las cookies de google.com y youtube.com, que decía "sesión caducada" al reiniciar.
- El .deb vuelve a incluir ytm_login.py y ytm_api.py.

## 1.2.12 (2026-11-07)

La portada de un disco abre su lista, el lanzador busca en todas las fuentes y las portadas dejan de quedarse en blanco.

- La portada de un disco abre su lista, en el escritorio y en el móvil, sin reproducir nada. La flecha de atrás vuelve a la página del artista con el scroll donde estaba.
- El lanzador de Ctrl+Espacio busca de verdad: resultados de YouTube Music, SoundCloud, Spotify y Tidal mientras escribes. Si el catálogo está ocupado, la búsqueda espera en vez de perderse. Enter abre la página de Buscar con esa consulta.
- Las portadas se quedaban en blanco y la app se congelaba por una recursión al redondear la imagen. No era la conexión.
- El botón de Inicio responde siempre, también dentro de un disco o de una lista.
- La letra se lee sobre cualquier fondo: tinta clara u oscura según el color medio de la portada, y las líneas secundarias con contraste suficiente.
- En las descargas, la lista usa su propia portada, "Radio de X" muestra la foto del artista, "Reproducir todo" respeta el orden de descarga y el audio va en opus para ocupar lo mínimo.
- El botón de reproducir de las tarjetas pasa abajo a la derecha y es más pequeño.

## 1.2.11 (2026-11-06)

La barra lateral del escritorio pasa a ser una isla flotante y la página de artista pierde el borde de arriba.

- La barra lateral acaba con aire abajo y esquinas redondeadas, en vez de ir pegada al borde y cortada.
- En la página de artista el botón de atrás flota sobre la página y no ocupa sitio en la cabecera. El artista empieza más abajo, al margen.
- En una lista abierta se quita el fundido negro que tapaba la última fila: la lista deja aire al final y el velo de la portada es más suave, en el escritorio y en el móvil.
- Versión 1.2.11 (Android 10211).

## 1.2.10 (2026-11-06)

La página de artista se ordena por secciones y la barra de reproducción se queda siempre a la vista.

- La página de artista va por secciones: canciones, álbumes, singles y EPs, radios y listas, artistas similares.
- "Reproducir todo" sigue el orden real de lanzamiento, con los singles que no están en ningún álbum, y se puede invertir. "Aleatorio" mezcla el catálogo completo.
- La barra de reproducción queda siempre visible como tarjeta flotante sobre las páginas. En el móvil va encima de la barra de pestañas, que ya no desaparece.
- Las portadas en blanco y negro se ven.
- En Buscar, los artistas salen en tarjetas y la búsqueda responde al escribir; Enter busca en todas las fuentes.
- Los accesos rápidos del inicio son solo listas.
- La comprobación de versión busca el archivo de cada plataforma: el .apk en Android, el paquete en Linux y el suyo en Windows.

## 1.2.8 (2026-11-06)

Los artistas de Buscar salen como tarjetas, y la app ya arranca en el escritorio.

- En Buscar, los artistas salen como tarjetas con portada redondeada, nombre y suscriptores: fila horizontal en Canciones y rejilla de tres columnas en Artistas.
- Cada canción muestra su miniatura de 40 px en vez del número de fila.
- Mismo estilo de tarjeta que la Biblioteca.
- Arreglado el arranque del escritorio: la ventana se creaba sin raíz y la app se cerraba sola.
- Ctrl+K abre Buscar con el campo listo. El atajo ya se anunciaba en Inicio.
- En Android, si pausas a mano, pones un vídeo y vuelves, la música ya no se reanuda sola. Solo se reanuda si estaba sonando al perder el foco.

## 1.2.7 (2026-11-05)

El tick de las listas descargadas va en el mismo botón que la descarga, y al pulsarlo pregunta antes de borrar.

- El tick sale en el mismo círculo, en el mismo sitio y con el mismo estilo que la flecha de descarga: solo cambia el icono. Ya no hay un distintivo aparte encima de la carátula.
- Al pulsar el tick se pregunta si desinstalar la descarga de esa lista y se avisa de que se borrarán los archivos. Con Cancelar, la lista sigue descargada y el tick se queda.

## 1.2.6 (2026-11-05)

Los widgets van centrados, las listas descargadas se marcan con un tick y Buscar usa el mismo estilo que una lista.

- En los widgets, la carátula, el título, el artista, los controles y la letra quedan centrados, también cuando ocupan varias líneas.
- Si una lista ya está descargada, su portada lleva un tick en la esquina superior izquierda, sin pasar el ratón ni abrirla. Se reconoce por la dirección de la lista y, si no la tiene, por su nombre.
- Los resultados de Buscar usan el mismo estilo que las filas de una lista: número, título y artista, corazón, duración y menú, también con pulsación larga en el móvil. Se puede deslizar para encolar.
- Versión 1.2.6 (Android 10206).

## 1.2.5 (2026-11-04)

Llega el widget de letra, y la música sigue sonando en segundo plano en los móviles que la silenciaban.

- Widget de letra nuevo: debajo de los controles se ven la línea anterior, la actual y la siguiente.
- Se puede redimensionar libremente. El espacio extra se lo queda la letra.
- Al cambiar de línea hace un fundido corto, sin texto duplicado ni saltos.
- En la intro muestra ♪ y, como siguiente, la primera línea. Mientras busca la letra pone "Cargando letra…" y, si no hay, "Sin letra para esta canción".
- El widget de música lleva barra de progreso y los controles completos: favorito, anterior, play o pausa, siguiente, repetir y aleatorio.
- La app pide el foco de audio. MIUI y HyperOS silenciaban la reproducción en segundo plano por no tenerlo, y de ahí venían los tirones y las paradas.
- El servicio en primer plano ya no se apaga en el hueco entre una pista y la siguiente.
- Si el reproductor dice que suena y la posición deja de avanzar, la app lo reanuda y, si hace falta, recarga la pista en el mismo punto.
- Al terminar una canción pasa sola a la siguiente también en segundo plano.
- La barra de progreso va suave en la app, el widget y la notificación. Aleatorio y repetir llegan a la barra compacta del móvil y a la tarjeta de medios del sistema.

## 1.2.4 (2026-11-04)

La app pide la frecuencia máxima del panel y en MIUI deja de quedarse en 60 Hz.

- Medido en el móvil: 8,3 ms por frame (unos 120 fps), ningún frame por encima de 16,7 ms y una latencia de dedo a frame de 0,1 a 0,3 ms.
- La detección de MIUI miraba una cadena del sistema que en HyperOS 3 ya no aparece, así que todo lo de MIUI estaba muerto sin avisar.
- MIUI ignora la petición de frecuencia de las apps, pero respeta su propio ajuste de refresco. La app lo escribe al arrancar y al volver del segundo plano.
- Para eso hace falta un permiso, una sola vez: adb shell pm grant com.lotustuneremote.app android.permission.WRITE_SECURE_SETTINGS. Sin el permiso la app funciona igual, solo se queda en la frecuencia que le dé el sistema.
- En reposo la app no repinta nada: 0 frames y 0 % de CPU. Los iconos se dibujan una vez y las barritas del ecualizador de la cola solo animan con el panel abierto y sonando.
- Cada portada deja de recalcular su clave por cada imagen que termina de procesarse en cualquier parte de la app.
- Android va por hardware, con el bucle de dibujo de Qt por defecto.
- Fuera el parche que desactivaba la aceleración de la ventana: nunca se ejecutaba y solo podía empeorar el tacto.

## 1.2.3 (2026-11-03)

La app pide 120 Hz al arrancar y deja de repintar cuando no hay nada que mover.

- Al arrancar y al volver del segundo plano pide la frecuencia máxima del panel. Antes nadie la pedía y se quedaba en 60. Medido en un panel de 120 Hz: 8,1 ms por frame, sin frames perdidos.
- En reposo la app consume 0 % de CPU: los iconos se dibujan una vez y las barritas del ecualizador de la cola solo animan con el panel abierto y sonando.
- Cada portada deja de recalcular su clave por cada imagen que termina de procesarse en cualquier parte de la app, así que deslizar va más ligero.
- Android va por hardware. El dibujo por software queda solo para el escritorio.
- En MIUI y HyperOS la petición de 120 Hz no basta: mantiene su propia lista de apps con refresco alto e ignora a la app. Ahí hay que activarlo en Ajustes, Pantalla, Frecuencia de actualización.
- Versión 1.2.3 (Android 10203).

## 1.2.2 (2026-11-03)

El audio suena en el móvil sin depender de Python, la canción empieza antes y las radios traen portada.

- El audio se descarga y se reproduce en local, sin esperar a un proceso externo. Antes, al cancelar una precarga para adelantar una canción, la cola se quedaba a medias y el reproductor en silencio.
- Fuera la espera de siete segundos del preanuncio: la canción suena unos siete u ocho segundos antes.
- Las radios de YouTube Music venían sin miniatura. Ahora se lee esa forma y, si falta, la portada sale del identificador del vídeo, también en las listas ya guardadas.
- La cabecera de una radio ya no enseña el artista de la primera pista como autor: pone "Radio · YouTube Music".
- Inicio no lleva flecha de atrás, porque es el sitio por defecto. La flecha sale en las demás páginas.
- La barra inferior usa la misma isla que la barra lateral del escritorio.
- Ajustes estrena el interruptor de sonidos de interfaz.
- Versión 1.2.2 (Android 10202).

## 1.2.1-android-fix (2026-11-02)

Arreglo del APK para móviles MIUI: el paquete de pantallas estaba corrupto y faltaban módulos de Qt.

- El paquete de recursos de Qt llevaba la cabecera mal, así que Android no lo abría. Ahora se genera con la cabecera buena.
- Faltaban los módulos de interfaz de Qt: Window, Layouts, Dialogs, Core, Quick y QuickControls2. Van dentro del APK.
- Se añade lo necesario para que MIUI extraiga las bibliotecas nativas al instalar.
- El paquete cambia de nombre para saltarse las restricciones de usuario del móvil.

## 1.2.0 (2026-10-24)

La música del móvil ya no depende de Python ni de yt-dlp: la app resuelve el audio por su cuenta.

- La app sigue el mismo camino que yt-dlp para sacar el enlace del audio: pide el formato con tu sesión de YouTube Music, lee el reproductor de YouTube y descifra la firma en el navegador interno del sistema.
- El reproductor de YouTube y su forma ya procesada se guardan en memoria y en disco: la primera pista cuesta un poco, las siguientes van rápidas.
- La precarga de la cola usa el mismo camino, así que la siguiente pista suena al instante si ya está resuelta.
- Sigue haciendo falta tener la sesión de YouTube Music iniciada en la app.
- Los menús, desplegables y el editor de listas ya se leen: antes salía texto negro sobre fondo negro.
- El botón de Inicio queda en el centro exacto de la barra inferior del móvil.
- En el móvil el volumen se deja a los botones físicos. En el escritorio no cambia nada.
- La vista de reproducción se reescribe: carátula arriba en el centro, letra debajo y la barra de controles visible. Se cierra arrastrando hacia abajo o con el botón de atrás.
- Arreglados los cierres al arrancar en Android y un error del informe de MPRIS.

## 1.1.0 (2026-10-24)

Primera entrega con APK: el cine se actualiza con la pista que suena y la app abre desde el menú del escritorio.

- El cine o pantalla completa actualiza la portada, el título y el autor con la pista en curso, y usa la portada en máxima resolución con fundido.
- El fondo del cine es el mismo que el del menú principal y sigue a la pista actual. Nunca queda la portada de otra canción ni el recuadro gris de YouTube.
- La letra se dibuja por líneas, con la de arriba y la de abajo atenuadas y un aviso en los tramos instrumentales.
- La sesión guardada recupera también la portada al arrancar.
- La app abre desde el menú de aplicaciones.
- Cambiar de pista ya no congela la interfaz: la portada se refresca después de pintar.
- Las tarjetas del inicio ya no cambian el fondo de toda la app al sacar su color.
- APK para Android arm64, Android 8 o superior.

## 1.0.1 (2026-10-22)

Reproductor para YouTube Music y SoundCloud con karaoke palabra a palabra, y la letra ya no puede ser de otra canción.

- Karaoke real: los tiempos de cada palabra se alinean con la letra del vídeo.
- El emparejamiento de la letra se comprueba por título, artista y duración, y si falla se busca de otra forma.
- Las palabras ya no se alargan: el tiempo de la línea se reparte por la longitud de cada palabra.
- El APK de Android lleva su propio motor de audio.
- La app busca versiones nuevas en el repositorio, en Ajustes, Actualizaciones.

## 1.0.0-alpha (2026-10-22)

Primera versión con app para Android.

- Catálogo, portadas en alta resolución, letra con karaoke palabra a palabra y un fondo que sigue la portada.
- Todavía no reproduce audio: el motor de escritorio no existe en el móvil y falta su equivalente.
- El menú contextual se abre con el botón derecho en el escritorio; en el móvil falta el equivalente de pulsación larga.
