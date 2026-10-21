#pragma once

#include <QHash>
#include <QObject>
#include <QProcess>
#include <QSet>
#include <QTimer>
#include <QVariantList>

class SourceManager;

// Metadata layer: runs yt-dlp (flat JSON mode) for search and playlists,
// normalises entries into track maps, and persists the user's saved
// playlists + recently played tracks.
//
// Track map:    { title, artist, duration, url, source, thumb }
// Playlist map: { name, url, source, count }
class Catalog : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QVariantList results READ results NOTIFY changed)
    Q_PROPERTY(QString resultsQuery READ resultsQuery NOTIFY changed)
    // Resultados de la búsqueda por TODAS las fuentes: una lista de grupos
    // { id, name, items, locked } — uno por fuente, en el orden del
    // registro (YouTube Music primero). Las fuentes bloqueadas aparecen
    // con locked = true y sin resultados, para que se vea qué falta.
    Q_PROPERTY(QVariantList resultsBySource READ resultsBySource NOTIFY changed)
    // ¿Hay una búsqueda por todas las fuentes en marcha?
    Q_PROPERTY(bool multiSearching READ multiSearching NOTIFY changed)
    Q_PROPERTY(QVariantList tracks READ tracks NOTIFY changed)
    Q_PROPERTY(QString tracksTitle READ tracksTitle NOTIFY changed)
    Q_PROPERTY(QVariantList playlists READ playlists NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList recent READ recent NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList ytmLibrary READ ytmLibrary NOTIFY libraryChanged)
    Q_PROPERTY(bool libraryBusy READ libraryBusy NOTIFY libraryChanged)
    // Real in-app YT Music login ("", "waiting", "ok", "error").
    Q_PROPERTY(QString loginState READ loginState NOTIFY loginChanged)
    // Playlist YouTube Music abierta por la vía rápida: permite "quitar de esta
    // lista" a la pista en reproducción (su setVideoId viaja en cada pista).
    Q_PROPERTY(QString openPlaylistId READ openPlaylistId NOTIFY changed)
    // URL real de la lista abierta (para poder descargarla aunque no sea del
    // usuario o no la conozcamos por id).
    Q_PROPERTY(QString openListUrl READ openListUrl NOTIFY changed)
    // Estado "me gusta" (biblioteca) del usuario. likedReady pasa a true cuando
    // se ha cargado el conjunto (o fallado el intento con sesión); likedRevision
    // sube en cada cambio para que las filas repinten el corazón.
    Q_PROPERTY(bool likedReady READ likedReady NOTIFY likedChanged)
    Q_PROPERTY(int likedRevision READ likedRevision NOTIFY likedChanged)
    Q_PROPERTY(QString loginError READ loginError NOTIFY loginChanged)
    Q_PROPERTY(QString loginUrl READ loginUrl NOTIFY loginChanged)

public:
    explicit Catalog(SourceManager *sources, QObject *parent = nullptr);
    ~Catalog() override;

    bool busy() const { return m_busy; }
    QString error() const { return m_error; }
    QVariantList results() const { return m_results; }
    QString resultsQuery() const { return m_resultsQuery; }
    QVariantList resultsBySource() const { return m_resultsBySource; }
    bool multiSearching() const { return m_multiActive; }
    QVariantList tracks() const { return m_tracks; }
    QString tracksTitle() const { return m_tracksTitle; }
    QVariantList playlists() const { return m_playlists; }
    QVariantList recent() const { return m_recent; }
    QVariantList ytmLibrary() const { return m_ytmLibrary; }
    bool libraryBusy() const { return m_libraryBusy; }
    QString loginState() const { return m_loginState; }
    QString openPlaylistId() const { return m_openPlaylistId; }
    QString openListUrl() const { return m_openListUrl; }
    bool likedReady() const { return m_likedReady; }
    int likedRevision() const { return m_likedRevision; }
    QString loginError() const { return m_loginError; }
    QString loginUrl() const { return m_loginUrl; }

    Q_INVOKABLE void search(const QString &query);
    // Búsqueda en TODAS las fuentes disponibles a la vez: se consulta una
    // tras otra (la búsqueda de cada fuente es un proceso aparte) y los
    // resultados van llegando por grupos, en el orden del registro. Es lo
    // que usan el lanzador (Ctrl+Espacio) y la página Buscar: no hace
    // falta elegir fuente antes de buscar.
    Q_INVOKABLE void searchAll(const QString &query);
    Q_INVOKABLE void openPlaylist(int savedIndex);
    Q_INVOKABLE void openUrl(const QString &url, const QString &name);
    // Autorradio de YouTube Music para un videoId (lo que la propia app pone
    // "a continuación"): resuelve la mix RDAMVM<videoId> con yt-dlp y emite
    // radioReady() con la lista, sin tocar la cola. Se guarda además en la
    // caché de listas, de modo que sirve para precargar la radio con
    // antelación (al pasar el ratón sobre su tarjeta) y abrirla al instante.
    // fetchRadio() pide 80 pistas (autoplay); prefetchRadio() sólo 25, para
    // que la precarga de Inicio termine en ~1,4 s.
    Q_INVOKABLE void fetchRadio(const QString &videoId,
                                const QString &title = QString());
    Q_INVOKABLE void prefetchRadio(const QString &videoId,
                                   const QString &title = QString());
    // ---- Artistas -----------------------------------------------------------
    // Búsqueda de artistas (no canciones): artistsReady() con una lista de
    // { name, browseId, thumb, subtitle }; el acierto principal, primero.
    Q_INVOKABLE void searchArtists(const QString &query);
    // Discografía completa de un artista (álbumes, sencillos, EPs…), del más
    // nuevo primero: artistReady(browseId, albums).
    Q_INVOKABLE void fetchArtist(const QString &browseId);
    // Pistas de un álbum o sencillo: albumTracksReady(browseId, tracks).
    Q_INVOKABLE void fetchAlbumTracks(const QString &browseId);
    // Resuelve la pista principal de un artista para sembrar su radio
    // ("Radio del artista" del menú contextual): emite artistTopTrackResolved.
    Q_INVOKABLE void resolveArtistRadio(const QString &artistName);
    // Vídeo alternativo para una pista cuyo vídeo original ya no está (ver
    // alternateResolved()). Se busca en YT Music descartando el id fallido.
    // `duration` (segundos, 0 si se desconoce) ayuda a afinar la coincidencia.
    Q_INVOKABLE void resolveAlternate(const QString &artist, const QString &title,
                                      const QString &failedVideoId,
                                      double duration);
    Q_INVOKABLE void syncLiked();
    // Vacía la caché en memoria de listas ya cargadas: la próxima apertura de
    // cada una consulta de nuevo la red (útil para "refrescar").
    Q_INVOKABLE void invalidatePlaylistCache();
    // ---- Interacción con YouTube Music (requiere sesión iniciada) ---------
    // rating: "LIKE" | "DISLIKE" | "INDIFFERENT".
    Q_INVOKABLE void rateTrack(const QString &videoId, const QString &rating);
    Q_INVOKABLE void addToPlaylist(const QString &playlistId, const QString &videoId);
    Q_INVOKABLE void removeFromPlaylist(const QString &playlistId,
                                        const QString &videoId,
                                        const QString &setVideoId);
    // Reordena (`delta` ±1) o quita una pista de la lista ABIERTA
    // (m_openPlaylistId): se pinta al instante y se sincroniza con YT Music.
    Q_INVOKABLE void moveOpenPlaylistTrack(const QString &setVideoId, int delta);
    Q_INVOKABLE void removeOpenPlaylistTrack(const QString &videoId,
                                             const QString &setVideoId);
    // ¿La pista está en "me gusta" (biblioteca) según el conjunto cargado?
    Q_INVOKABLE bool isLiked(const QString &videoId) const;
    // Actualiza el conjunto local tras un voto (sin esperar al servidor).
    Q_INVOKABLE void setLiked(const QString &videoId, bool liked);
    // videoId de una URL de YouTube (o el propio id si ya lo es); "" si no aplica.
    Q_INVOKABLE QString videoIdOf(const QString &urlOrId) const;
    // Alterna "me gusta" de una pista (URL o videoId): vota y actualiza el set.
    Q_INVOKABLE void toggleLiked(const QString &videoIdOrUrl, bool currentlyLiked);
    // "Mis listas" de YouTube Music (playlists guardadas/creadas), vía API.
    Q_INVOKABLE void refreshYtmLibrary();
    // ---- gestión de listas propias (crear/editar/borrar) ----------------
    // Crea una lista (privada según `isPrivate`) y, si addVideoId no está
    // vacío, añade ahí esa pista.
    Q_INVOKABLE void createPlaylist(const QString &title, bool isPrivate,
                                    const QString &addVideoId);
    // Renombra y/o cambia la privacidad de una lista propia.
    Q_INVOKABLE void updatePlaylist(const QString &id, const QString &title,
                                    bool isPrivate);
    Q_INVOKABLE void deletePlaylist(const QString &id);
    // Pide título/descripción/privacidad/propiedad de una lista (async).
    Q_INVOKABLE void fetchPlaylistInfo(const QString &id);
    // Abre la ventana de Google integrada (WebKit) para iniciar sesión en YT Music.
    Q_INVOKABLE void loginYTM();
    Q_INVOKABLE void logoutYTM();
    Q_INVOKABLE void addPlaylist(const QString &name, const QString &url);
    Q_INVOKABLE void removePlaylist(int index);
    Q_INVOKABLE void addRecent(const QVariantMap &track);
    Q_INVOKABLE void clearRecent();
    Q_INVOKABLE void dismissError();

signals:
    void changed();
    void libraryChanged();
    // A track list finished loading and should replace the queue.
    void tracksReady(const QVariantList &tracks, const QString &title);
    // Llegó la radio (autoplay) de YouTube Music: `tracks` es lo que sigue tras
    // el videoId semilla, para que la UI amplíe "a continuación".
    void radioReady(const QString &seedVideoId, const QVariantList &tracks);
    // Resultados de la búsqueda de artistas (ver searchArtists()).
    void artistsReady(const QVariantList &artists);
    // Discografía recibida (ver fetchArtist()).
    void artistReady(const QString &browseId, const QVariantList &albums);
    // Pistas de un álbum/sencillo recibidas (ver fetchAlbumTracks()).
    void albumTracksReady(const QString &browseId, const QVariantList &tracks);
    // Resuelta la pista principal de un artista (ver resolveArtistRadio());
    // `track` vacío si no se pudo resolver (la UI cae a la radio de la pista).
    void artistTopTrackResolved(const QString &artistName, const QVariantMap &track);
    // Resuelto el vídeo alternativo para la pista fallida `key` (ver
    // resolveAlternate()); `track` vacío si no lo hubo.
    void alternateResolved(const QString &key, const QVariantMap &track);
    // loginState / loginError / loginUrl changed.
    void loginChanged();
    // Resultado de una interacción YT (votar / añadir / quitar de lista).
    void interactionDone(bool ok, const QString &message);
    // Cambió el conjunto de "me gusta" (cargado o tras un voto).
    void likedChanged();
    // Llegaron los metadatos de una lista (respuesta de fetchPlaylistInfo).
    void playlistInfoReady(const QVariantMap &info);

private:
    void run(const QString &target, const QString &purpose, const QString &title);
    // Punto común de fetchRadio()/prefetchRadio(): sólo cambia el propósito,
    // que es lo que decide el tope de pistas y el tiempo de espera.
    void runRadio(const QString &videoId, const QString &title,
                  const QString &purpose);
    // Lanza `python3 ytm_api.py <args...>` en m_artistProc (búsqueda de
    // artistas, discografía y pistas de álbum). `mode` dice cómo interpretar la
    // salida ("artists" | "artist" | "album") y `arg` es el dato que la UI
    // reconoce en la respuesta. Sólo hay una petición en vuelo: una nueva
    // anula a la anterior (cambiar de artista con su discografía aún llegando).
    void runArtist(const QStringList &args, const QString &mode,
                   const QString &arg);
    // Búsqueda en una fuente concreta ("ytm", "soundcloud"…): usa la vía
    // rápida de YT Music si procede y, si no, yt-dlp con su prefijo.
    void searchInSource(const QString &source, const QString &query);
    // Cadena de la búsqueda por todas las fuentes: siguiente fuente a
    // consultar y volcado de los resultados de la que acaba de terminar.
    void nextMultiSource();
    void absorbMultiResults();
    // Cancela una consulta de fondo en vuelo (radio/autoplay o precarga). Es
    // best-effort, así que pierde siempre frente a una acción del usuario.
    // Devuelve true si había una y se ha cancelado.
    bool cancelBackgroundFetch();
    // Ruta clásica con yt-dlp (usada directamente o como respaldo de la vía
    // rápida de playlists por la API interna de YouTube Music).
    void runYtdlp(const QString &target, const QString &purpose, const QString &title);
    // Shared launcher: arbitrary program (yt-dlp or the ytm_login.py helper)
    // whose stdout is yt-dlp -J shaped and feeds handleOutput().
    void startFetch(const QString &program, const QStringList &args,
                    const QString &purpose, const QString &title);
    // Devuelve true si produjo resultados; false si falló (p. ej. lista vacía).
    bool handleOutput(const QByteArray &json);
    void fail(const QString &message);
    QVariantMap normalize(const QVariantMap &entry) const;
    void loadLibrary();
    void saveLibrary() const;
    static QString stateFile();
    static QString helperPath();
    static QString ytmApiPath();
    static QString cookieFile();
    bool ytmLoggedIn() const;
    void handleLoginOutput();
    void finishLogin(int code);
    void setLoginState(const QString &state);
    // Lanza `python3 ytm_api.py <args...>` en m_ytmProc (interacciones).
    void runYtmAction(const QStringList &args, const QString &okMessage);
    // Lanza `python3 ytm_api.py <args...>` en m_plProc (gestión de listas).
    // `mode` dice cómo interpretar la salida: "info" | "create" | "update" |
    // "delete" (y "createadd", interno).
    void runPlaylistAction(const QStringList &args, const QString &mode);
    // Carga una vez la playlist "Me gusta" (LM) para conocer el estado real de
    // "me gusta" de todas las pistas (estilo Sonora).
    void refreshLikedSet();
    // Lanza el fetch de red del conjunto "me gusta" (sin TTL): lo usa tanto el
    // refresco perezoso como el botón manual syncLiked().
    void launchLikedFetch();

    // ---- caché en memoria de listas --------------------------------------
    // Clave de una lista: normaliza el `list=<id>` de YouTube para que la misma
    // lista abierta por URL, por id o desde "mis listas" comparta entrada.
    static QString cacheKeyFor(const QString &target);
    // Guarda una lista recién cargada (FIFO, máx. 24 entradas).
    void cachePlaylist(const QString &key, const QVariantList &tracks,
                       const QString &title);
    void forgetCachedPlaylist(const QString &key);

    // ---- caché en disco de listas ----------------------------------------
    // Fichero JSON en QStandardPaths::CacheLocation (playlists.json) con las
    // listas ya cargadas y su marca de tiempo: permite reabrir cualquier lista
    // (una radio incluida) al instante aunque la app se haya reiniciado.
    static QString playlistsFile();
    // Lee el fichero al arrancar y siembra la caché en memoria (las más
    // recientes), sin marcarlo sucio.
    void loadPlaylistCache();
    // Volcado diferido de la caché a disco (destino del QTimer single-shot).
    void savePlaylistCache();
    // Sirve una lista desde el fichero (si no está caducada) cuando no está en
    // memoria; la vía rápida la usa como último recurso antes de la red.
    bool cachedPlaylistFromDisk(const QString &key, QVariantList *tracks,
                                QString *title) const;
    // Marca la entrada como recién cargada (marca de tiempo) y programa el
    // volcado diferido a disco.
    void rememberPlaylistForDisk(const QString &key);

    // ---- persistencia del conjunto "me gusta" ----------------------------
    // Fichero JSON junto al estado de la biblioteca (library.json).
    static QString likedFile();
    // Carga el conjunto desde disco; devuelve false si no hay caché válida.
    bool loadLikedFromDisk();
    // Guarda el conjunto actual (con la marca de tiempo m_likedTs).
    void saveLikedToDisk() const;

    SourceManager *m_sources;
    QProcess m_proc;
    QString m_purpose;
    QString m_radioSeed;   // videoId semilla de la radio en curso
    // El usuario abrió a mano una lista que ya se estaba trayendo en segundo
    // plano (precarga de una radio al pasar el ratón): el resultado en vuelo se
    // sirve además como lista abierta, sin volver a descargarlo.
    bool m_promotePending = false;
    // Un proceso best-effort (radio) anulado al ceder el paso a otra petición:
    // su finished() posterior se ignora en lugar de informar un fallo.
    bool m_killed = false;
    QString m_pendingTitle;
    QString m_currentSource;
    bool m_busy = false;
    QString m_error;
    QVariantList m_results;
    QString m_resultsQuery;
    // Búsqueda por todas las fuentes: los grupos van llenándose uno a uno
    // (cada fuente es una consulta) y se emiten al terminar cada una.
    QVariantList m_resultsBySource;
    QStringList m_multiQueue;       // ids de las fuentes que faltan
    QString m_multiCurrent;         // id de la fuente que se está consultando
    QString m_multiQuery;
    bool m_multiActive = false;
    QVariantList m_tracks;
    QString m_tracksTitle;
    // Caché en memoria de resultados de lista (reabrir es instantáneo). La clave
    // es el destino normalizado (p. ej. "list:<id>"); se limita a 24 entradas.
    QHash<QString, QVariantList> m_playlistCache;
    QHash<QString, QString> m_playlistTitles;
    QList<QString> m_cacheOrder;   // orden FIFO para evacuar la caché
    QString m_pendingKey;          // clave de la carga de lista en curso
    // Marca de tiempo (epoch secs) de cada entrada de la caché, para el TTL del
    // fichero en disco (playlists.json).
    QHash<QString, qint64> m_playlistCacheAt;
    // Claves descartadas (ediciones/reordenados) que hay que borrar del fichero
    // en el próximo volcado: sin esto, reabrir la lista la traería vieja.
    QSet<QString> m_cacheForgotten;
    QTimer m_cacheSaveTimer;       // volcado diferido de la caché a disco
    bool m_cacheDirty = false;     // ¿hay cambios pendientes de guardar?
    QVariantList m_playlists;
    QVariantList m_recent;
    QVariantList m_ytmLibrary;
    bool m_libraryBusy = false;
    QProcess m_loginProc;      // dedicated: must not disturb m_proc searches
    QProcess m_statusProc;     // one-shot token check at startup
    QProcess m_libraryProc;    // one-shot "mis listas" fetch (ytm_api.py)
    QProcess m_artistProc;     // one-shot artistas/discografía/álbumes (ytm_api.py)
    QString m_artistMode;      // "artists" | "artist" | "album" | "toptrack" (vacío: anulada)
    QString m_artistArg;       // dato que se devuelve en la señal
    QVariantMap m_topTrack;    // pista principal resuelta (radio del artista)
    // Vídeo alternativo para una pista cuyo vídeo murió: proceso propio para no
    // pisar la navegación de artistas que esté en vuelo.
    QProcess m_altProc;
    QString m_altKey;          // videoId fallido que se está reintentando
    QProcess m_ytmProc;        // one-shot acciones (rate/addpl/rmpl)
    QString m_ytmOkMessage;    // mensaje de éxito asociado a la acción en curso
    QProcess m_plProc;         // one-shot gestión de listas (create/rename/delete/info)
    QString m_plMode;          // cómo interpretar la salida de m_plProc
    QString m_plAddVideo;      // pista a añadir tras crear una lista (o "")
    QString m_plSetId;         // setVideoId pendiente (quitar de una lista)
    QProcess m_likedProc;      // one-shot "me gusta" (LM) para el estado de las filas
    QSet<QString> m_likedIds;  // videoIds en "me gusta"
    // Ruta local (fichero descargado) -> videoId de YouTube, resuelto una sola
    // vez leyendo el .info.json hermano. Permite dar "me gusta" a las pistas
    // locales como si fueran de YouTube (mismo videoId, misma sincronización).
    mutable QHash<QString, QString> m_localIdCache;
    int m_likedRevision = 0;
    bool m_likedReady = false;
    qint64 m_likedTs = 0;      // marca de la última carga de red (epoch secs)
    // Respaldo a yt-dlp si la vía rápida de playlists (API interna) falla.
    QString m_fastFallback;      // destino yt-dlp pendiente ("" si no aplica)
    QString m_fastFallbackTitle; // título a conservar en el respaldo
    // Playlist abierta por la vía rápida (para el botón "quitar de la lista").
    QString m_openPlaylistId;
    QString m_openListUrl;
    QString m_loginState;
    QString m_loginError;
    QString m_loginUrl;
    QByteArray m_loginBuf;
    bool m_loginCancel = false;
};
