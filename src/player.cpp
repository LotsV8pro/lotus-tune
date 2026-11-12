#include "player.h"
#include "audiocache.h"
#include "errortext.h"

#ifdef Q_OS_ANDROID
#include <QAudioOutput>
#include <QCoreApplication>
#include <QMediaPlayer>
#include <cstring>
#include <QCryptographicHash>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#ifdef Q_OS_ANDROID
#include <QNetworkInformation>
#endif
#include <QNetworkRequest>
#include <QSaveFile>

// Android context (widget/notification).
static jobject ltAndroidContext();
static bool ltWidgetJava();
static bool ltServiceJava();
static bool ltLyricsWidgetJava();
// Real duration of the downloaded audio (defined further below).
static qint64 localAudioDurationMs(const QString &path);
// Video id of a YouTube url (defined further below).
static QString videoIdOf(const QString &trackUrl);
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
#include <utility>

#include <QDebug>

#include <csignal>
#ifdef Q_OS_LINUX
#  include <sys/prctl.h>
#endif

// Maximum simultaneous yt-dlp resolvers: the list prefetch ("cooking"
// streams ahead) advances up to 3x faster without changing priorities.
namespace { constexpr int kMaxResolvers = 3; }

// Pre-announce window: the longest wait between the audio url being
// resolved and the request for it. With 0 it is tried right away (see
// the 2026-11-03 test: the nodes served the audio without waiting).
namespace { constexpr qint64 kPreannounceMs = 0; }

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
        job->timer.setInterval(20000);  // 20 seconds to resolve a track
        connect(&job->timer, &QTimer::timeout, this, [this, job] { onResolveTimeout(job); });
        connect(&job->proc, &QProcess::finished, this,
                [this, job](int code, QProcess::ExitStatus) { onResolveFinished(job, code); });
    }

    // On a network change (wifi <-> mobile data) the public IP changes and
    // the signed urls stop working: the cache is dropped so the tracks
    // resolve again on the new network (otherwise the 403 is permanent
    // until a restart). No backend on some deployments: it is ignored.
#ifdef Q_OS_ANDROID
    if (QNetworkInformation::loadDefaultBackend()) {
        auto *ni = QNetworkInformation::instance();
        if (ni) {
            m_lastMedium = int(ni->transportMedium());
            connect(ni, &QNetworkInformation::transportMediumChanged, this,
                    [this](QNetworkInformation::TransportMedium m) {
                        const int now = int(m);
                        if (now == m_lastMedium)
                            return;
                        m_lastMedium = now;
                        qInfo() << "[player] ha cambiado la red: se descarta la"
                                   " cache de streams (las urls van por IP)";
                        m_resolved.clear();
                        m_resolvedAt.clear();
                        m_cacheDirty = true;
                        m_cacheSaveTimer.start();
                    });
        }
    }
#endif

#ifdef Q_OS_ANDROID
    m_chainTimer = new QTimer(this);
    m_chainTimer->setSingleShot(true);
    m_chainTimer->setInterval(35000);   // a normal chain takes ~2 s
    connect(m_chainTimer, &QTimer::timeout, this,
            [this]() { abortChain(QStringLiteral("timeout")); });
#endif

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
        if (a.size() < 2)
            continue;
        const QString direct = a.at(0).toString();
        const qint64 ts = qint64(a.at(1).toDouble());
        // Third field (optional): track duration according to YouTube. It is
        // kept so a track already in the cache shows its real time even if it
        // is not resolved again.
        if (a.size() >= 3) {
            const double secs = a.at(2).toDouble();
            if (secs > 0.0)
                m_trackDur.insert(it.key(), secs);
        }
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
        o.insert(p.first, QJsonArray{m_resolved.value(p.first), double(p.second),
                                    m_trackDur.value(p.first, 0.0)});
    QDir().mkpath(QFileInfo(m_cacheFile).absolutePath());
    QFile f(m_cacheFile);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return;
    f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
    f.close();
}

void Player::setLastError(const QString &msg)
{
    if (m_lastError == msg)
        return;
    m_lastError = msg;
    emit lastErrorChanged();
}

#ifndef Q_OS_ANDROID
// On desktop there is no home widget nor Android notification: the QML
// is the same in both builds, so the call is a no-op.
void Player::updateWidget(const QString &, const QString &, bool, bool, int,
                          bool, const QString &, double, double)
{
}

void Player::syncMediaProgress(double)
{
}

void Player::updateLyricsWidget(const QString &, const QString &,
                                const QString &)
{
}
#endif

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
                    // End of track fallback: some Android backends stop at
                    // the end WITHOUT reporting it through
                    // mediaStatusChanged, so the music went silent on the
                    // last song and the app never moved to the next one.
                    if (m_duration > 0.0 && m_playing && m_position > 0.5
                        && m_position >= m_duration - 0.35)
                        androidEndOfTrack("posicion");
                });
        connect(m_androidPlayer, &QMediaPlayer::durationChanged, this,
                [this](qint64 dur) {
                    // A 0 from the backend does not erase the duration read
                    // from the file: YouTube's fragmented MP4 stay at 0 and
                    // the bar showed 0:00.
                    if (dur <= 0 && m_duration > 0.0)
                        return;
                    m_duration = dur / 1000.0;
                    emit stateChanged();
                });
        // The REAL end of track: without this (only mpv emitted it) the song
        // ended and never moved to the next one.
        connect(m_androidPlayer, &QMediaPlayer::mediaStatusChanged, this,
                [this](QMediaPlayer::MediaStatus st) {
                    if (st == QMediaPlayer::EndOfMedia) {
                        androidEndOfTrack("EndOfMedia");
                    } else if (st == QMediaPlayer::InvalidMedia) {
                        if (m_endFired)
                            return;
                        m_endFired = true;
                        qWarning() << "[player] medio no valido:"
                                   << m_currentUrl;
                        m_hasFile = false;
                        m_loading = false;
                        if (!m_currentUrl.isEmpty()
                            && m_resolved.remove(m_currentUrl) > 0) {
                            m_resolvedAt.remove(m_currentUrl);
                            m_cacheDirty = true;
                            m_cacheSaveTimer.start();
                        }
                        emit endOfFile(false);
                    }
                });
        connect(m_androidPlayer, &QMediaPlayer::playbackStateChanged, this,
                [this](QMediaPlayer::PlaybackState st) {
                    m_playing = st == QMediaPlayer::PlayingState;
                    m_hasFile = st != QMediaPlayer::StoppedState;
                    // With the app in the background or the screen off, the
                    // foreground service keeps the process alive.
                    setBackgroundPlayback(st != QMediaPlayer::StoppedState);
                    emit stateChanged();
                });
        connect(m_androidPlayer, &QMediaPlayer::errorOccurred, this,
                [this](QMediaPlayer::Error e, const QString &err) {
                    qWarning() << "[player] error de reproducción:" << int(e)
                               << err << "| source:"
                               << (m_androidPlayer->source().isValid()
                                       ? m_androidPlayer->source().toString().left(160)
                                       : QStringLiteral("<sin fuente>"));
                    m_loading = false;
                    emit stateChanged();
                });
    }
    // Watchdog: every second it checks whether the position advances. In
    // the background the Android backend sometimes goes mute without
    // changing state (MIUI silenced the app for not holding audio focus).
    // If that happens it is resumed; if it is still stuck, the track is
    // reloaded at the same point. It also closes the end of track that
    // never reports.
    m_stallTimer.setInterval(1000);
    connect(&m_stallTimer, &QTimer::timeout, this, [this] {
        if (!m_playing || !m_hasFile || m_loading) {
            m_stallTicks = 0;
            m_stallPos = m_position;
            return;
        }
        if (m_position > m_stallPos + 0.05 || m_position < m_stallPos - 0.05) {
            m_stallTicks = 0;
            m_stallPos = m_position;
            return;
        }
        m_stallPos = m_position;
        if (++m_stallTicks < 4)
            return;
        if (m_duration > 0.0 && m_position >= m_duration - 1.0) {
            qInfo() << "[player] vigilante: fin de pista sin aviso";
            androidEndOfTrack("vigilante-fin");
            m_stallTicks = 0;
            return;
        }
        if (m_stallTicks == 5) {
            qWarning() << "[player] vigilante: audio parado en"
                       << m_position << "s, reanudando";
            // A minimal seek forces the backend to rebuild the buffer without
            // anyone noticing (50 ms).
            m_androidPlayer->setPosition(qint64(m_position * 1000.0) + 50);
            return;
        }
        if (m_stallTicks >= 10) {
            const QUrl src = m_androidPlayer->source();
            if (!src.isEmpty()) {
                qWarning() << "[player] vigilante: recargando"
                           << src.toString().left(120);
                m_stallTicks = 0;
                m_stallPos = m_position;
                const qint64 at = qint64(m_position * 1000.0);
                m_androidPlayer->setSource(src);
                m_androidPlayer->setPosition(at);
                m_androidPlayer->play();
            } else {
                m_stallTicks = 0;
            }
        }
    });
    m_stallTimer.start();
    // Home widget + background playback service. If the Java classes are
    // not in the APK it warns and continues: the music works the same, only
    // the external controls are missing.
    if (!ltWidgetJava())
        qWarning() << "[widget] PlayerWidget no esta en el APK:"
                   << "recompila el modulo Java (gradle) o reinstala";
    else
        QJniObject::callStaticMethod<void>(
            "com/lotustuneremote/app/PlayerWidget", "attach",
            "(Landroid/content/Context;)V", ltAndroidContext());
    if (ltLyricsWidgetJava())
        QJniObject::callStaticMethod<void>(
            "com/lotustuneremote/app/LyricsWidget", "attach",
            "(Landroid/content/Context;)V", ltAndroidContext());
    if (ltWidgetJava() && !m_widgetPoll) {
        m_widgetPoll = new QTimer(this);
        m_widgetPoll->setInterval(400);
        connect(m_widgetPoll, &QTimer::timeout, this, &Player::pollWidgetActions);
        m_widgetPoll->start();
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
            // The cached direct URL may have expired: it is invalidated so the retry
            // resolves it again (and does not fail in a loop).
            // remove() already returns bool (MSVC warned about the "> 0").
            if (!m_currentUrl.isEmpty() && m_resolved.remove(m_currentUrl)) {
                m_resolvedAt.remove(m_currentUrl);
                m_cacheDirty = true;
                m_cacheSaveTimer.start();
            }
            const QString rawErr =
                o.value(QStringLiteral("error")).toString() + QLatin1Char(' ')
                + o.value(QStringLiteral("file_error")).toString();
            qWarning() << "[player] playback error" << "url=" << m_currentUrl
                       << "err=" << rawErr;
            setLastError(LotusText::friendlyNetError(rawErr));
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
                if (m_lastError.isEmpty())
                    setLastError(tr("No se ha podido reproducir la pista."));
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

// Opens a local file in the Qt player. The duration is measured on the
// file itself because the Android backend does not get it from
// YouTube's fragmented MP4 (the bar stayed at 0:00 and seeking inside
// the song did not work).
#ifdef Q_OS_ANDROID
void Player::androidPlayLocalFile(const QString &path)
{
    if (!m_androidPlayer)
        return;
    m_mediaDurMs = localAudioDurationMs(path);
    if (m_mediaDurMs > 0) {
        m_duration = m_mediaDurMs / 1000.0;
        qInfo() << "[player] duracion del fichero:" << m_duration << "s";
    } else if (m_duration <= 0.0 && !m_currentUrl.isEmpty()) {
        // The file carries no duration (WebM DASH): the one YouTube gave at
        // resolve time is used. It is compared by id because the track url may
        // be music.youtube.com and the resolved one www.youtube.com.
        double secs = 0.0;
        const QString want = videoIdOf(m_currentUrl);
        for (auto it = m_trackDur.constBegin(); it != m_trackDur.constEnd(); ++it) {
            if (videoIdOf(it.key()) == want) {
                secs = it.value();
                break;
            }
        }
        if (secs > 0.0) {
            m_duration = secs;
            qInfo() << "[player] duracion (YouTube):" << m_duration << "s";
        }
    }
    m_androidPlayer->setSource(QUrl::fromLocalFile(path));
    m_androidPlayer->play();
    m_loading = false;
    emit stateChanged();
}

// End of track of the Qt player.
//
// The debounce is mandatory: when the next track is loaded, the backend
// still delivers positions of the previous one (at its end), and
// without a window the report repeated 3-4 times in a row and the
// player skipped songs. 3 s is more than enough for the new source to
// start at 0.
void Player::androidEndOfTrack(const char *why)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (m_endFired || now < m_endBlockUntil)
        return;
    m_endFired = true;
    m_endBlockUntil = now + 3000;
    m_hasFile = false;
    m_loading = false;
    m_position = 0;
    emit positionChanged();
    qInfo() << "[player] fin de pista (" << why << ")";
    emit endOfFile(true);
}
#endif   // Q_OS_ANDROID

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
        m_duration = m_hintDur > 0.0 ? m_hintDur : 0.0;
        m_mediaDurMs = 0;
        m_endFired = false;
        m_currentUrl = url;
        m_hasFile = true;
        m_loading = true;
    setLastError(QString());
        m_playing = true;
        emit positionChanged();
        emit stateChanged();
        if (network) {
            // Cached from an earlier prefetch: it sounds instantly.
            if (m_resolved.contains(url)) {
                const QString direct = m_resolved.value(url);
                const QString localPath = m_audioLocal.value(url);
                if (!localPath.isEmpty() && QFileInfo(localPath).isFile()
                    && QFileInfo(localPath).size() > 4096) {
                    androidPlayLocalFile(localPath);
                    return;
                }
                if (direct.startsWith(QStringLiteral("file:"))) {
                    // Stale cache entry of an old build: a deleted local
                    // file is resolved again from scratch.
                    if (QFileInfo(direct.mid(7)).isFile()) {
                        androidPlayLocalFile(direct.mid(7));
                        return;
                    }
                    m_resolved.remove(url);
                    beginChain(url);
                    return;
                }
                // A http url cached: it goes through the local copy (the
                // same path as the fresh resolutions).
                startAudioFetch(url, direct, true);
                return;
            }
            beginChain(url);
        } else {
            androidPlayLocalFile(url);
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
        // A job that already has a url is waiting (on Android there is only one
        // chain at a time, so the rest wait their turn): overwriting its url
        // would lose it.
        if (!job->url.isEmpty())
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
    // No yt-dlp on a phone: the stream is resolved with the app's own chain
    // (WEB_REMIX + WebView solver). One chain at a time: the other jobs
    // stay WAITING for their turn (job->url set) and endChain() calls
    // resolveQueue() again. Before, they were marked as failed right away,
    // and since the failure dragged a loadImpl() along, the track the user
    // had just asked for ended up silent.
    if (!m_apTrack.isEmpty()) {
        job->timer.stop();
        return;
    }
    m_chainJob = job;
    beginChain(url);
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
    // A job with a url assigned is resolving (Linux: yt-dlp running) or
    // waiting for its turn (Android: single chain queue). Without this,
    // dedupe did not work on the phone (proc never starts) and the same
    // track was queued over and over.
    for (const ResolveJob *job : m_jobs) {
        if (!job->url.isEmpty() && job->url == url)
            return true;
    }
#ifdef Q_OS_ANDROID
    if (m_apTrack == url)
        return true;
#endif
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
QString Player::sessionForOrigin(const QString &origin) const
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
    // The signature of the request (the same one ytm_api.py uses): the
    // digest binds the origin of the request, not a fixed host.
    const QString ts = QString::number(QDateTime::currentSecsSinceEpoch());
    const QByteArray digest = QCryptographicHash::hash(
        QStringLiteral("%1 %2 %3").arg(ts, sapisid, origin).toUtf8(),
        QCryptographicHash::Sha1).toHex();
    QString cookie;
    for (auto it = jar.constBegin(); it != jar.constEnd(); ++it)
        cookie += QStringLiteral("%1=%2; ").arg(it.key(), it.value());
    cookie.chop(2);
    return QStringLiteral("SAPISIDHASH %1_%2|%3").arg(ts, QString::fromLatin1(digest),
                                                  cookie);
}

// The catalog/lyrics keep talking to music.youtube.com.
QString Player::sessionCookie() const
{
    return sessionForOrigin(QStringLiteral("https://music.youtube.com"));
}

// The 11-character id of the video from any of its url forms:
// "...watch?v=ID&...", "...youtu.be/ID", "ID".
static QString videoIdOf(const QString &trackUrl)
{
    QString id = trackUrl;
    const int v = id.lastIndexOf(QLatin1Char('='));
    if (v >= 0)
        id = id.mid(v + 1);
    for (const char stop : {'&', '#', ' '}) {
        const int at = id.indexOf(QChar::fromLatin1(stop));
        if (at >= 0)
            id = id.left(at);
    }
    // A non-parameter form (youtu.be/ID) has no '=': the tail is the id.
    if (id.size() < 11 || id.startsWith(QLatin1String("/watch"))) {
        const QString tail = trackUrl.mid(trackUrl.lastIndexOf(QLatin1Char('/')) + 1);
        const int at = tail.indexOf(QLatin1Char('?'));
        return (at >= 0 && tail.size() - at - 1 >= 11) ? tail.mid(at + 2) : tail;
    }
    return id;
}

// Real duration of the downloaded audio, read from the file itself.
//
// It is needed because the Qt player on Android stays at 0 with
// YouTube's fragmented MP4 (the `moov` carries `mvex` and the backend
// does not compute the duration): the bar showed 0:00 and seeking
// inside the song did not work. `mvhd` is read from the MP4 and
// `Info>Duration` from the WebM.
#ifdef Q_OS_ANDROID
static qint64 localAudioDurationMs(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return 0;
    const QByteArray buf = f.read(4 * 1024 * 1024);
    auto be32 = [](const QByteArray &b, int at) -> quint32 {
        return (quint32(quint8(b.at(at))) << 24)
               | (quint32(quint8(b.at(at + 1))) << 16)
               | (quint32(quint8(b.at(at + 2))) << 8)
               | quint32(quint8(b.at(at + 3)));
    };
    // --- MP4 / M4A ---
    const int mv = buf.indexOf("mvhd");
    if (mv >= 0 && mv + 32 < buf.size()) {
        const int p = mv + 4;              // version + flags
        if (p + 20 <= buf.size()) {
            const int version = quint8(buf.at(p));
            quint32 timescale = 0;
            quint64 duration = 0;
            if (version == 1) {
                timescale = be32(buf, p + 20);
                duration = (quint64(be32(buf, p + 24)) << 32)
                           | be32(buf, p + 28);
            } else {
                timescale = be32(buf, p + 12);
                duration = be32(buf, p + 16);
            }
            if (timescale > 0 && duration > 0)
                return qint64(double(duration) * 1000.0 / double(timescale));
        }
    }
    // --- WebM / Matroska (itag 249/250/251) ---
    const int dur = buf.indexOf(QByteArray("\x44\x89", 2));
    if (dur >= 0 && dur + 2 < buf.size()) {
        const int b = quint8(buf.at(dur + 2));
        const int len = b & 0x0f;
        double secs = 0.0;
        if ((b & 0x80) && len == 4 && dur + 7 <= buf.size()) {
            const quint32 raw = be32(buf, dur + 3);
            float fl;
            memcpy(&fl, &raw, 4);
            secs = double(fl);
        } else if ((b & 0x80) && len == 8 && dur + 11 <= buf.size()) {
            quint64 raw = 0;
            for (int i = 0; i < 8; ++i)
                raw = (raw << 8) | quint8(buf.at(dur + 3 + i));
            double db;
            memcpy(&db, &raw, 8);
            secs = db;
        }
        // Default TimecodeScale: 1,000,000 ns (1 ms).
        if (secs > 0.0 && secs < 100000.0)
            return qint64(secs * 1000.0);
    }
    return 0;
}
#endif   // Q_OS_ANDROID

// Starts the resolve chain for `url`. Only one can be in flight: the
// solver's WebView is a single one and its state (challenges, signed
// url) is single lane. If another one comes, the requested track is
// noted and enters as soon as it ends; if it is the same one, nothing
// is touched (retrying it only gave "solver busy").
void Player::beginChain(const QString &url, bool forDownload)
{
    if (url.isEmpty() || m_resolved.contains(url))
        return;
    if (m_apTrack == url) {
        // Already resolving: if a download asks for it, it is noted so the
        // panel is told when it finishes (the chain is the same one).
        if (forDownload && !m_dlQueue.contains(url))
            m_dlQueue.append(url);
        return;
    }
    if (!m_apTrack.isEmpty()) {
        m_apWanted = url;
        qInfo() << "[player] resolucion en espera (cadena ocupada):" << url;
        return;
    }
    m_dlChainUrl = forDownload ? url : QString();
    m_apTrack = url;
    m_apUrl.clear();
    m_apSig.clear();
    m_apSp.clear();
    m_apN.clear();
    m_clientIdx = 0;
    if (m_chainTimer)
        m_chainTimer->start();
    resolveWithApi(url);
}

// Closes the chain in flight and frees the lane. It starts the track
// that was left waiting and refills the resolve queue.
void Player::endChain()
{
    if (m_chainTimer)
        m_chainTimer->stop();
    if (m_solverTimer)
        m_solverTimer->stop();
    m_apTrack.clear();
    m_apUrl.clear();
    m_apSig.clear();
    m_apSp.clear();
    m_apN.clear();
    m_dlChainUrl.clear();
    if (!m_apWanted.isEmpty()) {
        const QString next = m_apWanted;
        m_apWanted.clear();
        QTimer::singleShot(0, this, [this, next]() { beginChain(next); });
    } else if (!m_dlQueue.isEmpty()) {
        // Nobody from the player is using it: the downloads' turn.
        QTimer::singleShot(0, this, &Player::startNextDownloadResolve);
    }
    // Out of this stack: the waiting jobs can start now.
    QTimer::singleShot(0, this, &Player::resolveQueue);
}

// ---- Stream resolution for the downloads panel ------------------------
// The chain (WEB_REMIX + solver) is single lane: downloads queue
// behind the playback and are resolved one at a time.
void Player::resolveForDownload(const QString &url)
{
    const QString u = normalizeUrl(url);
    if (u.isEmpty() || videoIdOf(u).size() < 11)
        return;
    for (const QString &q : std::as_const(m_dlQueue))
        if (videoIdOf(q) == videoIdOf(u))
            return;
    if (m_resolved.contains(u)) {
        const QString direct = m_resolved.value(u);
        QTimer::singleShot(0, this, [this, u, direct]() {
            emit downloadStreamResolved(u, direct);
        });
        return;
    }
    m_dlQueue.append(u);
    if (m_apTrack.isEmpty())
        startNextDownloadResolve();
}

void Player::startNextDownloadResolve()
{
    if (!m_apTrack.isEmpty() || m_dlQueue.isEmpty())
        return;
    const QString next = m_dlQueue.takeFirst();
    if (m_resolved.contains(next)) {
        const QString direct = m_resolved.value(next);
        QTimer::singleShot(0, this, [this, next, direct]() {
            emit downloadStreamResolved(next, direct);
        });
        return;
    }
    beginChain(next, /*forDownload=*/true);
}

void Player::cancelDownloadResolve()
{
    m_dlQueue.clear();
    if (!m_dlChainUrl.isEmpty())
        abortChain(QStringLiteral("descarga cancelada"));
}

// Abandons the resolve chain in flight and leaves the state clean for
// the next track. Every error exit goes through here: before, several
// of them left m_apTrack set and the player silently rejected ALL the
// following resolutions (the next button stopped working).
void Player::abortChain(const QString &why)
{
    if (!m_apTrack.isEmpty() || m_chainJob)
        qWarning() << "[player] resolucion abandonada:" << why;
    m_loading = false;
    const QString failed = m_apTrack;
    const bool wasDownload = !m_dlChainUrl.isEmpty()
        && videoIdOf(m_dlChainUrl) == videoIdOf(failed);
    ResolveJob *job = m_chainJob;
    m_chainJob = nullptr;
    endChain();
    if (wasDownload)
        emit downloadStreamFailed(failed, why);
    if (job)
        onResolveFinished(job, 1);
    emit stateChanged();
}

// Player clients, in the order they are tried. YouTube changes what each
// one is allowed to answer every few weeks: TVHTML5 was the one that
// handed out formats for months and today it replies "the page needs to
// be reloaded" (or LOGIN_REQUIRED), while VISIONOS answers normally with
// the same web session and needs no PO token. Keeping the list short
// means a dead client costs one request, not a broken player.
namespace {
struct ClientProfile {
    const char *name;
    const char *version;
    const char *clientId;   // X-Youtube-Client-Name
    const char *ua;
    const char *make;
    const char *model;
    const char *osName;
    const char *osVersion;
    bool needsSts;
};
const ClientProfile kClients[] = {
    { "VISIONOS", "1.02", "101",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/26.0 Safari/605.1.15",
      "Apple", "RealityDevice17,1", "visionOS", "26.5.23O471", false },
    { "TVHTML5", "5.20260707", "7",
      "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 "
      "(KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
      "Samsung", "UKS9800", "Tizen", "2.4.0", true },
};
constexpr int kClientCount = int(sizeof(kClients) / sizeof(kClients[0]));
}   // namespace

void Player::resolveWithApi(const QString &url)
{
    // The 11-character id of the video (the watch URL or the permalink).
    const QString id = videoIdOf(url);
    if (id.size() < 11)
        return;

    // The first client that is going to answer needs, at least, the
    // visitor id scraped from the watch page and the player build (the
    // solver's n transform). The sts only matters to the TV fallback.
    const bool needSts = (m_clientIdx >= 0 && m_clientIdx < kClientCount)
                             ? kClients[m_clientIdx].needsSts
                             : true;
    if (m_visitor.isEmpty() || m_playerJsText.isEmpty()
        || (needSts && m_sigTs.isEmpty())) {
        m_apiPending = url;
        fetchBootPage(url);
        return;
    }
    sendPlayerRequest(url);
}



void Player::sendPlayerRequest(const QString &trackUrl)
{
    // The id of THIS track (a bad id makes YouTube answer "unavailable").
    const QString id = videoIdOf(trackUrl);
    static const QUrl apiUrl(QStringLiteral(
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"));
    if (m_clientIdx < 0 || m_clientIdx >= kClientCount)
        m_clientIdx = 0;
    const ClientProfile &cli = kClients[m_clientIdx];
    const QByteArray ua(cli.ua);

    QJsonObject client;
    client[QStringLiteral("clientName")] = QString::fromLatin1(cli.name);
    client[QStringLiteral("clientVersion")] = QString::fromLatin1(cli.version);
    client[QStringLiteral("deviceMake")] = QString::fromLatin1(cli.make);
    client[QStringLiteral("deviceModel")] = QString::fromLatin1(cli.model);
    client[QStringLiteral("userAgent")] = QString::fromLatin1(cli.ua);
    client[QStringLiteral("osName")] = QString::fromLatin1(cli.osName);
    client[QStringLiteral("osVersion")] = QString::fromLatin1(cli.osVersion);
    client[QStringLiteral("hl")] = QStringLiteral("en");
    client[QStringLiteral("gl")] = QStringLiteral("US");
    client[QStringLiteral("timeZone")] = QStringLiteral("UTC");
    client[QStringLiteral("utcOffsetMinutes")] = 0;
    if (!m_visitor.isEmpty())
        client[QStringLiteral("visitorData")] = m_visitor;

    QJsonObject ctx;
    ctx[QStringLiteral("client")] = client;
    QJsonObject body;
    body[QStringLiteral("videoId")] = id;
    body[QStringLiteral("context")] = ctx;
    body[QStringLiteral("contentCheckOk")] = true;
    body[QStringLiteral("racyCheckOk")] = true;
    if (cli.needsSts) {
        // The sts (read from the player JS) is what makes the TV player
        // answer with formats instead of "video unavailable".
        QJsonObject cpc;
        cpc[QStringLiteral("html5Preference")] =
            QStringLiteral("HTML5_PREF_WANTS");
        cpc[QStringLiteral("signatureTimestamp")] = m_sigTs.toInt();
        QJsonObject playbackContext;
        playbackContext[QStringLiteral("contentPlaybackContext")] = cpc;
        body[QStringLiteral("playbackContext")] = playbackContext;
    }

    QNetworkRequest req(apiUrl);
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(20000);
    req.setRawHeader("User-Agent", ua);
    req.setRawHeader("Origin", "https://www.youtube.com");
    req.setRawHeader("Referer", "https://www.youtube.com/");
    req.setRawHeader("X-Youtube-Client-Name", cli.clientId);
    req.setRawHeader("X-Youtube-Client-Version", cli.version);
    req.setRawHeader("X-Goog-Api-Format-Version", "1");
    if (!m_visitor.isEmpty())
        req.setRawHeader("X-Goog-Visitor-Id", m_visitor.toUtf8());
    // With a logged session the play is not blocked by IP reputation
    // (carrier CGNAT networks refuse the anonymous play of some videos).
    // The digest binds www.youtube.com, the host of this request.
    const QString session = sessionForOrigin(QStringLiteral("https://www.youtube.com"));
    if (!session.isEmpty()) {
        const int bar = session.indexOf(QLatin1Char('|'));
        req.setRawHeader("Authorization", session.left(bar).toUtf8());
        req.setRawHeader("Cookie", session.mid(bar + 1).toUtf8());
        qInfo() << "[player] GetPlayer" << cli.name << "con sesión iniciada";
    } else {
        qInfo() << "[player] GetPlayer" << cli.name << "anónimo (sin sesión)";
    }

    if (!m_apiNet)
        m_apiNet = new QNetworkAccessManager(this);
    QNetworkReply *reply = m_apiNet->post(req, QJsonDocument(body).toJson());
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, trackUrl]() { onApiReply(reply, trackUrl); });
}

// The watch page gives the anonymous visitor id AND the player id; its
// TV player build provides the sts.
void Player::fetchBootPage(const QString &trackUrl)
{
    // watch page of the id itself (not of the full url!)
    const QString id = videoIdOf(trackUrl);

    QNetworkRequest preq(QUrl(QStringLiteral("https://www.youtube.com/watch?v=") + id
                              + QStringLiteral("&bpctr=9999999999&has_verified=1")));
    preq.setTransferTimeout(20000);
    preq.setRawHeader(
        "User-Agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like"
        " Gecko) Chrome/130.0 Safari/537.36");
    preq.setRawHeader("Accept-Language", "en-US,en;q=0.9");
    // With a logged session the boot page binds the visitor token to the
    // account: CGNAT networks refuse the play of an authed request whose
    // visitor was fetched anonymously.
    const QString pageSession = sessionCookie();
    if (!pageSession.isEmpty()) {
        const int bar = pageSession.indexOf(QLatin1Char('|'));
        preq.setRawHeader("Cookie", pageSession.mid(bar + 1).toUtf8());
    }
    QNetworkReply *preply = (m_apiNet ? m_apiNet : (m_apiNet = new QNetworkAccessManager(this)))->get(preq);
    connect(preply, &QNetworkReply::finished, this,
            [this, preply, trackUrl]() { onWatchPageReply(preply, trackUrl); });
}

void Player::onApiReply(QNetworkReply *reply, const QString &url)
{
    reply->deleteLater();
    // Only the answer of the chain in flight matters: the one from an
    // abandoned chain arrived late and clobbered the challenges/url of the
    // new one.
    if (m_apTrack.isEmpty() || url != m_apTrack) {
        qInfo() << "[player] respuesta tardia ignorada:" << url;
        return;
    }
    const QByteArray raw = reply->readAll();
    if (reply->error() != QNetworkReply::NoError || raw.isEmpty()) {
        qWarning() << "[player] la API no devolvió el stream:"
                   << int(reply->error())
                   << reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt()
                   << QString::fromUtf8(raw.left(200))
                   << reply->errorString();
        abortChain(QStringLiteral("respuesta de la API"));
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(raw).object();
    // Which video was asked (so failures can be replayed on the desktop
    // with the exact same id) and the verdict details.
    const QString rawText = QString::fromUtf8(raw.left(12000));
    QString reason;
    if (const int ri = rawText.lastIndexOf(QLatin1String("\"reason\":\"")); ri >= 0) {
        reason = rawText.mid(ri + 10, 60);
        reason = reason.left(reason.indexOf(QLatin1Char('"')));
    }
    qInfo() << "[player] GetPlayer TV respondió para" << url
            << "| status:"
            << root.value(QStringLiteral("playabilityStatus"))
                   .toObject()
                   .value(QStringLiteral("status"))
                   .toString()
            << "| reason:" << reason;
    const QJsonObject streaming =
        root.value(QStringLiteral("streamingData")).toObject();

    // Track duration. It is needed because the downloaded file does not
    // always carry it: YouTube's DASH WebM omit the Duration element and
    // the fragmented MP4 stays at 0:00 in the Android backend. With this
    // the bar shows the real time and the end of track fallback can fire
    // the "next".
    {
        double secs = root.value(QStringLiteral("videoDetails"))
                          .toObject()
                          .value(QStringLiteral("lengthSeconds"))
                          .toString()
                          .toDouble();
        if (secs <= 0.0) {
            const QJsonArray af =
                streaming.value(QStringLiteral("adaptiveFormats")).toArray();
            for (const QJsonValue &v : af) {
                const double ms = v.toObject()
                                      .value(QStringLiteral("approxDurationMs"))
                                      .toString()
                                      .toDouble();
                secs = qMax(secs, ms / 1000.0);
            }
        }
        if (secs > 0.0) {
            m_trackDur.insert(url, secs);
            m_cacheDirty = true;
            m_cacheSaveTimer.start();
            if (m_duration <= 0.0 && !m_currentUrl.isEmpty()
                && videoIdOf(url) == videoIdOf(m_currentUrl)) {
                m_duration = secs;
                emit stateChanged();
            }
        }
    }

    // The best audio format. Two shapes arrive here:
    //  - `signatureCipher` (url + s): the web clients sign the URL and the
    //    WebView solver has to rebuild it.
    //  - `url`: the app clients (VISIONOS and friends) hand a ready URL
    //    that only needs the `n` throttle token transformed.
    // Preference for the AAC m4a (itag 140): the Android decoder (Media3)
    // opens it always, while the opus/webm can fail on some devices.
    const QJsonArray formats = streaming.value(QStringLiteral("adaptiveFormats")).toArray();
    QJsonObject chosen;
    QJsonObject chosenOpus;
    int bestBitrate = -1;
    int opusBitrate = -1;
    QStringList offered;
    for (const QJsonValue &fv : formats) {
        const QJsonObject f = fv.toObject();
        if (f.value(QStringLiteral("signatureCipher")).toString().isEmpty()
            && f.value(QStringLiteral("url")).toString().isEmpty())
            continue;
        const QString mime = f.value(QStringLiteral("mimeType")).toString();
        if (!mime.startsWith(QStringLiteral("audio/")))
            continue;
        const int bitrate = f.value(QStringLiteral("bitrate")).toInt();
        offered << QStringLiteral("itag%1 %2 %3k")
                       .arg(f.value(QStringLiteral("itag")).toInt())
                       .arg(mime.section(QLatin1Char(';'), 0, 0))
                       .arg(bitrate / 1000);
        if (mime.startsWith(QStringLiteral("audio/mp4"))) {
            if (bitrate > bestBitrate) {
                bestBitrate = bitrate;
                chosen = f;
            }
        } else if (bitrate > opusBitrate) {
            opusBitrate = bitrate;
            chosenOpus = f;
        }
    }
    if (!offered.isEmpty())
        qInfo() << "[player] audio ofrecido:" << offered.join(QLatin1String(" | "));
    // m4a/AAC is the most compatible container, but if the node serves a
    // clearly better opus (e.g. 160k against 128k) it is used: it plays
    // from a local file and FFmpeg opens both.
    if (!chosenOpus.isEmpty() && opusBitrate > bestBitrate + bestBitrate / 10)
        chosen = chosenOpus;
    else if (chosen.isEmpty())
        chosen = chosenOpus;
    if (chosen.isEmpty()) {
        // YouTube rotates what each client is allowed to answer without
        // warning: this one may have run dry. Try the next one on the same
        // chain before giving up.
        if (m_clientIdx + 1 < kClientCount) {
            qInfo() << "[player] sin formatos con" << kClients[m_clientIdx].name
                    << "→ se prueba" << kClients[m_clientIdx + 1].name;
            ++m_clientIdx;
            m_apiPending = url;
            sendPlayerRequest(url);
            return;
        }
        // One boot refresh per track: the cached visitor can have gone stale
        // ("video unavailable"), the page gives a new token and the same
        // request is retried once.
        const QString pStatus = root.value(QStringLiteral("playabilityStatus"))
                                    .toObject()
                                    .value(QStringLiteral("status"))
                                    .toString();
        if (!m_retriedBoot && (pStatus == QStringLiteral("UNPLAYABLE")
                               || pStatus == QStringLiteral("ERROR")
                               || pStatus == QStringLiteral("LOGIN_REQUIRED"))) {
            m_retriedBoot = true;
            m_visitor.clear();
            m_sigTs.clear();
            m_apUrl.clear();
            m_apSig.clear();
            m_clientIdx = 0;
            m_apiPending = url;
            qInfo() << "[player] la API rechazó la pista; renovando el boot";
            fetchBootPage(url);
            return;
        }
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
        abortChain(QStringLiteral("sin formato de audio firmado"));
        return;
    }

    // signatureCipher is form-encoded: url + s + sp (sp names the query
    // parameter that has to carry the decoded signature, usually "sig").
    // FullyDecoded: YT reencodes even '?' inside the url value (%3F) and
    // the default decode mode would leave it -> a stream url with NO
    // visible query.
    m_retriedBoot = false;
    const QString cipher = chosen.value(QStringLiteral("signatureCipher")).toString();
    if (!cipher.isEmpty()) {
        const QUrlQuery sc(cipher);
        m_apUrl = sc.queryItemValue(QStringLiteral("url"), QUrl::FullyDecoded);
        m_apSig = sc.queryItemValue(QStringLiteral("s"), QUrl::FullyDecoded);
        m_apSp = sc.hasQueryItem(QStringLiteral("sp"))
                     ? sc.queryItemValue(QStringLiteral("sp"), QUrl::FullyDecoded)
                     : QStringLiteral("sig");
    } else {
        // Ready URL from an app client: only the n parameter is missing.
        m_apUrl = chosen.value(QStringLiteral("url")).toString();
        m_apSig.clear();
        m_apSp = QStringLiteral("sig");
    }
    QUrlQuery uq(QUrl(m_apUrl).query());
    m_apN = uq.queryItemValue(QStringLiteral("n"));
    if (m_apUrl.isEmpty()) {
        qWarning() << "[player] formato sin url (len cipher:" << cipher.size() << ")";
        abortChain(QStringLiteral("formato sin url"));
        return;
    }
    // No challenge at all (the URL already plays): nothing to solve.
    if (m_apSig.isEmpty() && m_apN.isEmpty()) {
        finishStream(m_apUrl);
        return;
    }

    // The player JS is referenced from the watch page (it changes whenever
    // YouTube ships a new player): it stays cached in memory, so the next
    // track doesn't re-download ~2.9 MiB.
    if (!m_playerJsText.isEmpty() && !m_playerJsId.isEmpty()) {
        solveJsWithPlayerJs(url);
        return;
    }
    qInfo() << "[player] falta el player JS: página watch de boot";
    m_apiPending = url;
    fetchBootPage(url);
}

void Player::onWatchPageReply(QNetworkReply *reply, const QString &trackUrl)
{
    reply->deleteLater();
    if (m_apTrack.isEmpty() || trackUrl != m_apTrack) {
        qInfo() << "[player] página watch tardía ignorada:" << trackUrl;
        return;
    }
    const QByteArray raw = reply->readAll();
    if (reply->error() != QNetworkReply::NoError || raw.isEmpty()) {
        qWarning() << "[player] la página watch no llegó:" << reply->errorString();
        abortChain(QStringLiteral("pagina watch"));
        return;
        return;
    }
    const QString page = QString::fromUtf8(raw);
    // The anonymous visitor id travels in the page's ytcfg: the TV player
    // request only answers with formats when this token is in its
    // X-Goog-Visitor-Id header.
    static const QRegularExpression visitorRe(QStringLiteral(
        R"re("INNERTUBE_CONTEXT":\{"client":\{[^}]*?"visitorData":"([^"]+)")re"));
    if (const QRegularExpressionMatch mv = visitorRe.match(page);
        mv.hasMatch())
        m_visitor = mv.captured(1);
    // The page carries the token JSON-escaped (\u003d, \u0026): decoded
    // is what the header expects (same as the node reference test).
    m_visitor.replace(QStringLiteral("\\u003d"), QStringLiteral("="));
    m_visitor.replace(QStringLiteral("\\u0026"), QStringLiteral("&"));
    if (!m_visitor.isEmpty())
        qInfo() << "[player] visitor listo:" << m_visitor.size() << "bytes"
                << m_visitor.left(14);
    // Which egress IP YouTube attributed to this boot page (the visitor
    // token is bound to it: a carrier CGNAT IP explains play refusals
    // that do not reproduce on the desktop).
    if (const QRegularExpressionMatch mh = QRegularExpression(QStringLiteral(
            R"re("remoteHost":"([0-9.]+)")re")).match(page); mh.hasMatch())
        qInfo() << "[player] remoteHost de la página boot:" << mh.captured(1);
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
    // The solver must run the SAME build that signed the formats: the app
    // clients (VISIONOS) sign with the page's regular player, while the
    // old TV client used a tv-* build. The page tells us which one.
    QString jsPath;
    static const QRegularExpression jsPathRe(
        QStringLiteral(R"re("js":"(.*?)")re"));
    if (const QRegularExpressionMatch mj = jsPathRe.match(page); mj.hasMatch())
        jsPath = mj.captured(1);
    if (jsPath.isEmpty()) {
        static const QRegularExpression jsUrlRe(
            QStringLiteral(R"re("jsUrl":"(.*?)")re"));
        if (const QRegularExpressionMatch mj = jsUrlRe.match(page); mj.hasMatch())
            jsPath = mj.captured(1);
    }
    jsPath.replace(QStringLiteral("\\/"), QStringLiteral("/"));
    jsPath.replace(QStringLiteral("\\u0026"), QStringLiteral("&"));
    if (jsPath.isEmpty())
        jsPath = QStringLiteral("/s/player/") + m_playerJsId
                 + QStringLiteral("/player_ias.vflset/en_US/base.js");
    QUrl jurl(jsPath);
    if (jurl.isRelative())
        jurl = QUrl(QStringLiteral("https://www.youtube.com") + jsPath);
    QNetworkRequest jreq(jurl);
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
    if (m_apTrack.isEmpty() || trackUrl != m_apTrack) {
        qInfo() << "[player] player JS tardío ignorado:" << trackUrl;
        return;
    }
    const QByteArray raw = reply->readAll();
    if (reply->error() != QNetworkReply::NoError || raw.isEmpty()) {
        qWarning() << "[player] el player JS no llegó:" << reply->errorString();
        m_loading = false;
        emit stateChanged();
        return;
    }
    m_playerJsText = QString::fromUtf8(raw);
    // The signatureTimestamp (sts) travels inside the build itself: the
    // TV player request needs it or YouTube answers "unavailable".
    static const QRegularExpression stsRe(QStringLiteral(
        "(?:signatureTimestamp|sts)\\s*:\\s*([0-9]{5})"));
    if (const QRegularExpressionMatch mSts = stsRe.match(m_playerJsText);
        mSts.hasMatch())
        m_sigTs = mSts.captured(1);
    // A different player id invalidates any preprocessed blob of the old
    // one (a normally running session keeps the same id, so this only
    // happens when YouTube ships a new player build).
    if (!m_preprocessedFor.isEmpty() && m_playerJsId != m_preprocessedFor)
        m_preprocessed.clear();
    qInfo() << "[player] player JS cargado:" << m_playerJsId << raw.size()
            << "bytes | sts:" << m_sigTs;
    // Boot path (the page was fetched before asking the API): now the
    // player request can be sent with visitor + sts ready.
    if (m_apUrl.isEmpty() && !m_apiPending.isEmpty()) {
        const QString pending = m_apiPending;
        m_apiPending.clear();
        sendPlayerRequest(pending);
        return;
    }
    solveJsWithPlayerJs(trackUrl);
}

void Player::solveJsWithPlayerJs(const QString &trackUrl)
{
    // The n challenge is always there (it throttles the stream); the s
    // challenge only exists in the signatureCipher formats. A chain with
    // neither is a plain mistake and has nothing to solve.
    if (m_apN.isEmpty() && m_apSig.isEmpty()) {
        qWarning() << "[player] solve con retos vacíos; ignorado (s:"
                   << m_apSig.size() << "| n:" << m_apN.size() << ")";
        return;
    }
    // A solve is already in flight: the poll serves it; do not hijack
    // the WebView (a second post returns "solver busy").
    if (m_solverTimer && m_solverTimer->isActive()) {
        if (m_apTrack == trackUrl) {
            // It is the SAME track/chain: the poll will deliver the result.
            // Abandoning here left the track silent forever (it was the bug behind
            // the "does not play" reports on the phone).
            qInfo() << "[player] solve ya en vuelo para esta pista; se espera";
            return;
        }
        // The WebView is on another challenge (from an abandoned chain):
        // waiting here hung the player. This chain is abandoned; the next one
        // resolves again with everything clean.
        abortChain(QStringLiteral("solver ocupado"));
        return;
    }
    // Challenges: s (signature) and n (throttle). The WebView solver runs
    // the same scripts yt-dlp uses; its answer is polled every 200 ms.
    // The first solve parses the whole player JS (~2.9 MiB) and returns
    // a preprocessed form that is cached (memory + disk): the next solves
    // skip that parse.
    QJsonArray requests;
    if (!m_apSig.isEmpty())
        requests.append(QJsonObject{{QStringLiteral("type"),
                                     QStringLiteral("sig")},
                                    {QStringLiteral("challenges"),
                                     QJsonArray{m_apSig}}});
    if (!m_apN.isEmpty())
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
    m_solverInput = inputJson;
    qInfo() << "[player] solve a" << (havePre ? "preprocesado" : "player crudo")
            << "| s:" << m_apSig.size() << "| n:" << m_apN.size()
            << "| track:" << trackUrl.right(14);
    if (!m_solverTimer) {
        m_solverTimer = new QTimer(this);
        m_solverTimer->setInterval(200);
        connect(m_solverTimer, &QTimer::timeout, this, &Player::onSolverPoll);
    }
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/WebViewSolver", "solve",
        "(Ljava/lang/String;)V",
        QJniObject::fromString(inputJson).object());
    m_solverTimer->start();
}

// Reads the preprocessed player from disk (per player id, TV JS). Returns
// true when it is NOT usable (the real player text has to be sent).
bool Player::loadPreprocessed()
{
    const QString path = AppPaths::cacheDir()
                         + QStringLiteral("/solver_pp_%1_tv.js").arg(m_playerJsId);
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
                         + QStringLiteral("/solver_pp_%1_tv.js").arg(m_playerJsId);
    QFile f(path);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(pp.toUtf8());
}

void Player::onSolverPoll()
{
    // The solver answers through a static Java field that we poll: no
    // Qt-side thread blocks on the WebView.
    QJniEnvironment env;
    jclass cls = env.findClass("com/lotustuneremote/app/WebViewSolver");
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
    if (status == QStringLiteral("working") && m_solverWait < 450)
        return;
    // "solver busy": the WebView is finishing the previous solve. This
    // solve never got queued: re-post the same input every ~1 s while
    // there is patience left.
    if (status == QStringLiteral("error:solver busy") && m_solverWait < 450) {
        if (m_solverWait % 5 == 0) {
            if (m_solverWait % 25 == 0)
                qInfo() << "[player] el solver sigue ocupado; se reintenta la petición";
            QJniObject::callStaticMethod<void>(
                "com/lotustuneremote/app/WebViewSolver", "solve",
                "(Ljava/lang/String;)V",
                QJniObject::fromString(m_solverInput).object());
        }
        return;
    }
    m_solverTimer->stop();
    if (status != QStringLiteral("done")) {
        qWarning() << "[player] el solver JS no respondió:" << status;
        abortChain(QStringLiteral("solver JS"));
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
        abortChain(QStringLiteral("resultado vacio"));
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
    if ((!m_apSig.isEmpty() && sig.isEmpty())
        || (!m_apN.isEmpty() && nval.isEmpty())) {
        qWarning() << "[player] el solver no devolvió s/n | respuestas:"
                   << resp.size() << "| sig vacía:" << sig.isEmpty()
                   << "| n vacía:" << nval.isEmpty()
                   << "| resultado:" << result.left(280);
        abortChain(QStringLiteral("solver sin s/n"));
        return;
    }
    // Remember the preprocessed form for the next solves (the solver only
    // returns it when it parsed the raw player JS).
    const QString pp = out.value(QStringLiteral("preprocessed_player")).toString();
    if (!pp.isEmpty() && m_preprocessed.isEmpty())
        savePreprocessed(pp);

    // The final url: the sp parameter carries the decoded signature (web
    // clients only) and the n parameter the decoded throttle token.
    QString finalUrl = m_apUrl;
    if (!sig.isEmpty()) {
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
    if (!m_apN.isEmpty())
        finalUrl.replace(QLatin1String("n=") + m_apN,
                         QLatin1String("n=") + nval);
    finishStream(finalUrl);
}

// Stores a ready stream url and hands it to the fetch (local file before
// the player opens it). Shared by the solver path and the clients that
// answer with a URL that needs no transformation.
void Player::finishStream(const QString &finalUrl)
{
    qInfo() << "[player] stream resuelto:" << m_apTrack.left(60) << "[" << m_playerJsId << "]";

    m_resolved.insert(m_apTrack, finalUrl);
    m_resolvedAt.insert(m_apTrack, QDateTime::currentSecsSinceEpoch());
    m_cacheDirty = true;
    m_cacheSaveTimer.start();
    // The stream travels to a local file before the player opens it: a
    // device-agnostic, network-agnostic path (Media3's own HTTP stack is
    // out of the equation). The URL stays in the cache as fallback.
    const QString doneTrack = m_apTrack;
    ResolveJob *job = m_chainJob;
    m_chainJob = nullptr;
    // A chain requested by the downloads panel plays nothing: the URL is
    // delivered and the lane is freed. If the user is also asking for that
    // same track, the normal playback is done too.
    bool dlChain = !m_dlChainUrl.isEmpty()
        && videoIdOf(m_dlChainUrl) == videoIdOf(doneTrack);
    // A download that asked for this same track while the chain was
    // resolving it for the player: it is delivered now.
    for (int i = m_dlQueue.size() - 1; i >= 0; --i) {
        if (videoIdOf(m_dlQueue.at(i)) == videoIdOf(doneTrack)) {
            m_dlQueue.removeAt(i);
            dlChain = true;
        }
    }
    const bool playbackWants = !job && !m_currentUrl.isEmpty()
        && videoIdOf(m_currentUrl) == videoIdOf(doneTrack);
    m_dlChainUrl.clear();
    if (dlChain)
        emit downloadStreamResolved(doneTrack, finalUrl);
    if (dlChain && !playbackWants) {
        endChain();
        return;
    }
    // "Loading" is set BEFORE launching the download: if the audio was
    // already cached, startAudioFetch plays it right away and its
    // m_loading=false was overwritten by this line (the bar stayed at
    // "Loading..." forever even though the song was playing).
    if (!job)
        m_loading = true;
    startAudioFetch(doneTrack, finalUrl, /*playNow=*/!job);
    endChain();
    if (job) {
        // Prefetch job: the queue machinery takes it from here (it fills
        // the cache; QMediaPlayer must stay silent, and a load() that was
        // waiting for this track starts through the cached URL).
        onResolveFinished(job, 0);
        return;
    }
    emit stateChanged();
}

// ---- Home widget + notification (Android) ------------------------------
// The APK may not carry the Java classes (a build that was not
// refreshed), so Java is NEVER called blindly: if the class is missing
// it is ignored instead of aborting the process with CheckJNI (which
// is exactly what kept the app from opening: ClassNotFoundException
// inside startMpv).
static bool ltWidgetJava()
{
    static const bool ok = QJniObject::isClassAvailable(
        "com/lotustuneremote/app/PlayerWidget");
    return ok;
}

static bool ltServiceJava()
{
    static const bool ok = QJniObject::isClassAvailable(
        "com/lotustuneremote/app/AudioService");
    return ok;
}

static bool ltLyricsWidgetJava()
{
    static const bool ok = QJniObject::isClassAvailable(
        "com/lotustuneremote/app/LyricsWidget");
    return ok;
}

// The widget and the notification send actions through a volatile inbox
// polled here: that way the UI thread never blocks waiting for Java.
static jobject ltAndroidContext()
{
    return QNativeInterface::QAndroidApplication::context();
}

void Player::setBackgroundPlayback(bool on)
{
    jobject ctx = ltAndroidContext();
    if (!ctx || !ltServiceJava())
        return;
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/AudioService",
        on ? "start" : "stop", "(Landroid/content/Context;)V", ctx);
}

void Player::updateWidget(const QString &title, const QString &artist,
                          bool playing, bool shuffle, int repeat, bool fav,
                          const QString &artUrl, double position,
                          double duration)
{
    if (!ltWidgetJava())
        return;                         // no widget in the APK: nothing to do
    const QJniObject jt = QJniObject::fromString(title.left(120));
    const QJniObject ja = QJniObject::fromString(artist.left(120));
    // The cover travels as a URL: the service downloads it (off the UI
    // thread) and uses it in the notification and in the widget.
    const QJniObject ju = QJniObject::fromString(artUrl.left(400));
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/PlayerWidget", "update",
        "(Ljava/lang/String;Ljava/lang/String;ZZIZLjava/lang/String;JJ)V",
        jt.object(), ja.object(), jboolean(playing), jboolean(shuffle),
        jint(repeat), jboolean(fav), ju.object(),
        jlong(qint64(position * 1000.0)), jlong(qint64(duration * 1000.0)));
    jobject ctx = ltAndroidContext();
    if (ctx && ltServiceJava())
        QJniObject::callStaticMethod<void>(
            "com/lotustuneremote/app/AudioService", "refresh",
            "(Landroid/content/Context;)V", ctx);
}

void Player::updateLyricsWidget(const QString &prev, const QString &line,
                                const QString &next)
{
    if (!ltLyricsWidgetJava())
        return;                         // APK without the lyrics widget
    const QJniObject jp = QJniObject::fromString(prev.left(400));
    const QJniObject jl = QJniObject::fromString(line.left(400));
    const QJniObject jn = QJniObject::fromString(next.left(400));
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/LyricsWidget", "update",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
        jp.object(), jl.object(), jn.object());
}

void Player::syncMediaProgress(double position)
{
    if (!ltWidgetJava())
        return;
    const qint64 ms = qint64(position * 1000.0);
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/PlayerWidget", "progress", "(J)V", jlong(ms));
    jobject ctx = ltAndroidContext();
    if (ctx && ltServiceJava())
        QJniObject::callStaticMethod<void>(
            "com/lotustuneremote/app/AudioService", "syncPosition",
            "(Landroid/content/Context;)V", ctx);
}

void Player::pollWidgetActions()
{
    if (!ltWidgetJava())
        return;
    const jint seq = QJniObject::callStaticMethod<jint>(
        "com/lotustuneremote/app/PlayerWidget", "pendingSeq", "()I");
    if (int(seq) == m_widgetSeq)
        return;
    m_widgetSeq = int(seq);
    const QJniObject act = QJniObject::callStaticObjectMethod(
        "com/lotustuneremote/app/PlayerWidget", "pendingAction",
        "()Ljava/lang/String;");
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/PlayerWidget", "clearAction", "()V");
    const QString a = act.isValid() ? act.toString() : QString();
    if (!a.isEmpty()) {
        qInfo() << "[widget] accion:" << a;
        emit widgetAction(a);
    }
}

// The stream download (QMediaPlayer plays the local file): the HTTP url
// is bound to the egress IP, so this also keeps every media fetch on our
// own stack with our own user agent.
void Player::pumpAudioQueue()
{
    if (m_fetching.isEmpty() && !m_audioQueue.isEmpty()) {
        const QPair<QString, QString> job = m_audioQueue.takeFirst();
        startAudioFetch(job.first, job.second, true);
    }
}

void Player::startAudioFetch(const QString &track, const QString &streamUrl,
                             bool playNow)
{
    if (streamUrl.isEmpty() || track.isEmpty())
        return;
    QUrl u(streamUrl);
    if (!u.isValid() || u.scheme() != QLatin1String("https"))
        return;
    // A URL too big for the cache (> 40 MB) plays directly instead of
    // being downloaded.
    const QUrlQuery qu(u.query());
    const qint64 clen = qu.queryItemValue(QStringLiteral("clen")).toLongLong();
    if (clen > 40LL * 1024 * 1024) {
        const bool cur = !m_currentUrl.isEmpty()
                         && videoIdOf(track) == videoIdOf(m_currentUrl);
        if (playNow && m_androidPlayer && cur) {
            m_androidPlayer->setSource(QUrl(streamUrl));
            m_androidPlayer->play();
        }
        return;
    }
    // A local copy already fetched for this exact track: instant play.
    const QString path = AppPaths::cacheDir() + QStringLiteral("/audio_")
                         + videoIdOf(track) + QStringLiteral(".bin");
    const QFileInfo fi(path);
    if (fi.isFile() && fi.size() > 4096) {
        audioFetchDone(track, path, true);
        return;
    }
    if (!m_fetching.isEmpty() && videoIdOf(m_fetching) == videoIdOf(track))
        return;                       // already downloading
    m_audioPlay.insert(track, playNow);
    const bool wanted = !m_currentUrl.isEmpty()
                        && videoIdOf(track) == videoIdOf(m_currentUrl);
    // A background prefetch in flight must not delay the track the user
    // just asked for: it is cancelled and theirs starts. It is compared by
    // id: the same song asked with another host (music./www.) must not
    // cancel itself (both write the same .part file).
    if (wanted && !m_fetching.isEmpty()) {
        QJniObject::callStaticMethod<void>(
            "com/lotustuneremote/app/MediaFetch", "cancel", "()V");
        qInfo() << "[player] precarga en curso cancelada (prioridad a la pista actual)";
        m_fetching.clear();
    }
    // One download at a time: the 5G IP is shared (CGNAT) and several
    // simultaneous requests to the same node end in 403. If after
    // cancelling the prefetch none is left in flight, the current track
    // starts NOW: queueing it here left the queue with nobody to drain it
    // (silence).
    if (!m_fetching.isEmpty()) {
        const bool isCurrent = !m_currentUrl.isEmpty()
                               && videoIdOf(track) == videoIdOf(m_currentUrl);
        int at = -1;
        for (int i = 0; i < m_audioQueue.size(); ++i)
            if (m_audioQueue.at(i).first == track)
                at = i;
        if (at < 0) {
            if (isCurrent)
                m_audioQueue.prepend(qMakePair(track, streamUrl));
            else
                m_audioQueue.append(qMakePair(track, streamUrl));
        } else if (isCurrent && at > 0) {
            // The track the user just asked for goes ahead of the background
            // prefetches.
            m_audioQueue.move(at, 0);
        }
        return;
    }
    // Pre-announce window (see kPreannounceMs). With 0 the audio is
    // requested right away: tested on 2026-11-03 on this 5G, the nodes
    // return 206 on the first try and the 403 from before was the download
    // queue bug (a cancelled prefetch left the queue with nobody to drain
    // it). If the immediate 403 ever comes back, raising kPreannounceMs is
    // enough.
    if (m_resolvedAt.contains(track) && !m_fetchDeferred.contains(track)) {
        const qint64 at = m_resolvedAt.value(track);
        const qint64 ageMs =
            (QDateTime::currentMSecsSinceEpoch() / 1000 - at) * 1000;
        const qint64 waitMs = kPreannounceMs - ageMs;
        if (waitMs > 0) {
            m_fetchDeferred.insert(track);
            qInfo() << "[player] audio en espera" << waitMs
                    << "ms (ventana del preanuncio)";
            QTimer::singleShot(int(waitMs), this, [this, track, streamUrl]() {
                m_fetchDeferred.remove(track);
                startAudioFetch(track, streamUrl, true);
            });
            return;
        }
    }
    m_fetchDeferred.remove(track);
    m_fetching = track;
    // Java does the download (HttpsURLConnection): that is the system HTTP
    // stack, the same one OkHttp/Media3/Chrome use. Qt (OpenSSL) gets a
    // 403 from the carrier node with the same url and the same headers.
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/MediaFetch", "start",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
        QJniObject::fromString(track).object(),
        QJniObject::fromString(streamUrl).object(),
        QJniObject::fromString(path).object());
    qInfo() << "[player] descarga (sistema):" << track;
    if (!m_fetchPoll) {
        m_fetchPoll = new QTimer(this);
        m_fetchPoll->setInterval(300);
        connect(m_fetchPoll, &QTimer::timeout, this, &Player::pollAudioFetch);
    }
    m_fetchPoll->start();
}

// Retries the download, waiting if needed for the new resolution to
// leave the url in the cache (max ~12 s). Without this the retry could
// fire before the new url arrived and give everything up as lost.
void Player::waitForStreamAndFetch(const QString &track, int attempt)
{
    const QString url = m_resolved.value(track);
    if (!url.isEmpty()) {
        startAudioFetch(track, url, true);
        return;
    }
    if (attempt >= 12) {
        audioFetchDone(track, QString(), false);
        return;
    }
    QTimer::singleShot(1000, this, [this, track, attempt]() {
        waitForStreamAndFetch(track, attempt + 1);
    });
}

// End of a download: the current track plays as soon as its audio is
// ready (whether the download came from the tap or the background
// prefetch).
void Player::audioFetchDone(const QString &track, const QString &path, bool ok)
{
    m_audioPlay.remove(track);
    m_fetching.clear();
    // Starts the next download in the queue (outside this stack).
    QTimer::singleShot(0, this, &Player::pumpAudioQueue);
    // The current track may come with another host (music.youtube.com)
    // than the one the resolution uses (www.youtube.com): it is compared
    // by id, or the track stays "loading" forever.
    const bool isCurrent = !m_currentUrl.isEmpty()
                           && !track.isEmpty()
                           && videoIdOf(track) == videoIdOf(m_currentUrl);
    if (!ok) {
        if (isCurrent && m_androidPlayer) {
            // No local copy: the direct url (bound to this egress).
            const QString direct = m_resolved.value(track);
            if (direct.startsWith(QLatin1String("http"))) {
                m_androidPlayer->setSource(QUrl(direct));
                m_androidPlayer->play();
            }
            m_loading = false;
            emit stateChanged();
        }
        return;
    }
    m_audioLocal.insert(track, path);
    m_cacheDirty = true;
    m_cacheSaveTimer.start();
    if (isCurrent && m_androidPlayer) {
        qInfo() << "[player] reproduciendo fichero local:" << path;
        androidPlayLocalFile(path);
    }
}

// Poll of the Java downloader (never blocks the UI thread).
void Player::pollAudioFetch()
{
    if (m_fetching.isEmpty()) {
        if (m_fetchPoll)
            m_fetchPoll->stop();
        // Safety net: if a download was cancelled and work was left queued,
        // someone has to start it.
        if (!m_audioQueue.isEmpty())
            QTimer::singleShot(0, this, &Player::pumpAudioQueue);
        return;
    }
    const QString track = m_fetching;
    const QString status = QJniObject::callStaticObjectMethod(
        "com/lotustuneremote/app/MediaFetch", "status",
        "()Ljava/lang/String;").toString();
    if (status.isEmpty() || status == QLatin1String("working")
        || status == QLatin1String("idle"))
        return;
    if (m_fetchPoll)
        m_fetchPoll->stop();
    const QString path = AppPaths::cacheDir() + QStringLiteral("/audio_")
                         + videoIdOf(track) + QStringLiteral(".bin");
    if (status == QLatin1String("done")) {
        m_audioTries.remove(track);
        const QFileInfo fi(path);
        const bool ok = fi.isFile() && fi.size() > 4096;
        if (ok) {
            setLastError(QString());
            // Cache cap: the oldest tracks are deleted, and never the one being
            // played.
            AudioCache::instance()->prune(videoIdOf(track));
        }
        audioFetchDone(track, path, ok);
        return;
    }
    qWarning() << "[player] descarga fallo |" << status << "| pista:" << track;
    // A 403 from the node is almost always transient (shared 5G IP): it is
    // retried with a growing wait before falling back to the direct url.
    const int tries = m_audioTries.value(track, 0);
    if (tries < 4) {
        m_audioTries.insert(track, tries + 1);
        m_fetching.clear();
        // Staggered waits: if the 403 comes from the node (shared 5G IP) or
        // from a url that is not valid yet, the retry falls outside that window
        // without showing an error that is not one.
        static const int waits[4] = { 5000, 4000, 10000, 15000 };
        const int wait = waits[qBound(0, tries, 3)];
        // The googlevideo url is signed with the IP (`ip=...`): switching from
        // wifi to mobile data (or the node expiring) makes the 403 PERMANENT
        // and retrying the same url is useless. On the second one, the cache
        // is dropped and it is resolved again for this network.
        const bool stale = tries >= 1 && status.contains(QLatin1String("403"));
        if (stale) {
            qInfo() << "[player] url inservible en esta red: resolviendo de nuevo";
            m_resolved.remove(track);
            m_resolvedAt.remove(track);
            m_cacheDirty = true;
            m_cacheSaveTimer.start();
            m_audioTries.remove(track);          // fresh count for the new url
            enqueueResolve(track, true, true);
        }
        qInfo() << "[player] reintento de descarga" << (tries + 1)
                << "en" << wait << "ms";
        QTimer::singleShot(wait, this, [this, track]() {
            waitForStreamAndFetch(track, 0);
        });
        return;
    }
    // The attempts ran out: now it is explained and it falls back to the
    // direct url (QMediaPlayer may succeed where the CDN said 403).
    setLastError(LotusText::friendlyNetError(status));
    audioFetchDone(track, path, false);
}
#endif
