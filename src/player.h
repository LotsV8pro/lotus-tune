#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>

#include <QHash>
#include <QSet>
#include <QVector>

#ifdef Q_OS_ANDROID
#include <QNetworkReply>
#include <QJniEnvironment>
#include <QJniObject>
#include <QRegularExpression>
#include <QUrlQuery>
#endif

// Playback engine: mpv running headless (no video) with a JSON IPC socket.
//
// The app hands mpv watch/permalink URLs; mpv's ytdl hook resolves them
// through yt-dlp (direct audio extraction, no ads, no browser). All state
// needed by the UI (position, duration, pause, volume) is mirrored from
// mpv's property observations.
class Player : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool playing READ playing NOTIFY stateChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY stateChanged)
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY stateChanged)
    Q_PROPERTY(int volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(QString engineStatus READ engineStatus NOTIFY stateChanged)
    // Chosen audio quality: "max" | "alta" | "media" | "baja".
    Q_PROPERTY(QString quality READ quality NOTIFY qualityChanged)
    // Is there (or is there loading) a file in mpv? QML needs it to know
    // whether "play" should start the track restored from the session (not
    // loaded yet) or just toggle the pause of what is already playing.
    Q_PROPERTY(bool hasFile READ hasFile NOTIFY stateChanged)
    // Track requested but whose stream is still being resolved/loaded in
    // mpv (it does not sound yet). It lets the UI show a waiting state.
    Q_PROPERTY(bool loading READ loading NOTIFY stateChanged)
    // Ultimo fallo de reproduccion/descarga, ya en lenguaje humano
    // ("Tu operador ha bloqueado la descarga (403)..."). Vacio = sin error.
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    // Duracion conocida por la interfaz (la que trae la lista de YouTube
    // Music) para pistas que ya estan en cache y no se vuelven a resolver.
    Q_PROPERTY(double hintDuration WRITE setHintDuration)

public:
    explicit Player(QObject *parent = nullptr);
    ~Player() override;

    bool playing() const { return m_playing; }
    bool ready() const { return m_ready; }
    double position() const { return m_position; }
    double duration() const { return m_duration; }
    int volume() const { return m_volume; }
    QString engineStatus() const { return m_status; }
    QString quality() const { return m_quality; }
    // Is there (or is there loading) a file in mpv? It is needed because
    // mpv when idle reports pause=false: without this data a phantom
    // "Playing" would be published on MPRIS as soon as the app starts.
    bool hasFile() const { return m_hasFile; }
    // A track was asked for but does not sound yet (resolving/loading)?
    bool loading() const { return m_loading; }
    QString lastError() const { return m_lastError; }
    // La interfaz avisa de la duracion que conoce antes de cargar.
    void setHintDuration(double secs) { m_hintDur = secs; }
    // URL/page of the current track (for MPRIS' xesam:url). It is a
    // property (not only a method): the QML reads it and it was undefined.
    Q_PROPERTY(QString currentUrl READ currentUrl NOTIFY stateChanged)
    QString currentUrl() const { return m_currentUrl; }

    Q_INVOKABLE void load(const QString &url);
    Q_INVOKABLE void playPause();
    Q_INVOKABLE void stopPlayback();
    Q_INVOKABLE void seek(double seconds);
    Q_INVOKABLE void setVolume(int v);
    // Changes mpv's --ytdl-format selector on the fly (through IPC).
    Q_INVOKABLE void setQuality(const QString &q);
    // Estado del widget de pantalla de inicio y de la notificacion.
    Q_INVOKABLE void updateWidget(const QString &title, const QString &artist,
                                  bool playing, bool shuffle, int repeat,
                                  bool fav, const QString &artUrl,
                                  double position, double duration);
    // Solo la posicion: la tarjeta de medios del sistema y el widget la
    // extrapolan entre refrescos, asi que basta con corregirla cada
    // segundo (no repinta el aviso entero).
    Q_INVOKABLE void syncMediaProgress(double position);
    // Widget de la letra: la linea que se canta ahora y la siguiente. El
    // QML solo lo llama cuando cambia el indice (no en cada frame).
    Q_INVOKABLE void updateLyricsWidget(const QString &line, const QString &next);
    // Pre-resolves the direct stream URL of `url` in the background (yt-dlp
    // --get-url with the same session/cookies as mpv) and caches it, so a
    // later load() gets the already resolved URL and starts almost
    // instantly (Sonora style: no waiting for the resolution inside mpv).
    Q_INVOKABLE void prefetch(const QString &url);
    // Like prefetch(), but with PRIORITY: it is resolved before any list
    // prefetch and, if a background track is being resolved right now, it
    // is dropped to serve this one. It is meant for the hover of a row
    // (the user is about to click that track).
    Q_INVOKABLE void prefetchFront(const QString &url);
    // Drops the PENDING pre-resolutions of the background queue (it does
     // not touch the one in progress nor the priority ones). It is called
     // on a context change (new list, shuffle, another track) so no old
     // resolutions are left blocking the new ones.
    Q_INVOKABLE void clearPrefetch();

#ifdef Q_OS_ANDROID
    // Resolves the direct audio URL of `url` for the DOWNLOADS panel (it is
    // not played). It goes through the same WEB_REMIX + WebView-solver chain
    // as playback, one at a time, and the answer arrives by signal. The URL
    // is normalised (www.youtube.com) so it shares the stream cache with
    // the player.
    Q_INVOKABLE void resolveForDownload(const QString &url);
    // Drops the pending download resolutions (the one in flight is also
    // abandoned when it was requested only for a download).
    Q_INVOKABLE void cancelDownloadResolve();
#endif

    // Normalises the page URL: the music.youtube.com ones take ~1 s more
     // to resolve than the www.youtube.com ones (same video). Always
     // returning the www form makes the resolving faster and shares the
     // cache.
    static QString normalizeUrl(const QString &url);

signals:
    void stateChanged();
    void positionChanged();
    void volumeChanged();
    void qualityChanged();
    // A seek applied by the engine (both the ones the app makes and the
     // ones coming through MPRIS), with the final position in seconds.
     // MPRIS uses it to announce Seeked on the bus once per seek.
    void seeked(double seconds);
    // A track finished on its own (eof) or failed to play (error).
    void endOfFile(bool ok);
    // Cambia el ultimo error mostrable (vacio = se limpia).
    void lastErrorChanged();
    // Accion pedida desde el widget de inicio o la notificacion
    // ("TOGGLE", "NEXT", "PREV", "SHUFFLE", "REPEAT", "FAV").
    void widgetAction(const QString &action);
#ifdef Q_OS_ANDROID
    // Answer to resolveForDownload(): the direct audio URL, or the reason
    // why it could not be resolved.
    void downloadStreamResolved(const QString &url, const QString &direct);
    void downloadStreamFailed(const QString &url, const QString &why);
#endif

private:
    void startMpv();
    void setLastError(const QString &msg);
    QString m_lastError;
    void tryConnect();
    void send(const QJsonObject &cmd);
    void handleLine(const QByteArray &line);
    void emitPosition(bool force);
    // Real implementation of load(): `allowResolve=false` is used when
    // our pre-resolution failed and mpv has to try it on its own.
    void loadImpl(const QString &url, bool allowResolve);
    // Translates m_quality into yt-dlp's "--ytdl-format" selector.
    QString ytdlFormat() const;
    void loadStreamCache();
    void saveStreamCache();

    QProcess m_proc;
    // Forward declaration: prefetch slots are declared below.
    struct ResolveJob;
#ifdef Q_OS_ANDROID
    // On a phone there is no mpv: the audio is played by Qt itself and the
    // stream URL is asked to YouTube Music's internal API (the same one the
    // app already uses for the lyrics).
    class QMediaPlayer *m_androidPlayer = nullptr;
    class QAudioOutput *m_androidAudio = nullptr;
    // Abre un fichero local en el reproductor de Qt midiendo antes su
    // duracion (los MP4 fragmentados de YouTube dan 0:00 si no).
    void androidPlayLocalFile(const QString &path);
    // Fin de pista del reproductor de Qt, con anti-rebote: tras cargar la
    // siguiente el backend sigue entregando posiciones de la anterior y el
    // aviso se repetia (saltaba varias canciones de golpe).
    void androidEndOfTrack(const char *why);
    class QNetworkAccessManager *m_apiNet = nullptr;
    // Asks the API for the direct stream of a YouTube video.
    void resolveWithApi(const QString &url);
    void onApiReply(QNetworkReply *reply, const QString &url);
    // The page (visitor id) and the player build (sts) are needed before
    // the TV player request answers with formats.
    void fetchBootPage(const QString &trackUrl);
    void sendPlayerRequest(const QString &trackUrl);
    void onWatchPageReply(QNetworkReply *reply, const QString &trackUrl);
    void onPlayerJsReply(QNetworkReply *reply, const QUrl &jsUrl,
                         const QString &trackUrl);
    void solveJsWithPlayerJs(const QString &trackUrl);
    void onSolverPoll();
    // Stores a ready stream url, starts the fetch and closes the chain.
    void finishStream(const QString &finalUrl);
    // Challenge state for the solver chain.
    QString m_apTrack, m_apUrl, m_apSig, m_apSp, m_apN;
    // Client tried in the player request (0 = the first of the list). The
    // clients that YouTube accepts change every few weeks: when one stops
    // returning formats the next one is tried on the same chain.
    int m_clientIdx = 0;
    QString m_playerJsId, m_playerJsText;
    // TV bootstrap: the anonymous visitor id (header X-Goog-Visitor-Id,
    // scraped from the watch page once per session) and the signature
    // timestamp (sts) of the TV player build, read from its JS.
    QString m_visitor;
    QString m_sigTs;
    // Track url waiting for the boot to finish (page -> JS -> player).
    QString m_apiPending;
    // One visitor refresh per track when the API rejects the cached one.
    bool m_retriedBoot = false;
    // Preprocessed player text (the solver's own cache): after the first
    // solve the ~2.9 MiB player JS does not get re-parsed per track.
    QString m_preprocessed;
    QString m_preprocessedFor;
    // Vigilante de la cadena de resolucion (Android): si una peticion o el
    // solver JS se quedan colgados, la cadena se abandona para que la
    // siguiente pista pueda resolverse. Sin esto, una sola resolucion
    // fallida dejaba el reproductor sin poder cambiar de cancion.
    QTimer *m_chainTimer = nullptr;
    int m_lastMedium = -1;      // ultimo transporte de red conocido
    void abortChain(const QString &why);
    void waitForStreamAndFetch(const QString &track, int attempt);
    QTimer *m_solverTimer = nullptr;
    int m_solverWait = 0;
    // The input of the solve in flight: a "solver busy" answer re-posts
    // it once the WebView frees up.
    QString m_solverInput;
    // La descarga del audio la hace Java (MediaFetch): HttpsURLConnection
    // es el stack HTTP del sistema (el que usan OkHttp/Media3/Chrome) y el
    // único que los nodos del operador no rechazan con 403.
    QString m_fetching;
    // Pistas cuya descarga esta esperando a que se abra la ventana del
    // preanuncio de YouTube (no se reintentan ni se duplican).
    QSet<QString> m_fetchDeferred;
    QTimer *m_fetchPoll = nullptr;                  // sondeo del descargador
    // Widget de inicio + notificacion: sondeo del buzon de acciones.
    QTimer *m_widgetPoll = nullptr;
    int m_widgetSeq = -1;
    void pollWidgetActions();
    void setBackgroundPlayback(bool on);
    QHash<QString, QString> m_audioLocal;           // track -> local file
    QHash<QString, bool> m_audioPlay;               // track -> play on done
    QHash<QString, int> m_audioTries;               // track -> reintentos
    // Una descarga a la vez: los nodos del operador comparten IP (CGNAT) y
    // varias descargas simultáneas empiezan a devolver 403.
    QList<QPair<QString, QString>> m_audioQueue;    // (track, url) en espera
    void pumpAudioQueue();
    void audioFetchDone(const QString &track, const QString &path, bool ok);
    void pollAudioFetch();
    void startAudioFetch(const QString &track, const QString &streamUrl,
                         bool playNow);
    // True when the preprocessed blob is not readable (the real player
    // JS text must be sent to the solver).
    bool loadPreprocessed();
    void savePreprocessed(const QString &pp);
    // The session of the user (the SAPISID of the cookies), as
    // "SAPISIDHASH ts_digest|cookie string". The hash is bound to the
    // request origin (music vs www give different digests).
    QString sessionCookie() const;
    QString sessionForOrigin(const QString &origin) const;
    // On a phone the prefetch jobs (startResolve) run through the same
    // WEB_REMIX + WebView-solver chain as load(), but they only fill the
    // resolve cache (QMediaPlayer plays nothing). There is just one chain
    // at a time.
    ResolveJob *m_chainJob = nullptr;
    // Pista que el usuario pidio mientras la cadena estaba ocupada con
    // otra: se resuelve en cuanto la actual acabe. Sin esta espera, la
    // peticion nueva clobberaba el estado de la cadena en vuelo y el
    // solver contestaba "busy" -> se abandonaba todo y la pista no sonaba.
    QString m_apWanted;
    // Arranca la cadena para `url` (una sola a la vez; si hay otra en
    // vuelo, la deja apuntada en m_apWanted). `forDownload` marca la cadena
    // como pedida por el panel de descargas (no se reproduce nada).
    void beginChain(const QString &url, bool forDownload = false);
    // Cola de resoluciones pedidas por las descargas (una a la vez y solo
    // cuando el reproductor no esta usando la cadena).
    QStringList m_dlQueue;
    // URL que la cadena en vuelo esta resolviendo PARA UNA DESCARGA ("" si
    // la cadena es de reproduccion).
    QString m_dlChainUrl;
    void startNextDownloadResolve();
    // Cierra la cadena en curso y da paso a la siguiente / a la cola de
    // resoluciones. Todas las salidas (exito, error, timeout) pasan aqui.
    void endChain();
#endif
    class QLocalSocket *m_sock = nullptr;
    QByteArray m_buf;
    QTimer m_connectTimer;
    QTimer m_posFlush;
    QString m_socketPath;
    // Background pre-resolution: a pool of yt-dlp --get-url resolvers and
    // a cache (page url -> direct stream url). Every "slot" has its own
    // process, timer and the URL it is resolving, so the background
    // prefetch ("cooking" streams ahead) advances in parallel without
    // changing the priority semantics of the queues.
    struct ResolveJob {
        QProcess proc;
        // Aborts a pre-resolution that takes forever (e.g. videos that only
         // have HLS and force yt-dlp to solve JS challenges): that way a
         // slow track does not block the rest of the queue (when it is
         // pressed, mpv resolves it on its own).
        QTimer timer;
        // Extra margin already granted to this resolution (it avoids
         // postponing forever).
        bool grace = false;
        QString url;
        // Is this resolution a priority one (hover) or a background one
         // (list)?
        bool front = false;
        qint64 start = 0;
    };
    QVector<ResolveJob *> m_jobs;
    QStringList m_resolveFront;   // priority queue (hover)
    QStringList m_resolveQueue;   // background queue (the next ones of the list)
    QHash<QString, QString> m_resolved;
    // Moment (epoch) when each entry was resolved, for the cache's TTL.
    QHash<QString, qint64> m_resolvedAt;
    // Duration of each track according to YouTube. The fragmented DASH
    // files do not always carry it in the header (WebM has no Duration),
    // so it is kept in the cache: a track that was already resolved shows
    // its real time on any platform.
    QHash<QString, double> m_trackDur;
    // On-disk cache of direct URLs (so an already resolved track sounds
    // instantly even after restarting the app). It expires by TTL.
    QString m_cacheFile;
    QTimer m_cacheSaveTimer;
    bool m_cacheDirty = false;
    // Wraps the entry in the queues (dedup, priority, background cancel).
    void enqueueResolve(const QString &url, bool front, bool urgent = false);
    // Fills the free slots with pending work (front before background).
    void resolveQueue();
    // Takes the next URL to resolve; `front` says which queue it came
     // from. It skips the ones already resolved or in flight in another
     // slot (dedupe).
    QString takeNextResolve(bool &front);
    // Launches an yt-dlp in the given slot to resolve `url`.
    void startResolve(ResolveJob *job, const QString &url, bool front);
    // Is any slot resolving `url` right now?
    bool isResolving(const QString &url) const;
    // Is there a free slot to start another yt-dlp?
    bool hasFreeJob() const;
    // Picks which resolution in progress to drop to serve an urgent one.
    ResolveJob *pickVictim(const QString &url);
    // Callbacks per slot: process end and resolution timeout.
    void onResolveFinished(ResolveJob *job, int code);
    void onResolveTimeout(ResolveJob *job);
    // Number of consecutive retries of the current track (for transient
    // yt-dlp/YouTube failures). It is reset when a different track starts playing.
    int m_retry = 0;
    QString m_pendingUrl;
    // load() asked while our resolver was already working on that same
     // URL: it is postponed until the pre-resolution finishes (it avoids
     // resolving it twice and takes advantage of the hover's head start).
    QString m_pendingLoadUrl;
    QString m_currentUrl;
    QString m_status = QStringLiteral("starting");
    QString m_quality = QStringLiteral("max");  // "max"|"alta"|"media"|"baja"
    bool m_ready = false;
    bool m_playing = false;
    // True from the moment load() hands a file to mpv until it finishes
    // (eof/error), it is stopped or mpv dies.
    bool m_hasFile = false;
    // True from load() until mpv reports a real duration/position.
    bool m_loading = false;
    bool m_posDirty = false;
    double m_position = 0.0;
    double m_duration = 0.0;
    // Android: el reproductor de Qt no siempre avisa del final (algunos
    // backends se paran en silencio). Con estas dos marcas el fin se emite
    // una sola vez, venga de mediaStatusChanged o del respaldo por
    // posicion >= duracion.
    bool m_endFired = false;
    qint64 m_endBlockUntil = 0; // ms epoch: anti-rebote del fin de pista
    qint64 m_mediaDurMs = 0;   // duracion leida del fichero (mvhd/EBML)
    double m_hintDur = 0.0;    // duracion conocida por la interfaz
    int m_volume = 70;
    qint64 m_lastPosEmit = 0;
};
