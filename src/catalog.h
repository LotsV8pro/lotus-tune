#pragma once

#include <QHash>
#include <QObject>
#include <QProcess>
#include <QSet>
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
    // Estado "me gusta" (biblioteca) del usuario. likedReady pasa a true cuando
    // se ha cargado el conjunto (o fallado el intento con sesión); likedRevision
    // sube en cada cambio para que las filas repinten el corazón.
    Q_PROPERTY(bool likedReady READ likedReady NOTIFY likedChanged)
    Q_PROPERTY(int likedRevision READ likedRevision NOTIFY likedChanged)
    Q_PROPERTY(QString loginError READ loginError NOTIFY loginChanged)
    Q_PROPERTY(QString loginUrl READ loginUrl NOTIFY loginChanged)

public:
    explicit Catalog(SourceManager *sources, QObject *parent = nullptr);

    bool busy() const { return m_busy; }
    QString error() const { return m_error; }
    QVariantList results() const { return m_results; }
    QString resultsQuery() const { return m_resultsQuery; }
    QVariantList tracks() const { return m_tracks; }
    QString tracksTitle() const { return m_tracksTitle; }
    QVariantList playlists() const { return m_playlists; }
    QVariantList recent() const { return m_recent; }
    QVariantList ytmLibrary() const { return m_ytmLibrary; }
    bool libraryBusy() const { return m_libraryBusy; }
    QString loginState() const { return m_loginState; }
    QString openPlaylistId() const { return m_openPlaylistId; }
    bool likedReady() const { return m_likedReady; }
    int likedRevision() const { return m_likedRevision; }
    QString loginError() const { return m_loginError; }
    QString loginUrl() const { return m_loginUrl; }

    Q_INVOKABLE void search(const QString &query);
    Q_INVOKABLE void openPlaylist(int savedIndex);
    Q_INVOKABLE void openUrl(const QString &url, const QString &name);
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
    QString m_pendingTitle;
    QString m_currentSource;
    bool m_busy = false;
    QString m_error;
    QVariantList m_results;
    QString m_resultsQuery;
    QVariantList m_tracks;
    QString m_tracksTitle;
    // Caché en memoria de resultados de lista (reabrir es instantáneo). La clave
    // es el destino normalizado (p. ej. "list:<id>"); se limita a 24 entradas.
    QHash<QString, QVariantList> m_playlistCache;
    QHash<QString, QString> m_playlistTitles;
    QList<QString> m_cacheOrder;   // orden FIFO para evacuar la caché
    QString m_pendingKey;          // clave de la carga de lista en curso
    QVariantList m_playlists;
    QVariantList m_recent;
    QVariantList m_ytmLibrary;
    bool m_libraryBusy = false;
    QProcess m_loginProc;      // dedicated: must not disturb m_proc searches
    QProcess m_statusProc;     // one-shot token check at startup
    QProcess m_libraryProc;    // one-shot "mis listas" fetch (ytm_api.py)
    QProcess m_ytmProc;        // one-shot acciones (rate/addpl/rmpl)
    QString m_ytmOkMessage;    // mensaje de éxito asociado a la acción en curso
    QProcess m_plProc;         // one-shot gestión de listas (create/rename/delete/info)
    QString m_plMode;          // cómo interpretar la salida de m_plProc
    QString m_plAddVideo;      // pista a añadir tras crear una lista (o "")
    QProcess m_likedProc;      // one-shot "me gusta" (LM) para el estado de las filas
    QSet<QString> m_likedIds;  // videoIds en "me gusta"
    int m_likedRevision = 0;
    bool m_likedReady = false;
    qint64 m_likedTs = 0;      // marca de la última carga de red (epoch secs)
    // Respaldo a yt-dlp si la vía rápida de playlists (API interna) falla.
    QString m_fastFallback;      // destino yt-dlp pendiente ("" si no aplica)
    QString m_fastFallbackTitle; // título a conservar en el respaldo
    // Playlist abierta por la vía rápida (para el botón "quitar de la lista").
    QString m_openPlaylistId;
    QString m_loginState;
    QString m_loginError;
    QString m_loginUrl;
    QByteArray m_loginBuf;
    bool m_loginCancel = false;
};
