#include "downloads.h"
#include "paths.h"

#include <QDateTime>
#include <QtGui/QDesktopServices>
#include <QtGui/QImage>
#include <QDir>
#include <QDirIterator>

#include <sys/stat.h>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSettings>
#include <QStringList>
#include <QStorageInfo>
#include <QUrl>
#include <QUrlQuery>

#include <utility>
#include <algorithm>

#ifdef Q_OS_LINUX
#include <signal.h>
#include <sys/types.h>
#endif

#ifdef Q_OS_ANDROID
#include "player.h"
#include <QJniObject>
#endif

#include <QDebug>

namespace {

// Audio extensions that make up the local library.
const char *const kAudioExts[] = {
    "mp3", "flac", "m4a", "opus", "ogg", "wav", "webm", "mka",
};

// Partial leftovers that yt-dlp leaves when a download is interrupted; they
// are cleaned on cancel/fail (and, if orphans from another session are
// left, on startup).
bool isPartialName(const QString &name)
{
    const QString low = name.toLower();
    return low.endsWith(QLatin1String(".part"))
        || low.endsWith(QLatin1String(".ytdl"))
        || low.endsWith(QLatin1String(".temp"))
        || low.endsWith(QLatin1String(".tmp"))
        || low.contains(QLatin1String(".temp-"))
        || low.contains(QLatin1String(".part-frag"));
}

// Id of 11 characters of a YouTube video (or "" when the url is not
// one). It matches the url the player returns with the track asked for:
// music.youtube.com and www.youtube.com are the same video.
QString videoIdOfUrl(const QString &url)
{
    const QUrl u(url);
    const QString host = u.host();
    if (host.contains(QLatin1String("youtu.be"))) {
        const QString p = u.path().mid(1);
        if (p.size() >= 11)
            return p.left(11);
    }
    const QString v = QUrlQuery(u).queryItemValue(QStringLiteral("v"));
    if (v.size() == 11)
        return v;
    const QString tail = u.path().section(QLatin1Char('/'), -1);
    if (tail.size() == 11 && !tail.contains(QLatin1Char('.')))
        return tail;
    return QString();
}

bool isAudioFile(const QString &path)
{
    const QString ext = QFileInfo(path).suffix().toLower();
    for (const char *e : kAudioExts)
        if (ext == QLatin1String(e))
            return true;
    return false;
}

// Readable size for Settings ("1,2 GB", "480 MB", "12 KB").
QString humanBytes(qint64 bytes)
{
    const double mb = double(bytes) / (1024.0 * 1024.0);
    if (mb < 1.0)
        return QStringLiteral("%1 KB").arg(qMax<qint64>(1, bytes / 1024));
    if (mb < 1000.0)
        return QStringLiteral("%1 MB").arg(qRound(mb));
    return QStringLiteral("%1 GB").arg(mb / 1024.0, 0, 'f', 1)
            .replace(QLatin1Char('.'), QLatin1Char(','));
}

// Stable cover of a YouTube video: the thumbnails yt-dlp returns carry a
// signature (`?sqp=...`) that expires, and the `s_p/` playlist covers
// 404 without it. The /vi/ path never expires, so it is used as the
// fallback of a downloaded list (and directly for its rows).
QString stableThumb(const QString &url)
{
    static const QRegularExpression re(
        QStringLiteral("/vi/([A-Za-z0-9_-]{11})/"));
    const auto m = re.match(url);
    if (!m.hasMatch())
        return QString();
    return QStringLiteral("https://i.ytimg.com/vi/%1/hqdefault.jpg")
        .arg(m.captured(1));
}

// Key of an audio file to compare it with another copy of the same song:
// the yt-dlp list index ("03Nobody.opus" -> "nobody") is stripped, the
// rest is case-folded. Titles that begin with a number are left untouched
// when the digits are not followed by a letter (safer: no false matches).
QString trackFileKey(const QString &fileName)
{
    QString base = QFileInfo(fileName).completeBaseName().trimmed();
    static const QRegularExpression idx(QStringLiteral("^[0-9]{1,3}(?=[^0-9])"));
    base.remove(idx);
    return base.simplified().toLower();
}

// Minimum age (seconds) to consider a partial leftover orphan on startup:
// that way a resumable one from a recent close is not deleted, but the
// garbage left by a session aborted hours ago is.
constexpr qint64 kOrphanAgeSecs = 6 * 3600;

} // namespace

Downloads::Downloads(QObject *parent)
    : QObject(parent)
{    // Folder persisted by the user; if there is none, the default one.
    const QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    QString saved = s.value(QStringLiteral("downloadFolder")).toString().trimmed();
    // A value inherited from old test runs (temp folders like
    // /tmp/lotus-tune-tests-XXXX) is not a real folder: it is dropped and
    // the default one is used, which is also recreated if missing.
    if (!saved.isEmpty() && QDir(saved).isRelative())
        saved.clear();   // relative path: useless outside its context
    if (!saved.isEmpty() && QFileInfo(saved).absoluteFilePath()
                               .startsWith(QDir::tempPath()))
        saved.clear();
    m_folder = saved.isEmpty() ? defaultFolder() : saved;
    QDir().mkpath(m_folder);
    // Quality of new downloads (the smallest Opus by default: same master,
    // half the space).
    const QString q = s.value(QStringLiteral("downloadQuality")).toString();
    if (q == QLatin1String("max") || q == QLatin1String("alta")
            || q == QLatin1String("media") || q == QLatin1String("baja"))
        m_quality = q;

    // A single yt-dlp process, with stdout and stderr merged so both the
    // warnings and the progress bar can be read with the same parser.
    m_proc.setProcessChannelMode(QProcess::MergedChannels);
    connect(&m_proc, &QProcess::readyRead, this, &Downloads::readStdout);
    connect(&m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) { finishJob(code); });

    // Incremental scan: the QDirIterator advances in batches on every tick so
    // it does not freeze the UI with big libraries.
    m_scanTimer.setInterval(2);
    connect(&m_scanTimer, &QTimer::timeout, this, &Downloads::scanChunk);

#ifndef Q_OS_ANDROID
    // Metadata of the downloaded lists (one small yt-dlp call per list,
    // cached in the list folder). Separate from the download process so it
    // never interferes with it.
    m_metaProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_metaProc,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) { finishFolderMeta(code); });
#endif

    // Auto sync: any change on disk (files added/removed) rescans the
    // local library after a short silence, with no user intervention.
    m_watchDebounce.setSingleShot(true);
    m_watchDebounce.setInterval(600);
    connect(&m_watchDebounce, &QTimer::timeout, this, [this]() {
        if (!m_busy)
            refreshLocal();
    });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this,
            [this](const QString &) { m_watchDebounce.start(); });

#ifdef Q_OS_ANDROID
    // Polling of the Java download (it never blocks the UI thread).
    m_androidPoll.setInterval(300);
    connect(&m_androidPoll, &QTimer::timeout, this, &Downloads::androidPollTick);
    // Native helper with the tracks of the list: it is read whole at the end.
    m_androidList.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_androidList,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
        androidListFinished(code);
    });
#endif

    // Cleans orphan partial leftovers (from an aborted session) before the
    // first sync.
    sweepOrphans(kOrphanAgeSecs);

    // First sync on startup.
    refreshLocal();
}

Downloads::~Downloads()
{
    stopScan();
#ifdef Q_OS_ANDROID
    androidAbort();
#endif
    if (m_proc.state() != QProcess::NotRunning) {
        m_proc.kill();
        m_proc.waitForFinished(700);
    }
    if (m_metaProc.state() != QProcess::NotRunning) {
        m_metaProc.kill();
        m_metaProc.waitForFinished(700);
    }
}

QString Downloads::defaultFolder() const
{
    return AppPaths::downloadDir();
}

void Downloads::setFolder(const QString &dir)
{
    const QString clean = QDir::cleanPath(dir.trimmed());
    if (clean.isEmpty() || clean == m_folder)
        return;
    m_folder = clean;
    QDir().mkpath(m_folder);
    m_metaQueue.clear();
    m_metaFolder.clear();
    m_folderMeta.clear();
    m_metaLoaded.clear();

    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("downloadFolder"), m_folder);
    s.sync();

    emit changed();
    // The local library now lives in another folder: rescan.
    refreshLocal();
}

// The player resolves the direct audio URL on Android (there is no
// yt-dlp): its answers arrive by signal and are matched by video id.
void Downloads::setPlayer(Player *player)
{
#ifdef Q_OS_ANDROID
    m_player = player;
    if (!m_player)
        return;
    connect(m_player, &Player::downloadStreamResolved, this,
            [this](const QString &url, const QString &direct) {
        if (m_current < 0 || m_androidResolving.isEmpty())
            return;
        if (videoIdOfUrl(url) != videoIdOfUrl(m_androidResolving))
            return;
        androidStartFetch(direct);
    });
    connect(m_player, &Player::downloadStreamFailed, this,
            [this](const QString &url, const QString &why) {
        if (m_current < 0 || m_androidResolving.isEmpty())
            return;
        if (videoIdOfUrl(url) != videoIdOfUrl(m_androidResolving))
            return;
        m_androidPoll.stop();
        m_androidResolving.clear();
        androidTrackFailed(QStringLiteral("No se pudo resolver el audio (%1).")
                               .arg(why));
    });
#else
    Q_UNUSED(player);
#endif
}

void Downloads::setQuality(const QString &q)
{
    if (q != QLatin1String("max") && q != QLatin1String("alta")
            && q != QLatin1String("media") && q != QLatin1String("baja"))
        return;
    if (q == m_quality)
        return;
    m_quality = q;
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("downloadQuality"), m_quality);
    s.sync();
    emit changed();
}

// yt-dlp `-f` selector and post-processor quality for the chosen level.
QPair<QString, QString> Downloads::downloadFormat() const
{
    if (m_quality == QLatin1String("max"))
        return { QStringLiteral("bestaudio[ext=opus][abr<=192]"
                                "/bestaudio[ext=opus]/bestaudio/best"),
                 QStringLiteral("0") };
    if (m_quality == QLatin1String("alta"))
        return { QStringLiteral("bestaudio[ext=opus][abr<=128]"
                                "/bestaudio[ext=opus]/bestaudio/best"),
                 QStringLiteral("2") };
    if (m_quality == QLatin1String("baja"))
        return { QStringLiteral("bestaudio[ext=opus][abr<=64]"
                                "/bestaudio[webm][abr<=64]/bestaudio/best"),
                 QStringLiteral("8") };
    return { QStringLiteral("bestaudio[ext=opus][abr<=96]"
                            "/bestaudio[ext=opus]/bestaudio/best"),
             QStringLiteral("5") };
}

void Downloads::removeAll()
{
    if (m_folder.isEmpty())
        return;
    cancelAll();
    QDir root(m_folder);
    const QFileInfoList entries =
        root.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot
                               | QDir::Hidden,
                           QDir::DirsFirst);
    for (const QFileInfo &fi : entries) {
        if (fi.isDir())
            QDir(fi.absoluteFilePath()).removeRecursively();
        else
            QFile::remove(fi.absoluteFilePath());
    }
    m_folderMeta.clear();
    m_metaLoaded.clear();
    m_metaQueue.clear();
    refreshLocal();
}

void Downloads::cacheCover(const QString &dir, const QString &url)
{
    if (dir.isEmpty() || url.isEmpty() || m_coverBusy.contains(dir))
        return;
    if (QFileInfo::exists(dir + QStringLiteral("/cover.jpg")))
        return;
    const QUrl u(url);
    if (!u.isValid()
            || (u.scheme() != QLatin1String("http")
                && u.scheme() != QLatin1String("https")))
        return;
    if (!m_coverNet)
        m_coverNet = new QNetworkAccessManager(this);
    m_coverBusy.insert(dir);
    QNetworkRequest req{u};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_coverNet->get(req);
    QTimer::singleShot(8000, reply, [reply]() {
        if (reply->isRunning())
            reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, dir]() {
        reply->deleteLater();
        m_coverBusy.remove(dir);
        if (reply->error() != QNetworkReply::NoError)
            return;   // expired URL: the card already has the stable
                      // first-track cover as a fallback
        const QImage img = QImage::fromData(reply->readAll());
        if (img.isNull() || img.width() < 100 || img.height() < 100)
            return;
        if (img.save(dir + QStringLiteral("/cover.jpg"), "JPG", 88))
            emit libraryChanged();
    });
}

void Downloads::queueFolderCovers()
{
    if (m_folder.isEmpty())
        return;
    QSet<QString> seen;
    for (const QVariant &v : std::as_const(m_local)) {
        const QString folder =
            v.toMap().value(QStringLiteral("folder")).toString();
        if (folder.isEmpty() || seen.contains(folder))
            continue;
        seen.insert(folder);
        const QString dir = m_folder + QLatin1Char('/') + folder;
        if (QFileInfo::exists(dir + QStringLiteral("/cover.jpg")))
            continue;
        const QString url =
            m_folderMeta.value(folder)
                .value(QStringLiteral("_thumb")).toString();
        if (!url.isEmpty())
            cacheCover(dir, url);
    }
}

QString Downloads::storageSummary() const
{
    if (m_local.isEmpty())
        return tr("Sin descargas");
    const int tracks = m_local.size();
    const int lists = folders().size();
    const QString used = humanBytes(m_bytes);
    if (lists <= 0)
        return tr("%1 · %2 pistas").arg(used).arg(tracks);
    return tr("%1 · %2 pistas en %3 listas")
            .arg(used).arg(tracks).arg(lists);
}

int Downloads::activeProgress() const
{
    if (m_current < 0 || m_current >= m_jobs.size())
        return -1;
    return m_jobs[m_current].progress;
}

// ---------------------------------------------------------------- jobs ----

QVariantList Downloads::jobs() const
{
    QVariantList out;
    out.reserve(m_jobs.size());
    for (const Job &j : m_jobs) {
        QVariantMap m;
        m.insert(QStringLiteral("name"), j.name);
        m.insert(QStringLiteral("url"), j.url);
        m.insert(QStringLiteral("playlist"), j.playlist);
        // Target folder of a list ("" for loose tracks), so that the UI
        // can give feedback inside the list itself.
        m.insert(QStringLiteral("folder"), j.folder);
        m.insert(QStringLiteral("progress"), j.progress);
        m.insert(QStringLiteral("state"), j.state);
        m.insert(QStringLiteral("error"), j.error);
        out.append(m);
    }
    return out;
}

// Creates a safe folder/file name (yt-dlp escapes too, but the base path
// must not contain separators or forbidden characters, nor exceed the
// file system's limit with long UTF-8 titles).
QString Downloads::safeSegment(const QString &text)
{
    QString s = text.trimmed();
    s.replace(QRegularExpression(QStringLiteral("[\\\\/:*?\"<>|\\p{Cc}\\p{Cf}]")),
              QStringLiteral("_"));
    // Collapses repeated spaces for cleaner names.
    s.replace(QRegularExpression(QStringLiteral("\\s+")), QStringLiteral(" "));
    while (s.startsWith(QLatin1Char('.')) || s.startsWith(QLatin1Char(' ')))
        s.remove(0, 1);
    while (s.endsWith(QLatin1Char('.')) || s.endsWith(QLatin1Char(' ')))
        s.chop(1);
    if (s.isEmpty())
        s = QStringLiteral("descarga");

    // Truncates by BYTES, not by characters: a UTF-8 name can take several
     // bytes per character and overflow the file system's limit (255).
     // Whole code points are cut so no lone surrogate is left.
    static constexpr int kMaxBytes = 180;
    while (s.toUtf8().size() > kMaxBytes && !s.isEmpty()) {
        const QChar last = s.at(s.size() - 1);
        s.chop(last.isLowSurrogate() && s.size() >= 2 ? 2 : 1);
    }
    // The truncation may leave a trailing/leading dot or space again.
    while (s.startsWith(QLatin1Char('.')) || s.startsWith(QLatin1Char(' ')))
        s.remove(0, 1);
    while (s.endsWith(QLatin1Char('.')) || s.endsWith(QLatin1Char(' ')))
        s.chop(1);

    QString checkNoUnderscores = s;
    checkNoUnderscores.remove(QLatin1Char('_'));
    if (checkNoUnderscores.trimmed().isEmpty())
        s = QStringLiteral("descarga");
    return s;
}

// Single top level folder for a list. It reuses the existing one if it is
// the SAME list (metadata with the same URL) to resume/complete it; if
// the name collides with ANOTHER list it gets a "(2)", "(3)"... suffix.
QString Downloads::uniqueListFolder(const QString &seg, const QString &url) const
{
    const QString base = m_folder + QLatin1Char('/') + seg;
    if (!QDir(base).exists())
        return seg;

    QFile mf(base + QStringLiteral("/.lotus-list.json"));
    if (mf.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(mf.readAll()).object();
        const QString prev = o.value(QStringLiteral("url")).toString().trimmed();
        if (!url.isEmpty() && prev == url)
            return seg;   // same list: it is reused and resumed
    }

    for (int i = 2; i < 10000; ++i) {
        const QString cand = QStringLiteral("%1 (%2)").arg(seg).arg(i);
        if (!QDir(m_folder + QLatin1Char('/') + cand).exists())
            return cand;
    }
    return QStringLiteral("%1 (%2)")
        .arg(seg)
        .arg(QDateTime::currentMSecsSinceEpoch());
}

void Downloads::enqueue(const Job &job)
{
    m_jobs.append(job);
    emit jobsChanged();
    if (m_current < 0)
        startNext();
    else
        emit changed();
}

void Downloads::downloadPlaylist(const QString &url, const QString &name,
                                 const QString &kind)
{
    const QString u = url.trimmed();
    if (u.isEmpty())
        return;
    // Same list already in the queue (or paused, or failed): it is resumed
    // instead of adding a second job of the same download.
    const int alive = liveJobForUrl(u);
    if (alive >= 0) {
        const QString state = m_jobs.at(alive).state;
        if (state == QLatin1String("paused") || state == QLatin1String("error"))
            resumeDownload(alive);
        return;
    }
    Job j;
    j.url = u;
    j.playlist = true;
    const QString k = kind.trimmed().toLower();
    j.kind = (k == QLatin1String("album") || k == QLatin1String("single"))
             ? k : QStringLiteral("list");
    j.name = name.trimmed().isEmpty() ? QStringLiteral("Playlist") : name.trimmed();
    enqueue(j);
}

void Downloads::downloadTrack(const QString &url, const QString &title,
                              const QString &artist)
{
    const QString u = url.trimmed();
    if (u.isEmpty())
        return;
    const int alive = liveJobForUrl(u);
    if (alive >= 0) {
        const QString state = m_jobs.at(alive).state;
        if (state == QLatin1String("paused") || state == QLatin1String("error"))
            resumeDownload(alive);
        return;
    }
    Job j;
    j.url = u;
    j.playlist = false;
    const QString t = title.trimmed();
    const QString a = artist.trimmed();
    j.name = a.isEmpty() ? t : a + QStringLiteral(" - ") + t;
    if (j.name.trimmed().isEmpty())
        j.name = QStringLiteral("Pista");
    enqueue(j);
}

int Downloads::liveJobForUrl(const QString &url) const
{
    if (url.isEmpty())
        return -1;
    for (int i = m_jobs.size() - 1; i >= 0; --i) {
        const Job &j = m_jobs.at(i);
        if (j.url != url)
            continue;
        if (j.state == QLatin1String("queued")
            || j.state == QLatin1String("downloading")
            || j.state == QLatin1String("paused")
            || j.state == QLatin1String("error"))
            return i;
    }
    return -1;
}

void Downloads::pauseDownload(int index)
{
    if (index < 0 || index >= m_jobs.size())
        return;
    Job &j = m_jobs[index];
    if (j.state == QLatin1String("done"))
        return;

#ifdef Q_OS_ANDROID
    // Android download in progress: the resolution and the download are cut
    // and the job stays paused (the files already down are kept).
    if (index == m_current && m_busy) {
        j.state = QStringLiteral("paused");
        emit jobsChanged();
        emit changed();
        m_current = -1;
        m_busy = false;
        androidAbort();
        emit jobsChanged();
        emit changed();
        emit activeProgressChanged();
        startNext();
        return;
    }
#endif

    if (index == m_current
        && m_proc.state() != QProcess::NotRunning) {
        // Running: the process is stopped (SIGINT: yt-dlp closes the .part
        // where it is, so the resume continues from that byte) and
        // finishJob() sees m_pausing and leaves the job as "paused".
        j.state = QStringLiteral("paused");
        m_pausing = true;
        emit jobsChanged();
        emit changed();
#ifdef Q_OS_LINUX
        ::kill(static_cast<pid_t>(m_proc.processId()), SIGINT);
#else
        m_proc.terminate();
#endif
        // If it does not answer (a stuck postprocessor), it is killed: the
        // .part stays on disk either way.
        QTimer::singleShot(8000, this, [this, index]() {
            if (m_pausing && m_current == index
                && m_proc.state() != QProcess::NotRunning) {
                qWarning() << "[downloads] la pausa no cerró yt-dlp: se mata";
                m_proc.kill();
            }
        });
        return;
    }

    // The job is marked as running but the process is not up yet (it is
    // about to start, or it already exited and Qt has not delivered
    // `finished`): it is paused here and the queue is freed, so the pause
    // button never does nothing and no late finishJob can undo it.
    if (index == m_current && m_busy) {
        j.state = QStringLiteral("paused");
        m_pausing = false;
        m_current = -1;
        m_busy = false;
        emit jobsChanged();
        emit changed();
        emit activeProgressChanged();
        startNext();
        return;
    }

    // Not running: queued (it will not start) or already failed.
    if (j.state == QLatin1String("queued") || j.state == QLatin1String("error")) {
        j.state = QStringLiteral("paused");
        emit jobsChanged();
        emit changed();
        emit activeProgressChanged();
    }
}

void Downloads::resumeDownload(int index)
{
    if (index < 0 || index >= m_jobs.size())
        return;
    Job &j = m_jobs[index];
    if (j.state != QLatin1String("paused") && j.state != QLatin1String("error"))
        return;
    j.state = QStringLiteral("queued");
    j.error.clear();
    emit jobsChanged();
    emit changed();
    emit activeProgressChanged();
    // startNext() is a no-op with a download already in progress; calling
    // it unconditionally also covers Resume pressed while the pause is
    // still closing yt-dlp.
    startNext();
}

void Downloads::pauseAll()
{
    for (int i = 0; i < m_jobs.size(); ++i)
        if (m_jobs.at(i).state == QLatin1String("queued"))
            setJob(i, QStringLiteral("paused"));
    if (m_current >= 0)
        pauseDownload(m_current);
    emit jobsChanged();
    emit changed();
    emit activeProgressChanged();
}

void Downloads::resumeAll()
{
    for (int i = 0; i < m_jobs.size(); ++i) {
        const QString s = m_jobs.at(i).state;
        if (s == QLatin1String("paused") || s == QLatin1String("error")) {
            m_jobs[i].state = QStringLiteral("queued");
            m_jobs[i].error.clear();
        }
    }
    emit jobsChanged();
    emit changed();
    emit activeProgressChanged();
    if (m_current < 0)
        startNext();
}

void Downloads::setJob(int index, const QString &state, const QString &error)
{
    if (index < 0 || index >= m_jobs.size())
        return;
    m_jobs[index].state = state;
    m_jobs[index].error = error;
}

// Marks a job as failed with a READABLE message, warns the UI and, if it was
// the running download, frees the process and starts the next one of the queue.
void Downloads::failJob(int index, const QString &message)
{
    if (index < 0 || index >= m_jobs.size())
        return;
    const bool wasCurrent = (index == m_current);
    setJob(index, QStringLiteral("error"), message);
    if (wasCurrent) {
        m_current = -1;
        m_busy = false;
    }
    const QString name = m_jobs[index].name;
    emit jobsChanged();
    emit changed();
    emit downloadError(name, message);
    emit activeProgressChanged();
    if (wasCurrent)
        startNext();
}

void Downloads::startNext()
{
    if (m_current >= 0)
        return;  // there is already a download in progress

    int idx = -1;
    for (int i = 0; i < m_jobs.size(); ++i) {
        if (m_jobs[i].state == QLatin1String("queued")) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        // Empty queue: the work is over.
        if (m_busy) {
            m_busy = false;
            emit changed();
            emit activeProgressChanged();
        }
        return;
    }

    m_current = idx;
    Job &j = m_jobs[idx];
    // The progress is NOT reset: a job that was paused (or that failed and
    // is retried) keeps the percentage it had and goes on from there.
    j.state = QStringLiteral("downloading");
    j.error.clear();
    j.folder.clear();
    m_lastError.clear();
    m_buf.clear();
    m_plItem = 0;
    m_plTotal = 0;

    m_busy = true;
    emit changed();
    emit jobsChanged();
    emit activeProgressChanged();

    // It checks the free space before downloading (at least 50 MB for
     // audio).
    const QStorageInfo storage(m_folder);
    if (storage.isValid() && storage.bytesAvailable() > 0
        && storage.bytesAvailable() < 50 * 1024 * 1024) {
        failJob(idx, QStringLiteral("Espacio insuficiente en disco (menos de 50 MB disponibles)."));
        return;
    }

#ifdef Q_OS_ANDROID
    // On Android there is no yt-dlp: the tracks come from the native helper,
    // the player resolves the direct URL and MediaDownload fetches the bytes.
    startAndroidJob(idx);
    return;
#endif

    // -o relative to -P home (the app's folder):
    //   playlist -> <name>/<index><title>.<ext>
    //   track    -> <artist> - <title>.<ext>
    QString outTemplate;
    QString archivePath;
    if (j.playlist) {
        const QString seg = uniqueListFolder(safeSegment(j.name), j.url);
        j.folder = seg;
        const QString dir = m_folder + QLatin1Char('/') + seg;
        if (!QDir().mkpath(dir)) {
            failJob(idx, QStringLiteral("No se pudo crear la carpeta «%1». "
                                        "Comprueba los permisos.").arg(dir));
            return;
        }
        if (!QFileInfo(dir).isWritable()) {
            failJob(idx, QStringLiteral("La carpeta de descargas no tiene "
                                        "permiso de escritura: %1").arg(dir));
            return;
        }
        // Identity mark of the downloaded list: it stores the original name
         // and its URL so it can be matched later (uninstall, open, etc.),
         // even if the visible name changes or the title is sanitised.
        QJsonObject meta;
        meta.insert(QStringLiteral("name"), j.name);
        meta.insert(QStringLiteral("url"), j.url);
        meta.insert(QStringLiteral("kind"), j.kind);
        QFile mf(dir + QStringLiteral("/.lotus-list.json"));
        if (mf.open(QIODevice::WriteOnly | QIODevice::Truncate))
            mf.write(QJsonDocument(meta).toJson(QJsonDocument::Compact));
        // Download file per list: it avoids downloading again the tracks
         // already finished when resuming. It lives INSIDE the folder, so
         // uninstalling the list deletes it too (a new download fetches
         // everything again).
        archivePath = dir + QStringLiteral("/.lotus-archive.txt");
        outTemplate = seg
            + QStringLiteral("/%(playlist_index|)s%(title)s.%(ext)s");
    } else {
        if (!QDir().mkpath(m_folder) || !QFileInfo(m_folder).isWritable()) {
            failJob(idx, QStringLiteral("No se puede escribir en la carpeta de "
                                        "descargas: %1").arg(m_folder));
            return;
        }
        outTemplate = safeSegment(j.name) + QStringLiteral(".%(ext)s");
    }

    QStringList args{
        QStringLiteral("--no-config"),
        QStringLiteral("--newline"),
        // Everything (audio, .part, leftovers...) is written DIRECTLY in
         // the app's folder; nothing goes through ~/Downloads nor /tmp, so
         // there is no need to "move" files when it finishes.
        QStringLiteral("-P"), QStringLiteral("home:") + m_folder,
        QStringLiteral("-P"), QStringLiteral("temp:") + m_folder,
        // Quality chosen in Settings (see downloadFormat()): the smallest
        // one is the default - the same master, ~50 % smaller than the
        // 160 kbps Opus - and the big ones keep more bitrate for those who
        // want it. When the source is already Opus it is copied, without
        // re-encoding.
        QStringLiteral("-f"),
        downloadFormat().first,
        QStringLiteral("--extract-audio"),
        QStringLiteral("--audio-format"), QStringLiteral("opus"),
        QStringLiteral("--audio-quality"), downloadFormat().second,
        QStringLiteral("--embed-metadata"),
        // Without embedded thumbnail and without `.info.json`: less weight, less
        // post-processing and without depending on mutagen.
        QStringLiteral("--no-embed-thumbnail"),
        QStringLiteral("--no-write-info-json"),
        // Resumable and without downloading again what is already there.
        QStringLiteral("--continue"),
        QStringLiteral("--no-overwrites"),
        // Network resilience: timeout and automatic retries
        QStringLiteral("--socket-timeout"), QStringLiteral("15"),
        QStringLiteral("--retries"), QStringLiteral("3"),
        // Machine readable progress: index/total of the list + % of the
         // current track, with a recognisable prefix to compute ONE total
         // 0-100 %.
        QStringLiteral("--progress-template"),
        QStringLiteral("download:##LT##%(info.playlist_index)s|"
                       "%(info.n_entries)s|%(progress._percent_str)s"),
        QStringLiteral("-o"), outTemplate,
    };

    // If it is a loose track, avoid downloading playlists if the URL comes with &list=...
    if (!j.playlist)
        args << QStringLiteral("--no-playlist");

    // Download file per list (lists only).
    if (!archivePath.isEmpty())
        args << QStringLiteral("--download-archive") << archivePath;

    // YouTube Music session: the user's PRIVATE lists (e.g. "Vibes")
    // without cookies return "YouTube said: The playlist does not exist",
    // so the cookies.txt of the integrated login is attached, just like the
    // catalogue does to search/open lists.
    const QString cookies = AppPaths::cookiesFile();
    if (QFile::exists(cookies)
        && (j.url.contains(QLatin1String("youtube.com"))
            || j.url.contains(QLatin1String("youtu.be"))
            || j.url.contains(QLatin1String("music.youtube.com")))) {
        args << QStringLiteral("--cookies") << cookies;
    }

    args << j.url;

    m_proc.setProgram(QStringLiteral("yt-dlp"));
    m_proc.setArguments(args);
    m_proc.start();
    if (!m_proc.waitForStarted(3000)) {
        failJob(idx, QStringLiteral("No se pudo ejecutar yt-dlp. "
                                    "¿Está instalado?"));
    }
}

// Updates the AGGREGATED progress (0-100 of the WHOLE list) from the
// fraction (0..1) of the current track and publishes it only when it
// changes.
void Downloads::updateProgress(double frac)
{
    if (m_current < 0 || m_current >= m_jobs.size())
        return;
    frac = qBound(0.0, frac, 1.0);

    int p;
    if (m_plTotal > 1 && m_plItem > 0)
        p = qBound(0, qRound(((m_plItem - 1) + frac) / m_plTotal * 100.0), 100);
    else
        p = qBound(0, qRound(frac * 100.0), 100);

    if (p == m_jobs[m_current].progress)
        return;
    m_jobs[m_current].progress = p;
    emit jobsChanged();
    emit progressChanged(m_jobs[m_current].name, p);
    emit activeProgressChanged();
}

void Downloads::readStdout()
{
    m_buf += m_proc.readAllStandardOutput();
    int nl;
    while ((nl = m_buf.indexOf('\n')) >= 0) {
        const QString line = QString::fromUtf8(m_buf.left(nl)).trimmed();
        m_buf.remove(0, nl + 1);
        if (line.isEmpty() || m_current < 0)
            continue;

        // Preferred format, the one we ask for with --progress-template:
         //   ##LT##<index>|<total>|<pct>%
        static const QRegularExpression reTpl(
            QStringLiteral("##LT##\\s*([^|]*)\\|\\s*([^|]*)\\|\\s*"
                           "([0-9]+(?:\\.[0-9]+)?)%"));
        const QRegularExpressionMatch mt = reTpl.match(line);
        if (mt.hasMatch()) {
            const int item = mt.captured(1).toInt();
            const int total = mt.captured(2).toInt();
            if (item > 0)
                m_plItem = item;
            if (total > 0)
                m_plTotal = total;
            updateProgress(mt.captured(3).toDouble() / 100.0);
            continue;   // it is a progress line: nothing else to look at
        }

        // Compatibility with old yt-dlp: "Downloading item 3 of 20".
        static const QRegularExpression reItem(
            QStringLiteral("Downloading item ([0-9]+) of ([0-9]+)"));
        const QRegularExpressionMatch mi = reItem.match(line);
        if (mi.hasMatch()) {
            m_plItem = mi.captured(1).toInt();
            m_plTotal = mi.captured(2).toInt();
        }

        // Classic bar "[download]  12.3%": fallback in case there is no
         // template.
        static const QRegularExpression reProgress(
            QStringLiteral("\\[download\\]\\s+([0-9]+(?:\\.[0-9]+)?)%"));
        const QRegularExpressionMatch m = reProgress.match(line);
        if (m.hasMatch())
            updateProgress(m.captured(1).toDouble() / 100.0);

        // It stores the last real error to show it if the process fails.
        const int err = line.indexOf(QLatin1String("ERROR:"));
        if (err >= 0)
            m_lastError = line.mid(err + 6).trimmed();
    }
}

// Translates the most common yt-dlp errors into readable messages.
QString Downloads::friendlyError(const QString &raw)
{
    const QString r = raw.trimmed();
    if (r.isEmpty())
        return QStringLiteral("La descarga falló.");

    const QString low = r.toLower();
    auto has = [&low](const char *needle) {
        return low.contains(QLatin1String(needle));
    };

    if (has("ffmpeg") || has("ffprobe") || has("postprocessing")
        || has("post-process"))
        return QStringLiteral("Falta ffmpeg para procesar el audio.");
    if (has("does not exist") || has("not found") || has("unavailable")
        || has("404") || has("removed"))
        return QStringLiteral("La lista no existe, es privada o ya no está "
                              "disponible.");
    if (has("private") || has("members-only") || has("sign in")
        || has("login") || has("logged") || has("cookies")
        || has("account"))
        return QStringLiteral("Contenido privado: inicia sesión en Ajustes y "
                              "vuelve a intentarlo.");
    if (has("unsupported url") || has("is not a valid url")
        || has("invalid url"))
        return QStringLiteral("La dirección no es compatible.");
    if (has("timed out") || has("timeout") || has("temporary failure")
        || has("getaddrinfo") || has("unable to download") || has("network")
        || has("connection") || has("resolve") || has("http error")
        || has("ssl"))
        return QStringLiteral("Fallo de red. Comprueba tu conexión e "
                              "inténtalo de nuevo.");
    if (has("no space") || has("disk") || has("read-only")
        || has("permission denied"))
        return QStringLiteral("No hay espacio o la carpeta de descargas no "
                              "tiene permiso de escritura.");
    if (has("requested format is not available")
        || has("no video formats") || has("no formats"))
        return QStringLiteral("No hay ningún formato de audio disponible.");

    // No match: use the original message (already trimmed by yt-dlp).
    return r;
}

int Downloads::countAudioFiles(const QString &dir)
{
    QDir d(dir);
    if (!d.exists())
        return 0;
    const QStringList names = d.entryList(QDir::Files | QDir::NoDotAndDotDot);
    int n = 0;
    for (const QString &f : names)
        if (isAudioFile(f))
            ++n;
    return n;
}

void Downloads::dedupeFolder(const QString &dir)
{
    QDir root(m_folder);
    if (!root.exists() || dir.isEmpty())
        return;
    const QString newPath = QDir(dir).absolutePath();

    // Index of the copies that already exist elsewhere (sibling folders
    // and loose tracks in the root): key -> path.
    QHash<QString, QString> other;
    const auto indexDir = [&other](const QDir &d) {
        const QStringList names = d.entryList(QDir::Files | QDir::NoDotAndDotDot);
        for (const QString &n : names) {
            if (!isAudioFile(n))
                continue;
            const QString key = trackFileKey(n);
            if (!key.isEmpty() && !other.contains(key))
                other.insert(key, d.absoluteFilePath(n));
        }
    };
    const QFileInfoList subs =
        root.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QFileInfo &fi : subs) {
        if (fi.absoluteFilePath() != newPath)
            indexDir(QDir(fi.absoluteFilePath()));
    }
    indexDir(root);

    if (other.isEmpty())
        return;

    const QDir nd(dir);
    const QStringList fresh = nd.entryList(QDir::Files | QDir::NoDotAndDotDot);
    int linked = 0;
    for (const QString &n : fresh) {
        if (!isAudioFile(n))
            continue;
        const QString key = trackFileKey(n);
        const QString src = other.value(key);
        if (src.isEmpty())
            continue;
        const QString cur = nd.absoluteFilePath(n);
        // Same size is the cheap proof that it is the same audio (same
        // source and quality): different versions/edit lengths do not
        // match and are kept.
        if (QFileInfo(src).size() != QFileInfo(cur).size()
            || QFileInfo(src).size() <= 0)
            continue;
        const QString tmp = cur + QStringLiteral(".ltlink");
        QFile::remove(tmp);
        if (!QFile::link(src, tmp))
            continue;   // no hard links here (another FS): keep the copy
        QFile::remove(cur);
        if (QFile::rename(tmp, cur))
            ++linked;
        else
            QFile::remove(tmp);
    }
    if (linked > 0)
        qInfo() << "[downloads]" << linked
                << "pistas compartidas (enlace duro) en" << dir;
}

qint64 Downloads::listSize(const QString &folder) const
{
    const QString dir = m_folder + QLatin1Char('/') + folder;
    qint64 total = 0;
    QDirIterator it(dir, QDir::Files | QDir::NoDotAndDotDot);
    while (it.hasNext()) {
        const QFileInfo fi = it.nextFileInfo();
        // A hard link shares the inode with another folder: counting it
        // would invent space that deleting this list would not free.
        struct stat st;
        if (::stat(QFile::encodeName(fi.absoluteFilePath()).constData(), &st) == 0
            && st.st_nlink > 1)
            continue;
        total += fi.size();
    }
    return total;
}

QString Downloads::estimateSize(double minutes) const
{
    int kbps = 96;
    if (m_quality == QLatin1String("max"))
        kbps = 192;
    else if (m_quality == QLatin1String("alta"))
        kbps = 128;
    else if (m_quality == QLatin1String("baja"))
        kbps = 64;
    const double bytes = minutes * 60.0 * kbps * 1000.0 / 8.0;
    return humanBytes(qint64(bytes));
}

void Downloads::removePartials(const QString &dir, bool keepResumable)
{
    QDir d(dir);
    if (!d.exists())
        return;
    const QStringList names = d.entryList(QDir::Files | QDir::NoDotAndDotDot);
    for (const QString &n : names) {
        if (!isPartialName(n))
            continue;
        // A failed download keeps its .part: that is what makes the retry
        // continue from where it stopped instead of starting the track
        // again. The rest (.temp, .ytdl...) is useless after a failure.
        if (keepResumable
            && (n.endsWith(QLatin1String(".part"), Qt::CaseInsensitive)
                || n.endsWith(QLatin1String(".part-frag"), Qt::CaseInsensitive)))
            continue;
        d.remove(n);
    }
}

void Downloads::sweepOrphans(qint64 ageSecs)
{
    if (m_folder.isEmpty() || !QDir(m_folder).exists())
        return;
    const QDateTime now = QDateTime::currentDateTimeUtc();
    QDirIterator it(m_folder,
                    {QStringLiteral("*.part"), QStringLiteral("*.part-Frag*"),
                     QStringLiteral("*.part-frag*"), QStringLiteral("*.ytdl"),
                     QStringLiteral("*.temp"), QStringLiteral("*.tmp")},
                    QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString path = it.next();
        const QFileInfo fi(path);
        // Only the OLD orphans are removed: the recent ones can be a
        // resumable session.
        if (fi.lastModified().toUTC().secsTo(now) >= ageSecs)
            QFile::remove(path);
    }
}

void Downloads::finishJob(int code)
{
    readStdout();  // it drains what is pending before closing the job
    if (m_current < 0)
        return;

    const int idx = m_current;
    m_current = -1;

    const Job job = m_jobs[idx];   // copy: name, playlist and folder
    const QString dir = job.folder.isEmpty()
        ? m_folder
        : m_folder + QLatin1Char('/') + job.folder;

    if (m_pausing) {
        // Paused halfway: the .part is KEPT on purpose, so resuming goes on
        // from that same byte (--continue) and the list's archive skips the
        // tracks already downloaded.
        m_pausing = false;
        // If the user pressed Resume while yt-dlp was still closing, the
        // job is already queued: it must NOT be forced back to paused.
        if (m_jobs.at(idx).state != QLatin1String("queued"))
            setJob(idx, QStringLiteral("paused"));
        m_busy = false;
        emit jobsChanged();
        emit changed();
        emit activeProgressChanged();
        startNext();   // the rest of the queue (if any) carries on
        return;
    }

    if (m_cancelling) {
        // Cancelled halfway: it deletes the partial leftovers so no trash is left.
        removePartials(dir);
        setJob(idx, QStringLiteral("error"), QStringLiteral("Cancelado"));
        m_cancelling = false;
        m_busy = false;
        emit jobsChanged();
        emit changed();
        emit activeProgressChanged();
        return;  // cancelAll() already marked the rest of the queue
    }

    if (code == 0) {
        // Success, but an EMPTY list (or with no downloadable tracks) is
         // a failure too: yt-dlp can exit with 0 and have written
         // nothing.
        if (job.playlist && countAudioFiles(dir) == 0) {
            const QString msg = QStringLiteral("La lista está vacía o no se "
                                               "pudo descargar ninguna pista.");
            setJob(idx, QStringLiteral("error"), msg);
            emit jobsChanged();
            emit changed();
            emit downloadError(job.name, msg);
            startNext();
            refreshLocal();
            return;
        }
        removePartials(dir);
        if (job.playlist)
            dedupeFolder(dir);
        setJob(idx, QStringLiteral("done"));
        m_jobs[idx].progress = 100;
        emit jobsChanged();
        emit changed();
        emit progressChanged(job.name, 100);
        emit downloadCompleted(job.name, job.folder);
        emit activeProgressChanged();
    } else {
        // Failure: a readable reason is published and the RESUMABLE
        // leftovers (.part) are kept, so pressing retry/resume goes on from
        // the byte where it stopped instead of downloading the track again.
        const QString raw = m_lastError.isEmpty()
            ? QStringLiteral("yt-dlp terminó con código %1").arg(code)
            : m_lastError;
        const QString msg = friendlyError(raw);
        removePartials(dir, /*keepResumable=*/true);
        setJob(idx, QStringLiteral("error"), msg);
        emit jobsChanged();
        emit changed();
        emit downloadError(job.name, msg);
        emit activeProgressChanged();
    }

    // Next of the queue and automatic refresh of the local library.
    startNext();
    refreshLocal();
}

void Downloads::cancelAll()
{
    // The jobs still queued or paused will never get to run.
    for (int i = 0; i < m_jobs.size(); ++i) {
        const QString s = m_jobs.at(i).state;
        if (s == QLatin1String("queued") || s == QLatin1String("paused"))
            setJob(i, QStringLiteral("error"), QStringLiteral("Cancelado"));
    }

#ifdef Q_OS_ANDROID
    if (m_current >= 0) {
        const int idx = m_current;
        const QString dir = m_jobs.at(idx).folder.isEmpty()
            ? m_folder
            : m_folder + QLatin1Char('/') + m_jobs.at(idx).folder;
        m_current = -1;
        m_busy = false;
        androidAbort();
        removePartials(dir);
        setJob(idx, QStringLiteral("error"), QStringLiteral("Cancelado"));
        emit jobsChanged();
        emit changed();
        emit activeProgressChanged();
        return;
    }
#endif

    if (m_proc.state() != QProcess::NotRunning) {
        // finishJob() will clean the partial leftovers of the running
         // job.
        m_cancelling = true;
        m_proc.kill();
    }
    emit jobsChanged();
    emit changed();
}

#ifdef Q_OS_ANDROID
// --------------------------------------------------------- Android ----
// No yt-dlp: 1) the native helper returns the tracks of the list, 2) the
// Player resolves the direct URL (the same chain as playback), 3)
// MediaDownload (Java) fetches the bytes with the HTTP stack of the
// system. The folder layout is the one of the desktop
// (<list>/<NN><title>.<ext> + .lotus-list.json + .lotus-archive.txt).

void Downloads::startAndroidJob(int index)
{
    if (index < 0 || index >= m_jobs.size())
        return;
    Job &j = m_jobs[index];

    QString dir = m_folder;
    if (j.playlist) {
        const QString seg = uniqueListFolder(safeSegment(j.name), j.url);
        j.folder = seg;
        dir = m_folder + QLatin1Char('/') + seg;
        if (!QDir().mkpath(dir)) {
            failJob(index, QStringLiteral("No se pudo crear la carpeta «%1». "
                                          "Comprueba los permisos.").arg(dir));
            return;
        }
        if (!QFileInfo(dir).isWritable()) {
            failJob(index, QStringLiteral("La carpeta de descargas no tiene "
                                          "permiso de escritura: %1").arg(dir));
            return;
        }
        // Identity mark of the list (original name + url): it lets the app match
        // it later (uninstall, open...) even when the visible name changes.
        QJsonObject meta;
        meta.insert(QStringLiteral("name"), j.name);
        meta.insert(QStringLiteral("url"), j.url);
        meta.insert(QStringLiteral("kind"), j.kind);
        QFile mf(dir + QStringLiteral("/.lotus-list.json"));
        if (mf.open(QIODevice::WriteOnly | QIODevice::Truncate))
            mf.write(QJsonDocument(meta).toJson(QJsonDocument::Compact));
    } else if (!QDir().mkpath(m_folder)
               || !QFileInfo(m_folder).isWritable()) {
        failJob(index, QStringLiteral("No se puede escribir en la carpeta de "
                                      "descargas: %1").arg(m_folder));
        return;
    }

    m_androidDir = dir;
    m_androidTracks.clear();
    m_androidIndex = 0;
    m_androidRetries = 0;
    m_androidResolveTicks = 0;
    m_androidResolving.clear();
    m_androidFetchId.clear();
    m_androidOutPath.clear();
    m_androidDone.clear();

    // File of the tracks already downloaded (resume without repeating what
    // is already there).
    m_androidArchive = j.playlist
        ? dir + QStringLiteral("/.lotus-archive.txt") : QString();
    if (!m_androidArchive.isEmpty()) {
        QFile af(m_androidArchive);
        if (af.open(QIODevice::ReadOnly)) {
            const QList<QByteArray> lines = af.readAll().split('\n');
            for (const QByteArray &lb : lines) {
                const QString id = QString::fromUtf8(lb).trimmed();
                if (id.size() == 11)
                    m_androidDone.insert(id);
            }
        }
    }

    const QString cli = AppPaths::pythonProgram();
    if (cli.isEmpty() || !QFile::exists(cli)) {
        failJob(index, QStringLiteral("Falta el asistente nativo (libytmcli.so)."));
        return;
    }
    QStringList args{
        QStringLiteral("-J"),
        QStringLiteral("--no-warnings"),
        QStringLiteral("--ignore-errors"),
        QStringLiteral("--no-plugin-dirs"),
        QStringLiteral("--flat-playlist"),
        j.playlist ? QStringLiteral("--playlist-end=500")
                   : QStringLiteral("--playlist-end=1"),
    };
    const QString cookies = AppPaths::cookiesFile();
    if (QFile::exists(cookies)
        && (j.url.contains(QLatin1String("youtube.com"))
            || j.url.contains(QLatin1String("youtu.be")))) {
        args << QStringLiteral("--cookies") << cookies;
    }
    args << j.url;

    // The child does not resolve DNS (netd answers NODATA): the parent
    // resolves through Java and passes the IPs, as Catalog does.
    const QJniObject ips = QJniObject::callStaticObjectMethod(
        QStringLiteral("com/lotustuneremote/app/MainActivity")
            .toUtf8().constData(),
        "lookupDns", "(Ljava/lang/String;)Ljava/lang/String;",
        QJniObject::fromString(QStringLiteral("music.youtube.com")).object());
    if (ips.isValid())
        qputenv("LTM_DNS_IPS", ips.toString().toUtf8());

    m_androidList.setProgram(cli);
    m_androidList.setArguments(args);
    m_androidList.start();
    if (!m_androidList.waitForStarted(3000)) {
        failJob(index, QStringLiteral("No se pudo ejecutar el asistente de "
                                      "descargas."));
    }
}

void Downloads::androidListFinished(int code)
{
    if (m_current < 0)
        return;   // cancelado: la respuesta ya no interesa
    const int idx = m_current;

    const QByteArray out = m_androidList.readAllStandardOutput();
    if (code != 0) {
        QString err = QString::fromUtf8(m_androidList.readAllStandardError()).trimmed();
        if (err.isEmpty())
            err = QStringLiteral("No se pudo leer la lista (código %1).").arg(code);
        failJob(idx, friendlyError(err));
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(out).object();
    const QJsonArray entries = root.value(QStringLiteral("entries")).toArray();
    m_androidTracks.clear();
    m_androidTracks.reserve(entries.size());
    for (const QJsonValue &v : entries) {
        const QJsonObject o = v.toObject();
        const QString id = o.value(QStringLiteral("id")).toString();
        const QString title = o.value(QStringLiteral("title")).toString();
        if (id.size() != 11 || title.isEmpty())
            continue;
        AndroidTrack t;
        t.id = id;
        t.title = title;
        t.artist = o.value(QStringLiteral("channel")).toString();
        if (t.artist.isEmpty())
            t.artist = o.value(QStringLiteral("artist")).toString();
        t.url = o.value(QStringLiteral("url")).toString();
        if (t.url.isEmpty())
            t.url = QStringLiteral("https://www.youtube.com/watch?v=") + id;
        t.thumb = o.value(QStringLiteral("thumbnail")).toString();
        t.duration = o.value(QStringLiteral("duration")).toDouble();
        m_androidTracks.append(t);
    }
    if (m_androidTracks.isEmpty()) {
        failJob(idx, QStringLiteral("La lista está vacía o no se pudo leer "
                                    "ninguna pista."));
        return;
    }
    qInfo() << "[downloads] lista con" << m_androidTracks.size() << "pistas";
    m_androidIndex = 0;
    m_plTotal = m_androidTracks.size();
    m_plItem = 0;
    androidNextTrack();
}

// Asks the player for the direct URL of the current track (one at a time).
void Downloads::androidNextTrack()
{
    if (m_current < 0)
        return;
    m_androidResolving.clear();
    m_androidFetchId.clear();
    m_androidOutPath.clear();
    // Resume: skip what is already in the archive file.
    while (m_androidIndex < m_androidTracks.size()
           && m_androidDone.contains(m_androidTracks.at(m_androidIndex).id)) {
        ++m_androidIndex;
    }
    if (m_androidIndex >= m_androidTracks.size()) {
        m_androidPoll.stop();
        finishJob(0);
        return;
    }
    const AndroidTrack &t = m_androidTracks.at(m_androidIndex);
    m_plTotal = m_androidTracks.size();
    m_plItem = m_androidIndex + 1;
    m_jobs[m_current].progress =
        qBound(0, int(double(m_androidIndex) / double(m_plTotal) * 100.0), 100);
    emit jobsChanged();
    emit activeProgressChanged();
    if (!m_player) {
        failJob(m_current, QStringLiteral("El reproductor no está disponible "
                                          "para resolver el audio."));
        return;
    }
    m_androidResolving = Player::normalizeUrl(t.url);
    m_androidResolveTicks = 0;
    m_androidPoll.start();
    m_player->resolveForDownload(t.url);
}

// Direct URL resolved: it is downloaded with the HTTP stack of the system.
void Downloads::androidStartFetch(const QString &direct)
{
    if (m_current < 0 || m_androidIndex >= m_androidTracks.size())
        return;
    const AndroidTrack &t = m_androidTracks.at(m_androidIndex);

    if (!QJniObject::isClassAvailable("com/lotustuneremote/app/MediaDownload")) {
        androidTrackFailed(QStringLiteral("Esta versión de la app no trae el "
                                          "descargador. Reinstálala."));
        return;
    }

    // Extension from the mime of the stream (both formats are in the audio
    // extension list of the local library).
    const bool webm = direct.contains(QLatin1String("audio%2Fwebm"))
                      || direct.contains(QLatin1String("audio/webm"))
                      || direct.contains(QLatin1String("webm"));
    const QString ext = webm ? QStringLiteral("webm") : QStringLiteral("m4a");

    QString base;
    if (m_jobs[m_current].playlist) {
        base = QStringLiteral("%1").arg(m_androidIndex + 1, 2, 10,
                                        QLatin1Char('0'))
               + safeSegment(t.title);
    } else {
        base = t.artist.isEmpty()
            ? safeSegment(t.title)
            : safeSegment(t.artist + QStringLiteral(" - ") + t.title);
    }
    if (base.isEmpty())
        base = t.id;
    if (base.size() > 100)
        base = base.left(100);
    QString path = m_androidDir + QLatin1Char('/') + base
                   + QLatin1Char('.') + ext;
    for (int n = 2; QFileInfo::exists(path); ++n) {
        path = m_androidDir + QLatin1Char('/') + base
               + QStringLiteral(" (%1).").arg(n) + ext;
        if (n > 50)
            break;
    }
    m_androidOutPath = path;
    m_androidFetchId = t.id;
    m_androidRetries = 0;

    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/MediaDownload", "start",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
        QJniObject::fromString(t.id).object(),
        QJniObject::fromString(direct).object(),
        QJniObject::fromString(path).object());
    qInfo() << "[downloads] bajando" << t.id << t.title;
    m_androidPoll.start();
}

void Downloads::androidPollTick()
{
    if (m_current < 0) {
        m_androidPoll.stop();
        return;
    }
    // Waiting for the player to resolve the URL.
    if (!m_androidResolving.isEmpty() && m_androidFetchId.isEmpty()) {
        if (++m_androidResolveTicks > 120) {   // ~36 s
            m_androidPoll.stop();
            m_androidResolving.clear();
            androidTrackFailed(QStringLiteral("No se pudo resolver el audio de "
                                              "la pista (tiempo agotado)."));
        }
        return;
    }
    if (m_androidFetchId.isEmpty()) {
        m_androidPoll.stop();
        return;
    }
    const QString status = QJniObject::callStaticObjectMethod(
        "com/lotustuneremote/app/MediaDownload", "status",
        "()Ljava/lang/String;").toString();
    if (status.isEmpty() || status == QLatin1String("working")
        || status == QLatin1String("idle")) {
        const qint64 bytes = QJniObject::callStaticMethod<jlong>(
            "com/lotustuneremote/app/MediaDownload", "bytes", "()J");
        const qint64 total = QJniObject::callStaticMethod<jlong>(
            "com/lotustuneremote/app/MediaDownload", "total", "()J");
        if (total > 0) {
            m_plTotal = m_androidTracks.size();
            m_plItem = m_androidIndex + 1;
            updateProgress(double(bytes) / double(total));
        }
        return;
    }
    m_androidPoll.stop();

    if (status == QLatin1String("done")) {
        const QFileInfo fi(m_androidOutPath);
        if (!fi.isFile() || fi.size() < 4096) {
            androidTrackFailed(QStringLiteral("El archivo descargado llegó vacío."));
            return;
        }
        writeTrackInfo(m_androidOutPath, m_androidTracks.at(m_androidIndex));
        const QString id = m_androidTracks.at(m_androidIndex).id;
        m_androidDone.insert(id);
        if (!m_androidArchive.isEmpty()) {
            QFile af(m_androidArchive);
            if (af.open(QIODevice::Append))
                af.write(id.toUtf8() + '\n');
        }
        ++m_androidIndex;
        m_androidRetries = 0;
        m_androidResolving.clear();
        m_androidFetchId.clear();
        m_plTotal = m_androidTracks.size();
        m_plItem = m_androidIndex + 1;
        updateProgress(0.0);
        androidNextTrack();
        return;
    }

    // Failure (transient 403 from the node, network...): it retries a few
    // times before the track is given up.
    qWarning() << "[downloads] fallo de descarga:" << status;
    if (m_androidRetries < 3) {
        ++m_androidRetries;
        m_androidFetchId.clear();
        m_androidResolving.clear();
        QTimer::singleShot(1500, this, [this]() {
            if (m_current >= 0)
                androidNextTrack();
        });
        return;
    }
    androidTrackFailed(QStringLiteral("No se pudo descargar la pista (%1).")
                           .arg(status));
}

void Downloads::androidTrackFailed(const QString &message)
{
    if (m_current < 0)
        return;
    androidAbort();
    failJob(m_current, message);
}

void Downloads::androidAbort()
{
    m_androidPoll.stop();
    if (m_androidList.state() != QProcess::NotRunning) {
        m_androidList.kill();
        m_androidList.waitForFinished(500);
    }
    if (!m_androidFetchId.isEmpty()) {
        if (QJniObject::isClassAvailable("com/lotustuneremote/app/MediaDownload")) {
            QJniObject::callStaticMethod<void>(
                "com/lotustuneremote/app/MediaDownload", "cancel", "()V");
        }
        m_androidFetchId.clear();
    }
    // Order matters: what identifies the track is cleared first so the
    // "resolution abandoned" notice from the player does not come back in
    // here (a loop).
    m_androidResolving.clear();
    m_androidOutPath.clear();
    if (m_player)
        m_player->cancelDownloadResolve();
}

void Downloads::writeTrackInfo(const QString &path, const AndroidTrack &t) const
{
    QJsonObject o;
    o.insert(QStringLiteral("title"), t.title);
    if (!t.artist.isEmpty())
        o.insert(QStringLiteral("artist"), t.artist);
    if (t.duration > 0.0)
        o.insert(QStringLiteral("duration"), t.duration);
    if (!t.thumb.isEmpty())
        o.insert(QStringLiteral("thumbnail"), t.thumb);
    o.insert(QStringLiteral("id"), t.id);
    QFile f(path + QStringLiteral(".info.json"));
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
}
#endif   // Q_OS_ANDROID

// ------------------------------------------------------------- local ----

QString Downloads::artistForPath(const QString &dir) const
{
    const QDir root(m_folder);
    const QString rel = root.relativeFilePath(dir);
    if (rel.isEmpty() || rel == QLatin1String("."))
        return QStringLiteral("Local");
    return rel.section(QLatin1Char('/'), 0, 0);
}

QVariantList Downloads::folders() const
{
    // Groups the local library by top level folder: every folder is
    // a downloaded list (with name, number of tracks and a thumbnail).
    QStringList order;
    QHash<QString, QVariantList> groups;
    for (const QVariant &v : m_local) {
        const QString f = v.toMap().value(QStringLiteral("folder")).toString();
        if (f.isEmpty())
            continue;   // loose tracks in the root: they do not form a list
        if (!groups.contains(f))
            order.append(f);
        groups[f].append(v);
    }

    QVariantList out;
    out.reserve(order.size());
    for (const QString &f : std::as_const(order)) {
        const QVariantList &tr = groups.value(f);
        QString thumb;
        for (const QVariant &v : tr) {
            const QString th = v.toMap().value(QStringLiteral("thumb")).toString();
            if (!th.isEmpty()) {
                thumb = th;
                break;
            }
        }
        // The cover of the list itself (the one it has on YouTube Music),
        // not the cover of its first track.
        const QString dir = m_folder + QLatin1Char('/') + f;
        const QVariantMap meta = readFolderMeta(dir);
        const QString listThumb = meta.value(QStringLiteral("_thumb")).toString();
        if (!listThumb.isEmpty())
            thumb = listThumb;
        // A cover cached on disk wins: it is the real one of the list and
        // never expires (the signed URL does, and answered 404).
        const QString coverFile = dir + QStringLiteral("/cover.jpg");
        if (QFileInfo::exists(coverFile))
            thumb = QUrl::fromLocalFile(coverFile).toString();
        // The signed covers expire: the stable one of the first track is
        // kept as a second candidate (RoundedArt tries it if the first
        // answers 404).
        QString thumbAlt = meta.value(QStringLiteral("_thumbAlt")).toString();
        if (thumbAlt.isEmpty()) {
            for (const QVariant &v : tr) {
                thumbAlt = stableThumb(
                    v.toMap().value(QStringLiteral("thumb")).toString());
                if (!thumbAlt.isEmpty())
                    break;
            }
        }
        if (thumbAlt.isEmpty())
            thumbAlt = stableThumb(listThumb);
        QVariantMap m;
        m.insert(QStringLiteral("name"), f);
        m.insert(QStringLiteral("folder"), f);
        m.insert(QStringLiteral("count"), tr.size());
        m.insert(QStringLiteral("thumb"), thumb);
        if (!thumbAlt.isEmpty() && thumbAlt != thumb)
            m.insert(QStringLiteral("thumbFallback"), thumbAlt);
        // Metadata of the list (if it exists): original name, source URL
        // and what it is (album, single or saved list).
        QString kind;
        QString listUrl;
        QFile mf(m_folder + QLatin1Char('/') + f
                 + QStringLiteral("/.lotus-list.json"));
        if (mf.open(QIODevice::ReadOnly)) {
            const QJsonObject o = QJsonDocument::fromJson(mf.readAll()).object();
            const QString nm = o.value(QStringLiteral("name")).toString().trimmed();
            const QString u = o.value(QStringLiteral("url")).toString().trimmed();
            kind = o.value(QStringLiteral("kind")).toString().trimmed().toLower();
            listUrl = u;
            if (!nm.isEmpty())
                m.insert(QStringLiteral("name"), nm);
            if (!u.isEmpty())
                m.insert(QStringLiteral("url"), u);
        }
        if (kind != QLatin1String("album") && kind != QLatin1String("single")) {
            // Old folders have no `kind` in their JSON: an album playlist
            // id is recognisable (OLAK5uy_), a one-track folder is a
            // single, everything else (saved playlists, radios) is a list.
            if (tr.size() <= 1)
                kind = QStringLiteral("single");
            else if (listUrl.contains(QLatin1String("OLAK5uy_")))
                kind = QStringLiteral("album");
            else
                kind = QStringLiteral("list");
        }
        m.insert(QStringLiteral("kind"), kind);
        out.append(m);
    }
    return out;
}

QVariantMap Downloads::makeLocalTrack(const QString &path,
                                      const QVariantMap &meta) const
{
    const QFileInfo fi(path);
    // Top level folder under the root = a downloaded list ("Neon &
     // Shadows", etc.). It empties if the file is loose in the root.
    const QString rel = QDir(m_folder).relativeFilePath(fi.absolutePath());
    const QString folder = (rel.isEmpty() || rel == QLatin1String("."))
        ? QString() : rel.section(QLatin1Char('/'), 0, 0);
    QVariantMap t;
    t.insert(QStringLiteral("title"), fi.completeBaseName());
    t.insert(QStringLiteral("artist"), artistForPath(fi.absolutePath()));
    t.insert(QStringLiteral("folder"), folder);
    t.insert(QStringLiteral("duration"), 0.0);
    t.insert(QStringLiteral("thumb"), QString());
    t.insert(QStringLiteral("url"),
             QUrl::fromLocalFile(fi.absoluteFilePath()).toString());
    t.insert(QStringLiteral("source"), QStringLiteral("local"));
    // When the file arrived (its modification time): "play all" on the
    // Downloads page plays them in this order (or the reverse).
    t.insert(QStringLiteral("addedAt"),
             fi.lastModified().toMSecsSinceEpoch());

    // Compatibility with old libraries: if a sibling `.info.json` exists
     // (from versions that did write it), the track is enriched with its
     // title, artist, duration and artwork. The new downloads do not
     // create it any more.
    const QStringList candidates{
        fi.absolutePath() + QLatin1Char('/') + fi.fileName()
            + QStringLiteral(".info.json"),
        fi.absolutePath() + QLatin1Char('/') + fi.completeBaseName()
            + QStringLiteral(".info.json"),
    };
    for (const QString &info : candidates) {
        QFile f(info);
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        if (o.isEmpty())
            continue;

        const QString title = o.value(QStringLiteral("title")).toString().trimmed();
        if (!title.isEmpty())
            t.insert(QStringLiteral("title"), title);

        QString artist = o.value(QStringLiteral("artist")).toString().trimmed();
        if (artist.isEmpty())
            artist = o.value(QStringLiteral("uploader")).toString().trimmed();
        if (artist.isEmpty())
            artist = o.value(QStringLiteral("channel")).toString().trimmed();
        if (!artist.isEmpty())
            t.insert(QStringLiteral("artist"), artist);

        if (o.contains(QStringLiteral("duration")))
            t.insert(QStringLiteral("duration"),
                     o.value(QStringLiteral("duration")).toDouble());

        const QString thumb = o.value(QStringLiteral("thumbnail")).toString();
        if (!thumb.isEmpty())
            t.insert(QStringLiteral("thumb"), thumb);
        break;
    }

    // Metadata of the list (title, real artist, duration and cover): the
    // audio file only carries the sound. It is matched by the number the
    // file starts with ("03Crossed The Line" -> the 3rd track of the
    // list), and by title if the list moved things around.
    if (!meta.isEmpty()) {
        const QString base = fi.completeBaseName();
        static const QRegularExpression prefixRe(QStringLiteral("^(\\d{1,4})"));
        const auto hit = prefixRe.match(base);
        if (hit.hasMatch()) {
            const QString rest = base.mid(hit.capturedLength());
            auto matches = [&rest](const QVariantMap &cand) {
                const QString title = cand.value(QStringLiteral("title"))
                                          .toString();
                if (title.isEmpty())
                    return false;
                auto norm = [](const QString &s) {
                    QString out = s.toLower();
                    out.remove(QRegularExpression(
                        QStringLiteral("[^\\p{L}\\p{N}]+")));
                    return out;
                };
                const QString a = norm(title);
                const QString b = norm(rest);
                return !a.isEmpty() && a == b;
            };
            QVariantMap entry = meta.value(hit.captured(1)).toMap();
            if (!entry.isEmpty() && !matches(entry))
                entry.clear();
            if (entry.isEmpty()) {
                for (auto it = meta.cbegin(); it != meta.cend(); ++it) {
                    const QVariantMap cand = it.value().toMap();
                    if (!cand.isEmpty() && matches(cand)) {
                        entry = cand;
                        break;
                    }
                }
            }
            if (!entry.isEmpty()) {
                if (entry.contains(QStringLiteral("title")))
                    t.insert(QStringLiteral("title"),
                             entry.value(QStringLiteral("title")));
                if (entry.contains(QStringLiteral("artist")))
                    t.insert(QStringLiteral("artist"),
                             entry.value(QStringLiteral("artist")));
                if (entry.contains(QStringLiteral("duration")))
                    t.insert(QStringLiteral("duration"),
                             entry.value(QStringLiteral("duration")));
                if (entry.contains(QStringLiteral("thumb"))) {
                    const QString th =
                        entry.value(QStringLiteral("thumb")).toString();
                    const QString st = stableThumb(th);
                    t.insert(QStringLiteral("thumb"),
                             st.isEmpty() ? th : st);
                }
            }
        }
    }
    return t;
}

void Downloads::refreshLocal()
{
    // Restarts any scan in progress and starts from scratch.
    stopScan();
    m_scanItems.clear();
    m_scanDirs.clear();
    m_folderMeta.clear();
    m_metaLoaded.clear();
    m_localBusy = true;
    emit libraryChanged();
    startScan();
}

void Downloads::startScan()
{
    if (m_folder.isEmpty() || !QDir(m_folder).exists()) {
        m_local.clear();
        m_bytes = 0;
        m_localBusy = false;
        emit libraryChanged();
        return;
    }

    // Without name filters: the extension is tried by hand to be
     // case insensitive and find any audio format.
    // The space used is recounted on every scan: it is summed file by
    // file while walking, so opening Settings never walks the folder again.
    m_scanBytes = 0;
    m_scan = new QDirIterator(m_folder, QDir::Files | QDir::NoDotAndDotDot
                                           | QDir::Readable,
                              QDirIterator::Subdirectories);
    m_scanTimer.start();
    emit libraryChanged();
}

void Downloads::stopScan()
{
    m_scanTimer.stop();
    delete m_scan;
    m_scan = nullptr;
}

void Downloads::scanChunk()
{
    if (!m_scan) {
        m_scanTimer.stop();
        return;
    }

    // Small batch: it keeps the event loop alive between ticks.
    int processed = 0;
    while (processed < 60 && m_scan->hasNext()) {
        const QString path = m_scan->next();
        ++processed;
        const QFileInfo fi(path);
        // Audio, .json of the lists, leftovers...: everything that takes
        // space in the folder counts.
        m_scanBytes += fi.size();
        m_scanDirs.insert(fi.absolutePath());
        if (!isAudioFile(path))
            continue;
        // Metadata of the list this file belongs to (read once per scan).
        const QString rel = QDir(m_folder).relativeFilePath(fi.absolutePath());
        const QString folder = (rel.isEmpty() || rel == QLatin1String("."))
            ? QString() : rel.section(QLatin1Char('/'), 0, 0);
        if (!m_metaLoaded.contains(folder)) {
            m_metaLoaded.insert(folder);
            m_folderMeta.insert(folder, readFolderMeta(fi.absolutePath()));
        }
        m_scanItems.append(makeLocalTrack(path, m_folderMeta.value(folder)));
    }

    if (!m_scan->hasNext()) {
        stopScan();
        // Download order is the order the files arrived in (modification
        // time), not the alphabetical one of the folder walk.
        std::stable_sort(m_scanItems.begin(), m_scanItems.end(),
                         [](const QVariant &a, const QVariant &b) {
            return a.toMap().value(QStringLiteral("addedAt")).toLongLong()
                 < b.toMap().value(QStringLiteral("addedAt")).toLongLong();
        });
        m_local = m_scanItems;
        m_scanItems.clear();
        m_bytes = m_scanBytes;
        m_localBusy = false;
        updateWatchDirs();
        emit libraryChanged();
        // Lists downloaded before this cache existed (or lists that grew)
        // get their metadata fetched now, in the background.
        queueFolderMeta();
        // And their cover is copied next to the files, so it survives the
        // expiry of the signed URL.
        queueFolderCovers();
    }
}

// ---- metadata of the downloaded lists -----------------------------------

QVariantMap Downloads::readFolderMeta(const QString &dir)
{
    QVariantMap out;
    QFile f(dir + QStringLiteral("/.lotus-meta.json"));
    if (!f.open(QIODevice::ReadOnly))
        return out;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    // constBegin/constEnd: QJsonObject did not grow cbegin/cend until
    // much later, and the Android toolchain is Qt 6.6.
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        // Control keys: "_files" (how many tracks the cache covers) and
        // "_failedAt" (when it could not be fetched).
        if (it.key().startsWith(QLatin1Char('_'))) {
            out.insert(it.key(), it.value().toVariant());
            continue;
        }
        if (!it.value().isObject())
            continue;
        const QJsonObject e = it.value().toObject();
        QVariantMap t;
        const QString title = e.value(QStringLiteral("title")).toString().trimmed();
        if (!title.isEmpty())
            t.insert(QStringLiteral("title"), title);
        const QString artist = e.value(QStringLiteral("artist")).toString().trimmed();
        if (!artist.isEmpty())
            t.insert(QStringLiteral("artist"), artist);
        const double dur = e.value(QStringLiteral("duration")).toDouble();
        if (dur > 0.0)
            t.insert(QStringLiteral("duration"), dur);
        const QString thumb = e.value(QStringLiteral("thumb")).toString();
        if (!thumb.isEmpty())
            t.insert(QStringLiteral("thumb"), thumb);
        if (!t.isEmpty())
            out.insert(it.key(), t);
    }
    return out;
}

void Downloads::writeFolderMeta(const QString &dir, const QVariantMap &map)
{
    QJsonObject o;
    for (auto it = map.cbegin(); it != map.cend(); ++it) {
        if (it.key().startsWith(QLatin1Char('_'))) {
            o.insert(it.key(), QJsonValue::fromVariant(it.value()));
            continue;
        }
        const QVariantMap t = it.value().toMap();
        if (t.isEmpty())
            continue;
        QJsonObject e;
        if (t.contains(QStringLiteral("title")))
            e.insert(QStringLiteral("title"),
                     t.value(QStringLiteral("title")).toString());
        if (t.contains(QStringLiteral("artist")))
            e.insert(QStringLiteral("artist"),
                     t.value(QStringLiteral("artist")).toString());
        if (t.contains(QStringLiteral("duration")))
            e.insert(QStringLiteral("duration"),
                     t.value(QStringLiteral("duration")).toDouble());
        if (t.contains(QStringLiteral("thumb")))
            e.insert(QStringLiteral("thumb"),
                     t.value(QStringLiteral("thumb")).toString());
        o.insert(it.key(), e);
    }
    QFile f(dir + QStringLiteral("/.lotus-meta.json"));
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void Downloads::queueFolderMeta()
{
#ifdef Q_OS_ANDROID
    // Android has no yt-dlp: its downloads write the data of every track
    // in a `.info.json` next to it, so there is nothing to fetch.
    return;
#else
    if (m_busy || m_folder.isEmpty())
        return;   // yt-dlp is downloading: this can wait
    QHash<QString, int> count;
    for (const QVariant &v : std::as_const(m_local)) {
        const QString f = v.toMap().value(QStringLiteral("folder")).toString();
        if (!f.isEmpty())
            count[f] += 1;
    }
    for (auto it = count.cbegin(); it != count.cend(); ++it) {
        const QString &folder = it.key();
        if (m_metaQueue.contains(folder) || m_metaFolder == folder)
            continue;
        const QString dir = m_folder + QLatin1Char('/') + folder;
        const QVariantMap meta = readFolderMeta(dir);
        const int cachedFiles = meta.value(QStringLiteral("_files")).toInt();
        if (cachedFiles >= it.value()
            || (cachedFiles == 0 && meta.size() >= it.value())) {
            // Cached, but maybe without the cover file yet (lists
            // downloaded by older versions). One refresh is enough: the
            // new metadata run leaves `_coverTried`.
            if (!QFileInfo::exists(dir + QStringLiteral("/cover.jpg"))
                    && !meta.contains(QStringLiteral("_coverTried"))
                    && !m_metaTried.contains(folder)) {
                m_metaTried.insert(folder);
                m_metaQueue.append(folder);
            }
            continue;   // cached with (at least) every track of the folder
        }
        QFile lf(dir + QStringLiteral("/.lotus-list.json"));
        if (!lf.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject list = QJsonDocument::fromJson(lf.readAll()).object();
        if (list.value(QStringLiteral("url")).toString().trimmed().isEmpty())
            continue;
        // A failure less than a day old is not retried (offline, private
        // list...): no reason to hammer it on every scan.
        QFile mf(dir + QStringLiteral("/.lotus-meta.json"));
        if (mf.open(QIODevice::ReadOnly)) {
            const QJsonObject o = QJsonDocument::fromJson(mf.readAll()).object();
            const qint64 when = qint64(o.value(QStringLiteral("_failedAt"))
                                          .toDouble());
            if (when > 0
                && QDateTime::currentSecsSinceEpoch() - when < 24 * 3600)
                continue;
        }
        m_metaQueue.append(folder);
    }
    startNextFolderMeta();
#endif
}

void Downloads::startNextFolderMeta()
{
#ifdef Q_OS_ANDROID
    return;
#else
    if (m_metaProc.state() != QProcess::NotRunning || m_metaQueue.isEmpty())
        return;
    m_metaFolder = m_metaQueue.takeFirst();
    const QString dir = m_folder + QLatin1Char('/') + m_metaFolder;
    QFile lf(dir + QStringLiteral("/.lotus-list.json"));
    QString url;
    if (lf.open(QIODevice::ReadOnly))
        url = QJsonDocument::fromJson(lf.readAll()).object()
                  .value(QStringLiteral("url")).toString().trimmed();
    if (url.isEmpty()) {
        m_metaFolder.clear();
        startNextFolderMeta();
        return;
    }
    QStringList args{
        QStringLiteral("--no-config"),
        QStringLiteral("--no-warnings"),
        QStringLiteral("--flat-playlist"),
        QStringLiteral("--dump-single-json"),
    };
    const QString cookies = AppPaths::cookiesFile();
    if (QFile::exists(cookies)
        && (url.contains(QLatin1String("youtube.com"))
            || url.contains(QLatin1String("youtu.be"))))
        args << QStringLiteral("--cookies") << cookies;
    args << url;
    m_metaProc.setProgram(QStringLiteral("yt-dlp"));
    m_metaProc.setArguments(args);
    m_metaProc.start();
#endif
}

void Downloads::finishFolderMeta(int code)
{
#ifdef Q_OS_ANDROID
    Q_UNUSED(code)
    return;
#else
    const QString dir = m_folder + QLatin1Char('/') + m_metaFolder;
    const QByteArray out = m_metaProc.readAllStandardOutput();
    QVariantMap map;
    if (code == 0 && !out.isEmpty()) {
        const QJsonObject o = QJsonDocument::fromJson(out).object();
        const QJsonArray entries = o.value(QStringLiteral("entries")).toArray();
        int idx = 0;
        for (const QJsonValue &v : entries) {
            ++idx;
            const QJsonObject e = v.toObject();
            if (e.isEmpty())
                continue;
            const QString title = e.value(QStringLiteral("title"))
                                      .toString().trimmed();
            if (title.isEmpty())
                continue;
            QVariantMap t;
            t.insert(QStringLiteral("title"), title);
            QString artist = e.value(QStringLiteral("artist")).toString().trimmed();
            if (artist.isEmpty())
                artist = e.value(QStringLiteral("uploader")).toString().trimmed();
            if (artist.isEmpty())
                artist = e.value(QStringLiteral("channel")).toString().trimmed();
            if (!artist.isEmpty())
                t.insert(QStringLiteral("artist"), artist);
            const double dur = e.value(QStringLiteral("duration")).toDouble();
            if (dur > 0.0)
                t.insert(QStringLiteral("duration"), dur);
            const QJsonArray thumbs = e.value(QStringLiteral("thumbnails")).toArray();
            QString thumbUrl;
            for (int i = thumbs.size() - 1; i >= 0; --i) {
                const QString u = thumbs.at(i).toObject()
                                      .value(QStringLiteral("url")).toString();
                if (!u.isEmpty()) {
                    thumbUrl = u;
                    break;
                }
            }
            // The signed URL is fine while it lasts; the stable /vi/ one
            // of the video is what is stored, so the rows keep their art
            // months later.
            const QString stable = stableThumb(thumbUrl);
            if (!stable.isEmpty())
                t.insert(QStringLiteral("thumb"), stable);
            else if (!thumbUrl.isEmpty())
                t.insert(QStringLiteral("thumb"), thumbUrl);
            if (stable.isEmpty() && !thumbUrl.isEmpty()) {
                // Last resort: the entry's id is enough to build it.
                const QString id = e.value(QStringLiteral("id")).toString();
                static const QRegularExpression idRe(
                    QStringLiteral("^[A-Za-z0-9_-]{11}$"));
                if (idRe.match(id).hasMatch())
                    t.insert(QStringLiteral("thumb"),
                             QStringLiteral("https://i.ytimg.com/vi/%1/"
                                            "hqdefault.jpg").arg(id));
            }
            map.insert(QString::number(idx), t);
        }
        // Cover of the list itself (its own on YouTube Music): the folder
        // card shows it instead of the cover of the first track.
        const QJsonArray listThumbs = o.value(QStringLiteral("thumbnails")).toArray();
        // Prefer a signed cover (it works right now) over the plain
        // maxresdefault that yt-dlp also lists without a signature: that
        // one answers 404 and left the card empty.
        QString listThumb;
        for (int i = listThumbs.size() - 1; i >= 0; --i) {
            const QString u = listThumbs.at(i).toObject()
                                  .value(QStringLiteral("url")).toString();
            if (u.isEmpty())
                continue;
            if (u.contains(QLatin1String("?sqp="))) {
                listThumb = u;
                break;
            }
            if (listThumb.isEmpty())
                listThumb = u;
        }
        if (!listThumb.isEmpty())
            map.insert(QStringLiteral("_thumb"), listThumb);
        // Stable alternative: the first track's /vi/ cover (the card uses
        // it if the signed one has already expired).
        for (const QJsonValue &v : entries) {
            const QString id = v.toObject()
                                   .value(QStringLiteral("id")).toString();
            static const QRegularExpression idRe(
                QStringLiteral("^[A-Za-z0-9_-]{11}$"));
            if (idRe.match(id).hasMatch()) {
                map.insert(QStringLiteral("_thumbAlt"),
                           QStringLiteral("https://i.ytimg.com/vi/%1/"
                                          "hqdefault.jpg").arg(id));
                break;
            }
        }
    }
    if (!map.isEmpty()) {
        // Number of audio files the cache was built for: if the list grows
        // (more tracks downloaded) it is fetched again; if some file of the
        // folder is not part of the list, it is not retried for ever.
        map.insert(QStringLiteral("_files"), countAudioFiles(dir));
        map.insert(QStringLiteral("_coverTried"), 1);
        const QString listCover = map.value(QStringLiteral("_thumb")).toString();
        writeFolderMeta(dir, map);
        m_metaWrote = true;
        qInfo() << "[downloads] metadata of" << m_metaFolder << ":"
                << map.size() - 1 << "tracks";
        // The signed URL works right now: copy the cover next to the
        // tracks before it expires.
        if (!listCover.isEmpty())
            cacheCover(dir, listCover);
    } else if (!m_metaFolder.isEmpty()) {
        QVariantMap failed;
        failed.insert(QStringLiteral("_failedAt"),
                      QDateTime::currentSecsSinceEpoch());
        writeFolderMeta(dir, failed);
        qInfo() << "[downloads] no metadata for" << m_metaFolder;
    }
    m_metaFolder.clear();
    startNextFolderMeta();
    if (m_metaQueue.isEmpty() && m_metaProc.state() == QProcess::NotRunning
        && m_metaWrote) {
        // Now the library can show titles, artists, durations and covers.
        m_metaWrote = false;
        refreshLocal();
    }
#endif
}

void Downloads::updateWatchDirs()
{
    // It watches the root + every discovered subfolder (one per
     // list/track).
    QStringList want;
    if (!m_folder.isEmpty() && QDir(m_folder).exists())
        want << m_folder;
    for (const QString &d : std::as_const(m_scanDirs))
        if (QDir(d).exists())
            want << d;
    want.removeDuplicates();

    const QStringList current = m_watcher.directories();
    for (const QString &d : current)
        if (!want.contains(d))
            m_watcher.removePath(d);
    for (const QString &d : want)
        if (!current.contains(d))
            m_watcher.addPath(d);
}

void Downloads::openFolder()
{
    if (m_folder.isEmpty())
        return;
    QDir().mkpath(m_folder);
    // QDesktopServices opens the folder with the file manager of the
    // system (xdg-open does not exist on Windows or Android).
    QDesktopServices::openUrl(QUrl::fromLocalFile(m_folder));
}

QString Downloads::listFolderName(const QString &name) const
{
    return safeSegment(name);
}

void Downloads::removeList(const QString &folder)
{
    // Only a FIRST level folder inside the downloads folder may be
     // deleted (never the root, nor paths with separators or "..").
    const QString f = folder.trimmed();
    if (f.isEmpty() || f.contains(QLatin1Char('/'))
        || f.contains(QLatin1Char('\\')) || f == QLatin1String(".")
        || f == QLatin1String(".."))
        return;
    const QDir root(m_folder);
    const QString canon = QDir::cleanPath(root.absoluteFilePath(f));
    const QString rootCanon = QDir::cleanPath(root.absolutePath());
    if (canon == rootCanon
        || !canon.startsWith(rootCanon + QLatin1Char('/')))
        return;   // outside the downloads folder

    // If that list is being downloaded (or is queued) it is cancelled
     // before deleting so yt-dlp does not recreate the folder.
    bool killCurrent = false;
    for (int i = 0; i < m_jobs.size(); ++i) {
        if (!m_jobs[i].playlist)
            continue;
        // The resolved folder rules; if it was not resolved yet (job
         // queued) it is compared by the sanitised name.
        if (m_jobs[i].folder.isEmpty() ? safeSegment(m_jobs[i].name) != f
                                       : m_jobs[i].folder != f)
            continue;
        if (m_jobs[i].state == QLatin1String("queued"))
            setJob(i, QStringLiteral("error"), QStringLiteral("Cancelado"));
        else if (i == m_current)
            killCurrent = true;
    }
    if (killCurrent && m_proc.state() != QProcess::NotRunning) {
        m_cancelling = true;
        m_proc.kill();
    }

    QDir(canon).removeRecursively();
    // Rescans so the list disappears from the UI at once.
    refreshLocal();
    emit jobsChanged();
    emit changed();
}
