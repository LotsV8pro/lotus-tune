#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>

#include <QHash>
#include <QVector>

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

private:
    void startMpv();
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
    int m_volume = 70;
    qint64 m_lastPosEmit = 0;
};
