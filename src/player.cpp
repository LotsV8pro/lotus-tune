#include "player.h"

#ifdef Q_OS_ANDROID
#include <QAudioOutput>
#include <QMediaPlayer>
#include <QCryptographicHash>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#endif
#include "paths.h"

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

// Maximum simultaneous yt-dlp resolvers: the list prefetch ("cooking"
// streams ahead) advances up to 3x faster without changing priorities.
namespace { constexpr int kMaxResolvers = 3; }

Player::Player(QObject *parent)
    : QObject(parent)
{
    m_connectTimer.setInterval(250);
    connect(&m_connectTimer, &QTimer::timeout, this, &Player::tryConnect);

    m_posFlush.setSingleShot(true);
    m_posFlush.setInterval(240);
    connect(&m_posFlush, &QTimer::timeout, this, [this] { emitPosition(true); });

    // On-disk cache of resolved streams: it is dumped in a deferred way so
    // it does not write on every resolution.
    m_cacheSaveTimer.setSingleShot(true);
    m_cacheSaveTimer.setInterval(2500);
    connect(&m_cacheSaveTimer, &QTimer::timeout, this, &Player::saveStreamCache);
    loadStreamCache();

    // Resolver pool: up to kMaxResolvers yt-dlp in parallel. Every slot
    // carries its own process and timer; resolveQueue() only starts the
    // processes the queue needs, so 3 yt-dlp are only seen when there is
    // enough queue (never just because the pool is big).
    for (int i = 0; i < kMaxResolvers; ++i) {
        auto *job = new ResolveJob;
        m_jobs.append(job);
        job->proc.setProcessChannelMode(QProcess::SeparateChannels);
        // Time cap per pre-resolution: a safety net against a hung yt-dlp
         // (not against a normal resolution, which takes ~2.5 s). If a
         // load() is still waiting for this track, it is not abandoned to
         // mpv: a single extra margin is granted before killing it.
        job->timer.setSingleShot(true);
        job->timer.setInterval(20000);  // 20 segundos para resolver pistas
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
    // Stops the pool's resolvers: without the disconnect, killing a yt-dlp
    // here would fire finished() (and with it more resolutions) during
    // the destruction; without the kill+wait, a yt-dlp could be left
    // orphaned.
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

// The music.youtube.com URLs take ~1 s more to resolve than the
// www.youtube.com ones (same video): normalising speeds it up and unifies
// the cache.
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
                  return a.second > b.second;   // most recent first
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
#ifdef Q_OS_ANDROID
    // On a phone the audio is played by Qt itself.
    if (!m_androidPlayer) {
        m_androidPlayer = new QMediaPlayer(this);
        m_androidAudio = new QAudioOutput(this);
        m_androidPlayer->setAudioOutput(m_androidAudio);
        m_androidAudio->setVolume(m_volume / 100.0);
        connect(m_androidPlayer, &QMediaPlayer::positionChanged, this,
                [this](qint64 pos) {
                    m_position = pos / 1000.0;
                    emit positionChanged();
                });
        connect(m_androidPlayer, &QMediaPlayer::durationChanged, this,
                [this](qint64 dur) {
                    m_duration = dur / 1000.0;
                    emit stateChanged();
                });
        connect(m_androidPlayer, &QMediaPlayer::playbackStateChanged, this,
                [this](QMediaPlayer::PlaybackState st) {
                    m_playing = st == QMediaPlayer::PlayingState;
                    m_hasFile = st != QMediaPlayer::StoppedState;
                    emit stateChanged();
                });
        connect(m_androidPlayer, &QMediaPlayer::errorOccurred, this,
                [this](QMediaPlayer::Error, const QString &err) {
                    qWarning() << "[player] error de reproducción:" << err;
                    m_loading = false;
                    emit stateChanged();
                });
    }
    m_ready = true;
    emit stateChanged();
    return;
#endif
#ifdef Q_OS_ANDROID
    // There is no mpv on a phone: the playback engine of the Android
    // flavour is not there yet, so the app says it instead of failing
    // silently.
    m_status = QStringLiteral("sin motor de reproducción en Android");
    m_ready = true;
    emit stateChanged();
    return;
#endif
    QString sock = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (sock.isEmpty())
        sock = QDir::tempPath();
    m_socketPath = sock + QStringLiteral("/lotus-tune.sock");
    QFile::remove(m_socketPath);

    m_proc.setProgram(QStringLiteral("mpv"));
    // "Frugal" arguments: no window, no video, no OSD/OSC nor subtitles,
    // and with the demuxer caches at the minimum to trim RAM use. The
    // audio is NOT re-encoded: --audio-format and --audio-channels are not
    // forced, so yt-dlp's original stream plays at full fidelity.
    // Note: --ao is left out on purpose so mpv picks the available
    // output.
    QStringList args{
        QStringLiteral("--no-config"),
        QStringLiteral("--no-video"),
        QStringLiteral("--video=no"),        // alias of --vid=no (no video track)
        QStringLiteral("--vo=null"),         // no video output nor window
        QStringLiteral("--no-terminal"),
        QStringLiteral("--really-quiet"),
        QStringLiteral("--idle=yes"),
        QStringLiteral("--force-window=no"),
        QStringLiteral("--no-osc"),          // no on screen controller
        QStringLiteral("--osc=no"),          // equivalent to --no-osc (just in case)
        QStringLiteral("--no-osd-bar"),
        // --no-stats no longer exists in mpv >= 0.38; this is its current equivalent.
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
        QStringLiteral("--audio-display=no"),  // do not embed cover art
        QStringLiteral("--cache=no"),          // no network cache on disk/memory
        QStringLiteral("--demuxer-max-bytes=3MiB"),
        QStringLiteral("--demuxer-max-back-bytes=1MiB"),
        QStringLiteral("--demuxer-readahead-secs=10"),
    };
    // If there is a YouTube Music session, yt-dlp plays with the cookies:
    // that way restricted tracks, "Liked Music" and private playlists
    // resolve.
    const QString cookies =
        AppPaths::cookiesFile();
    if (QFile::exists(cookies))
        args << QStringLiteral("--ytdl-raw-options=cookies=") + cookies
             << QStringLiteral("--ytdl-raw-options-append=no-warnings=")
             // Extraction client that avoids the 403 "no audio or video data
             // played" YouTube returns today with the default client.
             // It needs cookies (authenticated client).
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
    // If the app dies (even with SIGKILL) mpv gets SIGTERM and is not
    // left as an orphan process blocking the IPC socket.
#ifdef Q_OS_LINUX
    // Only Linux has it (it is a QProcess API that arrived with 6.0 and it
    // is not there on Windows).
    m_proc.setChildProcessModifier([] {
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    });
#endif
    // Cleans a leftover socket from a previous run before starting.
    QFile::remove(m_socketPath);
    m_proc.start();
    if (!m_proc.waitForStarted(10000))
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
            // mpv reports pause=false when idle too (no file): without
             // the m_hasFile guard the app would think it is playing
             // nothing right after starting and would publish a phantom
             // "Playing" on MPRIS.
            m_playing = m_hasFile && !data.toBool(true);
            emit stateChanged();
        } else if (name == QLatin1String("duration")) {
            const double d = data.toDouble();
            // If a load() is waiting for the pre-resolution, mpv carries
             // on with the previous track: its events must not end the
             // wait.
            if (d > 0.0 && m_loading && m_pendingLoadUrl.isEmpty()) {
                m_loading = false;   // there is already a stream: the wait ends
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
            // The cached direct URL may have expired: it is invalidated so
            // the retry resolves it again (and does not fail in a loop).
            if (!m_currentUrl.isEmpty() && m_resolved.remove(m_currentUrl) > 0) {
                m_resolvedAt.remove(m_currentUrl);
                m_cacheDirty = true;
                m_cacheSaveTimer.start();
            }
            qWarning() << "[player] playback error" << "url=" << m_currentUrl
                       << "err=" << o.value(QStringLiteral("error")).toString()
                       << "file=" << o.value(QStringLiteral("file_error")).toString();
            // Typical transient YouTube/yt-dlp failure (rate limit or
             // token): it retries the same track a couple of times before
             // giving it up.
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
    // A new track (different from the current one) resets the counter of
    // retries; a retry of the same track keeps it.
    if (url != m_currentUrl)
        m_retry = 0;
    if (!m_ready) {
        m_pendingUrl = url;
        return;
    }
    const bool network = url.startsWith(QLatin1String("http"));
#ifdef Q_OS_ANDROID
    // On a phone there is no mpv and no yt-dlp: the stream is asked to
    // YouTube Music's API and played by Qt.
    if (m_androidPlayer) {
        m_pendingLoadUrl.clear();
        m_position = 0;
        m_duration = 0;
        m_currentUrl = url;
        m_hasFile = true;
        m_loading = true;
        m_playing = true;
        emit positionChanged();
        emit stateChanged();
        if (network) {
            // Cached from an earlier prefetch: it sounds instantly.
            if (m_resolved.contains(url)) {
                m_loading = false;
                m_androidPlayer->setSource(QUrl(m_resolved.value(url)));
                m_androidPlayer->play();
                emit stateChanged();
                return;
            }
            resolveWithApi(url);
        } else {
            m_androidPlayer->setSource(QUrl::fromLocalFile(url));
            m_androidPlayer->play();
            m_loading = false;
            emit stateChanged();
        }
        return;
    }
#endif
    const bool cached = m_resolved.contains(url);
    // "Already playing" case: we have the direct URL cached, it is a
    // local file that mpv opens as it is, or it can no longer be resolved
    // (our pre-resolution failed and we let mpv try on its own).
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
        // The entry is kept (not consumed): a repeat plays instantly
         // again. If the URL turns out to be expired, mpv's error
         // invalidates it.
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
    // Not cached: we resolve it OURSELVES (with the highest priority) and
    // wait. It is never handed to mpv to resolve: its internal yt-dlp is
    // much slower (on HLS only videos it goes over 25 s). The UI shows
    // "Loading..." meanwhile and, if it fails, it falls back to mpv
    // (loadImpl(false)).
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
#ifdef Q_OS_ANDROID
    if (m_androidPlayer) {
        if (m_androidPlayer->playbackState() == QMediaPlayer::PlayingState)
            m_androidPlayer->pause();
        else
            m_androidPlayer->play();
        return;
    }
#endif
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
    // Only the background queue: the priority one (hover/click) belongs to
    // the user and is about to be consumed; also a load() may be waiting
    // for it.
    m_resolveQueue.clear();
}

// Entry into the pre-resolution queues. The "front" queue (hover) has
// absolute priority over the background one (the list's next tracks):
// that way the user's imminent click does not wait behind the songs they
// are not going to play yet.
//
// `urgent` (the user's click) ALWAYS overtakes whatever is being
// resolved, hover or background, because the user already chose another
// track. Without `urgent` (hover) it only reorders: work already started
// is never dropped. And it is never dropped if a load() is waiting for
// that same resolution: that would leave the pressed track unloaded.
void Player::enqueueResolve(const QString &rawUrl, bool front, bool urgent)
{
    const QString url = normalizeUrl(rawUrl);
    if (url.isEmpty() || !url.startsWith(QLatin1String("http")))
        return;   // only network streams have to be resolved (the local ones are already direct)
    if (m_resolved.contains(url) || isResolving(url))
        return;   // dedupe: never two resolutions of the SAME url at once
    if (front) {
        m_resolveQueue.removeAll(url);
        // The front queue is LIFO: the MOST RECENT hover (the row the
         // mouse is on, the one the user is about to press) is resolved
         // before the old ones. Re-queueing refreshes that recency.
        m_resolveFront.removeAll(url);
        m_resolveFront.append(url);
        while (m_resolveFront.size() > 8)
            m_resolveFront.removeFirst();
        // The hover does NOT drop what is being resolved: it only
         // reorders (what was put by hand in `front` runs right after).
         // Before, a mouse sweep killed the background prefetch in
         // flight and it NEVER finished, which is exactly what made a
         // searched song take so long to sound. Only a real click
         // (`urgent`) overtakes what is in progress, because the user
         // already chose another track and cannot wait. With the pool it
         // is only killed if there is NO free slot: if there is one, the
         // urgent one starts right away without touching what is in
         // flight.
        if (urgent && !hasFreeJob()) {
            ResolveJob *victim = pickVictim(url);
            if (victim) {
                // The abandoned track is re-queued at the END (it used to
                 // go first, and an already dropped track was resolved
                 // again in a loop blocking the new prefetches). Its url
                 // is cleared BEFORE killing it so its finished() does
                 // not process it again.
                const QString abandoned = victim->url;
                victim->url.clear();
                victim->front = false;
                if (!abandoned.isEmpty())
                    m_resolveQueue.append(abandoned);
                while (m_resolveQueue.size() > 24)
                    m_resolveQueue.removeFirst();
                victim->proc.kill();   // finished() calls resolveQueue() again
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

// Fills every free slot of the pool with pending work. Since a slot
// consumes one URL (and stops as soon as there is nothing left) more
// yt-dlp are never started than needed: 3 only with enough queue.
void Player::resolveQueue()
{
    for (ResolveJob *job : m_jobs) {
        if (job->proc.state() != QProcess::NotRunning)
            continue;
        bool front = false;
        const QString url = takeNextResolve(front);
        if (url.isEmpty())
            return;   // no work left: it leaves the free slots asleep
        startResolve(job, url, front);
    }
}

// Next URL to resolve: first the priority queue (most recent hover first,
// LIFO) and then the background one (list order, FIFO). It skips what is
// already resolved or in flight in another slot.
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
        AppPaths::cookiesFile();
    if (QFile::exists(cookies)) {
        args << QStringLiteral("--cookies") << cookies
             << QStringLiteral("--extractor-args")
             // player_skip=configs avoids downloading the player's
             // configs: it trims ~0.5-1 s per resolution without
             // affecting the playback.
             << QStringLiteral("youtube:player_client=web_creator;player_skip=configs");
    }
    args << url;
#ifdef Q_OS_ANDROID
    // No yt-dlp on a phone: the stream is resolved with the app's own
    // chain (WEB_REMIX + WebView solver). One chain at a time: while one
    // resolution is in flight the other jobs finish as failed so the
    // queue keeps flowing (the player JS is cached, so a chain is a
    // couple of requests once warm).
    if (!m_apTrack.isEmpty()) {
        onResolveFinished(job, 1);
        return;
    }
    m_chainJob = job;
    m_apTrack = url;
    resolveWithApi(url);
    return;
#endif
    job->proc.setProgram(QStringLiteral("yt-dlp"));
    job->proc.setArguments(args);
    // If the app dies (even with SIGKILL) the slot's yt-dlp gets SIGTERM
    // and is not left orphaned eating CPU/network. It is set before EVERY
    // start because the same QProcess is reused for several
    // resolutions.
#ifdef Q_OS_LINUX
    job->proc.setChildProcessModifier([] {
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    });
#endif
    job->proc.start();
    job->timer.start();
    if (!job->proc.waitForStarted(10000)) {
        qWarning() << "[player] failed to start yt-dlp resolver";
        // Without a process there will be no finished(): the slot is
         // freed and, if a load() was waiting for this track, mpv is
         // left to resolve it on its own.
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

// Picks which resolution in progress to drop to serve an urgent one.
// Never the requested URL itself, nor one a load() is waiting for. It
// prefers dropping a background one over a priority one and, on a tie,
// the most recent one (it has the least work done).
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
                // Memory cap: the oldest ones are dropped.
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
    // A load() that was waiting for this same track (in any of the slots):
     // there is already a direct URL (or, if the resolution failed, it
     // falls back to mpv resolving it on its own).
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
    // If a load() is waiting for this track, a single extra margin is
    // granted before killing it (mpv's internal resolution is much
    // slower).
    if (!job->grace && !m_pendingLoadUrl.isEmpty() && m_pendingLoadUrl == job->url) {
        job->grace = true;
        job->timer.start(20000);
        return;
    }
    job->proc.kill();   // finished() clears the state and carries on with the queue
}

void Player::stopPlayback()
{
    m_pendingLoadUrl.clear();
#ifdef Q_OS_ANDROID
    if (m_androidPlayer) {
        m_androidPlayer->stop();
        m_playing = false;
        m_hasFile = false;
        m_loading = false;
        m_position = 0;
        emit stateChanged();
        emit positionChanged();
        return;
    }
#endif
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
    // Without a file there is nothing to look for: ignoring it avoids
    // publishing made up positions (MPRIS Position) while the engine is
    // idle.
    if (!m_hasFile)
        return;
#ifdef Q_OS_ANDROID
    if (m_androidPlayer) {
        if (seconds < 0.0)
            seconds = 0.0;
        else if (m_duration > 0.0 && seconds > m_duration)
            seconds = m_duration;
        m_androidPlayer->setPosition(static_cast<qint64>(seconds * 1000.0));
        m_position = seconds;
        emit positionChanged();
        emit seeked(seconds);
        return;
    }
#endif
    // Clamp to [0, duration] when it is known: a target out of range
    // makes mpv jump to eof and leaves the widgets with an invalid
    // position/length.
    if (seconds < 0.0)
        seconds = 0.0;
    else if (m_duration > 0.0 && seconds > m_duration)
        seconds = m_duration;

    // A seek right at the end makes mpv emit end-file immediately: the
    // track is unloaded, PlaybackStatus drops to "Stopped" and the
    // widgets lose trackid/length (the "widget breaks" if you drag
    // past the end). With keep-open PER FILE mpv stays stuck at the last
    // instant without unloading; if the target is not the end, keep-open
    // is restored to no AFTER the seek (restoring it before, already in
    // eof, would unload the track) so the natural end still advances the
    // queue.
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
    // MPRIS announces Seeked from here (once, whether the seek came from
    // the app or from the widget).
    emit seeked(seconds);
}

void Player::setVolume(int v)
{
    v = qBound(0, v, 150);
    m_volume = v;
    emit volumeChanged();
#ifdef Q_OS_ANDROID
    if (m_androidAudio) {
        m_androidAudio->setVolume(v / 100.0);
        return;
    }
#endif
    send({{QStringLiteral("command"),
           QJsonArray{QStringLiteral("set"), QStringLiteral("volume"),
                      QString::number(v)}}});
}

// Translates the chosen quality into the selector yt-dlp understands. It is
// shared between the initial arguments and the hot change through IPC.
QString Player::ytdlFormat() const
{
    if (m_quality == QLatin1String("alta"))
        return QStringLiteral("bestaudio[abr<=256]/bestaudio/best");
    if (m_quality == QLatin1String("media"))
        return QStringLiteral("bestaudio[abr<=160]/bestaudio/best");
    if (m_quality == QLatin1String("baja"))
        return QStringLiteral("bestaudio[abr<=96]/bestaudio/best");
    // "max" (default): best available audio, without re-encoding.
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
    // Hot change: mpv applies the new --ytdl-format the next time it
    // resolves a stream (it does not interrupt the current track).
    send({{QStringLiteral("command"),
           QJsonArray{QStringLiteral("set"), QStringLiteral("ytdl-format"),
                      ytdlFormat()}}});
}


#ifdef Q_OS_ANDROID
// The session of the user: the cookies file of the app. The API needs the
// SAPISID to sign the request, and with it it serves the stream.
QString Player::sessionCookie() const
{
    QFile f(AppPaths::cookiesFile());
    if (!f.open(QIODevice::ReadOnly))
        return QString();
    QHash<QString, QString> jar;
    const QList<QByteArray> lines = f.readAll().split('\n');
    for (const QByteArray &lb : lines) {
        const QString line = QString::fromUtf8(lb).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        const QStringList f2 = line.split(QLatin1Char('\t'));
        if (f2.size() >= 7)
            jar.insert(f2.at(5), f2.at(6));
    }
    if (jar.isEmpty())
        return QString();
    QString sapisid;
    for (const QString &name : { QStringLiteral("__Secure-3PAPISID"),
                                QStringLiteral("__Secure-1PAPISID"),
                                QStringLiteral("SAPISID") }) {
        if (jar.contains(name) && !jar.value(name).isEmpty()) {
            sapisid = jar.value(name);
            break;
        }
    }
    if (sapisid.isEmpty())
        return QString();
    // The signature of the request (the same one ytm_api.py uses).
    const QString ts = QString::number(QDateTime::currentSecsSinceEpoch());
    const QByteArray digest = QCryptographicHash::hash(
        QStringLiteral("%1 %2 %3").arg(ts, sapisid,
                                      QStringLiteral("https://music.youtube.com"))
            .toUtf8(), QCryptographicHash::Sha1).toHex();
    QString cookie;
    for (auto it = jar.constBegin(); it != jar.constEnd(); ++it)
        cookie += QStringLiteral("%1=%2; ").arg(it.key(), it.value());
    cookie.chop(2);
    return QStringLiteral("SAPISIDHASH %1_%2|%3").arg(ts, QString::fromLatin1(digest),
                                                  cookie);
}

void Player::resolveWithApi(const QString &url)
{
    // The id of the video: the watch URL or the permalink.
    QString id = url;
    const int q = id.indexOf(QLatin1Char('?'));
    if (q >= 0)
        id = id.left(q);
    const int v = id.lastIndexOf(QLatin1Char('='));
    if (v >= 0)
        id = id.mid(v + 1);
    if (id.size() < 11)
        return;

    const QString session = sessionCookie();
    QString auth, cookie;
    if (!session.isEmpty()) {
        const int bar = session.indexOf(QLatin1Char('|'));
        auth = session.left(bar);
        cookie = session.mid(bar + 1);
    }

    // WEB_REMIX is the client that accepts the web session: the mobile
    // clients reject the browser cookies outright (HTTP 400). It answers
    // with signatureCipher formats, which the WebView solver decodes.
    QJsonObject cli;
    cli[QStringLiteral("clientName")] = QStringLiteral("WEB_REMIX");
    cli[QStringLiteral("clientVersion")] = QStringLiteral("1.20240101.01.00");
    cli[QStringLiteral("hl")] = QStringLiteral("es");
    cli[QStringLiteral("gl")] = QStringLiteral("ES");
    QJsonObject ctx;
    ctx[QStringLiteral("client")] = cli;
    ctx[QStringLiteral("user")] = QJsonObject();
    QJsonObject body;
    body[QStringLiteral("videoId")] = id;
    body[QStringLiteral("context")] = ctx;
    body[QStringLiteral("contentCheckOk")] = true;
    body[QStringLiteral("racyCheckOk")] = true;

    QNetworkRequest req(QUrl(QStringLiteral("https://music.youtube.com/youtubei/v1/player"
                                           "?alt=json&key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
                                           "&prettyPrint=false")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(20000);
    if (!auth.isEmpty()) {
        req.setRawHeader("Authorization", auth.toUtf8());
        req.setRawHeader("Cookie", cookie.toUtf8());
    }
    req.setRawHeader("User-Agent",
                     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                     " (KHTML, like Gecko) Chrome/130.0 Safari/537.36");
    req.setRawHeader("Origin", "https://music.youtube.com");
    req.setRawHeader("Referer", "https://music.youtube.com/");
    req.setRawHeader("X-Goog-Api-Format-Version", "1");

    if (!m_apiNet)
        m_apiNet = new QNetworkAccessManager(this);
    QNetworkReply *reply = m_apiNet->post(req, QJsonDocument(body).toJson());
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, url]() { onApiReply(reply, url); });
}

void Player::onApiReply(QNetworkReply *reply, const QString &url)
{
    reply->deleteLater();
    const QByteArray raw = reply->readAll();
    if (reply->error() != QNetworkReply::NoError || raw.isEmpty()) {
        qWarning() << "[player] la API no devolvió el stream:"
                   << int(reply->error())
                   << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt()
                   << QString::fromUtf8(raw.left(200))
                   << reply->errorString();
        m_loading = false;
        emit stateChanged();
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(raw).object();
    const QJsonObject streaming =
        root.value(QStringLiteral("streamingData")).toObject();

    // The best audio format with signatureCipher (WEB_REMIX serves it
    // scrambled; the WebView solver decodes it).
    const QJsonArray formats = streaming.value(QStringLiteral("adaptiveFormats")).toArray();
    QString cipher;
    int bestBitrate = -1;
    for (const QJsonValue &fv : formats) {
        const QJsonObject f = fv.toObject();
        const QString mine = f.value(QStringLiteral("signatureCipher")).toString();
        if (mine.isEmpty())
            continue;
        const QString mime = f.value(QStringLiteral("mimeType")).toString();
        if (!mime.startsWith(QStringLiteral("audio/")))
            continue;
        const int bitrate = f.value(QStringLiteral("bitrate")).toInt();
        if (bitrate > bestBitrate) {
            bestBitrate = bitrate;
            cipher = mine;
        }
    }
    if (cipher.isEmpty()) {
        qWarning() << "[player] la API no devolvió ningún formato de audio firmado:"
                   << int(formats.count())
                   << root.value(QStringLiteral("playabilityStatus")).toObject()
                          .value(QStringLiteral("status")).toString()
                   << root.value(QStringLiteral("videoDetails")).toObject()
                          .value(QStringLiteral("videoId")).toString();
        qWarning() << root.value(QStringLiteral("playabilityStatus")).toObject()
                          .value(QStringLiteral("reason")).toString();
        qWarning() << raw.left(500);
        qWarning() << root.value(QStringLiteral("playabilityStatus")).toObject()
                          .value(QStringLiteral("reason")).toString();
        m_loading = false;
        emit stateChanged();
        return;
    }

    // signatureCipher is form-encoded: url + s + sp (sp names the query
    // parameter that has to carry the decoded signature, usually "sig").
    const QUrlQuery sc(cipher);
    m_apUrl = sc.queryItemValue(QStringLiteral("url"));
    m_apSig = sc.queryItemValue(QStringLiteral("s"));
    m_apSp = sc.hasQueryItem(QStringLiteral("sp"))
                 ? sc.queryItemValue(QStringLiteral("sp"))
                 : QStringLiteral("sig");
    QUrlQuery uq(QUrl(m_apUrl).query());
    m_apN = uq.queryItemValue(QStringLiteral("n"));
    if (m_apUrl.isEmpty() || m_apSig.isEmpty() || m_apN.isEmpty()) {
        qWarning() << "[player] url/s/n incompletos en el formato";
        m_loading = false;
        emit stateChanged();
        return;
    }

    // The player JS is referenced from the watch page (it changes whenever
    // YouTube ships a new player): it stays cached in memory, so the next
    // track doesn't re-download ~2.9 MiB.
    if (!m_playerJsText.isEmpty() && !m_playerJsId.isEmpty()) {
        solveJsWithPlayerJs(url);
        return;
    }
    QString id = url;
    if (const int v = id.lastIndexOf(QLatin1Char('=')); v >= 0)
        id = id.mid(v + 1);
    QNetworkRequest preq(QUrl(QStringLiteral("https://www.youtube.com/watch?v=") + id
                              + QStringLiteral("&bpctr=9999999999&has_verified=1")));
    preq.setTransferTimeout(20000);
    preq.setRawHeader(
        "User-Agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like"
        " Gecko) Chrome/130.0 Safari/537.36");
    const QString session = sessionCookie();
    if (!session.isEmpty()) {
        const int bar = session.indexOf(QLatin1Char('|'));
        preq.setRawHeader("Cookie", session.mid(bar + 1).toUtf8());
    }
    preq.setRawHeader("Accept-Language", "es-ES,es;q=0.9");
    QNetworkReply *preply = m_apiNet->get(preq);
    connect(preply, &QNetworkReply::finished, this,
            [this, preply, url]() { onWatchPageReply(preply, url); });
}

void Player::onWatchPageReply(QNetworkReply *reply, const QString &trackUrl)
{
    reply->deleteLater();
    const QByteArray raw = reply->readAll();
    if (reply->error() != QNetworkReply::NoError || raw.isEmpty()) {
        qWarning() << "[player] la página watch no llegó:" << reply->errorString();
        m_loading = false;
        emit stateChanged();
        return;
    }
    const QString page = QString::fromUtf8(raw);
    // The player id is stable for the whole YouTube build: any variant
    // reference gives the id; the classic player_ias variant (the one
    // yt-dlp reads too) is requested directly.
    static const QRegularExpression re(QStringLiteral(
        "\"js\": ?\"\\\\?/s\\\\?/player\\\\?/([0-9A-Za-z-]+)\\\\?/"));
    const QRegularExpressionMatch m = re.match(page);
    m_playerJsId.clear();
    if (!m.hasMatch()) {
        static const QRegularExpression re2(
            QStringLiteral("/s/player/([0-9A-Za-z-]+)/[A-Za-z0-9_]+\\.vflset"));
        const QRegularExpressionMatch m2 = re2.match(page);
        if (!m2.hasMatch()) {
            qWarning() << "[player] el id del player JS no está en la página";
            m_loading = false;
            emit stateChanged();
            return;
        }
        m_playerJsId = m2.captured(1);
    } else {
        m_playerJsId = m.captured(1);
    }
    QNetworkRequest jreq(QUrl(QStringLiteral("https://www.youtube.com/s/player/")
                              + m_playerJsId
                              + QStringLiteral("/player_ias.vflset/en_US/base.js")));
    jreq.setTransferTimeout(30000);
    jreq.setRawHeader(
        "User-Agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like"
        " Gecko) Chrome/130.0 Safari/537.36");
    QNetworkReply *jreply = m_apiNet->get(jreq);
    connect(jreply, &QNetworkReply::finished, this,
            [this, jreply, trackUrl, jurl = jreq.url()]() {
                onPlayerJsReply(jreply, jurl, trackUrl);
            });
}

void Player::onPlayerJsReply(QNetworkReply *reply, const QUrl &jsUrl,
                             const QString &trackUrl)
{
    reply->deleteLater();
    const QByteArray raw = reply->readAll();
    if (reply->error() != QNetworkReply::NoError || raw.isEmpty()) {
        qWarning() << "[player] el player JS no llegó:" << reply->errorString();
        m_loading = false;
        emit stateChanged();
        return;
    }
    m_playerJsText = QString::fromUtf8(raw);
    // A different player id invalidates any preprocessed blob of the old
    // one (a normally running session keeps the same id, so this only
    // happens when YouTube ships a new player build).
    if (!m_preprocessedFor.isEmpty() && m_playerJsId != m_preprocessedFor)
        m_preprocessed.clear();
    qInfo() << "[player] player JS cargado:" << m_playerJsId << raw.size() << "bytes";
    solveJsWithPlayerJs(trackUrl);
}

void Player::solveJsWithPlayerJs(const QString &trackUrl)
{
    // Challenges: s (signature) and n (throttle). The WebView solver runs
    // the same scripts yt-dlp uses; its answer is polled every 200 ms.
    // The first solve parses the whole player JS (~2.9 MiB) and returns
    // a preprocessed form that is cached (memory + disk): the next solves
    // skip that parse.
    QJsonArray requests;
    requests.append(QJsonObject{{QStringLiteral("type"),
                                 QStringLiteral("sig")},
                                {QStringLiteral("challenges"),
                                 QJsonArray{m_apSig}}});
    requests.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("n")},
                                {QStringLiteral("challenges"), QJsonArray{m_apN}}});

    QJsonObject input;
    bool havePre = !m_preprocessed.isEmpty();
    if (!m_playerJsId.isEmpty() && !havePre)
        havePre = !loadPreprocessed();   // true => not usable on disk
    if (!havePre) {
        input[QStringLiteral("type")] = QStringLiteral("player");
        input[QStringLiteral("player")] = m_playerJsText;
        input[QStringLiteral("output_preprocessed")] = true;
    } else {
        input[QStringLiteral("type")] = QStringLiteral("preprocessed");
        input[QStringLiteral("preprocessed_player")] = m_preprocessed;
    }
    input[QStringLiteral("requests")] = requests;
    const QString inputJson =
        QString::fromUtf8(QJsonDocument{input}.toJson(QJsonDocument::Compact));

    m_apTrack = trackUrl;
    m_solverWait = 0;
    if (!m_solverTimer) {
        m_solverTimer = new QTimer(this);
        m_solverTimer->setInterval(200);
        connect(m_solverTimer, &QTimer::timeout, this, &Player::onSolverPoll);
    }
    QJniObject::callStaticMethod<void>(
        "io/github/lotsv8pro/lotustune/WebViewSolver", "solve",
        "(Ljava/lang/String;)V",
        QJniObject::fromString(inputJson).object());
    m_solverTimer->start();
}

// Reads the preprocessed player from disk (per player id). Returns true
// when it is NOT usable (the real player text has to be sent).
bool Player::loadPreprocessed()
{
    const QString path = AppPaths::cacheDir()
                         + QStringLiteral("/solver_pp_%1.js").arg(m_playerJsId);
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly) || f.size() < 4096)
        return true;
    m_preprocessed = QString::fromUtf8(f.readAll());
    return false;
}

void Player::savePreprocessed(const QString &pp)
{
    m_preprocessed = pp;
    m_preprocessedFor = m_playerJsId;
    const QString path = AppPaths::cacheDir()
                         + QStringLiteral("/solver_pp_%1.js").arg(m_playerJsId);
    QFile f(path);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(pp.toUtf8());
}

void Player::onSolverPoll()
{
    // The solver answers through a static Java field that we poll: no
    // Qt-side thread blocks on the WebView.
    QJniEnvironment env;
    jclass cls = env.findClass("io/github/lotsv8pro/lotustune/WebViewSolver");
    if (!cls) {
        m_solverTimer->stop();
        return;
    }
    jfieldID statusField = env->GetStaticFieldID(
        cls, "sStatus", "Ljava/lang/String;");
    jstring jstatus =
        jstring(env->GetStaticObjectField(cls, statusField));
    const char *cs = env->GetStringUTFChars(jstatus, nullptr);
    const QString status = QString::fromUtf8(cs);
    env->ReleaseStringUTFChars(jstatus, cs);
    ++m_solverWait;
    if (status == QStringLiteral("working") && m_solverWait < 150)
        return;
    m_solverTimer->stop();
    if (status != QStringLiteral("done")) {
        qWarning() << "[player] el solver JS no respondió:" << status;
        if (m_chainJob) {
            ResolveJob *job = m_chainJob;
            m_chainJob = nullptr;
            m_apTrack.clear();
            m_apUrl.clear();
            onResolveFinished(job, 1);
        }
        m_loading = false;
        emit stateChanged();
        return;
    }
    jfieldID resField = env->GetStaticFieldID(
        cls, "sResult", "Ljava/lang/String;");
    jstring jres = jstring(env->GetStaticObjectField(cls, resField));
    const char *cr = env->GetStringUTFChars(jres, nullptr);
    const QString result = QString::fromUtf8(cr);
    env->ReleaseStringUTFChars(jres, cr);
    if (result.isEmpty()) {
        qWarning() << "[player] el solver devolvió un resultado vacío";
        m_loading = false;
        emit stateChanged();
        return;
    }

    const QJsonObject out = QJsonDocument::fromJson(result.toUtf8()).object();
    const QJsonArray resp = out.value(QStringLiteral("responses")).toArray();
    QString sig, nval;
    for (const QJsonValue &rv : resp) {
        const QJsonObject r = rv.toObject();
        if (r.value(QStringLiteral("type")).toString()
            != QStringLiteral("result"))
            continue;
        const QJsonObject data = r.value(QStringLiteral("data")).toObject();
        if (data.isEmpty() || data.keys().isEmpty())
            continue;
        const QString challenge = data.keys().constFirst();
        const QString value = data.value(challenge).toString();
        // s challenges are long strings (>= 40 chars), n challenges are
        // single words.
        if (challenge.size() > 20)
            sig = value;
        else
            nval = value;
    }
    if (sig.isEmpty() || nval.isEmpty()) {
        qWarning() << "[player] el solver no devolvió s/n";
        if (m_chainJob) {
            ResolveJob *job = m_chainJob;
            m_chainJob = nullptr;
            m_apTrack.clear();
            m_apUrl.clear();
            onResolveFinished(job, 1);
        }
        m_loading = false;
        emit stateChanged();
        return;
    }
    // Remember the preprocessed form for the next solves (the solver only
    // returns it when it parsed the raw player JS).
    const QString pp = out.value(QStringLiteral("preprocessed_player")).toString();
    if (!pp.isEmpty() && m_preprocessed.isEmpty())
        savePreprocessed(pp);

    // The final url: the sp parameter carries the decoded signature and
    // the n parameter the decoded throttle token.
    QString finalUrl = m_apUrl;
    {
        QUrl u(finalUrl);
        QUrlQuery uq(u.query());
        QList<QPair<QString, QString> > items;
        const auto original = uq.queryItems();
        for (const auto &kv : original)
            if (kv.first != m_apSp)
                items.append(kv);
        items.append(qMakePair(m_apSp, sig));
        uq.clear();
        for (const auto &kv : items)
            uq.addQueryItem(kv.first, kv.second);
        u.setQuery(uq);
        finalUrl = u.toString();
    }
    finalUrl.replace(QLatin1String("n=") + m_apN,
                     QLatin1String("n=") + nval);
    qInfo() << "[player] stream resuelto:" << m_apTrack.left(60) << "[" << m_playerJsId << "]";

    m_resolved.insert(m_apTrack, finalUrl);
    m_resolvedAt.insert(m_apTrack, QDateTime::currentSecsSinceEpoch());
    m_cacheDirty = true;
    m_cacheSaveTimer.start();
    if (m_chainJob) {
        // Prefetch job: the queue machinery takes it from here (it fills
        // the cache; QMediaPlayer must stay silent, and a load() that was
        // waiting for this track starts through the cached URL).
        ResolveJob *job = m_chainJob;
        m_chainJob = nullptr;
        m_apTrack.clear();
        m_apUrl.clear();
        m_apSig.clear();
        m_apN.clear();
        onResolveFinished(job, 0);
        return;
    }
    m_apTrack.clear();
    m_apUrl.clear();
    m_apSig.clear();
    m_apN.clear();
    if (m_androidPlayer && !finalUrl.isEmpty()) {
        m_androidPlayer->setSource(QUrl(finalUrl));
        m_androidPlayer->play();
    }
    m_loading = false;
    emit stateChanged();
}
#endif
