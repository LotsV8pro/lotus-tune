#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>

#include <QHash>

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
    // Calidad de audio elegida: "max" | "alta" | "media" | "baja".
    Q_PROPERTY(QString quality READ quality NOTIFY qualityChanged)
    // ¿Hay (o se está cargando) un fichero en mpv? Necesario en QML para saber
    // si el "play" debe arrancar la pista restaurada de la sesión (aún sin
    // cargar) o solo alternar la pausa de lo que ya está sonando.
    Q_PROPERTY(bool hasFile READ hasFile NOTIFY stateChanged)
    // Pista pedida pero cuyo stream aún se está resolviendo/cargando en mpv
    // (todavía no suena). Permite a la UI mostrar un estado de espera.
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
    // ¿Hay (o se está cargando) un fichero en mpv? Necesario porque mpv en
    // idle reporta pause=false: sin este dato se publicaría un "Playing"
    // fantasma en MPRIS nada más arrancar la app.
    bool hasFile() const { return m_hasFile; }
    // ¿Pedida una pista pero aún sin sonar (resolviendo/cargando)?
    bool loading() const { return m_loading; }
    // URL/página del track en curso (para xesam:url de MPRIS).
    QString currentUrl() const { return m_currentUrl; }

    Q_INVOKABLE void load(const QString &url);
    Q_INVOKABLE void playPause();
    Q_INVOKABLE void stopPlayback();
    Q_INVOKABLE void seek(double seconds);
    Q_INVOKABLE void setVolume(int v);
    // Cambia el selector --ytdl-format de mpv en caliente (por IPC).
    Q_INVOKABLE void setQuality(const QString &q);
    // Pre-resuelve la URL directa del stream de `url` en background (yt-dlp
    // --get-url con la misma sesión/cookies que mpv) y la cachea, de modo que
    // un load() posterior reciba la URL ya resuelta y empiece casi al instante
    // (estilo Sonora: sin esperar la resolución dentro de mpv).
    Q_INVOKABLE void prefetch(const QString &url);
    // Igual que prefetch(), pero con PRIORIDAD: se resuelve antes que cualquier
    // prefetch de lista y, si ahora mismo se está resolviendo una pista de
    // fondo, se descarta para atender esta ya. Pensado para el hover de una
    // fila (el usuario está a punto de hacer clic en esa pista).
    Q_INVOKABLE void prefetchFront(const QString &url);

signals:
    void stateChanged();
    void positionChanged();
    void volumeChanged();
    void qualityChanged();
    // Un seek aplicado por el motor (tanto los que hace la propia app como los
    // que llegan por MPRIS), con la posición final en segundos. MPRIS lo usa
    // para anunciar Seeked en el bus una sola vez por seek.
    void seeked(double seconds);
    // A track finished on its own (eof) or failed to play (error).
    void endOfFile(bool ok);

private:
    void startMpv();
    void tryConnect();
    void send(const QJsonObject &cmd);
    void handleLine(const QByteArray &line);
    void emitPosition(bool force);
    // Implementación real de load(): `allowResolve=false` se usa cuando nuestra
    // pre-resolución ha fallado y toca dejar que mpv lo intente por su cuenta.
    void loadImpl(const QString &url, bool allowResolve);
    // Traduce m_quality al selector "--ytdl-format" de yt-dlp.
    QString ytdlFormat() const;
    // Normaliza la URL de página: las de music.youtube.com tardan ~1 s más en
    // resolverse que las de www.youtube.com (mismo vídeo). Devolver siempre la
    // forma www hace que resolver sea más rápido y comparta caché.
    static QString normalizeUrl(const QString &url);
    void loadStreamCache();
    void saveStreamCache();

    QProcess m_proc;
    class QLocalSocket *m_sock = nullptr;
    QByteArray m_buf;
    QTimer m_connectTimer;
    QTimer m_posFlush;
    QString m_socketPath;
    // Pre-resolución en background: proceso yt-dlp --get-url y caché
    // (url de página -> url de stream directa).
    QProcess m_resolver;
    // Aborta una pre-resolución que se eterniza (p. ej. vídeos que sólo tienen
    // HLS y obligan a yt-dlp a resolver retos JS): así una pista lenta no
    // bloquea las demás de la cola (al pulsarla, mpv la resolverá por su cuenta).
    QTimer m_resolveTimer;
    // Margen extra ya concedido a la resolución en curso (evita prorrogar sin fin).
    bool m_resolveGrace = false;
    QString m_resolvingUrl;
    // ¿La resolución en curso es de prioridad (hover) o de fondo (lista)?
    bool m_resolvingFront = false;
    qint64 m_resolveStart = 0;
    QStringList m_resolveFront;   // cola prioritaria (hover)
    QStringList m_resolveQueue;   // cola de fondo (siguientes de la lista)
    QHash<QString, QString> m_resolved;
    // Momento (epoch) en que se resolvió cada entrada, para el TTL de la caché.
    QHash<QString, qint64> m_resolvedAt;
    // Caché en disco de URLs directas (para que una pista ya resuelta suene al
    // instante incluso tras reiniciar la app). Caduca por TTL.
    QString m_cacheFile;
    QTimer m_cacheSaveTimer;
    bool m_cacheDirty = false;
    // Encapsula el alta en las colas (dedup, prioridad, cancelación de fondo).
    void enqueueResolve(const QString &url, bool front, bool urgent = false);
    void resolveQueue();
    // Nº de reintentos seguidos de la pista actual (para fallos transitorios
    // de yt-dlp/YouTube). Se resetea al empezar a sonar una pista distinta.
    int m_retry = 0;
    QString m_pendingUrl;
    // load() pedido mientras nuestro resolver ya trabajaba en esa misma URL:
    // se pospone hasta que la pre-resolución termine (evita resolverla dos
    // veces y aprovecha el adelanto del hover).
    QString m_pendingLoadUrl;
    QString m_currentUrl;
    QString m_status = QStringLiteral("starting");
    QString m_quality = QStringLiteral("max");  // "max"|"alta"|"media"|"baja"
    bool m_ready = false;
    bool m_playing = false;
    // Cierto desde que load() entrega un fichero a mpv hasta que termina
    // (eof/error), se para o mpv muere.
    bool m_hasFile = false;
    // Cierto desde load() hasta que mpv reporta duración/posición reales.
    bool m_loading = false;
    bool m_posDirty = false;
    double m_position = 0.0;
    double m_duration = 0.0;
    int m_volume = 70;
    qint64 m_lastPosEmit = 0;
};
