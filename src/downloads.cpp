#include "downloads.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSettings>
#include <QStringList>
#include <QStorageInfo>
#include <QUrl>

#include <utility>

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

bool isAudioFile(const QString &path)
{
    const QString ext = QFileInfo(path).suffix().toLower();
    for (const char *e : kAudioExts)
        if (ext == QLatin1String(e))
            return true;
    return false;
}

// Minimum age (seconds) to consider a partial leftover orphan on startup:
// that way a resumable one from a recent close is not deleted, but the
// garbage left by a session aborted hours ago is.
constexpr qint64 kOrphanAgeSecs = 6 * 3600;

} // namespace

Downloads::Downloads(QObject *parent)
    : QObject(parent)
{
    // Folder persisted by the user; if there is none, the default one.
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

    // Cleans orphan partial leftovers (from an aborted session) before the
    // first sync.
    sweepOrphans(kOrphanAgeSecs);

    // First sync on startup.
    refreshLocal();
}

Downloads::~Downloads()
{
    stopScan();
    if (m_proc.state() != QProcess::NotRunning) {
        m_proc.kill();
        m_proc.waitForFinished(700);
    }
}

QString Downloads::defaultFolder() const
{
    return QDir::homePath() + QStringLiteral("/.local/share/lotus-tune/descargas");
}

void Downloads::setFolder(const QString &dir)
{
    const QString clean = QDir::cleanPath(dir.trimmed());
    if (clean.isEmpty() || clean == m_folder)
        return;
    m_folder = clean;
    QDir().mkpath(m_folder);

    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("downloadFolder"), m_folder);
    s.sync();

    emit changed();
    // The local library now lives in another folder: rescan.
    refreshLocal();
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

void Downloads::downloadPlaylist(const QString &url, const QString &name)
{
    const QString u = url.trimmed();
    if (u.isEmpty())
        return;
    Job j;
    j.url = u;
    j.playlist = true;
    j.name = name.trimmed().isEmpty() ? QStringLiteral("Playlist") : name.trimmed();
    enqueue(j);
}

void Downloads::downloadTrack(const QString &url, const QString &title,
                              const QString &artist)
{
    const QString u = url.trimmed();
    if (u.isEmpty())
        return;
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
    j.progress = 0;
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
        // Tidal style: Opus with an efficient compression (better than m4a,
         // higher quality).
        QStringLiteral("-f"),
        QStringLiteral("bestaudio[ext=opus]/bestaudio/best"),
        QStringLiteral("--extract-audio"),
        QStringLiteral("--audio-format"), QStringLiteral("opus"),
        QStringLiteral("--audio-quality"), QStringLiteral("0"),
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
    const QString cookies = QDir::homePath()
        + QStringLiteral("/.config/lotus-tune/cookies.txt");
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

void Downloads::removePartials(const QString &dir)
{
    QDir d(dir);
    if (!d.exists())
        return;
    const QStringList names = d.entryList(QDir::Files | QDir::NoDotAndDotDot);
    for (const QString &n : names)
        if (isPartialName(n))
            d.remove(n);
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
        // Only "old" orphans: the recent ones can be a resumable
         // session.
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
        setJob(idx, QStringLiteral("done"));
        m_jobs[idx].progress = 100;
        emit jobsChanged();
        emit changed();
        emit progressChanged(job.name, 100);
        emit downloadCompleted(job.name, job.folder);
        emit activeProgressChanged();
    } else {
        // Failure: it cleans the partials and publishes a readable reason.
        const QString raw = m_lastError.isEmpty()
            ? QStringLiteral("yt-dlp terminó con código %1").arg(code)
            : m_lastError;
        const QString msg = friendlyError(raw);
        removePartials(dir);
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
    // The jobs still queued will never get to run.
    for (int i = 0; i < m_jobs.size(); ++i) {
        if (m_jobs[i].state == QLatin1String("queued"))
            setJob(i, QStringLiteral("error"), QStringLiteral("Cancelado"));
    }

    if (m_proc.state() != QProcess::NotRunning) {
        // finishJob() will clean the partial leftovers of the running
         // job.
        m_cancelling = true;
        m_proc.kill();
    }
    emit jobsChanged();
    emit changed();
}

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
        QVariantMap m;
        m.insert(QStringLiteral("name"), f);
        m.insert(QStringLiteral("folder"), f);
        m.insert(QStringLiteral("count"), tr.size());
        m.insert(QStringLiteral("thumb"), thumb);
        // Metadata of the list (if it exists): original name and source URL.
        QFile mf(m_folder + QLatin1Char('/') + f
                 + QStringLiteral("/.lotus-list.json"));
        if (mf.open(QIODevice::ReadOnly)) {
            const QJsonObject o = QJsonDocument::fromJson(mf.readAll()).object();
            const QString nm = o.value(QStringLiteral("name")).toString().trimmed();
            const QString u = o.value(QStringLiteral("url")).toString().trimmed();
            if (!nm.isEmpty())
                m.insert(QStringLiteral("name"), nm);
            if (!u.isEmpty())
                m.insert(QStringLiteral("url"), u);
        }
        out.append(m);
    }
    return out;
}

QVariantMap Downloads::makeLocalTrack(const QString &path) const
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
    return t;
}

void Downloads::refreshLocal()
{
    // Restarts any scan in progress and starts from scratch.
    stopScan();
    m_scanItems.clear();
    m_scanDirs.clear();
    m_localBusy = true;
    emit libraryChanged();
    startScan();
}

void Downloads::startScan()
{
    if (m_folder.isEmpty() || !QDir(m_folder).exists()) {
        m_local.clear();
        m_localBusy = false;
        emit libraryChanged();
        return;
    }

    // Without name filters: the extension is tried by hand to be
     // case insensitive and find any audio format.
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
        m_scanDirs.insert(QFileInfo(path).absolutePath());
        if (isAudioFile(path))
            m_scanItems.append(makeLocalTrack(path));
    }

    if (!m_scan->hasNext()) {
        stopScan();
        m_local = m_scanItems;
        m_scanItems.clear();
        m_localBusy = false;
        updateWatchDirs();
        emit libraryChanged();
    }
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
    QProcess::startDetached(QStringLiteral("xdg-open"), {m_folder});
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
