#include "catalog.h"
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

// El conjunto «me gusta» se sincroniza solo al arrancar y al hacer login
// (refreshLikedSet); ya no se hace gating por TTL de 24 h, porque la consulta
// a la API interna es asíncrona y barata. syncLiked() lo refuerza a demanda.

// Caché en disco de listas (playlists.json): TTL de validez y un tope de 300
// entradas (las más antiguas se podan) para que el fichero no crezca sin freno.
static constexpr qint64 kPlaylistTtlSecs = 24 * 60 * 60;
static constexpr int kPlaylistCacheMax = 300;

Catalog::Catalog(SourceManager *sources, QObject *parent)
    : QObject(parent)
    , m_sources(sources)
{
    loadLibrary();

    // Caché en disco de listas: se vuelca en diferido (igual que streams.json
    // del reproductor) para no escribir en cada carga, y se lee ya en el
    // arranque para que reabrir una lista (o una radio precargada) sea
    // instantáneo incluso tras reiniciar la app.
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

    // Artistas: búsqueda, discografía y pistas de álbum (ytm_api.py, vía anónima
    // cuando no hay sesión). Proceso propio para no pisar búsquedas de canciones
    // ni la apertura de listas; su respuesta llega por señales dedicadas.
    m_artistProc.setProcessChannelMode(QProcess::SeparateChannels);
    connect(&m_artistProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) {
                const QByteArray out = m_artistProc.readAllStandardOutput();
                const QString mode = m_artistMode;
                const QString arg = m_artistArg;
                m_artistMode.clear();
                m_artistArg.clear();
                if (mode.isEmpty())
                    return;   // anulado por una petición nueva: se ignora
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

    // Vídeo alternativo (m_altProc): el JSON que devuelve ytm_api.py ya es una
    // pista completa; se normaliza igual que una pista de búsqueda, pero con la
    // fuente fijada a YouTube Music (es lo que siempre es un candidato de YTM).
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
                        // normalize() etiqueta con m_currentSource; lo que se
                        // reproduce es la pista de YTM, así que el origen es ytm.
                        track = normalize(doc.object().toVariantMap());
                        if (!track.isEmpty())
                            track.insert(QStringLiteral("source"),
                                         QStringLiteral("ytm"));
                    }
                }
                emit alternateResolved(key, track);
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
                    m_plSetId.clear();
                    if (mode == QLatin1String("info")) {
                        emit playlistInfoReady({});
                    } else {
                        // Un reordenado fallido deja la fila movida en local:
                        // se recarga la lista abierta para volver al orden real.
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
                if (mode == QLatin1String("move")) {
                    emit interactionDone(true, QStringLiteral("Lista reordenada"));
                    return;
                }
                if (mode == QLatin1String("remove")) {
                    // Ya confirmado por YouTube: quita la fila de la lista abierta.
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
                QVariantList lmTracks;
                for (const QJsonValue &v : entries) {
                    const QJsonObject o = v.toObject();
                    const QString id = o.value(QStringLiteral("id")).toString();
                    if (!id.isEmpty())
                        ids.insert(id);
                    lmTracks.append(normalize(o.toVariantMap()));
                }
                m_likedIds = ids;
                m_likedReady = true;
                m_likedTs = QDateTime::currentSecsSinceEpoch();
                saveLikedToDisk();
                ++m_likedRevision;
                // La misma respuesta trae el contenido de la lista «Me gusta»
                // (LM): lo dejamos en caché para que al pulsar «Me gusta» se vea
                // al instante y sin volver a la red. Si la lista LM está abierta
                // ahora mismo, la refrescamos en pantalla (así un unlike hecho
                // en otro sitio quita la fila sin recargar).
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
                // Proceso anulado al ceder el paso a una petición explícita
                // del usuario: no hay nada que informar.
                if (m_killed) {
                    m_killed = false;
                    return;
                }
                const QByteArray out = m_proc.readAllStandardOutput();
                if (code == 0 && handleOutput(out)) {
                    m_busy = false;
                    // Búsqueda por todas las fuentes: lo que acaba de llegar
                    // es de una fuente; se guarda en su grupo y se sigue con
                    // la siguiente.
                    if (m_multiActive && m_purpose == QLatin1String("search")) {
                        absorbMultiResults();
                        return;
                    }
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

                // Una fuente que falla no puede hundir la búsqueda completa:
                // se pasa a la siguiente.
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

    // Si ya hay sesión guardada, traer "mis listas" al arrancar.
    if (ytmLoggedIn()) {
        refreshYtmLibrary();
        refreshLikedSet();
    }
}

Catalog::~Catalog()
{
    // El chequeo de sesión que arranca el constructor no debe quedar suelto:
    // si sigue en marcha se le mata (igual que ~Player con mpv y sus
    // resolutores) para no dejar procesos huérfanos ni avisos al destruir.
    if (m_statusProc.state() != QProcess::NotRunning) {
        m_statusProc.kill();
        m_statusProc.waitForFinished(500);
    }
    // Al salir, vuelca ya lo que quede pendiente: sin esto, una lista cargada
    // justo antes de cerrar no llegaría a persistir (el volcado va diferido).
    savePlaylistCache();
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

// Propósitos que van en segundo plano: son best-effort, no deben bloquear a
// nadie ni informar error si algo los pisa. Son dos: la radio del autoplay
// (pide más pistas) y la precarga de las radios de Inicio (pide pocas, para
// estar lista en ~1,4 s).
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
        // La marca hace que el finished() posterior se ignore en silencio (si
        // no, informaría de un fallo que no interesa a nadie).
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
    // Una consulta en segundo plano (radio del autoplay o precarga de las
    // radios de Inicio) es siempre best-effort: una petición explícita del
    // usuario la pisa sin más. Cualquier otra operación en marcha sigue
    // esperando como antes.
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

// Una radio de YouTube Music no es una lista normal: el identificador
// «RDAMVM<videoId>» lo entiende sólo yt-dlp (la API interna devuelve vacío y
// dispara el respaldo, que es lo que hacía que tardara ~20 s) y el tope de
// pistas es lo único que decide lo que tarda (ver runYtdlp()).
static bool isRadioTarget(const QString &target)
{
    return target.contains(QLatin1String("list=RDAMVM"))
        || target.contains(QLatin1String("start_radio=1"));
}

void Catalog::run(const QString &target, const QString &purpose, const QString &title)
{
    if (target.isEmpty())
        return;

    // Recordamos la URL real de la lista abierta (para descargarla).
    if (purpose == QLatin1String("playlist"))
        m_openListUrl = target;

    // Caché de listas: reabrir una ya cargada no lanza ningún proceso y
    // responde al instante. Se mira primero la memoria y, si falla, el fichero
    // en disco (playlists.json), de modo que también es instantáneo tras
    // reiniciar. Solo para listas; la búsqueda siempre va a la red.
    // Una precarga de fondo en vuelo no debe impedirlo (es justo lo que hace
    // que abrir una radio de «Para ti» sea instantáneo): se cancela y se sirve.
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
            // No está en memoria: puede seguir en la caché en disco de una
            // sesión anterior. Si es así se sirve igual de rápido (sin red) y
            // se asciende a memoria para las próximas veces.
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
            // Diferido: no reentramos en QML desde dentro de la propia llamada.
            QTimer::singleShot(0, this, [this, cached, cachedTitle]() {
                m_tracks = cached;
                m_tracksTitle = cachedTitle;
                m_busy = false;   // servir de caché nunca deja la UI bloqueada
                emit tracksReady(cached, cachedTitle);
                emit changed();
            });
            return;
        }
    }

    // Ya se está trayendo esta misma lista en segundo plano (precarga de una
    // radio al pasar el ratón). No se relanza el proceso: se espera el que
    // está en vuelo y su resultado se sirve como lista abierta.
    if (m_busy && m_pendingKey == key) {
        if (purpose == QLatin1String("playlist"))
            m_promotePending = true;   // sólo se activa, nunca se quita
        return;
    }

    m_pendingKey = key;
    m_promotePending = false;

    m_fastFallback.clear();
    m_fastFallbackTitle.clear();
    m_openPlaylistId.clear();

    // Vía rápida de listas: para playlists de YouTube Music, la API interna
    // devuelve todas las pistas en ~0.5 s (sin arrancar yt-dlp, que tarda
    // varios segundos). Se usa cuando hay sesión; si no, se cae a yt-dlp.
    // Las radios (RDAMVM/start_radio) se saltan este atajo: ytm_api.py no las
    // conoce y su respuesta vacía sólo servía para demorar el respaldo.
    if (purpose == QLatin1String("playlist") && ytmLoggedIn()
        && !isRadioTarget(target)) {
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
    // Una radio no necesita 500 pistas: la API de YouTube la trae página a
    // página, así que el tope decide el tiempo de espera. La radio abierta
    // como lista (las de «Para ti») bloquea la vista, así que se pide corta:
    // 25 pistas ≈1.4 s y ≈2 h de música. La de autoplay llega en segundo
    // plano sin interrumpir, así que se pide más larga.
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
    searchInSource(source, q);
}

// Búsqueda en una fuente concreta. La vía rápida (API interna de YT Music)
// sólo aplica a YouTube Music con sesión iniciada; el resto va por yt-dlp
// con el prefijo de la fuente (ytsearch15:, scsearch15:…).
void Catalog::searchInSource(const QString &source, const QString &query)
{
    // Vía rápida: la API interna de YT Music busca en ~0.6 s lo que yt-dlp
    // tarda ~2.4 s (arranca la extracción completa en cada búsqueda). Sólo con
    // sesión iniciada y en YouTube Music; si la API falla o no devuelve nada,
    // el respaldo (m_fastFallback) reintenta con yt-dlp automáticamente.
    if (source == QLatin1String("ytm") && ytmLoggedIn()) {
        m_fastFallback = m_sources->searchPrefix(source) + query;
        m_fastFallbackTitle = query;
        startFetch(QStringLiteral("python3"),
                   {ytmApiPath(), QStringLiteral("search"), query},
                   QStringLiteral("search"), query);
        return;
    }
    run(m_sources->searchPrefix(source) + query, QStringLiteral("search"), query);
}

// ---- búsqueda por todas las fuentes ---------------------------------------
// Se consulta una fuente tras otra (cada búsqueda es un proceso) y los
// grupos se van rellenando: la interfaz ve los resultados de cada fuente
// según llegan, sin esperar a la última.
void Catalog::searchAll(const QString &query)
{
    const QString q = query.trimmed();
    if (q.isEmpty())
        return;

    m_multiQuery = q;
    m_multiActive = true;
    m_multiCurrent.clear();
    m_multiQueue.clear();
    m_resultsBySource.clear();
    m_resultsQuery = q;

    // Todas las fuentes del registro, en su orden (YouTube Music primero).
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

    // El grupo se crea ya (vacío) para que la interfaz pueda mostrar la
    // sección de la fuente aunque no devuelva nada.
    QVariantMap group;
    group.insert(QStringLiteral("id"), id);
    group.insert(QStringLiteral("name"), src.value(QStringLiteral("name")).toString());
    group.insert(QStringLiteral("items"), QVariantList{});
    group.insert(QStringLiteral("locked"), !ready);
    m_resultsBySource.append(group);

    if (!ready) {
        // Bloqueada (le faltan credenciales): no hay nada que consultar.
        nextMultiSource();
        return;
    }
    searchInSource(id, m_multiQuery);
}

// Los resultados de la fuente que acaba de terminar se guardan en su grupo
// y se pasa a la siguiente.
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

// Radio/autoplay de YouTube Music: la lista que la propia app reproduce "a
// continuación" de un vídeo es la mix RDAMVM<videoId>. yt-dlp la resuelve como
// playlist plana (la semilla primero y luego la autorradio). Se usa a propósito
// un propósito de fondo (no "playlist") para que run() omita la vía rápida de la
// API interna (ytm_api.py devuelve vacío para RDAMVM...) y acabe en runYtdlp(),
// que ya adjunta las cookies de YT Music.
//
// Hay dos variantes, y la diferencia es el tope de pistas, que es lo único que
// decide el tiempo de espera (YouTube entrega la lista página a página):
//   · fetchRadio()    — la del autoplay: pide 80 (≈5 h) porque va sin
//                       interrumpir a nadie.
//   · prefetchRadio() — la precarga de las radios de Inicio: pide 25 (≈1,4 s),
//                       justo lo que verá quien abra la radio a mano. Al
//                       guardarla igualmente en caché de listas, abrirla a
//                       continuación sale al instante.
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
    // Best-effort: la radio es un extra (no debe interrumpir ni dar error si
    // ya hay otra consulta en marcha). Se reintenta en la siguiente pista.
    if (m_busy)
        return;
    m_radioSeed = v;
    const QString target =
        QStringLiteral("https://www.youtube.com/watch?v=") + v
        + QStringLiteral("&list=RDAMVM") + v;
    run(target, purpose,
        title.trimmed().isEmpty() ? QStringLiteral("Radio") : title.trimmed());
}

// ---- Artistas -------------------------------------------------------------
// Los tres lanzados corren en m_artistProc (una petición a la vez); la salida
// se interpreta en el finished() conectado en el constructor.

void Catalog::runArtist(const QStringList &args, const QString &mode,
                        const QString &arg)
{
    if (m_artistProc.state() != QProcess::NotRunning) {
        // La petición nueva manda: se anula la anterior y su respuesta se
        // ignora (m_artistMode queda vacío antes del kill).
        m_artistMode.clear();
        m_artistArg.clear();
        m_artistProc.kill();
        m_artistProc.waitForFinished(250);
    }
    m_artistMode = mode;
    m_artistArg = arg;
    // normalize() etiqueta las pistas con la fuente activa.
    m_currentSource = m_sources->activeId();
    m_artistProc.setProgram(QStringLiteral("python3"));
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

// Pista principal del artista (lo más escuchado): es la mejor semilla para su
// radio sin pasar por "Radio de la canción". Si el proceso de artistas está
// ocupado se rinde al instante (el menú cae a la radio de la pista pulsada).
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

// Vídeo alternativo para una pista cuyo vídeo original murió. Se busca en YT
// Music descartando el id fallido; la búsqueda de YTM sólo devuelve vídeos
// reproducibles, así que el mejor candidato sirve para sustituirlo. El
// argumento va con campos separados por TAB (título con espacios incluido).
void Catalog::resolveAlternate(const QString &artist, const QString &title,
                               const QString &failedVideoId, double duration)
{
    const QString a = artist.trimmed();
    const QString t = title.trimmed();
    if (t.isEmpty()) {
        emit alternateResolved(failedVideoId, {});
        return;
    }
    // Un recambio a medias: se ignora (la pista fallida se salta igual).
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
    m_altProc.setProgram(QStringLiteral("python3"));
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
    // Botón manual: fuerza el fetch de red del conjunto de "me gusta" (ignora
    // la TTL y la caché en disco) para que el corazón refleje el estado real.
    launchLikedFetch();
    // Y recarga la lista "Liked Music" en la cola, saltándose la caché en
    // memoria para traer el contenido fresco.
    const QString lm =
        QStringLiteral("https://music.youtube.com/playlist?list=LM");
    forgetCachedPlaylist(cacheKeyFor(lm));
    run(lm, QStringLiteral("playlist"), QStringLiteral("Liked Music"));
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

// Reordena la pista `setVideoId` de la lista abierta `delta` posiciones (±1).
// La fila se mueve al instante en local y el cambio se sube a YouTube Music.
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
        return;   // ya está en un extremo
    // Vecino y sentido ANTES de mutar la lista local.
    const QString neighbor =
        m_tracks.at(j).toMap().value(QStringLiteral("setId")).toString();
    if (neighbor.isEmpty())
        return;
    const bool before = delta < 0;   // subir -> antes del vecino de arriba
    const QString plId = m_openPlaylistId;
    m_tracks.move(i, j);
    forgetCachedPlaylist(QStringLiteral("list:") + plId);
    emit changed();
    runPlaylistAction({ytmApiPath(), QStringLiteral("movepl"), plId, sid,
                       neighbor, before ? QStringLiteral("before")
                                        : QStringLiteral("after")},
                      QStringLiteral("move"));
}

// Quita de la lista abierta la pista con ese setVideoId. Se espera a que
// YouTube confirme para borrar la fila (así no queda descuadrado si falla).
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

    // Fichero local descargado: el .info.json hermano guarda el videoId real de
    // YouTube. Así las pistas locales se pueden "marcar" y sincronizar con YT
    // Music igual que las de la nube. Se cachea por ruta (I/O sólo la 1ª vez).
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
    // La lista «Me gusta» (LM) acaba de quedar vieja en cualquier caso: se
    // descarta su caché (memoria y disco) para que la próxima apertura traiga
    // el contenido fresco de YouTube Music.
    forgetCachedPlaylist(QStringLiteral("list:LM"));
    // Y si la lista LM está abierta ahora mismo: al quitar el corazón la fila
    // desaparece al instante (en YT esa pista ya no está en «Me gusta»). Sólo
    // en la vista «Me gusta»: en otras listas abiertas el unlike no toca filas.
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
    // Persistir el conjunto local (conservando m_likedTs) para que el arranque
    // pinte el corazón al instante y no pierda el voto recién hecho.
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

    // 1) Carga inmediata desde disco (sin red): el conjunto queda listo al
    //    instante y las filas pintan el corazón sin esperar al fetch.
    if (loadLikedFromDisk()) {
        m_likedReady = true;
        ++m_likedRevision;
        emit likedChanged();
    }

    // 2) Sincronización automática: la consulta a la red se lanza siempre que
    //    hay sesión (arranque y login), no sólo cuando la caché caduca. Así
    //    los «me gusta» que diste —o quitaste— en otro sitio se reflejan solos
    //    sin pulsar nada. Es asíncrona y barata (una página de la API interna).
    launchLikedFetch();
}

// Lanza el fetch de red del conjunto "me gusta" (m_likedProc). No mira la TTL
// ni la caché: lo llama el refresco perezoso (ya filtrado) y syncLiked().
void Catalog::launchLikedFetch()
{
    if (!ytmLoggedIn() || m_likedProc.state() != QProcess::NotRunning)
        return;
    if (!QFile::exists(ytmApiPath()))
        return;
    m_likedProc.setProgram(QStringLiteral("python3"));
    m_likedProc.setArguments({ytmApiPath(), QStringLiteral("playlist"),
                              QStringLiteral("LM")});
    m_likedProc.start();
}

// ------------------------------------------------- caché de "me gusta" ----

// Fichero JSON junto al estado de la biblioteca (library.json).
QString Catalog::likedFile()
{
    const QString dir = QDir::homePath() + QStringLiteral("/.local/state/lotus-tune");
    QDir().mkpath(dir);
    return dir + QStringLiteral("/liked.json");
}

// Carga el conjunto desde disco; deja m_likedTs con su marca de tiempo.
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

// ------------------------------------------- caché de listas (memoria) ----

// Normaliza el `list=<id>` de YouTube: la misma lista abierta por URL, por id
// o desde "mis listas" comparte entrada de caché. El resto de destinos
// (ytsearch..., SoundCloud, etc.) usan la URL tal cual.
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
        // Límite de RAM: evacuar las más antiguas por encima de 24 entradas.
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
    // También se descarta la copia en disco: si no, la próxima apertura la
    // serviría vieja (p. ej. tras quitar o reordenar una pista, o al forzar el
    // refresco de "Liked Music").
    m_cacheForgotten.insert(key);
    m_cacheDirty = true;
    m_cacheSaveTimer.start();
}

// Olvida las listas cacheadas (memoria y disco): la próxima apertura las
// recarga. Se usa al cerrar sesión y para "refrescar" la biblioteca.
void Catalog::invalidatePlaylistCache()
{
    m_playlistCache.clear();
    m_playlistTitles.clear();
    m_cacheOrder.clear();
    m_playlistCacheAt.clear();
    m_cacheForgotten.clear();
    // El fichero también se olvida: sin esto, reabrir una lista "invalidada"
    // volvería a servirse desde disco.
    QFile::remove(playlistsFile());
    m_cacheDirty = false;
}

// ------------------------------------------------- caché en disco ----

// Caché en disco de listas ya cargadas (persiste entre reinicios). Vive en la
// caché del usuario, como streams.json del reproductor.
QString Catalog::playlistsFile()
{
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
           + QStringLiteral("/playlists.json");
}

// Lee el fichero al arrancar y siembra la caché en memoria con las entradas
// más recientes (respetando el tope de RAM de cachePlaylist). No lo marca
// sucio: lo leído no necesita volver a escribirse. Un fichero corrupto o
// ilegible se ignora sin más.
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

    // Orden cronológico ascendente: al sembrar con cachePlaylist() (FIFO de 24)
    // quedan en memoria las más recientes, justo como si se hubieran abierto.
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
            continue;   // caducada: no se siembra (se podará al guardar)
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

// Sirve una lista desde el fichero (si sigue dentro de la TTL) cuando no está
// en memoria. Lo usa la vía rápida de run() antes de lanzar ninguna consulta.
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

// Marca una lista recién cargada con su marca de tiempo y programa el volcado
// diferido (no se escribe en disco en cada carga).
void Catalog::rememberPlaylistForDisk(const QString &key)
{
    if (key.isEmpty())
        return;
    m_cacheForgotten.remove(key);   // recién cargada: ya no hay que borrarla
    m_playlistCacheAt.insert(key, QDateTime::currentSecsSinceEpoch());
    m_cacheDirty = true;
    m_cacheSaveTimer.start();
}

// Vuelca la caché a disco. Parte de lo que ya había en el fichero (entradas
// antiguas que no cupieron en memoria), lo fusiona con la caché en memoria,
// poda lo caducado y recorta a las 300 entradas más recientes.
void Catalog::savePlaylistCache()
{
    if (!m_cacheDirty)
        return;
    m_cacheDirty = false;
    const qint64 now = QDateTime::currentSecsSinceEpoch();

    // El fichero se escribe entero y compacto; si estuviera corrupto se parte
    // de vacío (la memoria lo regenera).
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

    // Poda: fuera lo caducado, y sólo las 300 entradas más recientes.
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
                  return a.first > b.first;   // más recientes primero
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
    // La sesión se fue: olvidar listas cacheadas y el "me gusta" persistido.
    invalidatePlaylistCache();
    QFile::remove(likedFile());
    m_loginError.clear();
    setLoginState(QString());
    // Al cerrar sesión, olvidar el conjunto de "me gusta".
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
        // La radio no reemplaza la cola: el reproductor la usa solo para
        // ampliar «a continuación» tras la pista semilla. Sí se cachea con su
        // clave normal (list:RDAMVM<semilla>), para que la precarga que se
        // hace en segundo plano desde Inicio deje la lista lista y abrirla
        // desde «Recomendado para ti» sea instantánea.
        cachePlaylist(m_pendingKey, list, m_pendingTitle);
        rememberPlaylistForDisk(m_pendingKey);
        emit radioReady(m_radioSeed, list);
        // Si mientras cargaba el usuario abrió la radio a mano, ese mismo
        // resultado sirve como lista abierta (no se vuelve a descargar).
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
        // Guarda en la caché en memoria: reabrir esta lista será instantáneo.
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
    // Los «recientes» anteriores a la v1 no guardaban `setId`, así que no se
    // puede saber cuáles sonaron dentro de una playlist. Se marcan como
    // «legacy»: no se pintan como canciones sueltas, pero siguen alimentando
    // «Recomendado para ti» hasta que se van cayendo solos.
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
