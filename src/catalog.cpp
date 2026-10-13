#include "catalog.h"
#include "sources.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QSettings>
#include <QStandardPaths>
#include <QUrl>

#include <QDebug>

Catalog::Catalog(SourceManager *sources, QObject *parent)
    : QObject(parent)
    , m_sources(sources)
{
    loadLibrary();

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
        m_statusProc.setProgram(QStringLiteral("python3"));
        m_statusProc.setArguments({helperPath(), QStringLiteral("status")});
        m_statusProc.start();
    } else if (m_loginState == QLatin1String("ok")) {
        m_loginState.clear();
    }

    // "Mis listas": consulta puntual a la API de YT Music con ytm_api.py. Usa
    // su propio QProcess para no interferir con m_proc ni con el login.
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
                        // Una lista PROPIA (se le puede renombrar/borrar) trae
                        // las acciones EDIT/DELETE en su menú; una guardada de
                        // otro, no.
                        it.insert(QStringLiteral("owned"),
                                  o.value(QStringLiteral("owned")).toBool());
                        items.append(it);
                    }
                }
                m_ytmLibrary = items;
                m_libraryBusy = false;
                emit libraryChanged();
            });

    // Acciones puntuales sobre YT Music (votar, añadir/quitar de lista). Van en
    // su propio QProcess para no bloquear búsquedas ni "mis listas".
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

    // Gestión de listas propias (crear/renombrar/privacidad/borrar y leer su
    // info). Proceso propio para no chocar con las acciones de voto/addpl/rmpl.
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
                    if (mode == QLatin1String("info"))
                        emit playlistInfoReady({});
                    else
                        emit interactionDone(false, msg);
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
                        // Encadena: crea la lista y añade la pista en la misma
                        // tanda (mismo QProcess, ya libre).
                        m_plMode = QStringLiteral("createadd");
                        m_plProc.setProgram(QStringLiteral("python3"));
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
            });

    // "Me gusta" (biblioteca): una consulta puntual a la playlist LM para
    // conocer el estado real de cada pista, con su propio QProcess.
    m_likedProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_likedProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_likedProc.readAllStandardOutput();
                if (code != 0) {
                    qWarning() << "[catalog] no se pudo cargar \"me gusta\"";
                    return;   // sin sesión/red: las filas usan el likeStatus embebido
                }
                const QJsonDocument doc = QJsonDocument::fromJson(out);
                const QJsonArray entries =
                    doc.object().value(QStringLiteral("entries")).toArray();
                QSet<QString> ids;
                for (const QJsonValue &v : entries) {
                    const QString id =
                        v.toObject().value(QStringLiteral("id")).toString();
                    if (!id.isEmpty())
                        ids.insert(id);
                }
                m_likedIds = ids;
                m_likedReady = true;
                ++m_likedRevision;
                qInfo() << "[catalog] me gusta:" << m_likedIds.size() << "pistas";
                emit likedChanged();
            });

    m_proc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_proc, &QProcess::finished, this,
            [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_proc.readAllStandardOutput();
                if (code == 0 && handleOutput(out)) {
                    m_busy = false;
                    emit changed();
                    return;   // éxito
                }

                // Respaldo: si la vía rápida de playlists falló (API interna no
                // accesible, lista vacía, etc.) se reintenta con yt-dlp.
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

    // Si ya hay sesión guardada, traer "mis listas" al arrancar.
    if (ytmLoggedIn()) {
        refreshYtmLibrary();
        refreshLikedSet();
    }
}

QString Catalog::stateFile()
{
    const QString dir = QDir::homePath() + QStringLiteral("/.local/state/lotus-tune");
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
    return QDir::homePath() + QStringLiteral("/.config/lotus-tune/cookies.txt");
}

// El helper de "mis listas": junto al binario (post-build) o en el árbol de
// fuentes vía el fallback ../tools.
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

// ---------------------------------------------------------------- fetch ----

void Catalog::startFetch(const QString &program, const QStringList &args,
                         const QString &purpose, const QString &title)
{
    if (m_busy) {
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

void Catalog::run(const QString &target, const QString &purpose, const QString &title)
{
    if (target.isEmpty())
        return;

    m_fastFallback.clear();
    m_fastFallbackTitle.clear();
    m_openPlaylistId.clear();

    // Vía rápida de listas: para playlists de YouTube Music, la API interna
    // devuelve todas las pistas en ~0.5 s (sin arrancar yt-dlp, que tarda
    // varios segundos). Se usa cuando hay sesión; si no, se cae a yt-dlp.
    if (purpose == QLatin1String("playlist") && ytmLoggedIn()) {
        const QRegularExpression re(
            QStringLiteral("list=([A-Za-z0-9_-]+)"));
        const QRegularExpressionMatch m = re.match(target);
        if (target.contains(QLatin1String("youtube.com")) && m.hasMatch()) {
            // Guardamos el destino por si la vía rápida falla (playlist no
            // accesible por la API interna): se reintenta con yt-dlp.
            m_fastFallback = target;
            m_fastFallbackTitle = title;
            m_openPlaylistId = m.captured(1);
            startFetch(QStringLiteral("python3"),
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
    QStringList args{
        QStringLiteral("-J"),
        QStringLiteral("--no-warnings"),
        QStringLiteral("--ignore-errors"),
        QStringLiteral("--no-plugin-dirs"),
        QStringLiteral("--playlist-end=500"),
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
    // Sesión de YT Music: usar las cookies del login integrado en los destinos
    // de YouTube (búsqueda, playlists, Liked Music). El resto de fuentes van
    // sin cookies.
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
    run(m_sources->searchPrefix(source) + q, QStringLiteral("search"), q);
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
    // "Liked Music" (playlist LM) autenticada con las cookies del login
    // integrado. yt-dlp emite el JSON -J que handleOutput() ya sabe leer.
    run(QStringLiteral("https://music.youtube.com/playlist?list=LM"),
        QStringLiteral("playlist"), QStringLiteral("Liked Music"));
}

// ------------------------------------------------------------ "mis listas" ----

void Catalog::refreshYtmLibrary()
{
    if (!ytmLoggedIn())
        return;
    if (m_libraryProc.state() != QProcess::NotRunning)
        return;  // ya hay una consulta en curso
    if (!QFile::exists(ytmApiPath()))
        return;

    m_libraryBusy = true;
    emit libraryChanged();
    m_libraryProc.setProgram(QStringLiteral("python3"));
    m_libraryProc.setArguments({ytmApiPath(), QStringLiteral("library")});
    m_libraryProc.start();
}

// --------------------------------------------------- interacción YT Music ----

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
    m_ytmProc.setProgram(QStringLiteral("python3"));
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

// --------------------------------------------------- gestión de listas ----

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
    m_plProc.setProgram(QStringLiteral("python3"));
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
    // ¿Ya es un videoId crudo de YouTube? (11 caracteres, sin separadores).
    if (s.size() == 11 && !s.contains(QLatin1Char('/'))
        && !s.contains(QLatin1Char('.')) && !s.contains(QLatin1Char(' ')))
        return s;
    return {};
}

void Catalog::setLiked(const QString &videoId, bool liked)
{
    if (videoId.isEmpty())
        return;
    const bool had = m_likedIds.contains(videoId);
    if (liked && !had)
        m_likedIds.insert(videoId);
    else if (!liked && had)
        m_likedIds.remove(videoId);
    // Sigue subiendo la revisión aunque no cambie: el voto ya se envió y las
    // filas/corazón deben repintarse con el estado decidido localmente.
    ++m_likedRevision;
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
    if (m_likedReady || !ytmLoggedIn()
        || m_likedProc.state() != QProcess::NotRunning)
        return;
    if (!QFile::exists(ytmApiPath()))
        return;
    m_likedProc.setProgram(QStringLiteral("python3"));
    m_likedProc.setArguments({ytmApiPath(), QStringLiteral("playlist"),
                              QStringLiteral("LM")});
    m_likedProc.start();
}

// ------------------------------------------------------------ login ----

bool Catalog::ytmLoggedIn() const
{
    if (m_loginState == QLatin1String("ok"))
        return true;

    // Comprobación ligera: ¿hay una cookie SAPISID en el cookies.txt?
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
    // Al iniciar sesión, traer automáticamente las listas guardadas y el
    // conjunto de "me gusta".
    if (state == QLatin1String("ok")) {
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

    m_loginProc.setProgram(QStringLiteral("python3"));
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
    QFile::remove(QDir::homePath()
                  + QStringLiteral("/.config/lotus-tune/ytm_session.json"));
    m_loginError.clear();
    setLoginState(QString());
    // Al cerrar sesión, olvidar el conjunto de "me gusta".
    if (!m_likedIds.isEmpty() || m_likedReady) {
        m_likedIds.clear();
        m_likedReady = false;
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
        fail(m_purpose == QLatin1String("search")
                 ? QStringLiteral("Nada encontrado para «%1»").arg(m_pendingTitle)
                 : QStringLiteral("La playlist está vacía o no es accesible"));
        return false;
    }

    if (m_purpose == QLatin1String("search")) {
        m_results = list;
    } else {
        QString title = m_pendingTitle;
        if (title.isEmpty())
            title = root.value(QStringLiteral("title")).toString();
        if (title.isEmpty())
            title = QStringLiteral("Playlist");
        m_tracks = list;
        m_tracksTitle = title;
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

    // Miniatura: si yt-dlp trae varias resoluciones, tomar la mejor que no
    // pase de 480 px para no malgastar RAM; si no hay ninguna válida, la
    // cadena suelta `thumbnail`; y como último recurso la última de la lista.
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
    // setVideoId de YouTube Music: identifica la fila de la pista dentro de la
    // playlist en la que estaba, necesario para quitarla con rmpl.
    const QString setId = e.value(QStringLiteral("setVideoId")).toString();
    if (!setId.isEmpty())
        t.insert(QStringLiteral("setId"), setId);
    // likeStatus de YT Music ("LIKE"/"DISLIKE"/"INDIFFERENT"): estado de "me
    // gusta" que trae cada pista con sesión, para pintar el corazón de la fila.
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
    const QJsonArray rec = o.value(QStringLiteral("recent")).toArray();
    for (const QJsonValue &v : rec)
        m_recent.append(v.toObject().toVariantMap());
}

void Catalog::saveLibrary() const
{
    QJsonArray pls, rec;
    for (const QVariant &v : m_playlists)
        pls.append(QJsonObject::fromVariantMap(v.toMap()));
    for (const QVariant &v : m_recent)
        rec.append(QJsonObject::fromVariantMap(v.toMap()));
    const QJsonObject o{{QStringLiteral("playlists"), pls}, {QStringLiteral("recent"), rec}};
    QFile f(stateFile());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
}
