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
        QDir::homePath() + QStringLiteral("/.config/lotus-tune/cookies.txt");
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
    m_proc.setChildProcessModifier([] {
#ifdef Q_OS_LINUX
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
#endif
    });
    // Cleans a leftover socket from a previous run before starting.
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
        QDir::homePath() + QStringLiteral("/.config/lotus-tune/cookies.txt");
    if (QFile::exists(cookies)) {
        args << QStringLiteral("--cookies") << cookies
             << QStringLiteral("--extractor-args")
             // player_skip=configs avoids downloading the player's
             // configs: it trims ~0.5-1 s per resolution without
             // affecting the playback.
             << QStringLiteral("youtube:player_client=web_creator;player_skip=configs");
    }
    args << url;
    job->proc.setProgram(QStringLiteral("yt-dlp"));
    job->proc.setArguments(args);
    // If the app dies (even with SIGKILL) the slot's yt-dlp gets SIGTERM
    // and is not left orphaned eating CPU/network. It is set before EVERY
    // start because the same QProcess is reused for several
    // resolutions.
    job->proc.setChildProcessModifier([] {
#ifdef Q_OS_LINUX
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
#endif
    });
    job->proc.start();
    job->timer.start();
    if (!job->proc.waitForStarted(3000)) {
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
