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

// Helpers of the lyrics alignment (they are defined next to the
// Musixmatch code, further down).
static QString normLine(const QString &t);
static bool isInstrumental(const QString &norm);

// LRCLIB: public API, no key. GET returns the best match (or 404); search
// returns a list. The User-Agent is required out of courtesy to the service
// (and so that we are not blocked as an anonymous client).
static const char *kUserAgent = "LotusTune/0.1 (https://github.com/lotus-tune)";
static const char *kApiGet = "https://lrclib.net/api/get";
static const char *kApiSearch = "https://lrclib.net/api/search";
// NetEase Cloud Music: also without a key. /api/search/get finds the song id
// and /song/lyric returns the LRC in "lrc.lyric". It is our plan C when
// LRCLIB only has plain text (without timestamps).
static const char *kNeteaseSearch = "https://music.163.com/api/search/get";
static const char *kNeteaseLyric = "https://music.163.com/api/song/lyric";
// ---- YouTube Music (first source) --------------------------------------
// Internal API of the YouTube Music web/mobile client. It carries no
// authorisation key and no cookies: it is queried anonymously (see the note
// in lyrics.h) with the same public key the web player uses.
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
// YouTube Music search params with the "Songs" filter.
static const char *kYtmSearchParams = "EgWKAQIIAWoKEAoQAxAEEAkQBQ==";
// How many videos are tried before giving up on YouTube Music. Each
// attempt is two short requests (next + browse); with 3 we cover the
// cases where the official video has no lyrics and the alternative upload
// does.
static const int kYtmMaxCandidates = 3;
// Enough for home networks; it avoids staying "loading" forever.
static const int kTimeoutMs = 10000;

Lyrics::Lyrics(QObject *parent)
    : QObject(parent)
    , m_net(new QNetworkAccessManager(this))
{
}

// Normalises for comparison: no capitals, no accents, no spaces, no
// punctuation.
static QString norm(const QString &s)
{
    static const QRegularExpression junk(
        QStringLiteral("[^\\p{L}\\p{N}]+"));
    return s.normalized(QString::NormalizationForm_KD)
        .toLower()
        .remove(junk);
}

// Removes the little tails in parentheses or brackets: "Not Ready to Die
// (From "Call of the Dead")" -> "Not Ready to Die". The Sonora cache
// stores the bare title, so it has to be stripped to compare it.
static QString stripParenthetical(const QString &s)
{
    QString out = s;
    static const QRegularExpression re(
        QStringLiteral("\\s*[\\(\\[].*$"));
    out.remove(re);
    return out.trimmed();
}

// Kugou and some Apple Music lyrics mask the word that cannot be said with
// asterisks ("your **** nightmare"). The shell widget removes them; the
// app painted them literally and, on top of that, their time range broke
// the word by word sweep. The asterisk goes INSIDE the token
// ("your **** "), so it has to be cleaned, not the whole token dropped.
// NOTE: the word's trailing space is kept ("your "), otherwise the words
// come out glued when they are painted.
static QString stripMask(const QString &s)
{
    static const QRegularExpression re(QStringLiteral("\\s*\\*+"));
    QString out = s;
    out.remove(re);
    return out;
}

// Is the token only a mask? (then it is dropped entirely)
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

// Removes the masks from a lyrics line.
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

    // The key identifies the track being played. Any reply whose key does
    // not match m_trackKey is dropped (the user already changed the song).
    // `m_gen` covers the case of two fetch() in a row with the same key.
    m_trackKey = a + QStringLiteral(" - ") + t;
    m_artist = a;
    m_title = t;
    m_duration = qMax(0, qRound(durationSeconds));
    m_videoId = videoId.trimmed();
    m_exactTried = m_videoId.isEmpty();
    m_neteaseTried = false;
    m_mxmTried = false;
    ++m_gen;

    m_loading = true;
    m_hasLyrics = false;
    m_hasSynced = false;
    m_plain.clear();
    m_synced.clear();
    m_cacheLines.clear();
    m_cacheSource.clear();
    // The word level flag belongs to the track that was playing: without
    // this reset the lyrics of the previous song (with its word timings)
    // were kept and the new ones were never shown.
    m_worded = false;
    m_refLines.clear();
    m_error.clear();
    m_syncSource.clear();
    m_plainSource.clear();
    m_lines.clear();
    m_ytmIds.clear();
    m_ytmIdx = 0;
    m_ytmBrowseId.clear();
    publishTrack();   // the shell widget finds out before anything arrives
    emit changed();

    if (t.isEmpty()) {
        fail(QStringLiteral("Sin letra disponible"));
        return;
    }

    qInfo().noquote() << QString("[lyrics] buscar pista=\"%1\" dur=%2s")
                             .arg(m_trackKey)
                             .arg(m_duration);

    // First the local Sonora cache: it is instant and it brings word level
    // timings (real karaoke). If it is not there, the network carries on.
    if (trySonoraCache()) {
        finish();
        return;
    }
    // The cache may have the track under another videoId (the one Sonora
    // cached): it is looked up by title and artist, like the shell widget
    // does.
    if (trySonoraByTitle()) {
        finish();
        return;
    }

    // YouTube Music and Musixmatch go in parallel: the first one brings
    // the lyrics of the video that is playing (the reference for the word
    // timings) and the second one the timing of every word. Whichever
    // answers first is used and the other one completes it.
    startYtm();
    startMusixmatch();
}

// Classic plan (LRCLIB -> NetEase), used when YouTube Music has no lyrics
// for the track.
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
    // Qt6 follows redirects safely by default; it is set explicitly so a
    // 301/302 from the CDN does not cut the fetch.
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    if (url.host().endsWith(QLatin1String("163.com")))
        req.setRawHeader("Referer", "https://music.163.com");
    req.setTransferTimeout(kTimeoutMs);

    QNetworkReply *reply = m_net->get(req);
    // The key travels with the reply: the handler compares it with
    // m_trackKey.
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
        case Stage::MxmToken:      onMxmTokenReply(reply, key); break;
        case Stage::MxmRichsync:   onMxmRichsyncReply(reply, key); break;
        }
    });
}

// POST with a JSON body for YouTube Music's internal API. No cookies and
// no Authorization: anonymously it works (authenticated the API returns
// "Lyrics not available" or 400).
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

// Does the reply belong to an earlier fetch() (same track or not)?
static bool isStale(QNetworkReply *reply, const QString &key,
                    const QString &currentKey, int currentGen)
{
    return key != currentKey || reply->property("gen").toInt() != currentGen;
}

// ---- YouTube Music --------------------------------------------------------

// Base body with the `context` that YouTube Music's internal API demands.
// `android` adds the fields the ANDROID_MUSIC client needs for the
// server to serve the lyrics with timings (only the mobile app gets
// them).
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

// Walks a JSON tree and gathers every value of `key` (deep searches: that
// way we do not depend on the exact path, which changes between
// versions).
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

// First text string found under `key` (title, videoId, etc.).
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
    // If the track comes from YouTube with its exact videoId, that video
    // is tried directly in /next (its timings match the recording being
    // played; a title search may bring a cover or another take).
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

// Splits into normalised words (no accents, no punctuation). Unlike
// `norm()` they are NOT concatenated here: the token by token coverage
// is needed.
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

// Scores a search result: 45 for an exact title, 30 if it fits partially
// (e.g. it adds "(Official Video)") and 25 if the artist shows up too.
// A partial fit needs DOUBLE coverage so the lyrics of the wrong song
// are not read:
//   - at least 70% of the searched title's words appear in the candidate,
//   - and at least 50% of the candidate's words are in the searched
//     title+artist.
// Without this, a short titled candidate ("Python") passed as a
// substring of "Python Full Course for free" and brought the lyrics of
// another song.
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
        return;   // old answer

    if (reply->error() != QNetworkReply::NoError) {
        ytmGiveUp(QStringLiteral("búsqueda fallida (%1)")
                      .arg(reply->errorString()));
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();
    QJsonArray items;
    collectJson(root, QStringLiteral("musicResponsiveListItemRenderer"), &items);

    QList<QPair<int, QString>> ranked;   // score, videoId
    for (const QJsonValue &v : items) {
        const QJsonObject item = v.toObject();
        const QString videoId = firstString(item, QStringLiteral("videoId"));
        if (videoId.isEmpty())
            continue;
        // Title in the first column; artist/album in the second.
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
            // The exact video being played had no lyrics: it is looked up
            // by title/artist (classic fallback) just once.
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

// Finds the "Lyrics" tab (Lyrics/Letra) and its MPLYt_* browseId. If the
// tab comes `unselectable` YouTube will not serve the lyrics for that
// video, so it moves to the next candidate without even asking for the
// browse.
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
        return;   // old answer

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
        return;   // old answer

    if (reply->error() != QNetworkReply::NoError) {
        qInfo().noquote()
            << QString("[lyrics] youtube music: browse falló (%1)")
                   .arg(reply->errorString());
        ytmNextFor(m_ytmIdx + 1);
        return;
    }

    const QJsonObject root = QJsonDocument::fromJson(reply->readAll()).object();

    // Real path: contents.elementRenderer.newElement.type.componentType.model
    //   .timedLyricsModel.lyricsData -> { sourceMessage, timedLyricsData:[...] }
    // It is looked up by key to tolerate path changes between versions.
    QJsonArray timed;
    collectJson(root, QStringLiteral("timedLyricsData"), &timed);
    if (!timed.isEmpty()) {
        const QJsonArray entries = timed.at(0).toArray();
        // Source (LyricFind, Musixmatch, ...) for the log.
        QJsonArray sources;
        collectJson(root, QStringLiteral("sourceMessage"), &sources);
        const QString source = sources.isEmpty()
            ? QStringLiteral("youtube music")
            : QStringLiteral("youtube music · %1")
                  .arg(sources.at(0).toString());

        // An LRC is generated with the same format as the other sources so
        // that a single code parses it (parseLrc).
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
        // Without usable timings: the plain text is kept and the other
        // candidates are looked at, in case those do have timings.
        QString plain;
        for (const QJsonValue &v : entries) {
            const QString t =
                v.toObject().value(QStringLiteral("lyricLine")).toString();
            if (!t.trimmed().isEmpty())
                plain += t + QLatin1Char('\n');
        }
        rememberPlain(plain, "ytmusic");
    }

    // Either there were no timings, or only plain text: next candidate.
    ytmNextFor(m_ytmIdx + 1);
}

// YouTube Music did not give lyrics: the classic plan (LRCLIB/NetEase)
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
        return;   // old answer

    const int status =
        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray body = reply->readAll();

    // 404 (or any failure) => plan B: search by name.
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
        return;   // old answer

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
            << "resultados, ninguno sincronizado -> probando Musixmatch";
    if (!m_mxmTried)
        startMusixmatch();
    else {
        m_neteaseTried = true;
        startNetease();
    }
}

// ---- NetEase Cloud Music --------------------------------------------------

void Lyrics::startNetease()
{
    if (m_title.trimmed().isEmpty()) {
        settleOrFail();
        return;
    }

    // The search works better with "title artist".
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
        return;   // old answer

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
        return;   // old answer

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
    // "klyric" is the same lyrics with WORD level timings: if it is
    // there, it is used for the karaoke (the shell widget goes for it
    // too).
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
    // Without word level timings: it is only used if there is no synced
    // lyrics yet (a good lyrics is not overwritten with a worse one).
    if (!m_hasSynced && adoptSynced(lrc, "netease", /*filterCredits=*/true)) {
        finish();
        return;
    }
    if (m_hasSynced) {
        // We already had lyrics: NetEase brings nothing better.
        settleOrFail();
        return;
    }

    qInfo() << "[lyrics] netease: LRC no utilizable"
            << (lrc.trimmed().isEmpty() ? "(vacío)" : "(solo créditos/sin tiempos)");
    settleOrFail();
}

// Picks the NetEase song that best fits the title/artist/duration.
// Rough scoring: 45 for an exact title, 30 if it only matches in part, 35
// for the artist and 25 for the duration. At least 45 is required (exact
// title).
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
        return 0;   // not even the title matches

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

    // NetEase gives the duration in milliseconds.
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

// ---- result ------------------------------------------------------------

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
        return false;   // almost nothing: it is not worth hiding the plain text

    m_synced = lrc;
    // The timed lines of the video are kept as the reference: the word
    // level timings that come later are aligned with them.
    m_refLines = parsed;
    // The word level lyrics are never replaced by the line ones.
    if (!m_worded) {
        m_lines = std::move(parsed);
    } else {
        // The lines of the video arrived after the karaoke: the words are
        // aligned with them now.
        alignWords(m_lines, m_refLines);
    }
    m_hasSynced = true;
    m_syncSource = source;
    return true;
}

bool Lyrics::adoptWorded(QVector<LrcLine> lines, const QString &source)
{
    if (lines.size() < 2)
        return false;
    // The words come from the album: they are aligned with the video and
    // the text of the video wins. If the lines do not match at all it is
    // another version of the song and it is not used.
    if (!alignWords(lines, m_refLines))
        return false;
    // The instrumental markers of the video are added (the album may not
    // have them) and every one of them is marked with as many "♪" as the
    // stretch lasts.
    for (const LrcLine &r : m_refLines) {
        if (!isInstrumental(normLine(r.text)))
            continue;
        bool covered = false;
        for (const LrcLine &l : lines) {
            if (l.time >= r.time - 0.5 && l.time <= r.time + 2.0) {
                covered = true;
                break;
            }
        }
        if (covered)
            continue;
        LrcLine m = r;
        m.words.clear();
        m.instrumental = true;
        lines.append(m);
    }
    std::sort(lines.begin(), lines.end(),
              [](const LrcLine &x, const LrcLine &y) { return x.time < y.time; });
    // The instrumental stretches in the middle of the song are not always
    // marked by the sources: without a line for them the previous phrase
    // would be sung until the next one (it looked too long).
    {
        QVector<LrcLine> withGaps;
        for (int i = 0; i < lines.size(); ++i) {
            withGaps.append(lines.at(i));
            if (i + 1 >= lines.size())
                break;
            if (lines.at(i + 1).time - lines.at(i).time >= 6.0) {
                LrcLine m;
                m.time = lines.at(i).time + 0.5;
                m.text = QStringLiteral("♪");
                m.instrumental = true;
                withGaps.append(m);
            }
        }
        lines = withGaps;
    }
    expandInstrumentals(lines);
    m_lines = std::move(lines);
    m_hasSynced = true;
    m_syncSource = source;
    m_worded = true;
    return true;
}

// Aligns the word timings with a reference timeline (the timed lyrics of the
// very video being played). The word level timings come from the ALBUM and
// the video may cut the intro (or the outro): without this correction the
// karaoke front runs seconds ahead of the voice and the lines look already
// sung. The offset is the median of the difference between the lines that
// match by text.

// Converts {"secs":N,"nanos":M} to seconds.
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

    // Own and ephemeral connection, read only. The handle is destroyed
    // BEFORE removeDatabase(): if it is still alive, Qt warns that the
    // connection is in use.
    QByteArray raw;
    const QString conn = QStringLiteral("lotus_lyrics");
    {
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
    }

    if (raw.isEmpty())
        return false;

    const QJsonArray hits =
        QJsonDocument::fromJson(raw).object().value(QStringLiteral("hits")).toArray();

    // The hit with the most "worded" lines wins; on a tie, the most
    // reliable source (Apple Music has the most exact word timings).
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

    const QString source = QStringLiteral("lotus tune · %1").arg(
        bestSource.isEmpty() ? QStringLiteral("cache") : bestSource);
    if (bestWorded <= 0) {
        // Without word level timings this is not karaoke: it is kept aside
        // and the network is asked first (YouTube Music may bring the real
        // word timings).
        m_cacheLines = best;
        m_cacheSource = source;
        qInfo().noquote()
            << QString("[lyrics] cache local sin letra a letra: se sigue con la red");
        return false;
    }

    return adoptWorded(std::move(best), source);
}

// Fallback of the Sonora cache: look it up by TITLE and ARTIST, not only
// by videoId. The shell widget does it like this (prefiltering in SQL
// with `instr` and comparing every hit properly) and that is why the
// widget finds word timings for tracks whose videoId is not the one
// Sonora cached: the app fell back to YTM/LRCLIB (times per line) and
// the word level karaoke disappeared. Now the app uses the same search
// and brings the word level timings.
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
        // Own and ephemeral connection, read only. The handle is
        // destroyed BEFORE removeDatabase(): if it is still alive, Qt
        // warns that the connection is in use.
        const QString cname = QStringLiteral("lotus_lyrics_title");
        {
            QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), cname);
            db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
            db.setDatabaseName(path);
            if (db.open()) {
                QSqlQuery q(db);
                // Cheap prefilter: only the rows whose text mentions the
                // track. The good comparison comes later, with the JSON
                // already parsed. Several needles are tried because the
                // app's title usually has little tails ("Not Ready to
                // Die (From "Call of the Dead")") that the cache stores
                // bare.
                QStringList needles;
                const QString bare = stripParenthetical(m_title);
                if (!bare.isEmpty() && bare != m_title)
                    needles << bare;
                needles << m_title;
                // The first words of the title: a short prefix that
                // appears inside the row's value.
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
        }
        QSqlDatabase::removeDatabase(cname);
    }
    if (payloads.isEmpty())
        return false;

    qInfo() << "[lyrics] cache local por titulo: filas =" << payloads.size()
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
            // Is this the track? Title and artist (the artist may come
            // with suffixes: "Artist - Theme").
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
            // The track's duration in the cache, used to break ties.
            int diff = 0;
            const QJsonObject dur = h.value(QStringLiteral("duration")).toObject();
            if (m_duration > 0 && dur.contains(QStringLiteral("secs"))) {
                const int ds = dur.value(QStringLiteral("secs")).toInt();
                diff = qAbs(ds - m_duration);
            }
            // Order: first the one with word level timings, then the most
            // reliable source and then the one that fits the duration.
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

    if (best.size() < 2)
        return false;

    const QString source = QStringLiteral("sonora · %1").arg(
        bestSource.isEmpty() ? QStringLiteral("cache") : bestSource);
    if (bestWorded <= 0) {
        // Same as the cache by id: without word timings it is only the last
        // resort.
        m_cacheLines = best;
        m_cacheSource = source;
        qInfo().noquote()
            << QString("[lyrics] cache local (por titulo) sin letra a letra: se sigue con la red");
        return false;
    }

    return adoptWorded(std::move(best), source);
}

void Lyrics::settleOrFail()
{
    if (m_hasLyrics || !m_plain.trimmed().isEmpty()) {
        finish();
        return;
    }
    // Last resort: the Sonora lyrics without word level timings (the
    // network had nothing better for this track).
    if (m_cacheLines.size() >= 2) {
        m_lines = m_cacheLines;
        m_hasSynced = true;
        m_syncSource = m_cacheSource;
        qInfo().noquote()
            << QString("[lyrics] cache local por lineas (ultimo recurso): %1")
                   .arg(m_cacheSource);
        finish();
        return;
    }
    // Nothing at all: Musixmatch is tried (it also has the line timings)
    // and, if it does not know the song, NetEase.
    if (!m_mxmTried)
        startMusixmatch();
    else {
        m_neteaseTried = true;
        startNetease();
    }
}

void Lyrics::finish()
{
    m_loading = false;
    m_hasLyrics = m_hasSynced || !m_plain.trimmed().isEmpty();
    if (m_hasLyrics)
        m_error.clear();

    // The lyrics we have bring no word level timings: NetEase is asked for
    // its "klyric" (which does bring them) to get the word level karaoke,
    // like the shell widget. If it arrives, it replaces the lyrics.
    if (m_hasSynced && !hasWordTimings() && !m_mxmTried
        && !m_title.trimmed().isEmpty()) {
        // The lyrics have no word level timings: Musixmatch is asked for
        // them (it is the catalogue YouTube Music uses) and, if it does not
        // have them either, NetEase.
        if (!m_mxmTried)
            startMusixmatch();
    }

    const QString source = m_hasSynced
        ? (m_syncSource.isEmpty() ? QStringLiteral("?") : m_syncSource)
        : (m_plainSource.isEmpty() ? QStringLiteral("ninguna")
                                   : QStringLiteral("plana de ") + m_plainSource);
    // In synced mode the timed lines are counted; in plain mode, the text
    // lines (m_lines stays empty in that case).
    const int count = m_hasSynced
        ? m_lines.size()
        : m_plain.split(QLatin1Char('\n'), Qt::SkipEmptyParts).size();
    // QA format: it is ALWAYS emitted when there is a result, whatever the
    // source (YouTube Music, LRCLIB or NetEase).
    qInfo().noquote()
        << QString("[lyrics] fuente: %1 | synced: %2 | lineas: %3 | pista=\"%4\"")
               .arg(source,
                    m_hasSynced ? QStringLiteral("sí") : QStringLiteral("no"),
                    QString::number(count),
                    m_trackKey);
    publishLines();   // full dump to the published state (lines or discard)
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
    // Same format as in finish(): QA always expects the source line.
    qInfo().noquote() << QString("[lyrics] fuente: ninguna | synced: no | "
                                 "pista=\"%1\"").arg(m_trackKey);
    emit changed();
}

QVariantList Lyrics::lines() const
{
    QVariantList out;
    out.reserve(m_lines.size());
    for (int i = 0; i < m_lines.size(); ++i) {
        const LrcLine &l = m_lines.at(i);
        QVariantMap m;
        m.insert(QStringLiteral("time"), l.time);
        // The end of the line: the phrase is not sung past its own
        // length. With word timings it is the end of the last word, so
        // an instrumental stretch in the middle does not make the
        // previous phrase longer.
        {
            double end = 0.0;
            if (!l.words.isEmpty()) {
                const QVariantMap last = l.words.last().toMap();
                end = last.value(QStringLiteral("e")).toDouble();
            }
            if (!(end > l.time)) {
                end = l.time + 4.0;
                for (int j = i + 1; j < m_lines.size(); ++j) {
                    if (m_lines.at(j).time > l.time) {
                        end = m_lines.at(j).time;
                        break;
                    }
                }
            }
            m.insert(QStringLiteral("end"), end);
        }
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

// Converts the LRC into a sorted vector of {seconds, text}. It accepts
// several timestamps per line ("[00:12.00][01:20.00]chorus"), takes both
// the dot and the colon as the decimal separator and drops the lines
// without a time (metadata like [ar:...]) and, optionally, the credits.
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
            continue;   // no timestamp: metadata or empty line
        // The text is what follows the last timestamp of the line.
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

// "Enriched" LRC: besides the line timing it has the timing of every
// word between angle brackets: [00:12.34]<00:12.34>Hello
// <00:12.80>world. That is what NetEase calls "klyric" and what allows
// the word level karaoke.
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
        // Text and word marks: it is cut by the marks.
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
            // The word's text goes until the next mark (or the end).
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
        // The line's text: everything without the marks.
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

// Detects the credit lines that NetEase (and some other source) mixes in
// with the lyrics: "作词 : ..." / "Written by ...". They are not shown.
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
    // Last line whose time is <= seconds (binary search).
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
    ++m_gen;              // it invalidates any answer still in flight
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
    m_cacheLines.clear();
    m_cacheSource.clear();
    m_error.clear();
    m_syncSource.clear();
    m_plainSource.clear();
    m_lines.clear();
    removePublished();
    emit changed();
}

// ---- state published for the desktop (inir widgets) ---------------------
// See the note in lyrics.h. The files live in ~/.local/state/lotus-tune/
// and the shell (inir's LyricsService) reads them with FileView: that is
// why the format of `lines` is THE SAME one lyrics.py produces
// ({t,e,text,w,instrumental}), so the widget cannot tell the app's own
// lyrics from the ones inherited from it.

namespace {

QString stateDir()
{
    return QDir::homePath() + QStringLiteral("/.local/state/lotus-tune");
}

bool writeJsonFile(const QString &path, const QJsonObject &obj)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    // ATOMIC write (temp file + rename): the desktop widgets read these
    // files as soon as they change and must never see half a JSON.
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
                m_runtimeBeat->start();   // the beat only while it sounds
        });
    }
    // Play/pause/state change: it is written right away (when paused there
    // is no beat, and the widget must know the clock is frozen here).
    connect(player, &Player::stateChanged, this, [this]() {
        if (m_engine && m_engine->playing()) {
            if (m_runtimeBeat && !m_runtimeBeat->isActive())
                m_runtimeBeat->start();
        } else if (m_runtimeBeat) {
            m_runtimeBeat->stop();
        }
        publishRuntime();
    });
    // Search with the pause on: positionChanged does not fire again until
    // resuming, so the seek is published apart.
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

// New track (or a fetch() retry): the widget knows right away what is
// playing and that the lyrics are on the way, so it does not ask twice
// for the same thing.
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

// Lyrics resolved (or dropped): the full lines are dumped with their
// words. The `e` of each line is the start of the next one (the lyrics.py
// contract), with a reasonable cap so no huge durations are announced.
void Lyrics::publishLines()
{
    if (m_trackKey.isEmpty())
        return;
    // The widget waits for the lyrics of a finished track; if the search
    // is still running (there was a publishTrack after), old lines are
    // not released into a file that already describes another track.
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
                // LrcLine::words are QVariantMap {t,e,text}: they pass as
                // they are to the widget's contract, but as real JSON.
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

// Engine position/state: a small file so the widget can read it without
// cost. The position is the raw one from the engine; the adjustment
// (`offset`) travels apart and the widget adds it, just like the app.
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
    // Instead of deleting the published files, they are overwritten
    // empty. A FileView in the shell does not always notice the `remove`
    // and the widget kept painting the previous track's lyrics - the
    // eternal "Creep" of the widget.
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


// ---------------------------------------------------------------------------
// Musixmatch: word level timings (the "richsync" of the macro call).
//
// It is the same catalogue YouTube Music uses for its lyrics, but the
// answer carries the timing of every word, so the karaoke is real. The
// token is asked only once every ten minutes and it is kept on disk, so
// neither the app nor the API are hammered.
// ---------------------------------------------------------------------------
static QString mxmTokenPath()
{
    return QDir::homePath() + QStringLiteral("/.cache/lotus-tune/mxm_token.json");
}

// The titles that come from YouTube Music carry the uploader and the
// marketing noise ("xi - Topic - Freedom Dive", "Savior (Official Music
// Video)"). Musixmatch knows the song without them.
static QString cleanTrackTitle(const QString &in)
{
    QString t = in;
    const QStringList junk = {
        QStringLiteral("official music video"), QStringLiteral("official video"),
        QStringLiteral("official audio"), QStringLiteral("official lyric video"),
        QStringLiteral("official lyrics"), QStringLiteral("lyric video"),
        QStringLiteral("lyrics"), QStringLiteral("audio"), QStringLiteral("video"),
        QStringLiteral("music video"), QStringLiteral("mv"), QStringLiteral("hd"),
        QStringLiteral("hq"), QStringLiteral("4k"), QStringLiteral("remastered"),
        QStringLiteral("topic")
    };
    t.remove(QRegularExpression(QStringLiteral("\\s*\\[[^\\]]*\\]")));
    t.remove(QRegularExpression(QStringLiteral("\\s*\\([^)]*\\)")));
    t.remove(QRegularExpression(QStringLiteral("\\s*-\\s*Topic\\s*$"),
                                QRegularExpression::CaseInsensitiveOption));
    for (const QString &j : junk) {
        const QRegularExpression re(
            QStringLiteral("\\s*\\(?\\b%1\\b\\)?\\s*").arg(j),
            QRegularExpression::CaseInsensitiveOption);
        t.remove(re);
    }
    t = t.simplified();
    return t;
}

static QString cleanTrackArtist(const QString &in)
{
    QString a = in;
    a.remove(QRegularExpression(QStringLiteral("\\s*-\\s*Topic\\s*$"),
                                QRegularExpression::CaseInsensitiveOption));
    a.remove(QRegularExpression(QStringLiteral("\\s*\\(.*\\)\\s*$")));
    a = a.simplified();
    return a;
}

void Lyrics::startMusixmatch()
{
    if (m_mxmTried)
        return;   // it is already on its way
    m_mxmTried = true;
    // A token in memory that is still fresh?
    if (!m_mxmToken.isEmpty() && m_mxmTokenAt.isValid()
        && m_mxmTokenAt.secsTo(QDateTime::currentDateTimeUtc()) < 540) {
        requestMusixmatchRichsync();
        return;
    }
    // ... or one on disk?
    QFile f(mxmTokenPath());
    if (f.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        f.close();
        const QString tok = o.value(QStringLiteral("token")).toString();
        const qint64 exp =
            static_cast<qint64>(o.value(QStringLiteral("exp")).toDouble());
        if (!tok.isEmpty()
            && exp > QDateTime::currentDateTimeUtc().toSecsSinceEpoch()) {
            m_mxmToken = tok;
            m_mxmTokenAt = QDateTime::currentDateTimeUtc();
            requestMusixmatchRichsync();
            return;
        }
    }
    QUrl url(QStringLiteral("https://apic.musixmatch.com/ws/1.1/token.get"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("app_id"),
                   QStringLiteral("android-player-v1.0"));
    q.addQueryItem(QStringLiteral("user_language"), QStringLiteral("en"));
    url.setQuery(q);
    request(url, Stage::MxmToken, m_trackKey);
}

void Lyrics::requestMusixmatchRichsync()
{
    if (m_mxmToken.isEmpty() || m_title.trimmed().isEmpty())
        return;
    const QString title = cleanTrackTitle(m_title);
    const QString artist = cleanTrackArtist(m_artist);
    if (title.isEmpty())
        return;

    QUrl url(QStringLiteral("https://apic.musixmatch.com/ws/1.1/macro.subtitles.get"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("format"), QStringLiteral("json"));
    q.addQueryItem(QStringLiteral("namespace"),
                   QStringLiteral("lyrics_richsynched"));
    q.addQueryItem(QStringLiteral("subtitle_format"), QStringLiteral("mxm"));
    q.addQueryItem(QStringLiteral("app_id"),
                   QStringLiteral("android-player-v1.0"));
    q.addQueryItem(QStringLiteral("usertoken"), m_mxmToken);
    q.addQueryItem(QStringLiteral("q_track"), title);
    q.addQueryItem(QStringLiteral("q_artist"), artist);
    if (m_duration > 0)
        q.addQueryItem(QStringLiteral("q_duration"),
                       QString::number(m_duration));
    // The word timings come as an extra sub call of the same request.
    q.addQueryItem(QStringLiteral("optional_calls"),
                   QStringLiteral("track.richsync"));
    q.addQueryItem(QStringLiteral("richsync_compact_type"),
                   QStringLiteral("words"));
    url.setQuery(q);
    request(url, Stage::MxmRichsync, m_trackKey);
}

// An instrumental stretch is marked with as many "♪" as it lasts: one
// for a short gap, two for a middle one and three for a long one (the
// silence is not left empty on the screen).
void Lyrics::expandInstrumentals(QVector<LrcLine> &lines)
{
    for (int i = 0; i < lines.size(); ++i) {
        if (!lines[i].instrumental)
            continue;
        const double end = (i + 1 < lines.size()) ? lines.at(i + 1).time
                                                  : lines.at(i).time + 4.0;
        const double len = end - lines.at(i).time;
        int marks = 1;
        if (len >= 8.0)
            marks = 3;
        else if (len >= 4.0)
            marks = 2;
        QStringList parts;
        for (int k = 0; k < marks; ++k)
            parts << QStringLiteral("♪");
        lines[i].text = parts.join(QLatin1Char(' '));
    }
}

void Lyrics::onMxmTokenReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (key != m_trackKey)
        return;
    const QByteArray body = reply->readAll();
    const QJsonObject root = QJsonDocument::fromJson(body).object();
    const QJsonObject msg = root.value(QStringLiteral("message")).toObject();
    const int code =
        msg.value(QStringLiteral("header")).toObject()
            .value(QStringLiteral("status_code")).toInt();
    const QString tok =
        msg.value(QStringLiteral("body")).toObject()
            .value(QStringLiteral("user_token")).toString();
    if (code != 200 || tok.isEmpty()) {
        qInfo() << "[lyrics] musixmatch: token no válido (" << code << ")";
        if (m_neteaseTried)
            fail(QStringLiteral("Sin letra disponible"));
        else {
            m_neteaseTried = true;
            startNetease();
        }
        return;
    }
    m_mxmToken = tok;
    m_mxmTokenAt = QDateTime::currentDateTimeUtc();
    // It is kept on disk: a new token is not asked for on every track.
    QDir().mkpath(QDir::homePath() + QStringLiteral("/.cache/lotus-tune"));
    QFile f(mxmTokenPath());
    if (f.open(QIODevice::WriteOnly)) {
        QJsonObject o;
        o.insert(QStringLiteral("token"), tok);
        o.insert(QStringLiteral("exp"),
                 QDateTime::currentDateTimeUtc().addSecs(540)
                     .toSecsSinceEpoch());
        f.write(QJsonDocument(o).toJson());
        f.close();
    }
    requestMusixmatchRichsync();
}

// Normalises a line of text so two of them can be compared: lower case,
// without punctuation and with single spaces.
static QString normLine(const QString &t)
{
    QString s = t.toLower();
    // The musical notes are kept: they are the markers of the instrumental
    // parts.
    s.remove(QRegularExpression(QStringLiteral("[^\\p{L}\\p{N} ♪♫♬ ]")));
    return s.simplified();
}

// The instrumental markers ("♪") are not a line of the song: they do not
// say anything about when the words are sung.
static bool isInstrumental(const QString &norm)
{
    return norm == QStringLiteral("♪") || norm == QStringLiteral("♫")
        || norm == QStringLiteral("♬") || norm == QStringLiteral("music")
        || norm == QStringLiteral("instrumental");
}

QVector<Lyrics::LrcLine> Lyrics::parseRichsync(const QJsonArray &arr)
{
    QVector<LrcLine> out;
    for (const QJsonValue &lv : arr) {
        const QJsonObject e = lv.toObject();
        const double ts = e.value(QStringLiteral("ts")).toDouble();
        const double te = e.value(QStringLiteral("te")).toDouble(ts + 4.0);
        const QJsonArray chunks = e.value(QStringLiteral("l")).toArray();
        LrcLine line;
        line.time = ts;
        QString text;
        int i = 0;
        while (i < chunks.size()) {
            const QJsonObject c = chunks.at(i).toObject();
            const QString ct = c.value(QStringLiteral("c")).toString();
            if (ct.trimmed().isEmpty()) {   // a space on its own
                text += ct;
                ++i;
                continue;
            }
            // The word takes the spaces that follow it.
            QString wtext = ct;
            int j = i + 1;
            while (j < chunks.size()
                   && chunks.at(j).toObject().value(QStringLiteral("c"))
                          .toString().trimmed().isEmpty()) {
                wtext += chunks.at(j).toObject().value(QStringLiteral("c")).toString();
                ++j;
            }
            const double t0 = ts + c.value(QStringLiteral("o")).toDouble();
            const double t1 = (j < chunks.size())
                ? ts + chunks.at(j).toObject().value(QStringLiteral("o")).toDouble()
                : te;
            QVariantMap wm;
            wm.insert(QStringLiteral("t"), t0);
            wm.insert(QStringLiteral("e"), t1);
            wm.insert(QStringLiteral("text"), wtext);
            line.words.append(wm);
            text += wtext;
            i = j;
        }
        if (line.words.size() < 2)
            continue;
        line.text = text.trimmed();
        if (line.text.isEmpty())
            continue;
        // The instrumental markers ("♪") are kept: they are shown as they
        // are, without being sung.
        line.instrumental = isInstrumental(normLine(line.text));
        out.append(line);
    }

    return out;
}

void Lyrics::onMxmRichsyncReply(QNetworkReply *reply, const QString &key)
{
    reply->deleteLater();
    if (key != m_trackKey)
        return;
    const QByteArray body = reply->readAll();
    if (reply->error() != QNetworkReply::NoError || body.isEmpty()) {
        qInfo() << "[lyrics] musixmatch: richsync falló:" << reply->errorString();
        if (m_neteaseTried)
            fail(QStringLiteral("Sin letra disponible"));
        else {
            m_neteaseTried = true;
            startNetease();
        }
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(body).object();
    const QJsonObject calls =
        root.value(QStringLiteral("message")).toObject()
            .value(QStringLiteral("body")).toObject()
            .value(QStringLiteral("macro_calls")).toObject();

    // The word level timings.
    const QJsonObject rs =
        calls.value(QStringLiteral("track.richsync.get")).toObject()
            .value(QStringLiteral("message")).toObject();
    if (rs.value(QStringLiteral("header")).toObject()
            .value(QStringLiteral("status_code")).toInt() == 200) {
        const QString raw =
            rs.value(QStringLiteral("body")).toObject()
                .value(QStringLiteral("richsync")).toObject()
                .value(QStringLiteral("richsync_body")).toString();
        if (!raw.isEmpty()) {
            const QJsonArray arr =
                QJsonDocument::fromJson(raw.toUtf8()).array();
            QVector<LrcLine> worded = parseRichsync(arr);
            if (worded.size() >= 2) {
                qInfo() << "[lyrics] musixmatch: karaoke con tiempos por palabra ("
                        << worded.size() << " líneas)";
                if (adoptWorded(std::move(worded),
                                QStringLiteral("musixmatch"))) {
                    finish();
                    return;
                }
            }
        }
    }

    // No word timings: the line timings of the same answer are used.
    const QJsonObject subs =
        calls.value(QStringLiteral("track.subtitles.get")).toObject()
            .value(QStringLiteral("message")).toObject();
    if (subs.value(QStringLiteral("header")).toObject()
            .value(QStringLiteral("status_code")).toInt() == 200) {
        const QJsonArray list =
            subs.value(QStringLiteral("body")).toObject()
                .value(QStringLiteral("subtitle_list")).toArray();
        if (!list.isEmpty()) {
            const QString lrc = list.at(0).toObject()
                    .value(QStringLiteral("subtitle")).toObject()
                    .value(QStringLiteral("subtitle_body")).toString();
            if (!lrc.trimmed().isEmpty()) {
                QVector<LrcLine> worded = parseLrcWords(lrc);
                if (worded.size() >= 2) {
                    qInfo() << "[lyrics] musixmatch: karaoke con tiempos por palabra ("
                            << worded.size() << " líneas)";
                    if (adoptWorded(std::move(worded),
                                    QStringLiteral("musixmatch"))) {
                        finish();
                        return;
                    }
                }
                if (adoptSynced(lrc, QStringLiteral("musixmatch"),
                                /*filterCredits=*/true)) {
                    finish();
                    return;
                }
            }
        }
    }

    // Nothing here: NetEase carries on.
    qInfo() << "[lyrics] musixmatch: sin karaoke para esta canción";
    if (m_neteaseTried)
        fail(QStringLiteral("Sin letra disponible"));
    else {
        m_neteaseTried = true;
        startNetease();
    }
}


// It returns false when the reference and the words do not match at all:
// the lyrics are not used then.
bool Lyrics::alignWords(QVector<LrcLine> &lines,
                        const QVector<LrcLine> &reference)
{
    if (lines.size() < 2)
        return false;
    if (reference.size() < 2)
        return true;   // there is no reference to align with

    // The reference lines by normalised text (the same phrase can be
    // repeated in a song, so they are kept in order).
    QStringList refKeys;
    for (const LrcLine &l : reference)
        refKeys.append(normLine(l.text));
    if (refKeys.isEmpty())
        return true;

    // The two lists are paired with the longest common subsequence: the
    // lines are matched in order even when some of them are only in one
    // of the two (and a phrase that is repeated is paired with its own
    // repetition, not with the first one).
    const int n = lines.size();
    const int m = reference.size();
    QStringList lineKeys;
    for (const LrcLine &l : lines)
        lineKeys.append(normLine(l.text));
    QVector<QVector<int>> dp(n + 1, QVector<int>(m + 1, 0));
    for (int a = n - 1; a >= 0; --a) {
        const bool singable = !lineKeys.at(a).isEmpty()
                              && !isInstrumental(lineKeys.at(a));
        for (int b = m - 1; b >= 0; --b) {
            dp[a][b] = (singable && refKeys.at(b) == lineKeys.at(a))
                ? dp[a + 1][b + 1] + 1
                : qMax(dp[a + 1][b], dp[a][b + 1]);
        }
    }

    // The pairs are taken from the table: the index of the line of the
    // video that each line of the karaoke is paired with (-1 when there is
    // none).
    QVector<int> pairOf(n, -1);
    int a = 0, b = 0;
    while (a < n && b < m) {
        const QString k = lineKeys.at(a);
        const bool singable = !k.isEmpty() && !isInstrumental(k);
        if (singable && refKeys.at(b) == k && dp[a][b] == dp[a + 1][b + 1] + 1) {
            pairOf[a] = b;
            ++a;
            ++b;
        } else if (dp[a + 1][b] >= dp[a][b + 1]) {
            ++a;   // this line of the karaoke has no pair
        } else {
            ++b;   // this line of the video has no pair
        }
    }

    QVector<double> deltas;
    QVector<LrcLine> out;
    out.reserve(lines.size());
    int matched = 0;
    for (int i = 0; i < n; ++i) {
        LrcLine aligned = lines.at(i);
        const int j = pairOf.at(i);
        if (j >= 0) {
            // The line is in the video: the difference of times is a
            // sample for the offset. The text is NOT changed: the words
            // that are filled in the karaoke belong to this very text.
            deltas.append(reference.at(j).time - aligned.time);
            ++matched;
        }
        // The instrumental lines (and the ones the video does not have) are
        // kept: they are shown as they are.
        out.append(aligned);
    }
    if (out.size() < 2)
        return false;
    qInfo() << "[lyrics] alineacion: " << matched << " de " << lines.size()
            << " lineas emparejadas con el video";
    if (matched * 10 < lines.size() * 3)
        return false;  // it is another version of the song

    std::sort(deltas.begin(), deltas.end());
    double shift = deltas.at(deltas.size() / 2);
    // The offset is the one that most of the lines share: a few lines of
    // another take (or an instrumental marker) must not move the karaoke
    // several seconds away. The group of lines that agree with the median
    // is the one that counts, and if it is too small the timings are left
    // as they are.
    QVector<double> agree;
    for (double d : deltas)
        if (qAbs(d - shift) <= 1.5)
            agree.append(d);
    if (agree.size() * 10 < deltas.size() * 4) {
        // The times do not agree with the video: the karaoke is left as it
        // is (the manual offset of the track can still move it).
        qInfo() << "[lyrics] karaoke sin alinear: los tiempos no coinciden"
                << deltas.size() << "muestras";
        lines = out;
        return true;
    }
    std::sort(agree.begin(), agree.end());
    shift = agree.at(agree.size() / 2);
    if (qAbs(shift) >= 0.02) {
        for (LrcLine &l : out) {
            l.time += shift;
            for (QVariant &wv : l.words) {
                QVariantMap w = wv.toMap();
                w.insert(QStringLiteral("t"),
                         w.value(QStringLiteral("t")).toDouble() + shift);
                w.insert(QStringLiteral("e"),
                         w.value(QStringLiteral("e")).toDouble() + shift);
                wv = w;
            }
        }
        qInfo() << "[lyrics] karaoke alineada com o vídeo: desfase"
                << QString::number(shift, 'f', 2) << "s"
                << "(" << deltas.size() << " lineas)";
    }
    lines = out;
    return true;
}
