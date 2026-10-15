#include "player.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QStandardPaths>

#include <QDebug>

#include <csignal>
#ifdef Q_OS_LINUX
#  include <sys/prctl.h>
#endif

Player::Player(QObject *parent)
    : QObject(parent)
{
    m_connectTimer.setInterval(250);
    connect(&m_connectTimer, &QTimer::timeout, this, &Player::tryConnect);

    m_posFlush.setSingleShot(true);
    m_posFlush.setInterval(240);
    connect(&m_posFlush, &QTimer::timeout, this, [this] { emitPosition(true); });

    // Tope de tiempo por pre-resolución: red de seguridad ante un yt-dlp colgado
    // (no ante una resolución normal, que tarda ~2.5 s). Si aún así un load()
    // está esperando esta pista, no se abandona a mpv (su resolución interna es
    // bastante más lenta): se concede un único margen extra antes de matarla.
    m_resolveTimer.setSingleShot(true);
    m_resolveTimer.setInterval(12000);
    connect(&m_resolveTimer, &QTimer::timeout, this, [this] {
        if (m_resolver.state() == QProcess::NotRunning)
            return;
        if (!m_resolveGrace && !m_pendingLoadUrl.isEmpty()
                && m_pendingLoadUrl == m_resolvingUrl) {
            m_resolveGrace = true;
            m_resolveTimer.start(20000);
            return;
        }
        m_resolver.kill();   // finished() limpia el estado y sigue con la cola
    });

    m_resolver.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_resolver, &QProcess::finished, this, [this](int code, QProcess::ExitStatus) {
        m_resolveTimer.stop();
        m_resolveGrace = false;
        const QString url = m_resolvingUrl;
        m_resolvingUrl.clear();
        m_resolvingFront = false;
        if (code == 0) {
            const QByteArray out = m_resolver.readAllStandardOutput().trimmed();
            const QList<QByteArray> lines = out.split('\n');
            for (const QByteArray &l : lines) {
                const QString s = QString::fromUtf8(l).trimmed();
                if (s.startsWith(QLatin1String("http"))) {
                    m_resolved.insert(url, s);
                    qInfo() << "[player] pre-resuelta" << url << "->" << s.left(60) << "...";
                    break;
                }
            }
        }
        // Un load() que estaba esperando a esta misma pista: ya hay URL directa
        // (o, si la resolución falló, cae a que mpv la resuelva por su cuenta).
        if (!url.isEmpty() && m_pendingLoadUrl == url) {
            m_pendingLoadUrl.clear();
            load(url);
        }
        resolveQueue();
    });

    startMpv();
    m_connectTimer.start();
}

Player::~Player()
{
    if (m_sock && m_sock->state() == QLocalSocket::ConnectedState) {
        m_sock->write(QJsonDocument(QJsonObject{{QStringLiteral("command"),
                                                QJsonArray{QStringLiteral("quit")}}})
                          .toJson(QJsonDocument::Compact)
                      + '\n');
        m_sock->waitForBytesWritten(300);
    }
    if (m_proc.state() != QProcess::NotRunning) {
        m_proc.waitForFinished(700);
        if (m_proc.state() != QProcess::NotRunning)
            m_proc.kill();
    }
}

void Player::startMpv()
{
    QString sock = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (sock.isEmpty())
        sock = QDir::tempPath();
    m_socketPath = sock + QStringLiteral("/lotus-tune.sock");
    QFile::remove(m_socketPath);

    m_proc.setProgram(QStringLiteral("mpv"));
    // Argumentos "frugales": sin ventana, vídeo, OSD/OSC ni subtítulos, y con
    // las cachés del demuxer al mínimo para recortar el uso de RAM. El audio
    // NO se recodifica: no se fuerza --audio-format ni --audio-channels, así
    // que se reproduce el stream original de yt-dlp a máxima fidelidad.
    // Nota: --ao se omite a propósito para que mpv elija la salida disponible.
    QStringList args{
        QStringLiteral("--no-config"),
        QStringLiteral("--no-video"),
        QStringLiteral("--video=no"),        // alias de --vid=no (sin pista de vídeo)
        QStringLiteral("--vo=null"),         // sin salida de vídeo ni ventana
        QStringLiteral("--no-terminal"),
        QStringLiteral("--really-quiet"),
        QStringLiteral("--idle=yes"),
        QStringLiteral("--force-window=no"),
        QStringLiteral("--no-osc"),          // sin controller en pantalla
        QStringLiteral("--osc=no"),          // equivalente a --no-osc (por si acaso)
        QStringLiteral("--no-osd-bar"),
        // --no-stats ya no existe en mpv >= 0.38; este es su equivalente actual.
        QStringLiteral("--load-stats-overlay=no"),
        QStringLiteral("--input-ipc-server=") + m_socketPath,
        QStringLiteral("--no-input-default-bindings"),
        QStringLiteral("--no-input-vo-keyboard"),
        QStringLiteral("--ytdl-format=") + ytdlFormat(),
        QStringLiteral("--audio-client-name=Lotus Tune"),
        QStringLiteral("--volume=%1").arg(m_volume),
        QStringLiteral("--gapless-audio=yes"),
        QStringLiteral("--no-sub"),
        QStringLiteral("--audio-display=no"),  // no incrustar carátulas
        QStringLiteral("--cache=no"),          // sin caché de red en disco/memoria
        QStringLiteral("--demuxer-max-bytes=3MiB"),
        QStringLiteral("--demuxer-max-back-bytes=1MiB"),
        QStringLiteral("--demuxer-readahead-secs=10"),
    };
    // Si hay sesión de YouTube Music, yt-dlp reproduce con las cookies: así se
    // resuelven pistas restringidas, "Música que me gusta" y playlists privadas.
    const QString cookies =
        QDir::homePath() + QStringLiteral("/.config/lotus-tune/cookies.txt");
    if (QFile::exists(cookies))
        args << QStringLiteral("--ytdl-raw-options=cookies=") + cookies
             << QStringLiteral("--ytdl-raw-options-append=no-warnings=")
             // Cliente de extracción que evita los 403 "no audio or video data
             // played" que YouTube devuelve hoy con el cliente por defecto.
             // Requiere cookies (cliente autenticado).
             << QStringLiteral(
                    "--ytdl-raw-options-append=extractor-args=youtube:player_client=web_creator");
    m_proc.setArguments(args);
    connect(&m_proc, &QProcess::readyReadStandardError, this, [this] {
        const QByteArray err = m_proc.readAllStandardError();
        if (!err.trimmed().isEmpty())
            qWarning() << "[mpv]" << err.trimmed();
    });
    connect(&m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int code, QProcess::ExitStatus) {
                qWarning() << "[player] mpv exited with code" << code;
                m_ready = false;
                m_playing = false;
                m_hasFile = false;
                m_loading = false;
                m_status = QStringLiteral("mpv died");
                m_connectTimer.stop();
                emit stateChanged();
            });
    // Si la app muere (incluso con SIGKILL), mpv recibe SIGTERM y no queda como
    // proceso huérfano bloqueando el socket IPC.
    m_proc.setChildProcessModifier([] {
#ifdef Q_OS_LINUX
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
#endif
    });
    // Limpia un socket residual de una ejecución anterior antes de arrancar.
    QFile::remove(m_socketPath);
    m_proc.start();
    if (!m_proc.waitForStarted(3000))
        qWarning() << "[player] failed to start mpv";
}

void Player::tryConnect()
{
    if (m_proc.state() != QProcess::Running)
        return;
    if (m_ready)
        return;
    if (!m_sock) {
        m_sock = new QLocalSocket(this);
        connect(m_sock, &QLocalSocket::connected, this, [this] {
            qInfo() << "[player] mpv IPC connected";
            m_ready = true;
            m_status = QStringLiteral("ready");
            m_connectTimer.stop();
            static const char *const props[] = {"", "pause", "duration", "media-title",
                                                "time-pos", "volume"};
            for (int id = 1; id <= 5; ++id) {
                send({{QStringLiteral("command"),
                       QJsonArray{QStringLiteral("observe_property"), id,
                                  QString::fromLatin1(props[id])}}});
            }
            if (!m_pendingUrl.isEmpty()) {
                const QString url = m_pendingUrl;
                m_pendingUrl.clear();
                load(url);
            }
            emit stateChanged();
        });
        connect(m_sock, &QLocalSocket::readyRead, this, [this] {
            m_buf += m_sock->readAll();
            int nl;
            while ((nl = m_buf.indexOf('\n')) >= 0) {
                const QByteArray line = m_buf.left(nl);
                m_buf.remove(0, nl + 1);
                if (!line.trimmed().isEmpty())
                    handleLine(line);
            }
        });
        connect(m_sock, &QLocalSocket::errorOccurred, this,
                [this](QLocalSocket::LocalSocketError) {
                    if (!m_ready)
                        qInfo() << "[player] ipc not up yet:" << m_sock->errorString();
                });
    }
    m_sock->connectToServer(m_socketPath);
}

void Player::send(const QJsonObject &cmd)
{
    if (!m_sock || m_sock->state() != QLocalSocket::ConnectedState)
        return;
    m_sock->write(QJsonDocument(cmd).toJson(QJsonDocument::Compact) + '\n');
}

void Player::handleLine(const QByteArray &line)
{
    const QJsonObject o = QJsonDocument::fromJson(line).object();
    const QString ev = o.value(QStringLiteral("event")).toString();

    if (ev == QLatin1String("property-change")) {
        const QString name = o.value(QStringLiteral("name")).toString();
        const QJsonValue data = o.value(QStringLiteral("data"));
        if (name == QLatin1String("pause")) {
            // mpv reporta pause=false también en idle (sin fichero): sin el
            // guard de m_hasFile la app creería estar reproduciendo nada más
            // arrancar y publicaría un "Playing" fantasma en MPRIS.
            m_playing = m_hasFile && !data.toBool(true);
            emit stateChanged();
        } else if (name == QLatin1String("duration")) {
            const double d = data.toDouble();
            // Si hay un load() esperando a la pre-resolución, mpv sigue con la
            // pista anterior: sus eventos no deben dar por terminada la espera.
            if (d > 0.0 && m_loading && m_pendingLoadUrl.isEmpty()) {
                m_loading = false;   // ya hay stream: termina la espera
                emit stateChanged();
            }
            if (qAbs(d - m_duration) > 0.25) {
                m_duration = d;
                emit stateChanged();
            }
        } else if (name == QLatin1String("time-pos")) {
            if (data.isDouble()) {
                m_position = data.toDouble();
                if (m_position > 0.0 && m_loading && m_pendingLoadUrl.isEmpty()) {
                    m_loading = false;
                    emit stateChanged();
                }
                emitPosition(false);
            }
        } else if (name == QLatin1String("volume")) {
            const int v = int(data.toDouble());
            if (v != m_volume) {
                m_volume = v;
                emit volumeChanged();
            }
        }
        return;
    }

    if (ev == QLatin1String("end-file")) {
        const QString reason = o.value(QStringLiteral("reason")).toString();
        if (reason == QLatin1String("eof")) {
            m_hasFile = false;
            m_loading = false;
            m_position = 0;
            emit positionChanged();
            emit endOfFile(true);
        } else if (reason == QLatin1String("error")) {
            m_hasFile = false;
            m_loading = false;
            qWarning() << "[player] playback error" << "url=" << m_currentUrl
                       << "err=" << o.value(QStringLiteral("error")).toString()
                       << "file=" << o.value(QStringLiteral("file_error")).toString();
            // Fallo transitorio típico de YouTube/yt-dlp (rate-limit o token):
            // reintenta la misma pista un par de veces antes de darla por perdida.
            if (m_retry < 2 && !m_currentUrl.isEmpty()) {
                ++m_retry;
                const QString url = m_currentUrl;
                qWarning() << "[player] reintento" << m_retry << "de" << url;
                QTimer::singleShot(900 * m_retry, this, [this, url] {
                    if (m_currentUrl == url)
                        load(url);
                });
            } else {
                emit endOfFile(false);
            }
        }
        return;
    }

    if (ev == QLatin1String("shutdown")) {
        m_ready = false;
        m_hasFile = false;
        m_loading = false;
        m_status = QStringLiteral("mpv shutdown");
        emit stateChanged();
    }
}

void Player::emitPosition(bool force)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (!force) {
        if (now - m_lastPosEmit >= 240) {
            m_lastPosEmit = now;
            m_posDirty = false;
            m_posFlush.stop();
            emit positionChanged();
        } else {
            m_posDirty = true;
            if (!m_posFlush.isActive())
                m_posFlush.start();
        }
        return;
    }
    if (m_posDirty || force) {
        m_lastPosEmit = QDateTime::currentMSecsSinceEpoch();
        m_posDirty = false;
        m_posFlush.stop();
        emit positionChanged();
    }
}

void Player::load(const QString &url)
{
    if (url.isEmpty())
        return;
    // Una pista nueva (distinta de la actual) reinicia el contador de
    // reintentos; un reintento de la misma pista lo conserva.
    if (url != m_currentUrl)
        m_retry = 0;
    if (!m_ready) {
        m_pendingUrl = url;
        return;
    }
    // Nuestro resolver ya está trabajando en esta misma pista (hover): mejor
    // esperar a que acabe que dejar que mpv la resuelva otra vez. La UI se
    // actualiza ya (parece que arranca) y el loadfile sale al terminar.
    if (!m_resolved.contains(url) && url == m_resolvingUrl) {
        m_pendingLoadUrl = url;
        m_position = 0;
        m_duration = 0;
        m_currentUrl = url;
        m_hasFile = true;
        m_loading = true;
        m_playing = true;
        emit positionChanged();
        emit stateChanged();
        return;
    }
    m_pendingLoadUrl.clear();
    m_position = 0;
    m_duration = 0;
    m_currentUrl = url;
    m_hasFile = true;
    m_loading = true;
    qInfo() << "[player] load" << url;
    emit positionChanged();
    emit stateChanged();
    // Si el pre-resolver ya tiene la URL directa del stream, mpv arranca sin
    // esperar a yt-dlp dentro de su propio hook (≈instantáneo estilo Sonora).
    const QString direct = m_resolved.take(url);
    send({{QStringLiteral("command"),
           QJsonArray{QStringLiteral("loadfile"), direct.isEmpty() ? url : direct,
                      QStringLiteral("replace")}}});
    send({{QStringLiteral("command"),
           QJsonArray{QStringLiteral("set"), QStringLiteral("pause"), QStringLiteral("no")}}});
    m_playing = true;
    emit stateChanged();
}

void Player::playPause()
{
    send({{QStringLiteral("command"), QJsonArray{QStringLiteral("cycle"), QStringLiteral("pause")}}});
}

void Player::prefetch(const QString &url)
{
    enqueueResolve(url, false);
}

void Player::prefetchFront(const QString &url)
{
    enqueueResolve(url, true);
}

// Alta en las colas de pre-resolución. La cola "front" (hover) tiene prioridad
// absoluta sobre la de fondo (siguientes de la lista): así el clic inminente
// del usuario no espera detrás de las canciones que aún no va a tocar. Si hay
// una resolución de fondo en marcha y llega un hover, se descarta la de fondo
// (es recuperable) salvo que acabe de arrancar, para no malgastar el trabajo
// de yt-dlp por un simple barrido del ratón.
void Player::enqueueResolve(const QString &url, bool front)
{
    if (url.isEmpty() || !url.startsWith(QLatin1String("http")))
        return;   // sólo hay que resolver streams de red (los locales son ya directos)
    if (m_resolved.contains(url) || m_resolvingUrl == url)
        return;
    if (front) {
        m_resolveQueue.removeAll(url);
        if (m_resolveFront.contains(url))
            return;
        m_resolveFront.append(url);
        while (m_resolveFront.size() > 8)
            m_resolveFront.removeFirst();
        // Descarta una resolución de fondo en curso para atender el hover ya
        // (sólo si lleva un mínimo: evitar reinicios por micro-hovers). Nunca
        // se descarta si un load() está esperando esa misma resolución: sería
        // dejar la pista pulsada sin cargar.
        if (m_resolver.state() != QProcess::NotRunning && !m_resolvingFront
                && m_pendingLoadUrl != m_resolvingUrl
                && m_resolveStart > 0
                && QDateTime::currentMSecsSinceEpoch() - m_resolveStart > 500) {
            if (!m_resolvingUrl.isEmpty())
                m_resolveQueue.prepend(m_resolvingUrl);
            m_resolvingUrl.clear();
            m_resolvingFront = false;
            m_resolver.kill();
            return;   // finished() vuelve a llamar a resolveQueue()
        }
    } else {
        if (m_resolveQueue.contains(url) || m_resolveFront.contains(url))
            return;
        m_resolveQueue.append(url);
        while (m_resolveQueue.size() > 24)
            m_resolveQueue.removeFirst();
    }
    resolveQueue();
}

void Player::resolveQueue()
{
    if (m_resolver.state() != QProcess::NotRunning)
        return;
    if (m_resolveFront.isEmpty() && m_resolveQueue.isEmpty())
        return;
    const bool front = !m_resolveFront.isEmpty();
    const QString url = front ? m_resolveFront.takeFirst()
                              : m_resolveQueue.takeFirst();
    m_resolvingFront = front;
    m_resolveStart = QDateTime::currentMSecsSinceEpoch();
    m_resolveGrace = false;
    qInfo() << "[player] resolviendo" << (front ? "(hover)" : "(lista)") << url;
    QStringList args{
        QStringLiteral("--no-warnings"),
        QStringLiteral("--get-url"),
        QStringLiteral("--no-playlist"),
        QStringLiteral("--format"),
        ytdlFormat(),
    };
    const QString cookies =
        QDir::homePath() + QStringLiteral("/.config/lotus-tune/cookies.txt");
    if (QFile::exists(cookies)) {
        args << QStringLiteral("--cookies") << cookies
             << QStringLiteral("--extractor-args")
             << QStringLiteral("youtube:player_client=web_creator");
    }
    args << url;
    m_resolvingUrl = url;
    m_resolver.setProgram(QStringLiteral("yt-dlp"));
    m_resolver.setArguments(args);
    m_resolver.start();
    m_resolveTimer.start();
    if (!m_resolver.waitForStarted(3000))
        qWarning() << "[player] failed to start yt-dlp resolver";
}

void Player::stopPlayback()
{
    m_pendingLoadUrl.clear();
    send({{QStringLiteral("command"), QJsonArray{QStringLiteral("stop")}}});
    m_playing = false;
    m_hasFile = false;
    m_loading = false;
    m_position = 0;
    emit stateChanged();
    emit positionChanged();
}

void Player::seek(double seconds)
{
    // Sin fichero no hay nada que buscar: ignorar evita publicar posiciones
    // inventadas (Position de MPRIS) cuando el motor está en idle.
    if (!m_hasFile)
        return;
    // Clamp a [0, duración] si se conoce: un destino fuera de rango hace que
    // mpv salte a eof y deja a los widgets con position/length inválidos.
    if (seconds < 0.0)
        seconds = 0.0;
    else if (m_duration > 0.0 && seconds > m_duration)
        seconds = m_duration;

    // Un seek justo al final hace que mpv emita end-file de inmediato: la
    // pista se descarga, PlaybackStatus cae a "Stopped" y los widgets pierden
    // trackid/length (el "widget se rompe" si arrastras más allá del final).
    // Con keep-open POR FICHERO mpv se queda clavado en el último instante sin
    // descargar; si el destino no es el final se restaura keep-open=no DESPUÉS
    // del seek (restaurarlo antes, estando ya en eof, descargaría la pista)
    // para que el final natural siga avanzando la cola.
    const bool atEnd = m_duration > 0.0 && seconds >= m_duration - 0.05;
    if (atEnd) {
        send({{QStringLiteral("command"),
               QJsonArray{QStringLiteral("set"),
                          QStringLiteral("file-local-options/keep-open"),
                          QStringLiteral("yes")}}});
        send({{QStringLiteral("command"),
               QJsonArray{QStringLiteral("seek"), seconds, QStringLiteral("absolute")}}});
    } else {
        send({{QStringLiteral("command"),
               QJsonArray{QStringLiteral("seek"), seconds, QStringLiteral("absolute")}}});
        send({{QStringLiteral("command"),
               QJsonArray{QStringLiteral("set"),
                          QStringLiteral("file-local-options/keep-open"),
                          QStringLiteral("no")}}});
    }
    m_position = seconds;
    emit positionChanged();
    // MPRIS anuncia Seeked a partir de aquí (una vez, venga el seek de la app
    // o del widget).
    emit seeked(seconds);
}

void Player::setVolume(int v)
{
    v = qBound(0, v, 150);
    m_volume = v;
    emit volumeChanged();
    send({{QStringLiteral("command"),
           QJsonArray{QStringLiteral("set"), QStringLiteral("volume"),
                      QString::number(v)}}});
}

// Traduce la calidad elegida al selector que entiende yt-dlp. Se comparte
// entre los argumentos iniciales y el cambio en caliente por IPC.
QString Player::ytdlFormat() const
{
    if (m_quality == QLatin1String("alta"))
        return QStringLiteral("bestaudio[abr<=256]/bestaudio/best");
    if (m_quality == QLatin1String("media"))
        return QStringLiteral("bestaudio[abr<=160]/bestaudio/best");
    if (m_quality == QLatin1String("baja"))
        return QStringLiteral("bestaudio[abr<=96]/bestaudio/best");
    // "max" (por defecto): mejor audio disponible, sin recodificar.
    return QStringLiteral("bestaudio/best");
}

void Player::setQuality(const QString &q)
{
    const QString k = q.trimmed().toLower();
    const QString canonical =
        (k == QLatin1String("alta") || k == QLatin1String("media")
         || k == QLatin1String("baja"))
            ? k
            : QStringLiteral("max");
    if (canonical == m_quality)
        return;
    m_quality = canonical;
    emit qualityChanged();
    // Cambio en caliente: mpv aplica el nuevo --ytdl-format la próxima vez
    // que resuelve un stream (no interrumpe la pista actual).
    send({{QStringLiteral("command"),
           QJsonArray{QStringLiteral("set"), QStringLiteral("ytdl-format"),
                      ytdlFormat()}}});
}
