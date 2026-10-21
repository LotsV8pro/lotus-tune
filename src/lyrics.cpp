#include "lyrics.h"

#include "player.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDateTime>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QHash>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QUrlQuery>
#include <QVariantMap>

#include <algorithm>

#include <QDebug>

// LRCLIB: API pública, sin clave. GET devuelve la mejor coincidencia (o 404);
// search devuelve una lista. El User-Agent es obligatorio por cortesía con el
// servicio (y para que no nos bloqueen como cliente anónimo).
static const char *kUserAgent = "LotusTune/0.1 (https://github.com/lotus-tune)";
static const char *kApiGet = "https://lrclib.net/api/get";
static const char *kApiSearch = "https://lrclib.net/api/search";
// NetEase Cloud Music: también sin clave. /api/search/get localiza el id de la
// canción y /api/song/lyric devuelve el LRC en "lrc.lyric". Es nuestro plan C
// cuando LRCLIB solo tiene texto plano (sin timestamps).
static const char *kNeteaseSearch = "https://music.163.com/api/search/get";
static const char *kNeteaseLyric = "https://music.163.com/api/song/lyric";
// ---- YouTube Music (primera fuente) --------------------------------------
// Interfaz interna del cliente web/móvil de YouTube Music. No lleva clave de
// autorización ni cookies: se consulta en anónimo (ver nota en lyrics.h) con
// la misma key pública que usa el reproductor web.
static const char *kYtmApi = "https://music.youtube.com/youtubei/v1/";
static const char *kYtmKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30";
static const char *kYtmWebClient = "WEB_REMIX";
static const char *kYtmWebVersion = "1.20241001.01.00";
static const char *kYtmAndroidClient = "ANDROID_MUSIC";
static const char *kYtmAndroidVersion = "7.27.52";
static const char *kYtmWebUa =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
static const char *kYtmAppUa =
    "com.google.android.apps.youtube.music/7.27.52 "
    "(Linux; U; Android 14) gzip";
// params de búsqueda de YouTube Music con filtro «Canciones».
static const char *kYtmSearchParams = "EgWKAQIIAWoKEAoQAxAEEAkQBQ==";
// Cuántos vídeos se prueban antes de rendirse con YouTube Music. Cada intento
// son dos peticiones cortas (next + browse); con 3 cubrimos los casos en los
// que el vídeo oficial no tiene letra y sí la tiene la subida alternativa.
static const int kYtmMaxCandidates = 3;
// Suficiente para redes domésticas; evita quedarnos "loading" para siempre.
static const int kTimeoutMs = 10000;

Lyrics::Lyrics(QObject *parent)
    : QObject(parent)
    , m_net(new QNetworkAccessManager(this))
{
}

// Normaliza para comparar: sin mayúsculas, tildes, espacios ni puntuación.
static QString norm(const QString &s)
{
    static const QRegularExpression junk(
        QStringLiteral("[^\\p{L}\\p{N}]+"));
    return s.normalized(QString::NormalizationForm_KD)
        .toLower()
        .remove(junk);
}

// Quita las coletillas entre paréntesis o corchetes: "Not Ready to Die
// (From "Call of the Dead")" -> "Not Ready to Die". La caché de Sonora
// guarda el título pelado, así que para compararlo hay que pelarlo igual.
static QString stripParenthetical(const QString &s)
{
    QString out = s;
    static const QRegularExpression re(
        QStringLiteral("\\s*[\\(\\[].*$"));
    out.remove(re);
    return out.trimmed();
}

// Kugou y algunas letras de Apple Music enmascaran la palabra que no se
// puede decir con asteriscos ("your **** nightmare"). El widget del shell
// las quita; la app las pintaba literales y, además, su tramo de tiempo
// rompía el barrido palabra a palabra. El asterisco va DENTRO del token
// ("your **** "), así que hay que limpiarlo, no descartar el token entero.
// OJO: el espacio final de la palabra se conserva ("your "), si no las
// palabras salen pegadas al pintarlas.
static QString stripMask(const QString &s)
{
    static const QRegularExpression re(QStringLiteral("\\s*\\*+"));
    QString out = s;
    out.remove(re);
    return out;
}

// ¿El token es sólo una máscara? (entonces se descarta entero)
static bool isMaskedToken(const QString &s)
{
    const QString t = s.trimmed();
    if (t.isEmpty())
        return true;
    for (const QChar &c : t) {
        if (c != QLatin1Char('*'))
            return false;
    }
    return true;
}

// Quita las máscaras de una línea de letra.
static QString stripMaskedTokens(const QString &text)
{
    QString out;
    const QStringList parts = text.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    for (const QString &p : parts) {
        const QString clean = stripMask(p);
        if (clean.isEmpty())
            continue;
        if (!out.isEmpty())
            out += QLatin1Char(' ');
        out += clean;
    }
    return out;
}

void Lyrics::fetch(const QString &artist, const QString &title,
                   double durationSeconds, const QString &videoId)
{
    const QString a = artist.trimmed();
    const QString t = title.trimmed();

    // La clave identifica la pista en curso. Cualquier respuesta cuya clave no
    // coincida con m_trackKey se descarta (el usuario ya cambió de canción).
    // `m_gen` cubre el caso de dos fetch() seguidos con la misma clave.
    m_trackKey = a + QStringLiteral(" - ") + t;
    m_artist = a;
    m_title = t;
    m_duration = qMax(0, qRound(durationSeconds));
    m_videoId = videoId.trimmed();
    m_exactTried = m_videoId.isEmpty();
    m_neteaseTried = false;
    ++m_gen;

    m_loading = true;
    m_hasLyrics = false;
    m_hasSynced = false;
    m_plain.clear();
    m_synced.clear();
    m_error.clear();
    m_syncSource.clear();
    m_plainSource.clear();
    m_lines.clear();
    m_ytmIds.clear();
    m_ytmIdx = 0;
    m_ytmBrowseId.clear();
    publishTrack();   // el widget del shell se entera antes de que llegue nada
    emit changed();

    if (t.isEmpty()) {
        fail(QStringLiteral("Sin letra disponible"));
        return;
    }

    qInfo().noquote() << QString("[lyrics] buscar pista=\"%1\" dur=%2s")
                             .arg(m_trackKey)
                             .arg(m_duration);

    // Primero la caché local de Sonora: es instantánea y trae tiempos por
    // palabra (karaoke real). Si no está, se sigue con la red.
    if (trySonoraCache()) {
        finish();
        return;
    }
    // La caché puede tener la pista bajo otro videoId (el que Sonora
    // cacheó): se busca por título y artista, como hace el widget del shell.
    if (trySonoraByTitle()) {
        finish();
        return;
    }

    startYtm();
}

// Plan clásico (LRCLIB -> NetEase), al que se recurre cuando YouTube Music no
// tiene letra para la pista.
void Lyrics::startLrclib()
{
    QUrl url(QString::fromLatin1(kApiGet));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("artist_name"), m_artist);
    q.addQueryItem(QStringLiteral("track_name"), m_title);
    if (m_duration > 0)
        q.addQueryItem(QStringLiteral("duration"), QString::number(m_duration));
    url.setQuery(q);
    request(url, Stage::LrclibGet, m_trackKey);
}

void Lyrics::request(const QUrl &url, Stage stage, const QString &key)
{
    QNetworkRequest req(url);
    req.setHeader(QNetworkRequest::UserAgentHeader,
                  QString::fromLatin1(kUserAgent));
    req.setRawHeader("Accept", "application/json");
    // Qt6 sigue redirecciones de forma segura por defecto; lo dejamos explícito
    // para que un 301/302 del CDN no corte el fetch.
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    if (url.host().endsWith(QLatin1String("163.com")))
        req.setRawHeader("Referer", "https://music.163.com");
    req.setTransferTimeout(kTimeoutMs);

    QNetworkReply *reply = m_net->get(req);
    // La clave viaja con el reply: el handler la compara con m_trackKey.
    reply->setProperty("trackKey", key);
    reply->setProperty("gen", m_gen);
    connect(reply, &QNetworkReply::finished, this, [this, reply, stage] {
        const QString key = reply->property("trackKey").toString();
        switch (stage) {
        case Stage::YtmSearch:      onYtmSearchReply(reply, key); break;
        case Stage::YtmNext:        onYtmNextReply(reply, key); break;
        case Stage::YtmBrowse:      onYtmBrowseReply(reply, key); break;
        case Stage::LrclibGet:    onGetReply(reply, key); break;
        case Stage::LrclibSearch: onSearchReply(reply, key); break;
        case Stage::NeteaseSearch: onNeteaseSearchReply(reply, key); break;
        case Stage::NeteaseLyric:  onNeteaseLyricReply(reply, key); break;
        }
    });
}

// POST con cuerpo JSON para la API interna de YouTube Music. Sin cookies ni
// Authorization: en anónimo funciona (autenticado la API devuelve
// «La letra no está disponible» o 400).
void Lyrics::postJson(const QUrl &url, const QJsonObject &body, Stage stage,
                      const QString &key)
{
    QNetworkRequest req(url);
    req.setRawHeader("User-Agent",
                     stage == Stage::YtmBrowse
                         ? QByteArray(kYtmAppUa)
                         : QByteArray(kYtmWebUa));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    req.setRawHeader("Accept", "application/json");
    req.setTransferTimeout(kTimeoutMs);

    QNetworkReply *reply =
        m_net->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    reply->setProperty("trackKey", key);
    reply->setProperty("gen", m_gen);
    connect(reply, &QNetworkReply::finished, this, [this, reply, stage] {
        const QString key = reply->property("trackKey").toString();
        switch (stage) {
        case Stage::YtmSearch: onYtmSearchReply(reply, key); break;
        case Stage::YtmNext:   onYtmNextReply(reply, key); break;
        case Stage::YtmBrowse: onYtmBrowseReply(reply, key); break;
        default:               reply->deleteLater(); break;
        }
    });
}

// ¿La respuesta corresponde a un fetch() anterior (misma pista o no)?
static bool isStale(QNetworkReply *reply, const QString &key,
                    const QString &currentKey, int currentGen)
{
    return key != currentKey || reply->property("gen").toInt() != currentGen;
}

// ---- YouTube Music --------------------------------------------------------

// Cuerpo base con el `context` que exige la API interna de YouTube Music.
// `android` añade los campos que el cliente ANDROID_MUSIC necesita para que el
// servidor devuelva la letra con tiempos (solo la app móvil la sirve).
static QJsonObject ytmContext(const char *client, const char *version,
                              bool android)
{
    QJsonObject cli;
    cli[QStringLiteral("clientName")] = QString::fromLatin1(client);
    cli[QStringLiteral("clientVersion")] = QString::fromLatin1(version);
    cli[QStringLiteral("hl")] = QStringLiteral("es");
    cli[QStringLiteral("gl")] = QStringLiteral("ES");
    if (android) {
        cli[QStringLiteral("androidSdkVersion")] = 34;
        cli[QStringLiteral("userAgent")] = QString::fromLatin1(kYtmAppUa);
    }
    QJsonObject user;
    QJsonObject ctx;
    ctx[QStringLiteral("client")] = cli;
    ctx[QStringLiteral("user")] = user;
    QJsonObject body;
    body[QStringLiteral("context")] = ctx;
    return body;
}

static QUrl ytmUrl(const char *endpoint)
{
    return QUrl(QString::fromLatin1(kYtmApi)
                + QString::fromLatin1(endpoint)
                + QStringLiteral("?alt=json&key=")
                + QString::fromLatin1(kYtmKey));
}

// Recorre un árbol JSON y acumula todos los valores de `key` (búsquedas
// profundas: así no dependemos de la ruta exacta, que cambia de versión).
static void collectJson(const QJsonValue &v, const QString &key, QJsonArray *out)
{
    if (v.isObject()) {
        const QJsonObject o = v.toObject();
        if (o.contains(key))
            out->append(o.value(key));
        for (auto it = o.begin(); it != o.end(); ++it)
            collectJson(it.value(), key, out);
    } else if (v.isArray()) {
        const QJsonArray arr = v.toArray();
        for (const QJsonValue &e : arr)
            collectJson(e, key, out);
    }
}

// Primera cadena de texto encontrada bajo `key` (título, videoId, etc.).
static QString firstString(const QJsonValue &v, const QString &key)
{
    if (v.isObject()) {
        const QJsonObject o = v.toObject();
        if (o.contains(key) && o.value(key).isString())
            return o.value(key).toString();
        for (auto it = o.begin(); it != o.end(); ++it) {
            const QString s = firstString(it.value(), key);
            if (!s.isEmpty())
                return s;
        }
    } else if (v.isArray()) {
        for (const QJsonValue &e : v.toArray()) {
            const QString s = firstString(e, key);
            if (!s.isEmpty())
                return s;
        }
    }
    return QString();
}

void Lyrics::startYtm()
{
    // Si la pista viene de YouTube con su videoId exacto, probar ese vídeo
    // directamente en /next (sus tiempos corresponden a la grabación en
    // reproducción; la búsqueda por título puede traer un cover u otra toma).
    if (!m_videoId.isEmpty()) {
        qInfo().noquote()
            << QString("[lyrics] youtube music: vídeo exacto %1").arg(m_videoId);
        m_ytmIds = {m_videoId};
        m_ytmIdx = 0;
        ytmNextFor(0);
        return;
    }
    QJsonObject body = ytmContext(kYtmWebClient, kYtmWebVersion, /*android=*/false);
    QString query = m_title;
    if (!m_artist.isEmpty())
        query += QLatin1Char(' ') + m_artist;
    body[QStringLiteral("query")] = query;
    body[QStringLiteral("params")] = QString::fromLatin1(kYtmSearchParams);

    qInfo().noquote()
        << QString("[lyrics] youtube music: buscar \"%1\"").arg(query);
    postJson(ytmUrl("search"), body, Stage::YtmSearch, m_trackKey);
}

// Divide en palabras normalizadas (sin tildes ni puntuación). A diferencia de
// `norm()` aquí NO se concatenan: se necesita la cobertura token a token.
static QStringList wordsOf(const QString &s)
{
    static const QRegularExpression junk(
        QStringLiteral("[^\\p{L}\\p{N}]+"));
    const QString flat = s.normalized(QString::NormalizationForm_KD)
                             .toLower();
    QStringList out;
    const QStringList parts = flat.split(junk, Qt::SkipEmptyParts);
    for (const QString &p : parts)
        if (!p.isEmpty())
            out.append(p);
    return out;
}

// Puntúa un resultado de búsqueda: 45 por título exacto, 30 si encaja
// parcialmente (p. ej. añade «(Official Video)») y 25 si el artista también
// aparece. El encaje parcial exige DOBLE cobertura para no leer la letra de
// una canción equivocada:
//   - ≥70% de las palabras del título buscado aparecen en el candidato, y
//   - ≥50% de las palabras del candidato están en el título+artista buscados.
// Sin esto, un candidato de título corto («Python») pasaba por subcadena de
// «Python Full Course for free» y se traía letra de otra canción.
static int scoreYtm(const QString &title, const QString &line,
                    const QString &wantTitle, const QString &wantArtist)
{
    const QString got = norm(title);
    const QString want = norm(wantTitle);
    if (want.isEmpty() || got.isEmpty())
        return 0;

    const QString artist = norm(wantArtist);
    int score = 0;
    if (got == want) {
        score = 45;
    } else {
        const QStringList gTok = wordsOf(title);
        const QStringList wTok = wordsOf(wantTitle);
        if (gTok.isEmpty() || wTok.isEmpty())
            return 0;

        int inGot = 0;
        for (const QString &w : wTok)
            if (gTok.contains(w))
                ++inGot;

        QStringList ctx = wTok;
        ctx.append(wordsOf(wantArtist));
        int inCtx = 0;
        for (const QString &g : gTok)
            if (ctx.contains(g))
                ++inCtx;

        const double covWant = double(inGot) / wTok.size();
        const double covGot = double(inCtx) / gTok.size();
        if (covWant < 0.70 || covGot < 0.50)
            return 0;
        score = 30;
    }

    if (!artist.isEmpty() && norm(line).contains(artist))
        score += 25;
    return score;
}

void Lyrics::onYtmSearchReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (isStale(reply, key, m_trackKey, m_gen))
        return;   // respuesta antigua

    if (reply->error() != QNetworkReply::NoError) {
        ytmGiveUp(QStringLiteral("búsqueda fallida (%1)")
                      .arg(reply->errorString()));
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();
    QJsonArray items;
    collectJson(root, QStringLiteral("musicResponsiveListItemRenderer"), &items);

    QList<QPair<int, QString>> ranked;   // puntuación, videoId
    for (const QJsonValue &v : items) {
        const QJsonObject item = v.toObject();
        const QString videoId = firstString(item, QStringLiteral("videoId"));
        if (videoId.isEmpty())
            continue;
        // Título en la primera columna; artista/álbum en la segunda.
        const QJsonArray cols = item.value(QStringLiteral("flexColumns")).toArray();
        auto runsText = [](const QJsonValue &col) {
            const QJsonArray runs = col.toObject()
                .value(QStringLiteral("musicResponsiveListItemFlexColumnRenderer"))
                .toObject().value(QStringLiteral("text"))
                .toObject().value(QStringLiteral("runs")).toArray();
            QString s;
            for (const QJsonValue &r : runs)
                s += r.toObject().value(QStringLiteral("text")).toString();
            return s;
        };
        const QString title = cols.size() > 0 ? runsText(cols.at(0)) : QString();
        const QString line = cols.size() > 1 ? runsText(cols.at(1)) : QString();
        const int score = scoreYtm(title, line, m_title, m_artist);
        if (score >= 30)
            ranked.append(qMakePair(score, videoId));
    }

    std::sort(ranked.begin(), ranked.end(),
              [](const QPair<int, QString> &a, const QPair<int, QString> &b) {
                  return a.first > b.first;
              });

    m_ytmIds.clear();
    for (int i = 0; i < ranked.size() && i < kYtmMaxCandidates; ++i)
        m_ytmIds.append(ranked.at(i).second);
    m_ytmIdx = 0;

    if (m_ytmIds.isEmpty()) {
        ytmGiveUp(QStringLiteral("ningún vídeo coincide con la pista"));
        return;
    }

    qInfo().noquote()
        << QString("[lyrics] youtube music: %1 candidato(s): %2")
               .arg(m_ytmIds.size())
               .arg(m_ytmIds.join(QLatin1String(", ")));
    ytmNextFor(0);
}

void Lyrics::ytmNextFor(int index)
{
    if (index >= m_ytmIds.size()) {
        if (!m_exactTried) {
            // El vídeo exacto en reproducción no tenía letra: se busca por
            // título/artista (respaldo clásico) una sola vez.
            m_exactTried = true;
            m_videoId.clear();
            m_ytmIds.clear();
            startYtm();
            return;
        }
        ytmGiveUp(QStringLiteral("agotados los %1 vídeos candidatos")
                      .arg(m_ytmIds.size()));
        return;
    }
    m_ytmIdx = index;

    QJsonObject body = ytmContext(kYtmWebClient, kYtmWebVersion, /*android=*/false);
    body[QStringLiteral("videoId")] = m_ytmIds.at(index);
    postJson(ytmUrl("next"), body, Stage::YtmNext, m_trackKey);
}

// Localiza la pestaña «Letra» (Lyrics/Letra) y su browseId MPLYt_*. Si la
// pestaña viene `unselectable` YouTube no va a servir la letra para ese vídeo,
// así que se pasa al siguiente candidato sin siquiera pedir el browse.
static QString lyricsBrowseId(const QJsonObject &root, bool *unselectable)
{
    *unselectable = false;
    QJsonArray tabs;
    collectJson(root, QStringLiteral("tabRenderer"), &tabs);
    for (const QJsonValue &v : tabs) {
        const QJsonObject tab = v.toObject();
        const QString title = tab.value(QStringLiteral("title")).toString();
        if (title != QLatin1String("Lyrics") && title != QLatin1String("Letra"))
            continue;
        const QJsonObject ep = tab.value(QStringLiteral("endpoint")).toObject()
                                   .value(QStringLiteral("browseEndpoint")).toObject();
        const QString id = ep.value(QStringLiteral("browseId")).toString();
        if (id.isEmpty())
            continue;
        *unselectable = tab.value(QStringLiteral("unselectable")).toBool();
        return id;
    }
    return QString();
}

void Lyrics::onYtmNextReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (isStale(reply, key, m_trackKey, m_gen))
        return;   // respuesta antigua

    if (reply->error() != QNetworkReply::NoError) {
        qInfo().noquote()
            << QString("[lyrics] youtube music: next falló (%1), vídeo %2")
                   .arg(reply->errorString())
                   .arg(m_ytmIdx + 1);
        ytmNextFor(m_ytmIdx + 1);
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();
    bool unselectable = false;
    const QString browseId = lyricsBrowseId(root, &unselectable);
    if (browseId.isEmpty()) {
        qInfo().noquote()
            << QString("[lyrics] youtube music: vídeo %1 sin pestaña de letra")
                   .arg(m_ytmIdx + 1);
        ytmNextFor(m_ytmIdx + 1);
        return;
    }
    if (unselectable) {
        qInfo().noquote()
            << QString("[lyrics] youtube music: letra no disponible para el "
                       "vídeo %1, probando el siguiente").arg(m_ytmIdx + 1);
        ytmNextFor(m_ytmIdx + 1);
        return;
    }
    ytmBrowseFor(browseId);
}

void Lyrics::ytmBrowseFor(const QString &browseId)
{
    m_ytmBrowseId = browseId;
    QJsonObject body = ytmContext(kYtmAndroidClient, kYtmAndroidVersion, /*android=*/true);
    body[QStringLiteral("browseId")] = browseId;
    postJson(ytmUrl("browse"), body, Stage::YtmBrowse, m_trackKey);
}

void Lyrics::onYtmBrowseReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (isStale(reply, key, m_trackKey, m_gen))
        return;   // respuesta antigua

    if (reply->error() != QNetworkReply::NoError) {
        qInfo().noquote()
            << QString("[lyrics] youtube music: browse falló (%1)")
                   .arg(reply->errorString());
        ytmNextFor(m_ytmIdx + 1);
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();

    // Ruta real: contents.elementRenderer.newElement.type.componentType.model
    //   .timedLyricsModel.lyricsData -> { sourceMessage, timedLyricsData:[...] }
    // Buscamos por clave para tolerar cambios de ruta entre versiones.
    QJsonArray timed;
    collectJson(root, QStringLiteral("timedLyricsData"), &timed);
    if (!timed.isEmpty()) {
        const QJsonArray entries = timed.at(0).toArray();
        // Fuente (LyricFind, Musixmatch, ...) para el log.
        QJsonArray sources;
        collectJson(root, QStringLiteral("sourceMessage"), &sources);
        const QString source = sources.isEmpty()
            ? QStringLiteral("youtube music")
            : QStringLiteral("youtube music · %1")
                  .arg(sources.at(0).toString());

        // Se genera un LRC con el mismo formato que el resto de fuentes para
        // que lo parsee un único código (parseLrc).
        QString lrc;
        int withTime = 0;
        for (const QJsonValue &v : entries) {
            const QJsonObject e = v.toObject();
            const QString text = e.value(QStringLiteral("lyricLine")).toString();
            const QJsonValue cr = e.value(QStringLiteral("cueRange"));
            const QJsonValue start = cr.toObject()
                                         .value(QStringLiteral("startTimeMilliseconds"));
            if (text.trimmed().isEmpty())
                continue;
            if (start.isUndefined() || start.isNull())
                continue;
            const qint64 ms = start.isString()
                ? start.toString().toLongLong()
                : qint64(start.toDouble());
            const int mm = int(ms / 60000);
            const int ss = int((ms % 60000) / 1000);
            const int cs = int((ms % 1000) / 10);
            lrc += QStringLiteral("[%1:%2.%3]%4\n")
                       .arg(mm, 2, 10, QLatin1Char('0'))
                       .arg(ss, 2, 10, QLatin1Char('0'))
                       .arg(cs, 2, 10, QLatin1Char('0'))
                       .arg(text);
            ++withTime;
        }

        if (withTime >= 2
            && adoptSynced(lrc, source, /*filterCredits=*/false)) {
            qInfo().noquote()
                << QString("[lyrics] youtube music: %1 líneas con tiempos (%2)")
                       .arg(withTime)
                       .arg(source);
            finish();
            return;
        }
        // Sin tiempos utilizables: nos quedamos el texto plano y seguimos
        // mirando los demás candidatos por si esos sí llevan tiempos.
        QString plain;
        for (const QJsonValue &v : entries) {
            const QString t =
                v.toObject().value(QStringLiteral("lyricLine")).toString();
            if (!t.trimmed().isEmpty())
                plain += t + QLatin1Char('\n');
        }
        rememberPlain(plain, "ytmusic");
    }

    // O bien no había tiempos, o bien solo texto plano: siguiente candidato.
    ytmNextFor(m_ytmIdx + 1);
}

// YouTube Music no ha dado letra: se pasa al plan clásico (LRCLIB/NetEase).
void Lyrics::ytmGiveUp(const QString &why)
{
    qInfo().noquote()
        << QString("[lyrics] youtube music: %1 -> probando LRCLIB").arg(why);
    m_ytmIds.clear();
    startLrclib();
}

// ---- LRCLIB ---------------------------------------------------------------

void Lyrics::onGetReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (isStale(reply, key, m_trackKey, m_gen))
        return;   // respuesta antigua

    const int status =
        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray body = reply->readAll();

    // 404 (o cualquier fallo) => plan B: búsqueda por nombre.
    if (reply->error() == QNetworkReply::NoError && status < 400) {
        const QJsonObject obj = QJsonDocument::fromJson(body).object();
        if (!obj.isEmpty()) {
            applyPayload(obj);
            if (m_hasSynced) {
                finish();
                return;
            }
            if (!m_plain.trimmed().isEmpty())
                qInfo() << "[lyrics] lrclib get: solo texto plano,"
                        << "buscando una versión sincronizada";
        }
    } else {
        qInfo() << "[lyrics] lrclib get falló (" << status << "), probando search";
    }

    startSearch();
}

void Lyrics::startSearch()
{
    QUrl url(QString::fromLatin1(kApiSearch));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("track_name"), m_title);
    q.addQueryItem(QStringLiteral("artist_name"), m_artist);
    url.setQuery(q);
    request(url, Stage::LrclibSearch, m_trackKey);
}

void Lyrics::onSearchReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (isStale(reply, key, m_trackKey, m_gen))
        return;   // respuesta antigua

    if (reply->error() != QNetworkReply::NoError) {
        qInfo() << "[lyrics] lrclib search falló:" << reply->errorString();
        settleOrFail();
        return;
    }

    const QJsonArray arr = QJsonDocument::fromJson(reply->readAll()).array();
    for (const QJsonValue &v : arr) {
        const QJsonObject obj = v.toObject();
        const QString synced = obj.value(QStringLiteral("syncedLyrics")).toString();
        const QString plain = obj.value(QStringLiteral("plainLyrics")).toString();
        if (!synced.trimmed().isEmpty()) {
            applyPayload(obj);
            if (m_hasSynced) {
                finish();
                return;
            }
        } else {
            rememberPlain(plain, "lrclib");
        }
    }

    qInfo() << "[lyrics] lrclib search:" << arr.size()
            << "resultados, ninguno sincronizado -> probando NetEase";
    startNetease();
}

// ---- NetEase Cloud Music --------------------------------------------------

void Lyrics::startNetease()
{
    if (m_title.trimmed().isEmpty()) {
        settleOrFail();
        return;
    }

    // La búsqueda funciona mejor con "título artista".
    QString query = m_title;
    if (!m_artist.isEmpty())
        query += QStringLiteral(" ") + m_artist;

    const QUrl url = QUrl::fromEncoded(
        QByteArray(kNeteaseSearch) + "?s="
        + QUrl::toPercentEncoding(query)
        + "&type=1&limit=10");

    qInfo().noquote() << QString("[lyrics] netease: buscar \"%1\"").arg(query);
    request(url, Stage::NeteaseSearch, m_trackKey);
}

void Lyrics::onNeteaseSearchReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (isStale(reply, key, m_trackKey, m_gen))
        return;   // respuesta antigua

    if (reply->error() != QNetworkReply::NoError) {
        qInfo() << "[lyrics] netease search falló:" << reply->errorString();
        settleOrFail();
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();
    const QJsonArray songs =
        root.value(QStringLiteral("result")).toObject()
            .value(QStringLiteral("songs")).toArray();

    int best = -1;
    int bestScore = 0;
    for (int i = 0; i < songs.size(); ++i) {
        const int s = scoreNetease(songs.at(i).toObject());
        if (s > bestScore) {
            bestScore = s;
            best = i;
        }
    }
    if (best < 0) {
        qInfo() << "[lyrics] netease: sin coincidencia útil de"
                << songs.size() << "candidatas";
        settleOrFail();
        return;
    }

    const QJsonObject song = songs.at(best).toObject();
    const int id = song.value(QStringLiteral("id")).toInt();
    qInfo().noquote()
        << QString("[lyrics] netease: elegida \"%1\" (id=%2, puntuación=%3)")
               .arg(song.value(QStringLiteral("name")).toString())
               .arg(id)
               .arg(bestScore);

    const QUrl url = QUrl::fromEncoded(
        QByteArray(kNeteaseLyric) + "?id=" + QByteArray::number(id)
        + "&lv=-1&kv=-1&tv=-1");
    request(url, Stage::NeteaseLyric, m_trackKey);
}

void Lyrics::onNeteaseLyricReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (isStale(reply, key, m_trackKey, m_gen))
        return;   // respuesta antigua

    if (reply->error() != QNetworkReply::NoError) {
        qInfo() << "[lyrics] netease lyric falló:" << reply->errorString();
        settleOrFail();
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();
    if (root.value(QStringLiteral("nolyric")).toBool()
        || root.value(QStringLiteral("uncollected")).toBool()) {
        qInfo() << "[lyrics] netease: la canción no tiene letra";
        settleOrFail();
        return;
    }

    const QString lrc = root.value(QStringLiteral("lrc")).toObject()
                            .value(QStringLiteral("lyric")).toString();
    // "klyric" es la misma letra con los tiempos POR PALABRA: si está, se
    // usa para el karaoke (el widget del shell también va a por ella).
    const QString klyric = root.value(QStringLiteral("klyric")).toObject()
                                .value(QStringLiteral("lyric")).toString();
    if (!klyric.trimmed().isEmpty()) {
        QVector<LrcLine> worded = parseLrcWords(klyric);
        int withWords = 0;
        for (const LrcLine &l : worded) {
            if (l.words.size() > 1)
                ++withWords;
        }
        if (withWords > 1) {
            qInfo() << "[lyrics] netease: karaoke con tiempos por palabra ("
                    << withWords << "líneas)";
            m_synced = klyric;
            if (adoptWorded(std::move(worded),
                            QStringLiteral("netease · karaoke"))) {
                finish();
                return;
            }
        }
    }
    // Sin tiempos por palabra: sólo se usa si aún no tenemos letra
    // sincronizada (no se pisa una letra buena con otra peor).
    if (!m_hasSynced && adoptSynced(lrc, "netease", /*filterCredits=*/true)) {
        finish();
        return;
    }
    if (m_hasSynced) {
        // Ya teníamos letra: NetEase no aporta nada mejor.
        settleOrFail();
        return;
    }

    qInfo() << "[lyrics] netease: LRC no utilizable"
            << (lrc.trimmed().isEmpty() ? "(vacío)" : "(solo créditos/sin tiempos)");
    settleOrFail();
}

// Elige la canción de NetEase que mejor encaja con título/artista/duración.
// Puntuación orientativa: 45 por título exacto, 30 si solo coincide en parte,
// 35 por artista y 25 por duración. Se exige al menos 45 (título exacto).
int Lyrics::scoreNetease(const QJsonObject &song) const
{
    const QString wantTitle = norm(m_title);
    if (wantTitle.isEmpty())
        return 0;

    const QString gotTitle = norm(song.value(QStringLiteral("name")).toString());
    int score = 0;
    if (gotTitle == wantTitle)
        score += 45;
    else if (!gotTitle.isEmpty()
             && (gotTitle.contains(wantTitle) || wantTitle.contains(gotTitle)))
        score += 30;
    else
        return 0;   // ni siquiera el título encaja

    const QString wantArtist = norm(m_artist);
    if (!wantArtist.isEmpty()) {
        const QJsonArray artists =
            song.value(QStringLiteral("artists")).toArray();
        for (const QJsonValue &v : artists) {
            const QString a =
                norm(v.toObject().value(QStringLiteral("name")).toString());
            if (!a.isEmpty() && (a == wantArtist || wantArtist.contains(a)
                                 || a.contains(wantArtist))) {
                score += 35;
                break;
            }
        }
    }

    // NetEase da la duración en milisegundos.
    const int ms = song.value(QStringLiteral("duration")).toInt();
    if (m_duration > 0 && ms > 0) {
        const int diff = qAbs(ms / 1000 - m_duration);
        if (diff <= 4)
            score += 25;
        else if (diff <= 12)
            score += 12;
    }
    return score;
}

// ---- resultado ------------------------------------------------------------

void Lyrics::applyPayload(const QJsonObject &obj)
{
    rememberPlain(obj.value(QStringLiteral("plainLyrics")).toString(), "lrclib");
    const QString synced = obj.value(QStringLiteral("syncedLyrics")).toString();
    if (!synced.trimmed().isEmpty())
        adoptSynced(synced, "lrclib", /*filterCredits=*/true);
}

void Lyrics::rememberPlain(const QString &plain, const char *source)
{
    if (!m_plain.trimmed().isEmpty() || plain.trimmed().isEmpty())
        return;
    m_plain = plain;
    m_plainSource = QString::fromLatin1(source);
}

bool Lyrics::adoptSynced(const QString &lrc, const QString &source,
                         bool filterCredits)
{
    QVector<LrcLine> parsed = parseLrc(lrc, filterCredits);
    if (parsed.size() < 2)
        return false;   // casi nada: no compensa ocultar el texto plano

    m_synced = lrc;
    m_lines = std::move(parsed);
    m_hasSynced = true;
    m_syncSource = source;
    return true;
}

bool Lyrics::adoptWorded(QVector<LrcLine> lines, const QString &source)
{
    if (lines.size() < 2)
        return false;
    m_lines = std::move(lines);
    m_hasSynced = true;
    m_syncSource = source;
    return true;
}

// Convierte {"secs":N,"nanos":M} a segundos.
static double secsOf(const QJsonValue &v)
{
    const QJsonObject o = v.toObject();
    return o.value(QStringLiteral("secs")).toDouble()
        + o.value(QStringLiteral("nanos")).toDouble() / 1e9;
}

bool Lyrics::trySonoraCache()
{
    if (m_videoId.isEmpty())
        return false;
    const QString path = QDir::homePath()
        + QStringLiteral("/.cache/sonora/cache.sqlite");
    if (!QFile::exists(path))
        return false;

    // Conexión propia y efímera, en solo lectura.
    QByteArray raw;
    const QString conn = QStringLiteral("sonora_lyrics");
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), conn);
        db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        db.setDatabaseName(path);
        if (db.open()) {
            QSqlQuery q(db);
            q.prepare(QStringLiteral("SELECT value FROM lyrics WHERE key LIKE :k "
                                     "ORDER BY stored DESC LIMIT 1"));
            q.bindValue(QStringLiteral(":k"),
                        QStringLiteral("youtube:%1:lyrics:%").arg(m_videoId));
            if (q.exec() && q.next())
                raw = q.value(0).toString().toUtf8();
            db.close();
        }
    }
    QSqlDatabase::removeDatabase(conn);

    if (raw.isEmpty())
        return false;

    const QJsonArray hits =
        QJsonDocument::fromJson(raw).object().value(QStringLiteral("hits")).toArray();

    // Se elige el hit con más líneas "palabreadas"; a igualdad, el de fuente
    // más fiable (Apple Music trae los tiempos por palabra más exactos).
    static const QHash<QString, int> rank{
        { QStringLiteral("Apple Music"), 0 }, { QStringLiteral("Musixmatch"), 1 },
        { QStringLiteral("NetEase"), 2 },     { QStringLiteral("Kugou"), 3 },
        { QStringLiteral("LrcLib"), 4 } };

    QVector<LrcLine> best;
    int bestWorded = -1;
    int bestRank = 99;
    QString bestSource;
    for (const QJsonValue &hv : hits) {
        const QJsonObject h = hv.toObject();
        const QJsonArray ls = h.value(QStringLiteral("lyrics")).toObject()
                                  .value(QStringLiteral("Synced")).toObject()
                                  .value(QStringLiteral("lines")).toArray();
        QVector<LrcLine> parsed;
        int worded = 0;
        for (const QJsonValue &lv : ls) {
            const QJsonObject lo = lv.toObject();
            const QString text =
                lo.value(QStringLiteral("text")).toString().trimmed();
            if (text.isEmpty())
                continue;
            LrcLine line;
            line.time = secsOf(lo.value(QStringLiteral("start")));
            line.text = stripMaskedTokens(text);
            const QJsonArray ws = lo.value(QStringLiteral("words")).toArray();
            if (ws.size() > 1) {
                ++worded;
                for (const QJsonValue &wv : ws) {
                    const QJsonObject wo = wv.toObject();
                    const QString rawWord =
                        wo.value(QStringLiteral("text")).toString();
                    if (isMaskedToken(rawWord))
                        continue;
                    const QString wt = stripMask(rawWord);
                    QVariantMap wm;
                    wm.insert(QStringLiteral("t"),
                              secsOf(wo.value(QStringLiteral("start"))));
                    wm.insert(QStringLiteral("e"),
                              secsOf(wo.value(QStringLiteral("end"))));
                    wm.insert(QStringLiteral("text"), wt);
                    line.words.append(wm);
                }
                if (line.words.size() < 2)
                    line.words.clear();
            }
            parsed.append(line);
        }
        if (parsed.size() < 2)
            continue;
        const QString src = h.value(QStringLiteral("source")).toString();
        const int rk = rank.value(src, 9);
        if (worded > bestWorded || (worded == bestWorded && rk < bestRank)) {
            bestWorded = worded;
            bestRank = rk;
            best = parsed;
            bestSource = src;
        }
    }

    if (best.size() < 2)
        return false;

    return adoptWorded(std::move(best),
                       QStringLiteral("sonora · %1").arg(
                           bestSource.isEmpty() ? QStringLiteral("cache")
                                                : bestSource));
}

// Fallback de la caché de Sonora: buscar por TÍTULO y ARTISTA, no sólo por
// el videoId. El widget del shell lo hace así (prefiltrando en SQL con
// `instr` y comparando bien cada hit) y por eso finds word timings for
// tracks whose videoId is not the one Sonora cached: the app fell back to
// YTM/LRCLIB (times per line) and the karaoke por palabra disappeared.
// Ahora la app usa la misma búsqueda y trae los tiempos por palabra.
bool Lyrics::trySonoraByTitle()
{
    if (m_title.isEmpty())
        return false;
    const QString path = QDir::homePath()
        + QStringLiteral("/.cache/sonora/cache.sqlite");
    if (!QFile::exists(path))
        return false;

    QByteArray conn;
    QVector<QByteArray> payloads;
    {
        // Conexión propia y efímera, en solo lectura.
        const QString cname = QStringLiteral("sonora_lyrics_title");
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), cname);
        db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        db.setDatabaseName(path);
        if (db.open()) {
            QSqlQuery q(db);
            // Prefiltro barato: sólo las filas cuyo texto menciona la
            // pista. La comparación buena va después, con el JSON ya
            // parseado. Se prueban varias agujas porque el título de la
            // app suele traer coletillas ("Not Ready to Die (From "Call
            // of the Dead")") que en la caché están peladas.
            QStringList needles;
            const QString bare = stripParenthetical(m_title);
            if (!bare.isEmpty() && bare != m_title)
                needles << bare;
            needles << m_title;
            // Las primeras palabras del título: un prefijo corto que
            // aparece dentro del valor de la fila.
            const QStringList words = m_title.split(QLatin1Char(' '),
                                                    Qt::SkipEmptyParts);
            if (words.size() >= 3) {
                QString head = words.mid(0, 3).join(QLatin1Char(' '));
                if (head.size() >= 6 && !needles.contains(head))
                    needles << head;
            }
            if (!m_artist.isEmpty())
                needles << m_artist;
            for (const QString &needle : needles) {
                if (needle.isEmpty())
                    continue;
                q.prepare(QStringLiteral("SELECT value FROM lyrics "
                                         "WHERE instr(lower(value), lower(?)) > 0 "
                                         "LIMIT 60"));
                q.bindValue(0, needle);
                if (q.exec()) {
                    while (q.next())
                        payloads.append(q.value(0).toString().toUtf8());
                }
                if (!payloads.isEmpty())
                    break;
            }
            db.close();
        }
        QSqlDatabase::removeDatabase(cname);
    }
    if (payloads.isEmpty())
        return false;

    qInfo() << "[lyrics] sonora por título: filas =" << payloads.size()
            << "pista =" << m_trackKey;

    static const QHash<QString, int> rank{
        { QStringLiteral("Apple Music"), 0 }, { QStringLiteral("Musixmatch"), 1 },
        { QStringLiteral("NetEase"), 2 },     { QStringLiteral("Kugou"), 3 },
        { QStringLiteral("LrcLib"), 4 } };

    const QString wantTitle = norm(m_title);
    const QString wantArtist = norm(m_artist);

    QVector<LrcLine> best;
    int bestWorded = -1;
    int bestRank = 99;
    int bestDiff = 1 << 30;
    QString bestSource;
    for (const QByteArray &raw : payloads) {
        const QJsonObject entry =
            QJsonDocument::fromJson(raw).object();
        const QJsonArray hits = entry.value(QStringLiteral("hits")).toArray();
        for (const QJsonValue &hv : hits) {
            const QJsonObject h = hv.toObject();
            // ¿Es esta pista? Título y artista (el artista puede venir con
            // remitentes: "Artista - Tema").
            const QString hTitle = norm(h.value(QStringLiteral("title")).toString());
            const QString hArtist = norm(h.value(QStringLiteral("artist")).toString());
            if (!wantTitle.isEmpty() && !hTitle.isEmpty()
                && !hTitle.contains(wantTitle) && !wantTitle.contains(hTitle))
                continue;
            if (!wantArtist.isEmpty() && !hArtist.isEmpty()
                && !hArtist.contains(wantArtist) && !wantArtist.contains(hArtist))
                continue;

            const QJsonArray ls = h.value(QStringLiteral("lyrics")).toObject()
                                      .value(QStringLiteral("Synced")).toObject()
                                      .value(QStringLiteral("lines")).toArray();
            QVector<LrcLine> parsed;
            int worded = 0;
            for (const QJsonValue &lv : ls) {
                const QJsonObject lo = lv.toObject();
                const QString text =
                    lo.value(QStringLiteral("text")).toString().trimmed();
                if (text.isEmpty())
                    continue;
                LrcLine line;
                line.time = secsOf(lo.value(QStringLiteral("start")));
                line.text = stripMaskedTokens(text);
                const QJsonArray ws = lo.value(QStringLiteral("words")).toArray();
                if (ws.size() > 1) {
                    ++worded;
                    for (const QJsonValue &wv : ws) {
                        const QJsonObject wo = wv.toObject();
                        const QString rawWord =
                            wo.value(QStringLiteral("text")).toString();
                        if (isMaskedToken(rawWord))
                            continue;
                        const QString wt = stripMask(rawWord);
                        QVariantMap wm;
                        wm.insert(QStringLiteral("t"),
                                  secsOf(wo.value(QStringLiteral("start"))));
                        wm.insert(QStringLiteral("e"),
                                  secsOf(wo.value(QStringLiteral("end"))));
                        wm.insert(QStringLiteral("text"), wt);
                        line.words.append(wm);
                    }
                    if (line.words.size() < 2)
                        line.words.clear();
                }
                parsed.append(line);
            }
            if (parsed.size() < 2)
                continue;
            const QString src = h.value(QStringLiteral("source")).toString();
            const int rk = rank.value(src, 9);
            // Duración de la pista en la caché, para desempatar.
            int diff = 0;
            const QJsonObject dur = h.value(QStringLiteral("duration")).toObject();
            if (m_duration > 0 && dur.contains(QStringLiteral("secs"))) {
                const int ds = dur.value(QStringLiteral("secs")).toInt();
                diff = qAbs(ds - m_duration);
            }
            // Orden: primero el que tiene tiempos por palabra, luego la
            // fuente más fiable y luego el que encaja en la duración.
            const bool better = (worded > bestWorded)
                || (worded == bestWorded && rk < bestRank)
                || (worded == bestWorded && rk == bestRank && diff < bestDiff);
            if (better) {
                bestWorded = worded;
                bestRank = rk;
                bestDiff = diff;
                best = parsed;
                bestSource = src;
            }
        }
    }

    if (best.size() < 2 || bestWorded <= 0)
        return false;

    return adoptWorded(std::move(best),
                       QStringLiteral("sonora · %1").arg(
                           bestSource.isEmpty() ? QStringLiteral("cache")
                                                : bestSource));
}

void Lyrics::settleOrFail()
{
    if (m_hasLyrics || !m_plain.trimmed().isEmpty())
        finish();
    else
        fail(QStringLiteral("Sin letra disponible"));
}

void Lyrics::finish()
{
    m_loading = false;
    m_hasLyrics = m_hasSynced || !m_plain.trimmed().isEmpty();
    if (m_hasLyrics)
        m_error.clear();

    // La letra que tenemos no trae tiempos por palabra: se pide a NetEase
    // su "klyric" (que sí los trae) para tener el karaoke palabra a
    // palabra, como el widget del shell. Si arrives, se sustituye.
    if (m_hasSynced && !hasWordTimings() && !m_neteaseTried
        && !m_title.trimmed().isEmpty()) {
        m_neteaseTried = true;
        startNetease();
    }

    const QString source = m_hasSynced
        ? (m_syncSource.isEmpty() ? QStringLiteral("?") : m_syncSource)
        : (m_plainSource.isEmpty() ? QStringLiteral("ninguna")
                                   : QStringLiteral("plana de ") + m_plainSource);
    // En modo sincronizado contamos las líneas con marca de tiempo; en modo
    // plano, las líneas de texto (m_lines queda vacío en ese caso).
    const int count = m_hasSynced
        ? m_lines.size()
        : m_plain.split(QLatin1Char('\n'), Qt::SkipEmptyParts).size();
    // Formato de QA: se emite SIEMPRE que haya un resultado, sea de la fuente
    // que sea (YouTube Music, LRCLIB o NetEase).
    qInfo().noquote()
        << QString("[lyrics] fuente: %1 | synced: %2 | lineas: %3 | pista=\"%4\"")
               .arg(source,
                    m_hasSynced ? QStringLiteral("sí") : QStringLiteral("no"),
                    QString::number(count),
                    m_trackKey);
    publishLines();   // vuelco completo al estado publicado (líneas o descarte)
    emit changed();
}

void Lyrics::fail(const QString &message)
{
    m_loading = false;
    m_hasLyrics = false;
    m_hasSynced = false;
    m_plain.clear();
    m_synced.clear();
    m_lines.clear();
    m_syncSource.clear();
    m_plainSource.clear();
    m_error = message;
    qInfo().noquote() << QString("[lyrics] sin letra: %1 (pista=\"%2\")")
                             .arg(message, m_trackKey);
    // Mismo formato que en finish(): QA espera la línea de fuente siempre.
    qInfo().noquote() << QString("[lyrics] fuente: ninguna | synced: no | "
                                 "pista=\"%1\"").arg(m_trackKey);
    emit changed();
}

QVariantList Lyrics::lines() const
{
    QVariantList out;
    out.reserve(m_lines.size());
    for (const LrcLine &l : m_lines) {
        QVariantMap m;
        m.insert(QStringLiteral("time"), l.time);
        m.insert(QStringLiteral("text"), l.text);
        if (!l.words.isEmpty())
            m.insert(QStringLiteral("words"), l.words);
        if (l.instrumental)
            m.insert(QStringLiteral("instrumental"), true);
        out.append(m);
    }
    return out;
}

// ---- LRC ------------------------------------------------------------------

// Convierte el LRC a un vector ordenado de {segundos, texto}. Admite varios
// timestamps por línea ("[00:12.00][01:20.00]estribillo"), acepta tanto el
// punto como los dos puntos como separador de décimas y descarta las líneas sin
// tiempo (metadatos como [ar:...]) y, opcionalmente, las de créditos.
QVector<Lyrics::LrcLine> Lyrics::parseLrc(const QString &text, bool filterCredits)
{
    static const QRegularExpression re(
        QStringLiteral("\\[(\\d{1,3}):(\\d{1,2}(?:[.:]\\d{1,3})?)\\]"));

    QVector<LrcLine> out;
    const QStringList raw = text.split(QLatin1Char('\n'));
    for (const QString &line : raw) {
        auto it = re.globalMatch(line);
        const int first = out.size();
        int lastEnd = -1;
        while (it.hasNext()) {
            const QRegularExpressionMatch m = it.next();
            const double ts = m.captured(1).toInt() * 60.0
                              + m.captured(2).replace(QLatin1Char(':'),
                                                      QLatin1Char('.')).toDouble();
            lastEnd = m.capturedEnd(0);
            out.append(LrcLine{ts, QString()});
        }
        if (lastEnd < 0)
            continue;   // sin timestamp: metadato o línea vacía
        // El texto es lo que sigue al último timestamp de la línea.
        const QString body = line.mid(lastEnd).trimmed();
        if (body.isEmpty() || (filterCredits && looksLikeCredit(body))) {
            out.resize(first);
            continue;
        }
        for (int i = first; i < out.size(); ++i)
            out[i].text = body;
    }

    std::sort(out.begin(), out.end(),
              [](const LrcLine &a, const LrcLine &b) { return a.time < b.time; });
    return out;
}

// LRC "enriquecido": además de la marca de línea trae la marca de cada
// palabra entre ángulos: [00:12.34]<00:12.34>Hola <00:12.80>mundo. Es lo
// que NetEase llama "klyric" y lo que permite el karaoke palabra a
// palabra.
QVector<Lyrics::LrcLine> Lyrics::parseLrcWords(const QString &text)
{
    static const QRegularExpression lineRe(
        QStringLiteral("\\[(\\d{1,3}):(\\d{1,2}(?:[.:]\\d{1,3})?)\\]"));
    static const QRegularExpression wordRe(
        QStringLiteral("<(\\d{1,3}):(\\d{1,2}(?:[.:]\\d{1,3})?)>"));

    QVector<LrcLine> out;
    const QStringList raw = text.split(QLatin1Char('\n'));
    for (const QString &rawLine : raw) {
        const QRegularExpressionMatch lm = lineRe.match(rawLine);
        if (!lm.hasMatch())
            continue;
        const double lineTime = lm.captured(1).toInt() * 60.0
                              + lm.captured(2).replace(QLatin1Char(':'),
                                                      QLatin1Char('.')).toDouble();
        // Texto y marcas de palabra: se corta por las marcas.
        const QString body = rawLine.mid(lm.capturedEnd(0));
        LrcLine line;
        line.time = lineTime;
        double prev = lineTime;
        int pos = 0;
        QRegularExpressionMatchIterator it = wordRe.globalMatch(body);
        while (it.hasNext()) {
            const QRegularExpressionMatch m = it.next();
            const double t = m.captured(1).toInt() * 60.0
                           + m.captured(2).replace(QLatin1Char(':'),
                                                   QLatin1Char('.')).toDouble();
            // El texto de la palabra va hasta la siguiente marca (o al fin).
            const int start = m.capturedEnd(0);
            int end = body.size();
            const QRegularExpressionMatch nx = wordRe.match(body, start);
            if (nx.hasMatch())
                end = nx.capturedStart(0);
            const QString rawWord = body.mid(start, end - start);
            if (isMaskedToken(rawWord))
                continue;
            const QString w = stripMask(rawWord);
            if (!w.isEmpty()) {
                QVariantMap wm;
                wm.insert(QStringLiteral("t"), t);
                wm.insert(QStringLiteral("e"), qMax(t + 0.05, prev > t ? prev : t + 0.05));
                wm.insert(QStringLiteral("text"), w);
                line.words.append(wm);
                prev = t;
            }
            pos = end;
        }
        // El texto de la línea: todo sin las marcas.
        QString plain = body;
        plain.remove(wordRe);
        plain = stripMaskedTokens(plain.simplified());
        if (plain.isEmpty() && !line.words.isEmpty()) {
            QStringList parts;
            for (const QVariant &wv : line.words)
                parts << wv.toMap().value(QStringLiteral("text")).toString();
            plain = parts.join(QLatin1Char(' '));
        }
        if (plain.isEmpty())
            continue;
        line.text = plain;
        if (line.words.size() < 2)
            line.words.clear();
        out.append(line);
    }
    std::sort(out.begin(), out.end(),
              [](const LrcLine &a, const LrcLine &b) { return a.time < b.time; });
    return out;
}

bool Lyrics::hasWordTimings() const
{
    for (const LrcLine &l : m_lines) {
        if (l.words.size() > 1)
            return true;
    }
    return false;
}

// Detecta las líneas de créditos que NetEase (y alguna otra fuente) intercala
// con la letra: "作词 : ..." / "Written by ...". No se muestran.
bool Lyrics::looksLikeCredit(const QString &line)
{
    static const QRegularExpression cjk(
        QStringLiteral("(作词|作曲|編曲|编曲|監制|监制|制作人|出品人|发行|录音|混音"
                       "|母带|和声|和聲|弦乐|弦樂|配唱|统筹|統籌|编写|编写|题字"
                       "|封面|特别鸣谢|特別鳴謝|词曲|歌曲)"));
    if (cjk.match(line).hasMatch())
        return true;

    static const QRegularExpression en(
        QStringLiteral("^\\s*(?:written|produced|composed|arranged|recorded"
                       "|mixed|mastered|directed)\\s+(?:by|:)"),
        QRegularExpression::CaseInsensitiveOption);
    return en.match(line).hasMatch();
}

int Lyrics::lineIndexAt(double seconds)
{
    if (m_lines.isEmpty() || seconds < 0)
        return -1;
    // Última línea cuyo tiempo sea <= seconds (búsqueda binaria).
    int lo = 0;
    int hi = m_lines.size() - 1;
    int found = -1;
    while (lo <= hi) {
        const int mid = (lo + hi) / 2;
        if (m_lines.at(mid).time <= seconds) {
            found = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return found;
}

void Lyrics::clear()
{
    ++m_gen;              // invalida cualquier respuesta aún en vuelo
    m_trackKey.clear();
    m_artist.clear();
    m_title.clear();
    m_duration = 0;
    m_ytmIds.clear();
    m_ytmIdx = 0;
    m_ytmBrowseId.clear();
    m_loading = false;
    m_hasLyrics = false;
    m_hasSynced = false;
    m_plain.clear();
    m_synced.clear();
    m_error.clear();
    m_syncSource.clear();
    m_plainSource.clear();
    m_lines.clear();
    removePublished();
    emit changed();
}

// ---- estado publicado para el escritorio (widgets inir) ---------------------
// Ver la nota en lyrics.h. Los ficheros viven en ~/.local/state/lotus-tune/ y
// el shell (LyricsService de inir) los lee con FileView: por eso el formato de
// `lines` es EL MISMO que produce lyrics.py ({t,e,text,w,instrumental}), para
// que el widget no distinga entre letra propia y letra heredada de la app.

namespace {

QString stateDir()
{
    return QDir::homePath() + QStringLiteral("/.local/state/lotus-tune");
}

bool writeJsonFile(const QString &path, const QJsonObject &obj)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    // Escritura ATOMICA (temporal + rename): los widgets del escritorio leen
    // estos ficheros en cuanto cambian y nunca deben ver JSON a medias.
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    return f.commit();
}

} // namespace

void Lyrics::setEngine(Player *player)
{
    m_engine = player;
    if (!player)
        return;
    if (!m_runtimeBeat) {
        m_runtimeBeat = new QTimer(this);
        m_runtimeBeat->setInterval(1000);
        m_runtimeBeat->setTimerType(Qt::CoarseTimer);
        connect(m_runtimeBeat, &QTimer::timeout, this, [this]() {
            publishRuntime();
            if (m_engine && m_engine->playing())
                m_runtimeBeat->start();   // latido sólo mientras suena
        });
    }
    // Play/pausa/cambio de estado: se escribe al momento (al pausar no hay
    // latido, y el widget debe saber que el reloj queda congelado aquí).
    connect(player, &Player::stateChanged, this, [this]() {
        if (m_engine && m_engine->playing()) {
            if (m_runtimeBeat && !m_runtimeBeat->isActive())
                m_runtimeBeat->start();
        } else if (m_runtimeBeat) {
            m_runtimeBeat->stop();
        }
        publishRuntime();
    });
    // Búsqueda con la pausa puesta: positionChanged no vuelve a sonar hasta
    // reanudar, así que el seek se publica a parte.
    connect(player, &Player::seeked, this, [this]() { publishRuntime(); });
}

void Lyrics::setOffset(double v)
{
    const double x = qBound(-10.0, v, 10.0);
    if (qAbs(x - m_offset) < 1e-9)
        return;
    m_offset = x;
    publishRuntime();
    emit changed();
}

void Lyrics::setKaraoke(bool on)
{
    if (m_karaoke == on)
        return;
    m_karaoke = on;
    publishLines();
    emit changed();
}

// Pista nueva (o reintento de fetch): el widget se entera al instante de qué
// suena y de que la letra está en camino, para no pedir dos veces la misma.
void Lyrics::publishTrack()
{
    if (m_trackKey.isEmpty()) {
        removePublished();
        return;
    }
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("app"), QStringLiteral("lotus-tune"));
    obj.insert(QStringLiteral("trackKey"), m_trackKey);
    obj.insert(QStringLiteral("title"), m_title);
    obj.insert(QStringLiteral("artist"), m_artist);
    obj.insert(QStringLiteral("videoId"), m_videoId);
    obj.insert(QStringLiteral("duration"), m_duration);
    obj.insert(QStringLiteral("karaoke"), m_karaoke);
    obj.insert(QStringLiteral("offset"), m_offset);
    obj.insert(QStringLiteral("status"), QStringLiteral("loading"));
    obj.insert(QStringLiteral("ts"), QDateTime::currentMSecsSinceEpoch());
    writeJsonFile(stateDir() + QStringLiteral("/lyrics.json"), obj);
    publishRuntime();
}

// Letra resuelta (o descartada): se vuelcan las líneas completas con sus
// palabras. `e` de cada línea es el inicio de la siguiente (el contrato de
// lyrics.py), con un techo razonable para no anunciar duraciones enormes.
void Lyrics::publishLines()
{
    if (m_trackKey.isEmpty())
        return;
    // El widget espera la letra por pista terminada; si la búsqueda aún sigue
    // (hubo publishTrack después), no soltamos líneas viejas en un fichero
    // que ya describe otra pista.
    QJsonArray lines;
    if (m_hasSynced) {
        for (int i = 0; i < m_lines.size(); ++i) {
            const LrcLine &l = m_lines.at(i);
            QJsonObject lo;
            lo.insert(QStringLiteral("t"), l.time);
            double e = (i + 1 < m_lines.size()) ? m_lines.at(i + 1).time
                                                : l.time + 12.0;
            e = qMin(e, l.time + 45.0);
            lo.insert(QStringLiteral("e"), e);
            lo.insert(QStringLiteral("text"), l.text);
            if (!l.words.isEmpty()) {
                // LrcLine::words son QVariantMap {t,e,text}: pasan tal cual al
                // contrato del widget, pero en formato JSON de verdad.
                QJsonArray ws;
                for (const QVariant &wv : l.words)
                    ws.append(QJsonValue::fromVariant(wv));
                lo.insert(QStringLiteral("w"), ws);
            }
            if (l.instrumental)
                lo.insert(QStringLiteral("instrumental"), true);
            lines.append(lo);
        }
    }
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("app"), QStringLiteral("lotus-tune"));
    obj.insert(QStringLiteral("trackKey"), m_trackKey);
    obj.insert(QStringLiteral("title"), m_title);
    obj.insert(QStringLiteral("artist"), m_artist);
    obj.insert(QStringLiteral("videoId"), m_videoId);
    obj.insert(QStringLiteral("duration"), m_duration);
    obj.insert(QStringLiteral("karaoke"), m_karaoke);
    obj.insert(QStringLiteral("offset"), m_offset);
    obj.insert(QStringLiteral("status"),
               m_hasSynced ? QStringLiteral("ok") : QStringLiteral("none"));
    obj.insert(QStringLiteral("lines"), lines);
    obj.insert(QStringLiteral("ts"), QDateTime::currentMSecsSinceEpoch());
    writeJsonFile(stateDir() + QStringLiteral("/lyrics.json"), obj);
    publishRuntime();
}

// Posición/estado del motor: fichero pequeño para que el widget lo relea sin
// coste. La posición es la cruda del motor; el ajuste (`offset`) viaja aparte
// y lo suma el widget, igual que la app.
void Lyrics::publishRuntime()
{
    if (m_trackKey.isEmpty())
        return;
    double pos = 0.0;
    bool playing = false;
    if (m_engine) {
        pos = m_engine->position();
        playing = m_engine->playing();
    }
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("trackKey"), m_trackKey);
    obj.insert(QStringLiteral("pos"), pos);
    obj.insert(QStringLiteral("playing"), playing);
    obj.insert(QStringLiteral("offset"), m_offset);
    obj.insert(QStringLiteral("karaoke"), m_karaoke);
    obj.insert(QStringLiteral("ts"), QDateTime::currentMSecsSinceEpoch());
    writeJsonFile(stateDir() + QStringLiteral("/lyrics-runtime.json"), obj);
}

void Lyrics::removePublished()
{
    // En vez de borrar los ficheros publicados, se sobrescriben vacíos. Un
    // FileView del shell no siempre percibe el `remove` y el widget se quedaba
    // pintando la letra de la pista anterior — el «Creep» eterno del widget—.
    QJsonObject obj;
    obj.insert(QStringLiteral("v"), 1);
    obj.insert(QStringLiteral("app"), QStringLiteral("lotus-tune"));
    obj.insert(QStringLiteral("trackKey"), QString());
    obj.insert(QStringLiteral("status"), QStringLiteral("none"));
    obj.insert(QStringLiteral("lines"), QJsonArray());
    obj.insert(QStringLiteral("ts"), QDateTime::currentMSecsSinceEpoch());
    writeJsonFile(stateDir() + QStringLiteral("/lyrics.json"), obj);

    QJsonObject rt;
    rt.insert(QStringLiteral("v"), 1);
    rt.insert(QStringLiteral("trackKey"), QString());
    rt.insert(QStringLiteral("pos"), 0.0);
    rt.insert(QStringLiteral("playing"), false);
    rt.insert(QStringLiteral("ts"), QDateTime::currentMSecsSinceEpoch());
    writeJsonFile(stateDir() + QStringLiteral("/lyrics-runtime.json"), rt);
}
