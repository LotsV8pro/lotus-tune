#include "player.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QStandardPaths>

#include <algorithm>

#include <QDebug>

#include <csignal>
#ifdef Q_OS_LINUX
#  include <sys/prctl.h>
#endif

// Máximo de resolutores yt-dlp simultáneos: la precarga de listas ("cocer"
// streams por adelantado) avanza hasta 3x más rápida sin cambiar prioridades.
namespace { constexpr int kMaxResolvers = 3; }

Player::Player(QObject *parent)
    : QObject(parent)
{
    m_connectTimer.setInterval(250);
    connect(&m_connectTimer, &QTimer::timeout, this, &Player::tryConnect);

    m_posFlush.setSingleShot(true);
    m_posFlush.setInterval(240);
    connect(&m_posFlush, &QTimer::timeout, this, [this] { emitPosition(true); });

    // Caché en disco de streams resueltos: se vuelca en diferido para no
    // escribir en cada resolución.
    m_cacheSaveTimer.setSingleShot(true);
    m_cacheSaveTimer.setInterval(2500);
    connect(&m_cacheSaveTimer, &QTimer::timeout, this, &Player::saveStreamCache);
    loadStreamCache();

    // Pool de resolutores: hasta kMaxResolvers yt-dlp en paralelo. Cada slot
    // lleva su propio proceso y temporizador; resolveQueue() sólo arranca los
    // procesos que la cola necesite, así que 3 yt-dlp se ven únicamente cuando
    // hay cola suficiente (nunca por tener el pool grande).
    for (int i = 0; i < kMaxResolvers; ++i) {
        auto *job = new ResolveJob;
        m_jobs.append(job);
        job->proc.setProcessChannelMode(QProcess::SeparateChannels);
        // Tope de tiempo por pre-resolución: red de seguridad ante un yt-dlp
        // colgado (no ante una resolución normal, que tarda ~2.5 s). Si aún así
        // un load() está esperando esta pista, no se abandona a mpv: se concede
        // un único margen extra antes de matarla.
        job->timer.setSingleShot(true);
        job->timer.setInterval(12000);
        connect(&job->timer, &QTimer::timeout, this, [this, job] { onResolveTimeout(job); });
        connect(&job->proc, &QProcess::finished, this,
                [this, job](int code, QProcess::ExitStatus) { onResolveFinished(job, code); });
    }

    startMpv();
    m_connectTimer.start();
}

Player::~Player()
{
    saveStreamCache();
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
    // Detén los resolutores del pool: sin el disconnect, matar un yt-dlp aquí
    // dispararía finished() (y con él más resoluciones) durante la destrucción;
    // sin el kill+wait, un yt-dlp podría quedar huérfano.
    for (ResolveJob *job : m_jobs) {
        job->timer.stop();
        QObject::disconnect(&job->proc, nullptr, this, nullptr);
        if (job->proc.state() != QProcess::NotRunning) {
            job->proc.kill();
            job->proc.waitForFinished(700);
        }
        delete job;
    }
    m_jobs.clear();
}

// Las URLs de music.youtube.com tardan ~1 s más en resolverse que las de
// www.youtube.com (mismo vídeo): normalizar acelera y unifica la caché.
QString Player::normalizeUrl(const QString &url)
{
    if (url.contains(QLatin1String("music.youtube.com")))
        return QString(url).replace(QLatin1String("music.youtube.com"),
                                    QLatin1String("www.youtube.com"));
    return url;
}

namespace {
constexpr qint64 kStreamCacheTtlSec = 3 * 3600;
}  // namespace

void Player::loadStreamCache()
{
    m_cacheFile = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                  + QStringLiteral("/streams.json");
    QFile f(m_cacheFile);
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    f.close();
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        const QJsonArray a = it.value().toArray();
        if (a.size() != 2)
            continue;
        const QString direct = a.at(0).toString();
        const qint64 ts = qint64(a.at(1).toDouble());
        if (direct.isEmpty() || now - ts > kStreamCacheTtlSec)
            continue;
        m_resolved.insert(it.key(), direct);
        m_resolvedAt.insert(it.key(), ts);
    }
}

void Player::saveStreamCache()
{
    if (m_cacheFile.isEmpty() || !m_cacheDirty)
        return;
    m_cacheDirty = false;
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    QList<QPair<QString, qint64>> items;
    for (auto it = m_resolved.constBegin(); it != m_resolved.constEnd(); ++it) {
        const qint64 ts = m_resolvedAt.value(it.key(), now);
        if (now - ts <= kStreamCacheTtlSec)
            items.append({it.key(), ts});
    }
    std::sort(items.begin(), items.end(),
              [](const QPair<QString, qint64> &a, const QPair<QString, qint64> &b) {
                  return a.second > b.second;   // más recientes primero
              });
    if (items.size() > 300)
        items = items.mid(0, 300);
    QJsonObject o;
    for (const auto &p : items)
        o.insert(p.first, QJsonArray{m_resolved.value(p.first), double(p.second)});
    QDir().mkpath(QFileInfo(m_cacheFile).absolutePath());
    QFile f(m_cacheFile);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
    f.close();
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
        QStringLiteral("--sub-auto=no"),
        QStringLiteral("--audio-buffer=0.2"),
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
                    "--ytdl-raw-options-append=extractor-args=youtube:player_client=web_creator;player_skip=configs");
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
            // La URL directa cacheada puede haber caducado: se invalida para
            // que el reintento vuelva a resolverla (y no falle en bucle).
            if (!m_currentUrl.isEmpty() && m_resolved.remove(m_currentUrl) > 0) {
                m_resolvedAt.remove(m_currentUrl);
                m_cacheDirty = true;
                m_cacheSaveTimer.start();
            }
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
    loadImpl(url, /*allowResolve=*/true);
}

void Player::loadImpl(const QString &rawUrl, bool allowResolve)
{
    const QString url = normalizeUrl(rawUrl);
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
    const bool network = url.startsWith(QLatin1String("http"));
    const bool cached = m_resolved.contains(url);
    // Caso "ya suena": tenemos la URL directa cacheada, es un fichero local que
    // mpv abre tal cual, o ya no cabe resolver (nuestra pre-resolución falló y
    // dejamos que mpv lo intente por su cuenta).
    if (!network || cached || !allowResolve) {
        m_pendingLoadUrl.clear();
        m_position = 0;
        m_duration = 0;
        m_currentUrl = url;
        m_hasFile = true;
        m_loading = true;
        qInfo() << "[player] load" << url;
        emit positionChanged();
        emit stateChanged();
        // Se conserva la entrada (no se consume): una repetición vuelve a sonar
        // al instante. Si la URL resulta caducada, el error de mpv la invalida.
        const QString direct = m_resolved.value(url);
        send({{QStringLiteral("command"),
               QJsonArray{QStringLiteral("loadfile"), direct.isEmpty() ? url : direct,
                          QStringLiteral("replace")}}});
        send({{QStringLiteral("command"),
               QJsonArray{QStringLiteral("set"), QStringLiteral("pause"), QStringLiteral("no")}}});
        m_playing = true;
        emit stateChanged();
        return;
    }
    // Sin cachear: la resolvemos NOSOTROS (con prioridad máxima) y esperamos.
    // Nunca se la pasamos a mpv para que la resuelva: su yt-dlp interno es
    // bastante más lento (en vídeos sólo-HLS supera los 25 s). La UI muestra
    // "Cargando…" mientras tanto y, si falla, caemos a mpv (loadImpl(false)).
    if (!isResolving(url))
        enqueueResolve(url, true, /*urgent=*/true);
    m_pendingLoadUrl = url;
    m_position = 0;
    m_duration = 0;
    m_currentUrl = url;
    m_hasFile = true;
    m_loading = true;
    m_playing = true;
    emit positionChanged();
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

void Player::clearPrefetch()
{
    // Sólo la cola de fondo: la de prioridad (hover/clic) es del usuario y está
    // a punto de consumirse; además un load() puede estar esperándola.
    m_resolveQueue.clear();
}

// Alta en las colas de pre-resolución. La cola "front" (hover) tiene prioridad
// absoluta sobre la de fondo (siguientes de la lista): así el clic inminente
// del usuario no espera detrás de las canciones que aún no va a tocar.
//
// `urgent` (clic del usuario) adelanta SIEMPRE lo que se esté resolviendo, sea
// de hover o de fondo, porque el usuario ya ha elegido otra pista. Sin `urgent`
// (hover) sólo se reordena: nunca se descarta trabajo ya empezado. Nunca se
// descarta, además, si un load() espera esa misma resolución: sería dejar sin
// cargar la pista pulsada.
void Player::enqueueResolve(const QString &rawUrl, bool front, bool urgent)
{
    const QString url = normalizeUrl(rawUrl);
    if (url.isEmpty() || !url.startsWith(QLatin1String("http")))
        return;   // sólo hay que resolver streams de red (los locales son ya directos)
    if (m_resolved.contains(url) || isResolving(url))
        return;   // dedupe: nunca dos resoluciones del MISMO url a la vez
    if (front) {
        m_resolveQueue.removeAll(url);
        // La cola front es LIFO: el hover MÁS RECIENTE (la fila donde está el
        // ratón, la que el usuario está a punto de pulsar) se resuelve antes
        // que los hovers antiguos. Re-encolar refresca esa recencia.
        m_resolveFront.removeAll(url);
        m_resolveFront.append(url);
        while (m_resolveFront.size() > 8)
            m_resolveFront.removeFirst();
        // El hover NO descarta lo que se esté resolviendo: sólo reordena (lo
        // puesto a mano en `front` corre justo después). Antes un barrido del
        // ratón mataba la precarga de fondo en vuelo y ésta NUNCA terminaba,
        // que es justo lo que hacía que una canción buscada tardara en sonar.
        // Sólo un clic real (`urgent`) adelanta lo que haya en curso, porque el
        // usuario ya ha elegido otra pista y no puede esperar. Con el pool sólo
        // se mata si NO hay ningún slot libre: si lo hay, la urgente arranca de
        // inmediato sin tocar lo que ya está en vuelo.
        if (urgent && !hasFreeJob()) {
            ResolveJob *victim = pickVictim(url);
            if (victim) {
                // La pista abandonada se re-encola AL FINAL (antes iba al
                // principio, y una pista ya descartada se re-resolvía en bucle
                // bloqueando las pre-cargas nuevas). Se limpia su url ANTES de
                // matarla para que su finished() no la vuelva a procesar.
                const QString abandoned = victim->url;
                victim->url.clear();
                victim->front = false;
                if (!abandoned.isEmpty())
                    m_resolveQueue.append(abandoned);
                while (m_resolveQueue.size() > 24)
                    m_resolveQueue.removeFirst();
                victim->proc.kill();   // finished() vuelve a llamar a resolveQueue()
                return;
            }
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

// Rellena todos los slots libres del pool con trabajo pendiente. Al consumir
// una URL por slot (y parar en cuanto no queda nada) nunca se levantan más
// yt-dlp de los necesarios: 3 solo cuando hay cola suficiente.
void Player::resolveQueue()
{
    for (ResolveJob *job : m_jobs) {
        if (job->proc.state() != QProcess::NotRunning)
            continue;
        bool front = false;
        const QString url = takeNextResolve(front);
        if (url.isEmpty())
            return;   // no queda trabajo: deja los slots libres dormidos
        startResolve(job, url, front);
    }
}

// Siguiente URL a resolver: primero la cola prioritaria (hover más reciente
// primero, LIFO) y después la de fondo (orden de la lista, FIFO). Descarta lo
// ya resuelto o en vuelo en otro slot.
QString Player::takeNextResolve(bool &front)
{
    for (int pass = 0; pass < 2; ++pass) {
        QStringList &list = (pass == 0) ? m_resolveFront : m_resolveQueue;
        while (!list.isEmpty()) {
            const QString url = (pass == 0) ? list.takeLast() : list.takeFirst();
            if (m_resolved.contains(url) || isResolving(url))
                continue;
            front = (pass == 0);
            return url;
        }
    }
    front = false;
    return QString();
}

void Player::startResolve(ResolveJob *job, const QString &url, bool front)
{
    job->front = front;
    job->start = QDateTime::currentMSecsSinceEpoch();
    job->grace = false;
    job->url = url;
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
             // player_skip=configs evita descargar configs del player: recorta
             // ~0,5-1 s por resolución sin afectar a la reproducción.
             << QStringLiteral("youtube:player_client=web_creator;player_skip=configs");
    }
    args << url;
    job->proc.setProgram(QStringLiteral("yt-dlp"));
    job->proc.setArguments(args);
    // Si la app muere (incluso con SIGKILL), el yt-dlp del slot recibe SIGTERM
    // y no queda huérfano consumiendo CPU/red. Se fija antes de CADA arranque
    // porque el mismo QProcess se reutiliza para varias resoluciones.
    job->proc.setChildProcessModifier([] {
#ifdef Q_OS_LINUX
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
#endif
    });
    job->proc.start();
    job->timer.start();
    if (!job->proc.waitForStarted(3000)) {
        qWarning() << "[player] failed to start yt-dlp resolver";
        // Sin proceso no habrá finished(): libera el slot y, si un load()
        // esperaba esta pista, deja que mpv la resuelva por su cuenta.
        job->timer.stop();
        job->url.clear();
        job->front = false;
        if (!url.isEmpty() && m_pendingLoadUrl == url) {
            m_pendingLoadUrl.clear();
            loadImpl(url, /*allowResolve=*/false);
        }
    }
}

bool Player::isResolving(const QString &url) const
{
    for (const ResolveJob *job : m_jobs) {
        if (job->proc.state() != QProcess::NotRunning && job->url == url)
            return true;
    }
    return false;
}

bool Player::hasFreeJob() const
{
    for (const ResolveJob *job : m_jobs) {
        if (job->proc.state() == QProcess::NotRunning)
            return true;
    }
    return false;
}

// Elige qué resolución en curso descartar para atender una urgente. Nunca la
// misma URL pedida ni una que un load() esté esperando. Prefiere descartar una
// de fondo antes que una prioritaria y, a igualdad, la más reciente (es la que
// menos trabajo lleva hecho).
Player::ResolveJob *Player::pickVictim(const QString &url)
{
    ResolveJob *victim = nullptr;
    for (ResolveJob *job : m_jobs) {
        if (job->proc.state() == QProcess::NotRunning || job->url.isEmpty())
            continue;
        if (job->url == url || job->url == m_pendingLoadUrl)
            continue;
        if (!victim) {
            victim = job;
            continue;
        }
        if (victim->front && !job->front)
            victim = job;
        else if (victim->front == job->front && job->start > victim->start)
            victim = job;
    }
    return victim;
}

void Player::onResolveFinished(ResolveJob *job, int code)
{
    job->timer.stop();
    job->grace = false;
    const QString url = job->url;
    job->url.clear();
    job->front = false;
    if (code == 0) {
        const QByteArray out = job->proc.readAllStandardOutput().trimmed();
        const QList<QByteArray> lines = out.split('\n');
        for (const QByteArray &l : lines) {
            const QString s = QString::fromUtf8(l).trimmed();
            if (s.startsWith(QLatin1String("http"))) {
                m_resolved.insert(url, s);
                m_resolvedAt.insert(url, QDateTime::currentSecsSinceEpoch());
                m_cacheDirty = true;
                m_cacheSaveTimer.start();
                // Tope en memoria: descarta las más antiguas.
                if (m_resolved.size() > 300) {
                    QStringList keys = m_resolvedAt.keys();
                    std::sort(keys.begin(), keys.end(),
                              [this](const QString &a, const QString &b) {
                                  return m_resolvedAt.value(a) < m_resolvedAt.value(b);
                              });
                    for (int i = 0; i < keys.size() && m_resolved.size() > 300; ++i) {
                        m_resolved.remove(keys.at(i));
                        m_resolvedAt.remove(keys.at(i));
                    }
                }
                qInfo() << "[player] pre-resuelta" << url << "->" << s.left(60) << "...";
                break;
            }
        }
    }
    // Un load() que estaba esperando a esta misma pista (en cualquiera de los
    // slots): ya hay URL directa (o, si la resolución falló, cae a que mpv la
    // resuelva por su cuenta).
    if (!url.isEmpty() && m_pendingLoadUrl == url) {
        m_pendingLoadUrl.clear();
        loadImpl(url, /*allowResolve=*/m_resolved.contains(url));
    }
    resolveQueue();
}

void Player::onResolveTimeout(ResolveJob *job)
{
    if (job->proc.state() == QProcess::NotRunning)
        return;
    // Si un load() espera esta pista, se concede un único margen extra antes de
    // matarla (la resolución interna de mpv es bastante más lenta).
    if (!job->grace && !m_pendingLoadUrl.isEmpty() && m_pendingLoadUrl == job->url) {
        job->grace = true;
        job->timer.start(20000);
        return;
    }
    job->proc.kill();   // finished() limpia el estado y sigue con la cola
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
