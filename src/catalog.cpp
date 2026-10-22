#include "catalog.h"
#include "paths.h"
#include "sources.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

#include <algorithm>

#include <QDebug>

// The "liked" set syncs by itself on startup and on login
// (refreshLikedSet); there is no longer a 24 h TTL gate, because the
// query to the internal API is asynchronous and cheap. syncLiked()
// reinforces it on demand.

// On-disk list cache (playlists.json): validity TTL and a cap of 300
// entries (the oldest ones are pruned) so the file does not grow
static constexpr qint64 kPlaylistTtlSecs = 24 * 60 * 60;
static constexpr int kPlaylistCacheMax = 300;

Catalog::Catalog(SourceManager *sources, QObject *parent)
    : QObject(parent)
    , m_sources(sources)
{
    loadLibrary();

    // On-disk list cache: it is dumped in a deferred way (like the player's
    // streams.json) so it does not write on every load, and it is read at
    // startup so that reopening a list (or a pre-fetched radio) is instant
    // even after restarting the app.
    m_cacheSaveTimer.setSingleShot(true);
    m_cacheSaveTimer.setInterval(2500);
    connect(&m_cacheSaveTimer, &QTimer::timeout, this, &Catalog::savePlaylistCache);
    loadPlaylistCache();

    // Real in-app YT Music login state: the Netscape cookies.txt written by the
    // embedded WebKit login window (tools/ytm_login.py) is the source of truth.
    if (ytmLoggedIn())
        m_loginState = QStringLiteral("ok");

    // Dedicated process for the embedded login window: never touches m_proc.
    m_loginProc.setProcessChannelMode(QProcess::MergedChannels);
    connect(&m_loginProc, &QProcess::readyRead, this, &Catalog::handleLoginOutput);
    connect(&m_loginProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) { finishLogin(code); });

    // Confirm (async) that a stored session is still usable without blocking UI.
    m_statusProc.setProcessChannelMode(QProcess::MergedChannels);
    connect(&m_statusProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                setLoginState(code == 0 ? QStringLiteral("ok") : QString());
            });
    if (QFile::exists(helperPath())) {
        m_statusProc.setProgram(AppPaths::pythonProgram());
        m_statusProc.setArguments({helperPath(), QStringLiteral("status")});
        m_statusProc.start();
    } else if (m_loginState == QLatin1String("ok")) {
        m_loginState.clear();
    }

    // "My lists": one-off query to the YT Music API with ytm_api.py. It uses
    // its own QProcess so it does not interfere with m_proc nor with the login.
    m_libraryProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_libraryProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_libraryProc.readAllStandardOutput();
                QVariantList items;
                if (code == 0) {
                    const QJsonDocument doc = QJsonDocument::fromJson(out);
                    for (const QJsonValue &v : doc.array()) {
                        const QJsonObject o = v.toObject();
                        const QString id = o.value(QStringLiteral("id")).toString();
                        if (id.isEmpty())
                            continue;
                        QVariantMap it;
                        it.insert(QStringLiteral("id"), id);
                        it.insert(QStringLiteral("name"),
                                  o.value(QStringLiteral("name")).toString());
                        it.insert(QStringLiteral("url"),
                                  QStringLiteral("https://music.youtube.com/playlist?list=")
                                      + id);
                        it.insert(QStringLiteral("count"),
                                  o.value(QStringLiteral("count")).toInt());
                        it.insert(QStringLiteral("thumb"),
                                  o.value(QStringLiteral("thumb")).toString());
                        // An OWN list (it can be renamed/deleted) brings the
                        // EDIT/DELETE actions in its menu; someone else's
                        // saved list does not.
                        it.insert(QStringLiteral("owned"),
                                  o.value(QStringLiteral("owned")).toBool());
                        items.append(it);
                    }
                }
                m_ytmLibrary = items;
                m_libraryBusy = false;
                emit libraryChanged();
            });

    // Artists: search, discography and album tracks (ytm_api.py, anonymously
    // when there is no session). Its own process so it does not step on
    // the song searches or the list opening; its answer arrives through
    // dedicated signals.
    m_artistProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_artistProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_artistProc.readAllStandardOutput();
                const QString mode = m_artistMode;
                const QString arg = m_artistArg;
                m_artistMode.clear();
                m_artistArg.clear();
                if (mode.isEmpty())
                    return;   // cancelled by a new request: it is ignored
                QVariantList list;
                if (code == 0) {
                    const QJsonDocument doc = QJsonDocument::fromJson(out);
                    const QJsonObject root = doc.object();
                    if (mode == QLatin1String("artists")) {
                        for (const QJsonValue &v :
                             root.value(QStringLiteral("artists")).toArray()) {
                            const QJsonObject o = v.toObject();
                            if (o.value(QStringLiteral("browseId"))
                                    .toString()
                                    .isEmpty())
                                continue;
                            QVariantMap a;
                            a.insert(QStringLiteral("name"),
                                     o.value(QStringLiteral("name")).toString());
                            a.insert(QStringLiteral("browseId"),
                                     o.value(QStringLiteral("browseId")).toString());
                            a.insert(QStringLiteral("thumb"),
                                     o.value(QStringLiteral("thumb")).toString());
                            a.insert(QStringLiteral("subtitle"),
                                     o.value(QStringLiteral("subtitle")).toString());
                            list.append(a);
                        }
                    } else if (mode == QLatin1String("artist")) {
                        for (const QJsonValue &v :
                             root.value(QStringLiteral("albums")).toArray()) {
                            const QJsonObject o = v.toObject();
                            QVariantMap a;
                            a.insert(QStringLiteral("title"),
                                     o.value(QStringLiteral("title")).toString());
                            a.insert(QStringLiteral("browseId"),
                                     o.value(QStringLiteral("browseId")).toString());
                            a.insert(QStringLiteral("thumb"),
                                     o.value(QStringLiteral("thumb")).toString());
                            a.insert(QStringLiteral("subtitle"),
                                     o.value(QStringLiteral("subtitle")).toString());
                            a.insert(QStringLiteral("year"),
                                     o.value(QStringLiteral("year")).toInt());
                            list.append(a);
                        }
                    } else if (mode == QLatin1String("album")) {
                        for (const QJsonValue &v :
                             root.value(QStringLiteral("entries")).toArray())
                            list.append(normalize(v.toObject().toVariantMap()));
                    } else if (mode == QLatin1String("toptrack")) {
                        m_topTrack = normalize(root.toVariantMap());
                    }
                }
                if (mode == QLatin1String("artists"))
                    emit artistsReady(list);
                else if (mode == QLatin1String("artist"))
                    emit artistReady(arg, list);
                else if (mode == QLatin1String("album"))
                    emit albumTracksReady(arg, list);
                else if (mode == QLatin1String("toptrack"))
                    emit artistTopTrackResolved(arg, m_topTrack);
            });

    // Alternative video (m_altProc): the JSON that ytm_api.py returns is
    // already a whole track; it is normalised like a search track, but with
    // the source fixed to YouTube Music (which is what a YTM candidate
    // always is).
    m_altProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_altProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_altProc.readAllStandardOutput();
                const QString key = m_altKey;
                m_altKey.clear();
                QVariantMap track;
                if (code == 0) {
                    const QJsonDocument doc = QJsonDocument::fromJson(out);
                    if (doc.isObject()) {
                        // normalize() tags it with m_currentSource; what
                         // plays is the YTM track, so the source is ytm.
                        track = normalize(doc.object().toVariantMap());
                        if (!track.isEmpty())
                            track.insert(QStringLiteral("source"),
                                         QStringLiteral("ytm"));
                    }
                }
                emit alternateResolved(key, track);
            });

    // One off actions on YouTube Music (vote, add/remove from list). They go
    // in their own QProcess so they do not block searches or "my lists".
    m_ytmProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_ytmProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_ytmProc.readAllStandardOutput();
                const QByteArray err = m_ytmProc.readAllStandardError();
                QString message = m_ytmOkMessage;
                if (code != 0) {
                    const QStringList lines =
                        QString::fromUtf8(err).split(QLatin1Char('\n'),
                                                     Qt::SkipEmptyParts);
                    if (!lines.isEmpty())
                        message = lines.constLast().trimmed();
                    else
                        message = QStringLiteral("La acción falló");
                    emit interactionDone(false, message);
                    return;
                }
                emit interactionDone(true, message);
            });

    // Own list management (create/rename/privacy/delete and reading its
    // info). Its own process so it does not clash with the vote/addpl/rmpl
    // actions.
    m_plProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_plProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_plProc.readAllStandardOutput();
                const QByteArray err = m_plProc.readAllStandardError();
                const QString mode = m_plMode;
                m_plMode.clear();
                if (code != 0) {
                    QString msg = QStringLiteral("La operación falló");
                    const QStringList lines =
                        QString::fromUtf8(err).split(QLatin1Char('\n'),
                                                     Qt::SkipEmptyParts);
                    if (!lines.isEmpty())
                        msg = lines.constLast().trimmed();
                    m_plAddVideo.clear();
                    m_plSetId.clear();
                    if (mode == QLatin1String("info")) {
                        emit playlistInfoReady({});
                    } else {
                        // A failed reorder leaves the row moved locally:
                        // the open list is reloaded to get back the real order.
                        if (mode == QLatin1String("move")
                            && !m_openPlaylistId.isEmpty())
                            run(QStringLiteral("https://music.youtube.com/"
                                               "playlist?list=")
                                    + m_openPlaylistId,
                                QStringLiteral("playlist"), m_tracksTitle);
                        emit interactionDone(false, msg);
                    }
                    return;
                }
                if (mode == QLatin1String("info")) {
                    const QJsonDocument doc = QJsonDocument::fromJson(out);
                    emit playlistInfoReady(doc.object().toVariantMap());
                    return;
                }
                if (mode == QLatin1String("create")) {
                    const QJsonDocument doc = QJsonDocument::fromJson(out);
                    const QString id =
                        doc.object().value(QStringLiteral("id")).toString();
                    if (!m_plAddVideo.isEmpty() && !id.isEmpty()) {
                        // Chained: it creates the list and adds the track in
                         // the same batch (same QProcess, already free).
                        m_plMode = QStringLiteral("createadd");
                        m_plProc.setProgram(AppPaths::pythonProgram());
                        m_plProc.setArguments({ytmApiPath(), QStringLiteral("addpl"),
                                               id, m_plAddVideo});
                        m_plAddVideo.clear();
                        m_plProc.start();
                        return;
                    }
                    m_plAddVideo.clear();
                    refreshYtmLibrary();
                    emit interactionDone(true, QStringLiteral("Lista creada"));
                    return;
                }
                m_plAddVideo.clear();
                if (mode == QLatin1String("createadd")) {
                    refreshYtmLibrary();
                    emit interactionDone(true,
                                         QStringLiteral("Lista creada con la pista"));
                    return;
                }
                if (mode == QLatin1String("update")) {
                    refreshYtmLibrary();
                    emit interactionDone(true, QStringLiteral("Lista actualizada"));
                    return;
                }
                if (mode == QLatin1String("delete")) {
                    refreshYtmLibrary();
                    emit interactionDone(true, QStringLiteral("Lista eliminada"));
                    return;
                }
                if (mode == QLatin1String("move")) {
                    emit interactionDone(true, QStringLiteral("Lista reordenada"));
                    return;
                }
                if (mode == QLatin1String("remove")) {
                    // Already confirmed by YouTube: it removes the row from the open list.
                    const QString sid = m_plSetId;
                    m_plSetId.clear();
                    if (!sid.isEmpty()) {
                        for (int k = 0; k < m_tracks.size(); k++) {
                            if (m_tracks.at(k).toMap()
                                    .value(QStringLiteral("setId")).toString()
                                == sid) {
                                m_tracks.removeAt(k);
                                break;
                            }
                        }
                    }
                    if (!m_openPlaylistId.isEmpty())
                        forgetCachedPlaylist(QStringLiteral("list:")
                                             + m_openPlaylistId);
                    emit changed();
                    refreshYtmLibrary();
                    emit interactionDone(true, QStringLiteral("Quitado de la lista"));
                    return;
                }
            });

    // "Liked" (library): a one-off query to the LM playlist to
    // know the real state of every track, with its own QProcess.
    m_likedProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_likedProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_likedProc.readAllStandardOutput();
                if (code != 0) {
                    qWarning() << "[catalog] no se pudo cargar \"me gusta\"";
                    return;   // no session/network: the rows use the embedded likeStatus
                }
                const QJsonDocument doc = QJsonDocument::fromJson(out);
                const QJsonArray entries =
                    doc.object().value(QStringLiteral("entries")).toArray();
                QSet<QString> ids;
                QVariantList lmTracks;
                for (const QJsonValue &v : entries) {
                    const QJsonObject o = v.toObject();
                    const QString id = o.value(QStringLiteral("id")).toString();
                    if (!id.isEmpty())
                        ids.insert(id);
                    lmTracks.append(normalize(o.toVariantMap()));
                }
                m_likedIds = ids;
                // The same answer brings the metadata of the tracks, so the
                // home can seed its recommended radios with the artists the
                // user actually likes.
                m_likedTracks = lmTracks;
                m_likedReady = true;
                m_likedTs = QDateTime::currentSecsSinceEpoch();
                saveLikedToDisk();
                ++m_likedRevision;
                // The same answer brings the content of the "Liked" list
                // (LM): it is left in the cache so that pressing "Liked"
                // shows it at once and without going back to the network. If
                // the LM list is open right now, it is refreshed on screen
                // (so an unlike done elsewhere removes the row without
                // reloading).
                if (!lmTracks.isEmpty()) {
                    cachePlaylist(QStringLiteral("list:LM"), lmTracks,
                                  QStringLiteral("Me gusta"));
                    rememberPlaylistForDisk(QStringLiteral("list:LM"));
                    if (m_openPlaylistId == QLatin1String("LM")) {
                        m_tracks = lmTracks;
                        emit changed();
                    }
                }
                qInfo() << "[catalog] me gusta:" << m_likedIds.size() << "pistas";
                emit likedChanged();
            });

    m_proc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_proc, &QProcess::finished, this,
            [this](int code, QProcess::ExitStatus) {
                // Process cancelled to give way to an explicit request
                // from the user: there is nothing to report.
                if (m_killed) {
                    m_killed = false;
                    return;
                }
                const QByteArray out = m_proc.readAllStandardOutput();
                if (code == 0 && handleOutput(out)) {
                    m_busy = false;
                    // Search across all the sources: what just arrived
                    // belongs to one source; it is stored in its group and
                    // it goes on with the next one.
                    if (m_multiActive && m_purpose == QLatin1String("search")) {
                        absorbMultiResults();
                        return;
                    }
                    emit changed();
                    return;   // success
                }

                // Fallback: if the fast path for playlists failed (internal
                // API not reachable, empty list...) it is retried with
                // yt-dlp.
                if (!m_fastFallback.isEmpty()) {
                    const QString target = m_fastFallback;
                    const QString title = m_fastFallbackTitle;
                    m_fastFallback.clear();
                    m_fastFallbackTitle.clear();
                    m_openPlaylistId.clear();
                    m_busy = false;
                    m_error.clear();
                    runYtdlp(target, m_purpose, title);
                    return;
                }

                // A failing source cannot sink the whole search: it moves
                // on to the next one.
                if (m_multiActive && m_purpose == QLatin1String("search")) {
                    m_busy = false;
                    m_error.clear();
                    nextMultiSource();
                    return;
                }

                if (code != 0) {
                    QString tail;
                    const QStringList lines =
                        QString::fromUtf8(m_proc.readAllStandardError())
                            .split(QLatin1Char('\n'), Qt::SkipEmptyParts);
                    for (int i = lines.size() - 1; i >= 0; --i) {
                        const QString l = lines.at(i).trimmed();
                        if (!l.isEmpty() && !l.startsWith(QLatin1Char('['))) {
                            tail = l;
                            break;
                        }
                    }
                    fail(tail.isEmpty()
                             ? QStringLiteral("%1 devolvió un error").arg(m_proc.program())
                             : tail);
                }
                m_busy = false;
                emit changed();
            });

    // If there is a stored session, bring "my lists" on startup.
    if (ytmLoggedIn()) {
        refreshYtmLibrary();
        refreshLikedSet();
    }
}

Catalog::~Catalog()
{
    // The session check the constructor starts must not be left loose: if
    // it is still running it is killed (like ~Player with mpv and its
    // resolvers) so no orphan processes or warnings are left on destroy.
    if (m_statusProc.state() != QProcess::NotRunning) {
        m_statusProc.kill();
        m_statusProc.waitForFinished(500);
    }
    // On exit, dump what is still pending: without this, a list loaded
    // just before closing would not persist (the dump is deferred).
    savePlaylistCache();
}

QString Catalog::stateFile()
{
    const QString dir = AppPaths::stateDir();
    QDir().mkpath(dir);
    return dir + QStringLiteral("/library.json");
}

// The ytm_login.py helper: installed next to the binary (CMake post-build) or
// found in the source tree via the ../tools fallback.
QString Catalog::helperPath()
{
    const QString beside =
        QCoreApplication::applicationDirPath() + QStringLiteral("/ytm_login.py");
    if (QFile::exists(beside))
        return beside;
    const QString tools =
        QCoreApplication::applicationDirPath() + QStringLiteral("/../tools/ytm_login.py");
    if (QFile::exists(tools))
        return tools;
    return beside;
}

// Netscape cookies.txt written by the embedded WebKit login window.
QString Catalog::cookieFile()
{
    return AppPaths::cookiesFile();
}

// The "my lists" helper: next to the binary (post-build) or in the source
// tree through the ../tools fallback.
QString Catalog::ytmApiPath()
{
    const QString beside =
        QCoreApplication::applicationDirPath() + QStringLiteral("/ytm_api.py");
    if (QFile::exists(beside))
        return beside;
    const QString tools =
        QCoreApplication::applicationDirPath() + QStringLiteral("/../tools/ytm_api.py");
    if (QFile::exists(tools))
        return tools;
    return beside;
}

// Purposes that run in the background: they are best-effort, they must not
// block anybody nor report an error if something steps on them. There are
// two: the autoplay radio (it asks for more tracks) and the prefetch of
// the home radios (it asks for few, to be ready in ~1.4 s).
static bool isBackgroundPurpose(const QString &purpose)
{
    return purpose == QLatin1String("radio")
        || purpose == QLatin1String("prefetch");
}

// ---------------------------------------------------------------- fetch ----

bool Catalog::cancelBackgroundFetch()
{
    if (!m_busy || !isBackgroundPurpose(m_purpose))
        return false;
    if (m_proc.state() != QProcess::NotRunning) {
        // The mark makes the later finished() be ignored silently (it would
        // otherwise report a failure that nobody cares about).
        m_killed = true;
        m_proc.kill();
        m_proc.waitForFinished(300);
    }
    m_busy = false;
    return true;
}

void Catalog::startFetch(const QString &program, const QStringList &args,
                         const QString &purpose, const QString &title)
{
    // A background query (the autoplay radio or the home radio prefetch) is
    // always best-effort: an explicit user request steps on it without
    // more. Any other operation in flight keeps waiting as before.
    if (m_busy && !cancelBackgroundFetch()) {
        fail(QStringLiteral("Espera a que termine la operación actual"));
        return;
    }

    m_busy = true;
    m_error.clear();
    m_purpose = purpose;
    m_pendingTitle = title;
    m_currentSource = m_sources->activeId();
    emit changed();

    m_proc.setProgram(program);
    m_proc.setArguments(args);
    m_proc.start();
    if (!m_proc.waitForStarted(3000)) {
        fail(QStringLiteral("No se pudo ejecutar %1").arg(program));
        m_busy = false;
        emit changed();
    }
}

// A YouTube Music radio is not a normal list: the "RDAMVM<videoId>"
// identifier is only understood by yt-dlp (the internal API returns empty
// and triggers the fallback, which is what made it take ~20 s) and the
// track cap is the only thing that decides how long it takes (see
// runYtdlp()).
static bool isRadioTarget(const QString &target)
{
    return target.contains(QLatin1String("list=RDAMVM"))
        || target.contains(QLatin1String("start_radio=1"));
}

void Catalog::run(const QString &target, const QString &purpose, const QString &title)
{
    if (target.isEmpty())
        return;

    // It remembers the real URL of the open list (to download it).
    if (purpose == QLatin1String("playlist"))
        m_openListUrl = target;

    // List cache: reopening an already loaded one does not start any
    // process and answers instantly. Memory is looked at first and, if
    // that fails, the file on disk (playlists.json), so it is instant
    // after a restart too. Only for lists; the search always goes to the
    // network. A background prefetch in flight must not stop it (it is
    // exactly what makes opening a "For you" radio instant): it is
    // cancelled and the cached one is served.
    const QString key = cacheKeyFor(target);
    const bool bgBusy = m_busy && isBackgroundPurpose(m_purpose);
    if (purpose == QLatin1String("playlist") && (!m_busy || bgBusy)) {
        QVariantList cached;
        QString cachedTitle;
        bool hit = m_playlistCache.contains(key);
        if (hit) {
            cached = m_playlistCache.value(key);
            cachedTitle = m_playlistTitles.value(key);
        } else {
            // Not in memory: it may still be in the on-disk cache from a
            // previous session. If so it is served just as fast (no network)
            // and promoted to memory for the next times.
            hit = cachedPlaylistFromDisk(key, &cached, &cachedTitle);
            if (hit)
                cachePlaylist(key, cached, cachedTitle);
        }
        if (hit) {
            if (bgBusy)
                cancelBackgroundFetch();
            m_fastFallback.clear();
            m_fastFallbackTitle.clear();
            m_openPlaylistId.clear();
            if (target.contains(QLatin1String("youtube.com"))
                && key.startsWith(QLatin1String("list:"))
                && !isRadioTarget(target))
                m_openPlaylistId = key.mid(QStringLiteral("list:").size());
            m_error.clear();
            // Deferred: it does not re-enter QML from inside the call itself.
            QTimer::singleShot(0, this, [this, cached, cachedTitle]() {
                m_tracks = cached;
                m_tracksTitle = cachedTitle;
                m_busy = false;   // serving as a cache never leaves the UI blocked
                emit tracksReady(cached, cachedTitle);
                emit changed();
            });
            return;
        }
    }

    // This same list is already being fetched in the background (a radio
    // prefetch on mouse over). The process is not started again: the one
    // in flight is waited for and its result is served as the open list.
    if (m_busy && m_pendingKey == key) {
        if (purpose == QLatin1String("playlist"))
            m_promotePending = true;   // it is only set, never cleared
        return;
    }

    m_pendingKey = key;
    m_promotePending = false;

    m_fastFallback.clear();
    m_fastFallbackTitle.clear();
    m_openPlaylistId.clear();

    // Fast path for lists: for YouTube Music playlists the internal API
    // returns all the tracks in ~0.5 s (without starting yt-dlp, which
    // takes several seconds). It is used when there is a session;
    // without one it falls back to yt-dlp. The radios (RDAMVM/start_radio)
    // skip this shortcut: ytm_api.py does not know them and its empty
    // answer only served to delay the fallback.
    if (purpose == QLatin1String("playlist") && ytmLoggedIn()
        && !isRadioTarget(target)) {
        const QRegularExpression re(
            QStringLiteral("list=([A-Za-z0-9_-]+)"));
        const QRegularExpressionMatch m = re.match(target);
        if (target.contains(QLatin1String("youtube.com")) && m.hasMatch()) {
            // The target is stored in case the fast path fails (playlist not
            // reachable through the internal API): it is retried with
            // yt-dlp.
            m_fastFallback = target;
            m_fastFallbackTitle = title;
            m_openPlaylistId = m.captured(1);
            startFetch(AppPaths::pythonProgram(),
                       {ytmApiPath(), QStringLiteral("playlist"),
                        m.captured(1)},
                       purpose, title);
            return;
        }
    }

    runYtdlp(target, purpose, title);
}

void Catalog::runYtdlp(const QString &target, const QString &purpose,
                       const QString &title)
{
    // A radio does not need 500 tracks: the YouTube API brings them page
    // by page, so the cap decides the timeout. The radio opened as a list
    // (the "For you" ones) blocks the view, so it is asked short:
    // 25 tracks ~1.4 s and ~2 h of music. The autoplay one arrives in the
    // background without interrupting, so it is asked longer.
    const int radioEnd = purpose == QLatin1String("radio") ? 80 : 25;
    QStringList args{
        QStringLiteral("-J"),
        QStringLiteral("--no-warnings"),
        QStringLiteral("--ignore-errors"),
        QStringLiteral("--no-plugin-dirs"),
        (purpose == QLatin1String("radio") || isRadioTarget(target))
            ? QStringLiteral("--playlist-end=%1").arg(radioEnd)
            : QStringLiteral("--playlist-end=500"),
    };
    // Flat SoundCloud set entries are bare url_transparent stubs without
    // title/uploader/duration (yt-dlp SoundcloudSetIE._extract_set passes only
    // id + url + album), which normalize() cannot display: extract playlists
    // hosted on soundcloud.com fully (≈0.5 s/track). Searches (scsearchN:…)
    // and every other target stay flat for speed.
    const bool soundcloudPlaylist =
        purpose == QLatin1String("playlist")
        && target.contains(QLatin1String("soundcloud.com/"));
    if (!soundcloudPlaylist)
        args << QStringLiteral("--flat-playlist");
    // YouTube Music session: use the cookies of the integrated login for the
    // YouTube targets (search, playlists, Liked Music). The other sources
    // go without cookies.
    if (ytmLoggedIn()
        && (target.contains(QLatin1String("youtube.com"))
            || target.startsWith(QLatin1String("ytsearch")))) {
        args << QStringLiteral("--cookies") << cookieFile();
    }
    args << target;

    startFetch(QStringLiteral("yt-dlp"), args, purpose, title);
}

void Catalog::search(const QString &query)
{
    const QString q = query.trimmed();
    if (q.isEmpty())
        return;
    const QString source = m_sources->activeId();
    if (!m_sources->isReady(source)) {
        fail(QStringLiteral("La fuente activa no admite búsqueda todavía"));
        return;
    }
    m_resultsQuery = q;
    searchInSource(source, q);
}

// Search in a concrete source. The fast path (YouTube Music's internal
// API) only applies to YouTube Music with a signed in session; the rest goes
// through yt-dlp with the source's prefix (ytsearch15:, scsearch15:...).
void Catalog::searchInSource(const QString &source, const QString &query)
{
    // Fast path: YouTube Music's internal API finds in ~0.6 s what yt-dlp
    // takes ~2.4 s (it starts the full extraction on every search). Only
    // with a session and on YouTube Music; if the API fails or returns
    // nothing, the fallback (m_fastFallback) retries with yt-dlp
    // automatically.
    if (source == QLatin1String("ytm") && ytmLoggedIn()) {
        m_fastFallback = m_sources->searchPrefix(source) + query;
        m_fastFallbackTitle = query;
        startFetch(AppPaths::pythonProgram(),
                   {ytmApiPath(), QStringLiteral("search"), query},
                   QStringLiteral("search"), query);
        return;
    }
    run(m_sources->searchPrefix(source) + query, QStringLiteral("search"), query);
}

// ---- search across all the sources ---------------------------------------
// One source is queried after the other (each search is a process) and the
// groups fill up: the interface sees each source's results as they
// arrive, without waiting for the last one.
void Catalog::searchAll(const QString &query)
{
    const QString q = query.trimmed();
    if (q.isEmpty())
        return;

    // If the catalogue is busy the request is rejected: the multi state
    // must not be left switched on (the next search would end up in the
    // wrong group).
    if (m_busy) {
        fail(QStringLiteral("Espera a que termine la operación actual"));
        m_multiActive = false;
        return;
    }

    m_multiQuery = q;
    m_multiActive = true;
    m_multiCurrent.clear();
    m_multiQueue.clear();
    m_resultsBySource.clear();
    m_resultsQuery = q;

    // All the sources of the registry, in their order (YouTube Music first).
    const QVariantList all = m_sources->list();
    for (const QVariant &v : all) {
        const QString id = v.toMap().value(QStringLiteral("id")).toString();
        if (!id.isEmpty())
            m_multiQueue << id;
    }
    emit changed();
    nextMultiSource();
}

void Catalog::nextMultiSource()
{
    if (!m_multiActive)
        return;
    if (m_multiQueue.isEmpty()) {
        m_multiActive = false;
        m_multiCurrent.clear();
        emit changed();
        return;
    }

    const QString id = m_multiQueue.takeFirst();
    m_multiCurrent = id;
    const QVariantMap src = m_sources->entry(id);
    const bool ready = m_sources->isReady(id);

    // The group is created right away (empty) so the interface can show the
    // source's section even if it returns nothing.
    QVariantMap group;
    group.insert(QStringLiteral("id"), id);
    group.insert(QStringLiteral("name"), src.value(QStringLiteral("name")).toString());
    group.insert(QStringLiteral("items"), QVariantList{});
    group.insert(QStringLiteral("locked"), !ready);
    m_resultsBySource.append(group);

    if (!ready) {
        // Locked (it lacks the credentials): there is nothing to query.
        nextMultiSource();
        return;
    }
    searchInSource(id, m_multiQuery);
}

// The results of the source that just finished are stored in its group
// and it moves on to the next one.
void Catalog::absorbMultiResults()
{
    if (m_multiCurrent.isEmpty())
        return;
    const QVariantList items = m_results;
    for (int i = 0; i < m_resultsBySource.size(); ++i) {
        QVariantMap g = m_resultsBySource.at(i).toMap();
        if (g.value(QStringLiteral("id")).toString() != m_multiCurrent)
            continue;
        g.insert(QStringLiteral("items"), items);
        m_resultsBySource[i] = g;
        break;
    }
    nextMultiSource();
}

void Catalog::openPlaylist(int savedIndex)
{
    if (savedIndex < 0 || savedIndex >= m_playlists.size())
        return;
    const QVariantMap pl = m_playlists.at(savedIndex).toMap();
    run(pl.value(QStringLiteral("url")).toString(), QStringLiteral("playlist"),
        pl.value(QStringLiteral("name")).toString());
}

void Catalog::openUrl(const QString &url, const QString &name)
{
    const QString u = url.trimmed();
    if (u.isEmpty()) {
        fail(QStringLiteral("Pega la URL de una playlist"));
        return;
    }
    run(u, QStringLiteral("playlist"), name.trimmed());
}

// YouTube Music radio/autoplay: the list the app itself plays "next"
// after a video is the RDAMVM<videoId> mix. yt-dlp resolves it as a flat
// playlist (the seed first and then the self radio). It uses a background
// purpose on purpose (not "playlist") so run() skips the internal API
// fast path (ytm_api.py returns empty for RDAMVM...) and ends in
// runYtdlp(), which already attaches the YouTube Music cookies.
//
// There are two variants, and the difference is the track cap, which is
// the only thing that decides the timeout (YouTube delivers the list page
// by page):
//   . fetchRadio()    - the autoplay one: it asks for 80 (~5 h) because it
//                     goes without interrupting anybody.
//   . prefetchRadio() - the prefetch of the home radios: it asks for 25
//                     (~1.4 s), just what whoever opens the radio by hand
//                     will see. Storing it in the list cache as well
//                     makes opening it next instant.
void Catalog::fetchRadio(const QString &videoId, const QString &title)
{
    runRadio(videoId, title, QStringLiteral("radio"));
}

void Catalog::prefetchRadio(const QString &videoId, const QString &title)
{
    runRadio(videoId, title, QStringLiteral("prefetch"));
}

void Catalog::runRadio(const QString &videoId, const QString &title,
                       const QString &purpose)
{
    const QString v = videoId.trimmed();
    if (v.isEmpty())
        return;
    // Best-effort: the radio is an extra (it must not interrupt nor report an
    // error if there is another query in progress). It is retried on the next track.
    if (m_busy)
        return;
    m_radioSeed = v;
    const QString target =
        QStringLiteral("https://www.youtube.com/watch?v=") + v
        + QStringLiteral("&list=RDAMVM") + v;
    run(target, purpose,
        title.trimmed().isEmpty() ? QStringLiteral("Radio") : title.trimmed());
}

// ---- Artists -------------------------------------------------------------
// The three launches run in m_artistProc (one request at a time); the output
// is read in the finished() connected in the constructor.

void Catalog::runArtist(const QStringList &args, const QString &mode,
                        const QString &arg)
{
    if (m_artistProc.state() != QProcess::NotRunning) {
        // The new request wins: the previous one is cancelled and its
        // answer is ignored (m_artistMode is emptied before the kill).
        m_artistMode.clear();
        m_artistArg.clear();
        m_artistProc.kill();
        m_artistProc.waitForFinished(250);
    }
    m_artistMode = mode;
    m_artistArg = arg;
    // normalize() tags the tracks with the active source.
    m_currentSource = m_sources->activeId();
    m_artistProc.setProgram(AppPaths::pythonProgram());
    m_artistProc.setArguments(args);
    m_artistProc.start();
}

void Catalog::searchArtists(const QString &query)
{
    const QString q = query.trimmed();
    if (q.isEmpty()) {
        emit artistsReady({});
        return;
    }
    runArtist({ytmApiPath(), QStringLiteral("artists"), q},
              QStringLiteral("artists"), q);
}

void Catalog::fetchArtist(const QString &browseId)
{
    const QString id = browseId.trimmed();
    if (id.isEmpty()) {
        emit artistReady(id, {});
        return;
    }
    runArtist({ytmApiPath(), QStringLiteral("artist"), id},
              QStringLiteral("artist"), id);
}

void Catalog::fetchAlbumTracks(const QString &browseId)
{
    const QString id = browseId.trimmed();
    if (id.isEmpty()) {
        emit albumTracksReady(id, {});
        return;
    }
    runArtist({ytmApiPath(), QStringLiteral("album"), id},
              QStringLiteral("album"), id);
}

// The artist's main track (the most played one): it is the best seed for
// their radio without going through "Radio of the song". If the artist
// process is busy it gives up at once (the menu falls back to the radio of
// the pressed track).
void Catalog::resolveArtistRadio(const QString &artistName)
{
    const QString name = artistName.trimmed();
    if (name.isEmpty() || m_artistProc.state() != QProcess::NotRunning) {
        emit artistTopTrackResolved(name, {});
        return;
    }
    m_topTrack = {};
    runArtist({ytmApiPath(), QStringLiteral("toptrack"), name},
              QStringLiteral("toptrack"), name);
}

// Alternative video for a track whose original video died. It is looked up
// in YouTube Music dropping the failed id; the YTM search only returns
// playable videos, so the best candidate serves to replace it. The
// argument travels with fields separated by TAB (title with spaces
// included).
void Catalog::resolveAlternate(const QString &artist, const QString &title,
                               const QString &failedVideoId, double duration)
{
    const QString a = artist.trimmed();
    const QString t = title.trimmed();
    if (t.isEmpty()) {
        emit alternateResolved(failedVideoId, {});
        return;
    }
    // A half done replacement: it is ignored (the failed track is skipped anyway).
    if (m_altProc.state() != QProcess::NotRunning)
        return;
    m_altKey = failedVideoId;
    QString spec = a + QLatin1Char('\t') + t;
    if (!failedVideoId.isEmpty())
        spec += QLatin1Char('\t') + failedVideoId;
    QStringList args;
    args << ytmApiPath() << QStringLiteral("alternate") << spec;
    if (duration > 0.0)
        args << QString::number(duration);
    m_altProc.setProgram(AppPaths::pythonProgram());
    m_altProc.setArguments(args);
    m_altProc.start();
}

void Catalog::syncLiked()
{
    if (m_sources->activeId() != QLatin1String("ytm")) {
        fail(QStringLiteral("El sync de «Me gusta» es de YouTube Music"));
        return;
    }
    if (!ytmLoggedIn()) {
        fail(QStringLiteral("Inicia sesión en Ajustes para sincronizar «Me gusta»"));
        return;
    }
    // Manual button: it forces the network fetch of the "liked" set (it
    // ignores the TTL and the on-disk cache) so the heart reflects the
    // real state.
    launchLikedFetch();
    // And it reloads the "Liked Music" list in the queue, skipping the
    // memory cache to bring the fresh content.
    const QString lm =
        QStringLiteral("https://music.youtube.com/playlist?list=LM");
    forgetCachedPlaylist(cacheKeyFor(lm));
    run(lm, QStringLiteral("playlist"), QStringLiteral("Liked Music"));
}

// ------------------------------------------------------------ "my lists" ----

void Catalog::refreshYtmLibrary()
{
    if (!ytmLoggedIn())
        return;
    if (m_libraryProc.state() != QProcess::NotRunning)
        return;  // there is already a query in progress
    if (!QFile::exists(ytmApiPath()))
        return;

    m_libraryBusy = true;
    emit libraryChanged();
    m_libraryProc.setProgram(AppPaths::pythonProgram());
    m_libraryProc.setArguments({ytmApiPath(), QStringLiteral("library")});
    m_libraryProc.start();
}

// --------------------------------------------------- YouTube Music interaction ----

void Catalog::runYtmAction(const QStringList &args, const QString &okMessage)
{
    if (!ytmLoggedIn()) {
        emit interactionDone(false,
                             QStringLiteral("Inicia sesión en Ajustes para "
                                            "interactuar con YouTube Music"));
        return;
    }
    if (m_ytmProc.state() != QProcess::NotRunning) {
        emit interactionDone(false, QStringLiteral("Hay una acción en curso"));
        return;
    }
    if (!QFile::exists(ytmApiPath())) {
        emit interactionDone(false,
                             QStringLiteral("No se encontró ytm_api.py"));
        return;
    }
    m_ytmOkMessage = okMessage;
    m_ytmProc.setProgram(AppPaths::pythonProgram());
    m_ytmProc.setArguments(args);
    m_ytmProc.start();
}

void Catalog::rateTrack(const QString &videoId, const QString &rating)
{
    const QString v = videoId.trimmed();
    if (v.isEmpty()) {
        emit interactionDone(false, QStringLiteral("Pista sin vídeo de YouTube"));
        return;
    }
    const QString r = rating.trimmed().toUpper();
    QString msg;
    if (r == QLatin1String("LIKE"))
        msg = QStringLiteral("Me gusta añadido");
    else if (r == QLatin1String("DISLIKE"))
        msg = QStringLiteral("No me gusta registrado");
    else
        msg = QStringLiteral("Valoración quitada");
    runYtmAction({ytmApiPath(), QStringLiteral("rate"), v, r}, msg);
}

void Catalog::addToPlaylist(const QString &playlistId, const QString &videoId)
{
    const QString p = playlistId.trimmed();
    const QString v = videoId.trimmed();
    if (p.isEmpty() || v.isEmpty()) {
        emit interactionDone(false, QStringLiteral("Faltan datos de la lista"));
        return;
    }
    runYtmAction({ytmApiPath(), QStringLiteral("addpl"), p, v},
                 QStringLiteral("Añadido a la lista"));
}

void Catalog::removeFromPlaylist(const QString &playlistId, const QString &videoId,
                                 const QString &setVideoId)
{
    const QString p = playlistId.trimmed();
    const QString v = videoId.trimmed();
    const QString s = setVideoId.trimmed();
    if (p.isEmpty() || v.isEmpty() || s.isEmpty()) {
        emit interactionDone(false, QStringLiteral("Faltan datos de la lista"));
        return;
    }
    runYtmAction({ytmApiPath(), QStringLiteral("rmpl"), p, v, s},
                 QStringLiteral("Quitado de la lista"));
}

// Reorders the track `setVideoId` of the open list `delta` positions (±1).
// The row moves at once locally and the change is uploaded to YouTube Music.
void Catalog::moveOpenPlaylistTrack(const QString &setVideoId, int delta)
{
    const QString sid = setVideoId.trimmed();
    if (m_openPlaylistId.isEmpty() || sid.isEmpty() || delta == 0)
        return;
    if (!ytmLoggedIn() || m_plProc.state() != QProcess::NotRunning) {
        emit interactionDone(false,
                             QStringLiteral("No se puede reordenar ahora mismo"));
        return;
    }
    int i = -1;
    for (int k = 0; k < m_tracks.size(); k++) {
        if (m_tracks.at(k).toMap().value(QStringLiteral("setId")).toString() == sid) {
            i = k;
            break;
        }
    }
    if (i < 0)
        return;
    const int j = i + delta;
    if (j < 0 || j >= m_tracks.size())
        return;   // it is already at one end
    // Neighbour and direction BEFORE mutating the local list.
    const QString neighbor =
        m_tracks.at(j).toMap().value(QStringLiteral("setId")).toString();
    if (neighbor.isEmpty())
        return;
    const bool before = delta < 0;   // up -> before the neighbour above
    const QString plId = m_openPlaylistId;
    m_tracks.move(i, j);
    forgetCachedPlaylist(QStringLiteral("list:") + plId);
    emit changed();
    runPlaylistAction({ytmApiPath(), QStringLiteral("movepl"), plId, sid,
                       neighbor, before ? QStringLiteral("before")
                                        : QStringLiteral("after")},
                      QStringLiteral("move"));
}

// Removes from the open list the track with that setVideoId. It waits for
// YouTube to confirm before deleting the row (so it does not end up
// misaligned if it fails).
void Catalog::removeOpenPlaylistTrack(const QString &videoId,
                                      const QString &setVideoId)
{
    const QString vid = videoId.trimmed();
    const QString sid = setVideoId.trimmed();
    if (m_openPlaylistId.isEmpty() || vid.isEmpty() || sid.isEmpty()) {
        emit interactionDone(false,
                             QStringLiteral("Esta pista no se puede quitar"));
        return;
    }
    m_plSetId = sid;
    runPlaylistAction({ytmApiPath(), QStringLiteral("rmpl"), m_openPlaylistId,
                       vid, sid},
                      QStringLiteral("remove"));
}

// --------------------------------------------------- list management ----

void Catalog::runPlaylistAction(const QStringList &args, const QString &mode)
{
    if (!ytmLoggedIn()) {
        emit interactionDone(false,
                             QStringLiteral("Inicia sesión en Ajustes para "
                                            "gestionar tus listas"));
        return;
    }
    if (m_plProc.state() != QProcess::NotRunning) {
        emit interactionDone(false, QStringLiteral("Hay una operación de lista en curso"));
        return;
    }
    if (!QFile::exists(ytmApiPath())) {
        emit interactionDone(false, QStringLiteral("No se encontró ytm_api.py"));
        return;
    }
    m_plMode = mode;
    m_plProc.setProgram(AppPaths::pythonProgram());
    m_plProc.setArguments(args);
    m_plProc.start();
}

void Catalog::createPlaylist(const QString &title, bool isPrivate,
                             const QString &addVideoId)
{
    const QString t = title.trimmed();
    if (t.isEmpty()) {
        emit interactionDone(false, QStringLiteral("La lista necesita un nombre"));
        return;
    }
    m_plAddVideo = addVideoId.trimmed();
    runPlaylistAction({ytmApiPath(), QStringLiteral("createpl"), t,
                       isPrivate ? QStringLiteral("1") : QStringLiteral("0")},
                      QStringLiteral("create"));
}

void Catalog::updatePlaylist(const QString &id, const QString &title, bool isPrivate)
{
    const QString i = id.trimmed();
    const QString t = title.trimmed();
    if (i.isEmpty() || t.isEmpty()) {
        emit interactionDone(false, QStringLiteral("Faltan datos de la lista"));
        return;
    }
    runPlaylistAction({ytmApiPath(), QStringLiteral("renamepl"), i, t,
                       isPrivate ? QStringLiteral("1") : QStringLiteral("0")},
                      QStringLiteral("update"));
}

void Catalog::deletePlaylist(const QString &id)
{
    const QString i = id.trimmed();
    if (i.isEmpty()) {
        emit interactionDone(false, QStringLiteral("Falta la lista"));
        return;
    }
    runPlaylistAction({ytmApiPath(), QStringLiteral("deletepl"), i},
                      QStringLiteral("delete"));
}

void Catalog::fetchPlaylistInfo(const QString &id)
{
    const QString i = id.trimmed();
    if (i.isEmpty()) {
        emit playlistInfoReady({});
        return;
    }
    if (!ytmLoggedIn() || !QFile::exists(ytmApiPath())
        || m_plProc.state() != QProcess::NotRunning) {
        emit playlistInfoReady({});
        return;
    }
    runPlaylistAction({ytmApiPath(), QStringLiteral("playlistinfo"), i},
                      QStringLiteral("info"));
}

bool Catalog::isLiked(const QString &videoId) const
{
    const QString id = videoIdOf(videoId);
    return !id.isEmpty() && m_likedIds.contains(id);
}

QString Catalog::videoIdOf(const QString &urlOrId) const
{
    const QString s = urlOrId.trimmed();
    if (s.isEmpty())
        return {};

    // Downloaded local file: the sibling .info.json stores the real YouTube
    // videoId. That way the local tracks can be "liked" and synced with
    // YouTube Music just like the cloud ones. It is cached by path (I/O
    // only the first time).
    if (s.startsWith(QLatin1String("file://"))) {
        const QString path = QUrl(s).toLocalFile();
        const auto cached = m_localIdCache.constFind(path);
        if (cached != m_localIdCache.constEnd())
            return cached.value();
        QString id;
        const QFileInfo fi(path);
        const QStringList candidates{
            path + QStringLiteral(".info.json"),
            fi.absolutePath() + QLatin1Char('/') + fi.completeBaseName()
                + QStringLiteral(".info.json"),
        };
        for (const QString &info : candidates) {
            QFile f(info);
            if (!f.open(QIODevice::ReadOnly))
                continue;
            const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
            const QString wid = o.value(QStringLiteral("id")).toString().trimmed();
            if (!wid.isEmpty()) {
                id = wid;
                break;
            }
        }
        m_localIdCache.insert(path, id);
        return id;
    }

    int i = s.indexOf(QLatin1String("watch?v="));
    if (i >= 0) {
        QString id = s.mid(i + 8);
        const int amp = id.indexOf(QLatin1Char('&'));
        return amp >= 0 ? id.left(amp) : id;
    }
    i = s.indexOf(QLatin1String("youtu.be/"));
    if (i >= 0) {
        QString id = s.mid(i + 9);
        const int q = id.indexOf(QLatin1Char('?'));
        return q >= 0 ? id.left(q) : id;
    }
    i = s.indexOf(QLatin1String("/shorts/"));
    if (i >= 0) {
        QString id = s.mid(i + 8);
        const int q = id.indexOf(QLatin1Char('?'));
        return q >= 0 ? id.left(q) : id;
    }
    // Is it already a raw YouTube videoId? (11 characters, no separators).
    if (s.size() == 11 && !s.contains(QLatin1Char('/'))
        && !s.contains(QLatin1Char('.')) && !s.contains(QLatin1Char(' ')))
        return s;
    return {};
}

void Catalog::setLiked(const QString &videoId, bool liked)
{
    // The id is normalised as in isLiked(): with an URL (or a local
    // file) the heart would never be marked.
    const QString id = videoIdOf(videoId);
    if (id.isEmpty())
        return;
    const bool had = m_likedIds.contains(id);
    if (liked && !had)
        m_likedIds.insert(id);
    else if (!liked && had)
        m_likedIds.remove(id);
    // The revision goes up even if nothing changed: the vote has already
    // been sent and the rows/heart must repaint with the locally decided
    // state.
    ++m_likedRevision;
    // The "Liked" list (LM) has gone stale anyway: its cache is dropped
    // (memory and disk) so the next open brings the fresh content from
    // YouTube Music.
    forgetCachedPlaylist(QStringLiteral("list:LM"));
    // And if the LM list is open right now: removing the heart makes the
    // row disappear at once (in YouTube that track is no longer in
    // "Liked"). Only in the "Liked" view: in other open lists the
    // unlike does not touch rows.
    if (!liked && m_openPlaylistId == QLatin1String("LM")) {
        bool removed = false;
        for (int k = 0; k < m_tracks.size(); k++) {
            if (videoIdOf(m_tracks.at(k).toMap()
                              .value(QStringLiteral("url")).toString())
                == videoId) {
                m_tracks.removeAt(k);
                removed = true;
                break;
            }
        }
        if (removed)
            emit changed();
    }
    // Persist the local set (keeping m_likedTs) so the startup paints the
    // heart at once and does not lose the vote that was just made.
    saveLikedToDisk();
    emit likedChanged();
}

void Catalog::toggleLiked(const QString &videoIdOrUrl, bool currentlyLiked)
{
    const QString id = videoIdOf(videoIdOrUrl);
    if (id.isEmpty()) {
        emit interactionDone(false,
                             QStringLiteral("La pista no es de YouTube"));
        return;
    }
    const bool next = !currentlyLiked;
    setLiked(id, next);
    rateTrack(id, next ? QStringLiteral("LIKE") : QStringLiteral("INDIFFERENT"));
}

void Catalog::refreshLikedSet()
{
    if (!ytmLoggedIn())
        return;

    // 1) Immediate load from disk (no network): the set is ready at once
    //    and the rows paint the heart without waiting for the fetch.
    if (loadLikedFromDisk()) {
        m_likedReady = true;
        ++m_likedRevision;
        emit likedChanged();
    }

    // 2) Automatic sync: the network query is always fired when there is
    //    a session (startup and login), not only when the cache expires.
    //    That way the "liked" you gave - or took away - somewhere else
    //    shows up on its own without pressing anything. It is asynchronous
    //    and cheap (one page of the internal API).
    launchLikedFetch();
}

// Starts the network fetch of the "liked" set (m_likedProc). It does not
// look at the TTL nor the cache: the lazy refresh (already filtered) and
// syncLiked() call it.
void Catalog::launchLikedFetch()
{
    if (!ytmLoggedIn() || m_likedProc.state() != QProcess::NotRunning)
        return;
    if (!QFile::exists(ytmApiPath()))
        return;
    m_likedProc.setProgram(AppPaths::pythonProgram());
    m_likedProc.setArguments({ytmApiPath(), QStringLiteral("playlist"),
                              QStringLiteral("LM")});
    m_likedProc.start();
}

// ------------------------------------------------- "liked" cache ----

// JSON file next to the library state (library.json).
QString Catalog::likedFile()
{
    const QString dir = AppPaths::stateDir();
    QDir().mkpath(dir);
    return dir + QStringLiteral("/liked.json");
}

// Loads the set from disk; it leaves m_likedTs with its timestamp.
bool Catalog::loadLikedFromDisk()
{
    QFile f(likedFile());
    if (!f.open(QIODevice::ReadOnly))
        return false;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    const QJsonArray ids = o.value(QStringLiteral("ids")).toArray();
    QSet<QString> set;
    for (const QJsonValue &v : ids) {
        const QString id = v.toString();
        if (!id.isEmpty())
            set.insert(id);
    }
    if (set.isEmpty())
        return false;
    m_likedIds = set;
    // The metadata is not stored on disk: until the next sync the home
    // falls back to the recently played tracks for its recommendations.
    m_likedTracks.clear();
    m_likedTs = qint64(o.value(QStringLiteral("ts")).toDouble());
    return true;
}

void Catalog::saveLikedToDisk() const
{
    QJsonArray ids;
    for (const QString &id : m_likedIds)
        ids.append(id);
    const QJsonObject o{
        {QStringLiteral("ts"), QJsonValue(double(m_likedTs))},
        {QStringLiteral("ids"), ids},
    };
    QFile f(likedFile());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

// ------------------------------------------- list cache (memory) ----

// Normalises YouTube's `list=<id>`: the same list opened by URL, by id
// or from "my lists" shares a cache entry. The other targets
// (ytsearch..., SoundCloud, etc.) use the URL as it is.
QString Catalog::cacheKeyFor(const QString &target)
{
    static const QRegularExpression re(QStringLiteral("list=([A-Za-z0-9_-]+)"));
    const QRegularExpressionMatch m = re.match(target);
    if (m.hasMatch())
        return QStringLiteral("list:") + m.captured(1);
    return target;
}

void Catalog::cachePlaylist(const QString &key, const QVariantList &tracks,
                            const QString &title)
{
    if (key.isEmpty())
        return;
    if (!m_playlistCache.contains(key)) {
        m_cacheOrder.append(key);
        // RAM limit: evict the oldest ones above 24 entries.
        while (m_cacheOrder.size() > 24) {
            const QString old = m_cacheOrder.takeFirst();
            m_playlistCache.remove(old);
            m_playlistTitles.remove(old);
            m_playlistCacheAt.remove(old);
        }
    }
    m_playlistCache.insert(key, tracks);
    m_playlistTitles.insert(key, title);
}

void Catalog::forgetCachedPlaylist(const QString &key)
{
    m_playlistCache.remove(key);
    m_playlistTitles.remove(key);
    m_cacheOrder.removeAll(key);
    m_playlistCacheAt.remove(key);
    // The on-disk copy is dropped too: otherwise the next open would serve
    // it stale (e.g. after removing or reordering a track, or when forcing
    // the refresh of "Liked Music").
    m_cacheForgotten.insert(key);
    m_cacheDirty = true;
    m_cacheSaveTimer.start();
}

// Forgets the cached lists (memory and disk): the next open reloads them.
// It is used on sign out and to "refresh" the library.
void Catalog::invalidatePlaylistCache()
{
    m_playlistCache.clear();
    m_playlistTitles.clear();
    m_cacheOrder.clear();
    m_playlistCacheAt.clear();
    m_cacheForgotten.clear();
    // The file is forgotten too: without this, reopening an "invalidated"
    // list would be served from disk.
    QFile::remove(playlistsFile());
    m_cacheDirty = false;
}

// ------------------------------------------------- on-disk cache ----

// On-disk cache of the lists already loaded (it survives restarts). It
// lives in the user's cache, like the player's streams.json.
QString Catalog::playlistsFile()
{
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
           + QStringLiteral("/playlists.json");
}

// Reads the file on startup and seeds the in-memory cache with the most
// recent entries (respecting the RAM cap of cachePlaylist). It does not
// mark it dirty: what was read does not need to be written again. A
// corrupt or unreadable file is simply ignored.
void Catalog::loadPlaylistCache()
{
    QFile f(playlistsFile());
    if (!f.open(QIODevice::ReadOnly))
        return;
    QJsonParseError perr;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll(), &perr).object();
    f.close();
    if (perr.error != QJsonParseError::NoError || o.isEmpty())
        return;

    // Chronological ascending order: when seeded with cachePlaylist() (FIFO of
    // 24) the most recent ones stay in memory, just as if they had been
    // opened.
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    QList<QPair<qint64, QString>> order;
    order.reserve(o.size());
    for (auto it = o.constBegin(); it != o.constEnd(); ++it)
        order.append({qint64(it.value().toObject()
                                 .value(QStringLiteral("t")).toDouble()),
                      it.key()});
    std::sort(order.begin(), order.end(),
              [](const QPair<qint64, QString> &a,
                 const QPair<qint64, QString> &b) {
                  return a.first < b.first;
              });
    for (const auto &p : order) {
        const qint64 ts = p.first;
        if (ts <= 0 || now - ts > kPlaylistTtlSecs)
            continue;   // expired: it is not seeded (it will be pruned on save)
        const QJsonObject e = o.value(p.second).toObject();
        const QJsonArray arr = e.value(QStringLiteral("l")).toArray();
        if (arr.isEmpty())
            continue;
        QVariantList tracks;
        tracks.reserve(arr.size());
        for (const QJsonValue &v : arr)
            tracks.append(v.toObject().toVariantMap());
        cachePlaylist(p.second, tracks, e.value(QStringLiteral("n")).toString());
        m_playlistCacheAt.insert(p.second, ts);
    }
}

// Serves a list from the file (if it is still within the TTL) when it is
// not in memory. The fast path of run() uses it before firing any query.
bool Catalog::cachedPlaylistFromDisk(const QString &key, QVariantList *tracks,
                                     QString *title) const
{
    if (key.isEmpty() || m_cacheForgotten.contains(key))
        return false;
    QFile f(playlistsFile());
    if (!f.open(QIODevice::ReadOnly))
        return false;
    QJsonParseError perr;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll(), &perr).object();
    f.close();
    if (perr.error != QJsonParseError::NoError || o.isEmpty())
        return false;
    const QJsonObject e = o.value(key).toObject();
    if (e.isEmpty())
        return false;
    const qint64 ts = qint64(e.value(QStringLiteral("t")).toDouble());
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    if (ts <= 0 || now - ts > kPlaylistTtlSecs)
        return false;
    const QJsonArray arr = e.value(QStringLiteral("l")).toArray();
    if (arr.isEmpty())
        return false;
    QVariantList l;
    l.reserve(arr.size());
    for (const QJsonValue &v : arr)
        l.append(v.toObject().toVariantMap());
    if (tracks)
        *tracks = l;
    if (title)
        *title = e.value(QStringLiteral("n")).toString();
    return true;
}

// Marks a freshly loaded list with its timestamp and schedules the
// deferred dump (it does not write to disk on every load).
void Catalog::rememberPlaylistForDisk(const QString &key)
{
    if (key.isEmpty())
        return;
    m_cacheForgotten.remove(key);   // freshly loaded: there is nothing to forget any more
    m_playlistCacheAt.insert(key, QDateTime::currentSecsSinceEpoch());
    m_cacheDirty = true;
    m_cacheSaveTimer.start();
}

// Dumps the cache to disk. It starts from what was already in the file
// (old entries that did not fit in memory), merges it with the in-memory
// cache, prunes the expired ones and cuts to the 300 most recent entries.
void Catalog::savePlaylistCache()
{
    if (!m_cacheDirty)
        return;
    m_cacheDirty = false;
    const qint64 now = QDateTime::currentSecsSinceEpoch();

    // The file is written whole and compact; if it were corrupt it starts
    // from empty (the memory regenerates it).
    QJsonObject o;
    QFile f(playlistsFile());
    if (f.open(QIODevice::ReadOnly)) {
        o = QJsonDocument::fromJson(f.readAll()).object();
        f.close();
    }
    for (const QString &key : m_cacheForgotten)
        o.remove(key);
    m_cacheForgotten.clear();
    for (auto it = m_playlistCache.constBegin(); it != m_playlistCache.constEnd();
         ++it) {
        QJsonArray arr;
        for (const QVariant &v : it.value())
            arr.append(QJsonObject::fromVariantMap(v.toMap()));
        o.insert(it.key(),
                 QJsonObject{
                     {QStringLiteral("t"),
                      QJsonValue(double(m_playlistCacheAt.value(it.key(), now)))},
                     {QStringLiteral("n"), m_playlistTitles.value(it.key())},
                     {QStringLiteral("l"), arr},
                 });
    }

    // Pruning: out goes the expired stuff, and only the 300 most recent
    // entries stay.
    QList<QPair<qint64, QString>> items;
    items.reserve(o.size());
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        const qint64 ts = qint64(it.value().toObject()
                                     .value(QStringLiteral("t")).toDouble());
        if (ts <= 0 || now - ts > kPlaylistTtlSecs)
            continue;
        items.append({ts, it.key()});
    }
    std::sort(items.begin(), items.end(),
              [](const QPair<qint64, QString> &a,
                 const QPair<qint64, QString> &b) {
                  return a.first > b.first;   // most recent first
              });
    if (items.size() > kPlaylistCacheMax)
        items = items.mid(0, kPlaylistCacheMax);

    QJsonObject out;
    for (const auto &p : items)
        out.insert(p.second, o.value(p.second));

    QDir().mkpath(QFileInfo(playlistsFile()).absolutePath());
    QFile w(playlistsFile());
    if (w.open(QIODevice::WriteOnly | QIODevice::Truncate))
        w.write(QJsonDocument(out).toJson(QJsonDocument::Compact));
}

// ------------------------------------------------------------ login ----

bool Catalog::ytmLoggedIn() const
{
    if (m_loginState == QLatin1String("ok"))
        return true;

    // Light check: is there a SAPISID cookie in cookies.txt?
    QFile f(cookieFile());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;
    const QList<QByteArray> lines = f.readAll().split('\n');
    for (const QByteArray &line : lines) {
        if (line.startsWith('#') || line.trimmed().isEmpty())
            continue;
        const QList<QByteArray> cols = line.split('\t');
        if (cols.size() >= 7) {
            const QByteArray name = cols.at(5).trimmed();
            if (name == "SAPISID" || name == "__Secure-3PAPISID"
                || name == "__Secure-1PAPISID")
                return true;
        }
    }
    return false;
}

void Catalog::setLoginState(const QString &state)
{
    if (m_loginState == state)
        return;
    m_loginState = state;
    emit loginChanged();
    // On sign in, automatically bring the saved lists and the "liked"
    // set.
    if (state == QLatin1String("ok")) {
        forgetCachedPlaylist(QStringLiteral("list:LM"));
        refreshYtmLibrary();
        refreshLikedSet();
    }
}

void Catalog::handleLoginOutput()
{
    m_loginBuf += m_loginProc.readAll();
    int nl;
    while ((nl = m_loginBuf.indexOf('\n')) >= 0) {
        const QString line = QString::fromUtf8(m_loginBuf.left(nl)).trimmed();
        m_loginBuf.remove(0, nl + 1);
        if (line.startsWith(QLatin1String("LOGIN_URL "))) {
            m_loginUrl = line.mid(int(qstrlen("LOGIN_URL ")));
            emit loginChanged();
        } else if (line.startsWith(QLatin1String("STATUS error "))) {
            m_loginError = line.mid(int(qstrlen("STATUS error ")));
        }
    }
}

void Catalog::finishLogin(int code)
{
    if (m_loginCancel) {
        m_loginCancel = false;
        return;
    }
    if (code == 0 && ytmLoggedIn()) {
        m_loginError.clear();
        setLoginState(QStringLiteral("ok"));
    } else {
        if (m_loginError.isEmpty())
            m_loginError = QStringLiteral("No se completó el inicio de sesión.");
        setLoginState(QStringLiteral("error"));
    }
}

void Catalog::loginYTM()
{
    if (ytmLoggedIn()) {
        setLoginState(QStringLiteral("ok"));
        return;
    }
    if (m_loginProc.state() != QProcess::NotRunning)
        return;  // already waiting for the user
    if (!QFile::exists(helperPath())) {
        m_loginError = QStringLiteral("Falta el asistente de login (ytm_login.py).");
        setLoginState(QStringLiteral("error"));
        return;
    }

    m_loginError.clear();
    m_loginUrl.clear();
    m_loginBuf.clear();
    m_loginCancel = false;
    setLoginState(QStringLiteral("waiting"));

    m_loginProc.setProgram(AppPaths::pythonProgram());
    m_loginProc.setArguments({helperPath(), QStringLiteral("login")});
    m_loginProc.start();
    if (!m_loginProc.waitForStarted(3000)) {
        m_loginError = QStringLiteral("No se pudo abrir la ventana de Google.");
        setLoginState(QStringLiteral("error"));
    }
}

void Catalog::logoutYTM()
{
    if (m_loginProc.state() != QProcess::NotRunning) {
        m_loginCancel = true;
        m_loginProc.kill();
    }
    QFile::remove(cookieFile());
    QFile::remove(AppPaths::configDir()
                  + QStringLiteral("/ytm_session.json"));
    // The session is gone: forget the cached lists and the persisted
    // "liked" set.
    invalidatePlaylistCache();
    QFile::remove(likedFile());
    m_loginError.clear();
    setLoginState(QString());
    // On sign out, forget the "liked" set.
    if (!m_likedIds.isEmpty() || m_likedReady) {
        m_likedIds.clear();
        m_likedReady = false;
        m_likedTs = 0;
        ++m_likedRevision;
        emit likedChanged();
    }
}

bool Catalog::handleOutput(const QByteArray &json)
{
    QJsonParseError perr;
    const QJsonObject root = QJsonDocument::fromJson(json, &perr).object();
    if (perr.error != QJsonParseError::NoError || root.isEmpty()) {
        fail(QStringLiteral("Respuesta ilegible"));
        return false;
    }

    QVariantList list;
    const QJsonArray entries = root.value(QStringLiteral("entries")).toArray();
    if (!entries.isEmpty()) {
        for (const QJsonValue &v : entries) {
            const QVariantMap t = normalize(v.toObject().toVariantMap());
            if (!t.isEmpty())
                list.append(t);
        }
    } else {
        const QVariantMap t = normalize(root.toVariantMap());
        if (!t.isEmpty())
            list.append(t);
    }

    if (list.isEmpty()) {
        if (m_purpose == QLatin1String("search"))
            fail(QStringLiteral("Nada encontrado para «%1»").arg(m_pendingTitle));
        else if (m_purpose == QLatin1String("radio"))
            fail(QStringLiteral("No se pudo obtener la radio de YouTube Music"));
        else
            fail(QStringLiteral("La playlist está vacía o no es accesible"));
        return false;
    }

    if (m_purpose == QLatin1String("search")) {
        m_results = list;
    } else if (isBackgroundPurpose(m_purpose)) {
        // The radio does not replace the queue: the player only uses it to
         // extend "up next" after the seed track. It is cached with its
         // normal key (list:RDAMVM<seed>), so the prefetch done in the
         // background from Home leaves the list ready and opening it from
         // "Recommended for you" is instant.
        cachePlaylist(m_pendingKey, list, m_pendingTitle);
        rememberPlaylistForDisk(m_pendingKey);
        emit radioReady(m_radioSeed, list);
        // If the user opened the radio by hand while it was loading, that
         // same result works as the open list (it is not downloaded
         // again).
        if (m_promotePending) {
            m_promotePending = false;
            m_tracks = list;
            m_tracksTitle = m_pendingTitle;
            emit tracksReady(list, m_pendingTitle);
        }
    } else {
        QString title = m_pendingTitle;
        if (title.isEmpty())
            title = root.value(QStringLiteral("title")).toString();
        if (title.isEmpty())
            title = QStringLiteral("Playlist");
        m_tracks = list;
        m_tracksTitle = title;
        // It is stored in the in-memory cache: reopening this list will be
         // instant.
        cachePlaylist(m_pendingKey, list, title);
        rememberPlaylistForDisk(m_pendingKey);
        emit tracksReady(list, title);
    }
    emit changed();
    return true;
}

QVariantMap Catalog::normalize(const QVariantMap &e) const
{
    QVariantMap t;

    QString artist = e.value(QStringLiteral("channel")).toString();
    if (artist.isEmpty())
        artist = e.value(QStringLiteral("uploader")).toString();
    if (artist.isEmpty())
        artist = e.value(QStringLiteral("artist")).toString();

    // Flat SoundCloud entries carry the canonical permalink in webpage_url
    // (their url is an api.soundcloud.com/tracks/... API URL); YouTube flat
    // entries have no webpage_url and use url (already a watch URL).
    QString url = e.value(QStringLiteral("webpage_url")).toString();
    if (!url.startsWith(QLatin1String("http")))
        url = e.value(QStringLiteral("url")).toString();
    const QString id = e.value(QStringLiteral("id")).toString();
    const QString source = m_currentSource;

    if (!url.startsWith(QLatin1String("http"))) {
        if (source == QLatin1String("ytm") && !id.isEmpty())
            url = QStringLiteral("https://www.youtube.com/watch?v=") + id;
        else if (url.startsWith(QLatin1String("soundcloud.com/")))
            url = QStringLiteral("https://www.") + url;
        else
            return {};
    }

    QString title = e.value(QStringLiteral("title")).toString().trimmed();
    if (title.isEmpty()) {
        // Bare SoundCloud permalink stubs: rebuild a title from the slug
        // (https://soundcloud.com/user/my-love -> "My Love").
        const QUrl u(url);
        const QStringList segs =
            u.path().split(QLatin1Char('/'), Qt::SkipEmptyParts);
        if (u.host().contains(QLatin1String("soundcloud.com"))
            && segs.size() >= 2) {
            const QString slug =
                QUrl::fromPercentEncoding(segs.constLast().toUtf8());
            bool numeric = !slug.isEmpty();
            for (const QChar c : slug)
                numeric = numeric && c.isDigit();
            if (!numeric && !slug.isEmpty()) {
                title = slug;
                title.replace(QLatin1Char('-'), QLatin1Char(' '));
                title = title.trimmed();
            }
        }
    }
    if (title.isEmpty())
        return {};

    if (artist.isEmpty()) {
        // SoundCloud permalink stubs without uploader: owner is the first
        // path segment (https://soundcloud.com/user/slug -> "user").
        const QUrl u(url);
        const QStringList segs =
            u.path().split(QLatin1Char('/'), Qt::SkipEmptyParts);
        if (u.host().contains(QLatin1String("soundcloud.com"))
            && segs.size() >= 2)
            artist = segs.constFirst();
    }

    // Thumbnail: if yt-dlp brings several resolutions, it takes the best one
     // that does not go over 480 px so it does not waste RAM; if there is
     // no valid one, the plain `thumbnail` string; and as a last resort
     // the last one of the list.
    QString thumb = e.value(QStringLiteral("thumbnail")).toString();
    const QVariantList thumbs = e.value(QStringLiteral("thumbnails")).toList();
    if (!thumbs.isEmpty()) {
        QString best;
        QString last;
        int bestDim = 0;
        for (const QVariant &tv : thumbs) {
            const QVariantMap tm = tv.toMap();
            const QString u = tm.value(QStringLiteral("url")).toString();
            if (u.isEmpty())
                continue;
            last = u;
            const int dim = qMax(tm.value(QStringLiteral("width")).toInt(),
                                 tm.value(QStringLiteral("height")).toInt());
            if (dim > 0 && dim <= 480 && dim > bestDim) {
                bestDim = dim;
                best = u;
            }
        }
        if (!best.isEmpty())
            thumb = best;
        else if (thumb.isEmpty())
            thumb = last;
    }

    t.insert(QStringLiteral("title"), title);
    t.insert(QStringLiteral("artist"), artist);
    t.insert(QStringLiteral("duration"), e.value(QStringLiteral("duration")).toDouble());
    t.insert(QStringLiteral("url"), url);
    t.insert(QStringLiteral("source"), source);
    t.insert(QStringLiteral("thumb"), thumb);
    // setVideoId of YouTube Music: it identifies the row of the track inside
    // the playlist it was in, needed to remove it with rmpl.
    const QString setId = e.value(QStringLiteral("setVideoId")).toString();
    if (!setId.isEmpty())
        t.insert(QStringLiteral("setId"), setId);
    // YouTube Music's likeStatus ("LIKE"/"DISLIKE"/"INDIFFERENT"): the
     // "liked" state that every track brings with a session, to paint
     // the row's heart.
    const QString like = e.value(QStringLiteral("likeStatus")).toString();
    if (!like.isEmpty())
        t.insert(QStringLiteral("liked"), like == QLatin1String("LIKE"));
    return t;
}

void Catalog::fail(const QString &message)
{
    m_error = message;
    qWarning() << "[catalog]" << message;
    emit changed();
}

void Catalog::dismissError()
{
    if (m_error.isEmpty())
        return;
    m_error.clear();
    emit changed();
}

// ------------------------------------------------------------- library ----

void Catalog::addPlaylist(const QString &name, const QString &url)
{
    const QString u = url.trimmed();
    if (u.isEmpty()) {
        fail(QStringLiteral("Pega la URL de una playlist"));
        return;
    }
    for (const QVariant &v : m_playlists) {
        if (v.toMap().value(QStringLiteral("url")).toString() == u) {
            fail(QStringLiteral("Esa playlist ya está guardada"));
            return;
        }
    }
    QVariantMap pl{
        {QStringLiteral("url"), u},
        {QStringLiteral("source"), m_sources->activeId()},
        {QStringLiteral("count"), 0},
    };
    QString n = name.trimmed();
    if (n.isEmpty())
        n = u.endsWith(QLatin1Char('/'))
                ? u.mid(u.lastIndexOf(QLatin1Char('/'), u.size() - 2) + 1)
                : u.section(QLatin1Char('='), -1);
    if (n.isEmpty())
        n = QStringLiteral("Playlist");
    pl.insert(QStringLiteral("name"), n);
    m_playlists.prepend(pl);
    while (m_playlists.size() > 25)
        m_playlists.removeLast();
    saveLibrary();
    emit libraryChanged();
    emit changed();
}

void Catalog::removePlaylist(int index)
{
    if (index < 0 || index >= m_playlists.size())
        return;
    m_playlists.removeAt(index);
    saveLibrary();
    emit libraryChanged();
}

void Catalog::addRecent(const QVariantMap &track)
{
    const QString url = track.value(QStringLiteral("url")).toString();
    if (url.isEmpty())
        return;
    for (int i = m_recent.size() - 1; i >= 0; --i) {
        if (m_recent.at(i).toMap().value(QStringLiteral("url")).toString() == url)
            m_recent.removeAt(i);
    }
    m_recent.prepend(track);
    while (m_recent.size() > 12)
        m_recent.removeLast();
    saveLibrary();
    emit libraryChanged();
}

void Catalog::clearRecent()
{
    m_recent.clear();
    saveLibrary();
    emit libraryChanged();
}

void Catalog::loadLibrary()
{
    QFile f(stateFile());
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    const QJsonArray pls = o.value(QStringLiteral("playlists")).toArray();
    for (const QJsonValue &v : pls)
        m_playlists.append(v.toObject().toVariantMap());
    // The "recent" ones before v1 did not store `setId`, so it cannot be
     // known which ones played inside a playlist. They are tagged as
     // "legacy": they are not painted as loose songs, but they still feed
     // "Recommended for you" until they fall away on their own.
    const int schema = o.value(QStringLiteral("schema")).toInt();
    const QJsonArray rec = o.value(QStringLiteral("recent")).toArray();
    for (const QJsonValue &v : rec) {
        QVariantMap m = v.toObject().toVariantMap();
        if (schema < 1)
            m.insert(QStringLiteral("legacy"), true);
        m_recent.append(m);
    }
}

void Catalog::saveLibrary() const
{
    QJsonArray pls, rec;
    for (const QVariant &v : m_playlists)
        pls.append(QJsonObject::fromVariantMap(v.toMap()));
    for (const QVariant &v : m_recent)
        rec.append(QJsonObject::fromVariantMap(v.toMap()));
    const QJsonObject o{{QStringLiteral("schema"), 1},
                        {QStringLiteral("playlists"), pls},
                        {QStringLiteral("recent"), rec}};
    QFile f(stateFile());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
}

// ---- the session of YouTube Music -----------------------------------------

bool Catalog::exportSession(const QString &path)
{
    QFile f(AppPaths::cookiesFile());
    if (!f.open(QIODevice::ReadOnly))
        return false;
    QJsonArray cookies;
    const QList<QByteArray> lines = f.readAll().split('\n');
    for (const QByteArray &lb : lines) {
        const QString line = QString::fromUtf8(lb).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        const QStringList f2 = line.split(QLatin1Char('\t'));
        if (f2.size() < 7)
            continue;
        QJsonObject c;
        c[QStringLiteral("domain")] = f2.at(0);
        c[QStringLiteral("path")] = f2.at(2);
        c[QStringLiteral("secure")] = f2.at(3);
        c[QStringLiteral("expires")] = f2.at(4);
        c[QStringLiteral("name")] = f2.at(5);
        c[QStringLiteral("value")] = f2.at(6);
        cookies.append(c);
    }
    f.close();
    if (cookies.isEmpty())
        return false;

    QJsonObject root;
    root[QStringLiteral("app")] = QStringLiteral("lotus-tune");
    root[QStringLiteral("version")] = QStringLiteral("1");
    root[QStringLiteral("cookies")] = cookies;

    QFile out(path);
    if (!out.open(QIODevice::WriteOnly))
        return false;
    out.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    out.close();
    return true;
}

bool Catalog::importSession(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return false;
    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    f.close();
    const QJsonArray cookies = root.value(QStringLiteral("cookies")).toArray();
    if (cookies.isEmpty())
        return false;

    const QString target = AppPaths::cookiesFile();
    QDir().mkpath(QFileInfo(target).absolutePath());
    QFile out(target);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    out.write("# Netscape HTTP Cookie File\n");
    out.write("# Exported by LotusTune\n\n");
    for (const QJsonValue &v : cookies) {
        const QJsonObject c = v.toObject();
        out.write(QStringLiteral("%1\tFALSE\t%2\t%3\t%4\t%5\t%6\n")
                     .arg(c.value(QStringLiteral("domain")).toString(),
                          c.value(QStringLiteral("path")).toString(),
                          c.value(QStringLiteral("secure")).toString(),
                          c.value(QStringLiteral("expires")).toString(),
                          c.value(QStringLiteral("name")).toString(),
                          c.value(QStringLiteral("value")).toString())
                     .toUtf8());
    }
    out.close();
    return true;
}
