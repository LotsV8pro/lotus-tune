#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

class QJsonArray;
class QJsonObject;
class QNetworkAccessManager;
class QNetworkReply;
class Player;
class QTimer;

// Song lyrics (YouTube Music -> LRCLIB -> NetEase, no API key), exposed
// to QML as the `lyrics` context property.
//
// The flow is:
//   1. YouTube Music (first option, lyrics *with timings*, karaoke style):
//      POST /youtubei/v1/search (WEB_REMIX client) finds the videos of the
//      song; POST /next returns the "Lyrics" tab with its browseId
//      MPLYt_*; POST /browse with the ANDROID_MUSIC client returns
//      timedLyricsModel.lyricsData with startTimeMilliseconds per line.
//      From there an LRC is generated and parsed with the same code as the
//      other sources. Songs whose tab comes `unselectable` (or with no
//      lyrics) try the next video candidate and, if none works, they carry
//      on with the classic sources.
//   2. LRCLIB /api/get and, if it brings no synced lyrics, /api/search.
//   3. NetEase Cloud Music (search + /song/lyric).
// The plain text (or an error) is only shown when no source gives
// timestamps.
//
// YouTube Music is ALWAYS queried anonymously: with the account cookies the
// browse returns "Lyrics not available" (or 400), and without them it
// works. No sign in is needed to read lyrics.
//
// The replies are tagged with the current trackKey to drop the ones from
// old requests (the user may have changed the song before the network
// answered). The LRC is cached already parsed so lineIndexAt(seconds) is a
// simple binary search over the vector.
class Lyrics : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(bool hasLyrics READ hasLyrics NOTIFY changed)
    Q_PROPERTY(bool hasSynced READ hasSynced NOTIFY changed)
    Q_PROPERTY(QString plain READ plain NOTIFY changed)
    Q_PROPERTY(QString synced READ synced NOTIFY changed)   // LRC crudo
    Q_PROPERTY(QVariantList lines READ lines NOTIFY changed) // [{time, text}]
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString trackKey READ trackKey NOTIFY changed)
    // Sync adjustment in seconds (positive = moves the front forward). It
    // lives here and not in the view so it also travels in the published
    // state.
    Q_PROPERTY(double offset READ offset WRITE setOffset NOTIFY changed)
    // "Word level karaoke": with word level timings the active line lights
    // up letter by letter. If it is off, the whole line lights up when it
    // is sung.
    Q_PROPERTY(bool karaoke READ karaoke WRITE setKaraoke NOTIFY changed)

public:
    explicit Lyrics(QObject *parent = nullptr);

    // The playback engine: it is only used to publish the position in the
    // lyrics state (the desktop widgets sync with it).
    void setEngine(Player *player);

    bool loading() const { return m_loading; }
    bool hasLyrics() const { return m_hasLyrics; }
    bool hasSynced() const { return m_hasSynced; }
    QString plain() const { return m_plain; }
    QString synced() const { return m_synced; }
    QString error() const { return m_error; }
    QString trackKey() const { return m_trackKey; }
    double offset() const { return m_offset; }
    void setOffset(double v);
    bool karaoke() const { return m_karaoke; }
    void setKaraoke(bool on);
    // Lines already parsed (with their seconds). It is the single source
    // of truth for painting and for lineIndexAt(), so the index and the
    // highlighted row can never drift apart.
    QVariantList lines() const;

    // Looks for the lyrics of a track. durationSeconds is rounded for
    // /api/get. If videoId brings the exact video being played, YouTube
    // Music is asked directly for that video (the timings match that
    // recording); if it has no lyrics, the normal search works as a
    // fallback.
    Q_INVOKABLE void fetch(const QString &artist, const QString &title,
                           double durationSeconds, const QString &videoId = QString());
    Q_INVOKABLE void clear();
    // Index of the active LRC line at `seconds`, -1 if it has not started
    // yet or there is none.
    Q_INVOKABLE int lineIndexAt(double seconds);
    // Main.qml publishes the sync adjustment here (same value as the
    // `offset` property, so there is a single source of truth). QML sees
    // it because it is Q_INVOKABLE and PUBLIC: the private ones are not
    // exposed.
    Q_INVOKABLE void setPublishedOffset(double v) { setOffset(v); }

signals:
    void changed();

private:
    // The tests (tests/test_all.cpp) exercise the LRC parsing and the
    // active line search - pure logic - without depending on the network.
    friend class TestLotusTune;

    struct LrcLine {
        double time;    // segundos desde el inicio
        QString text;
        // WORD level timings (only if the source brings them): [{t,e,text}].
        // Empty in the line level sources (YTM/LRCLIB/NetEase).
        QVariantList words;
        bool instrumental = false;   // tramo sin voz (solo Sonora lo marca)
    };

    // Stage of the sources cascade; it travels attached to the reply to
    // know which handler has to process the answer.
    enum class Stage {
        YtmSearch,        // POST /youtubei/v1/search  (candidatos)
        YtmNext,          // POST /youtubei/v1/next    (pestaña «Letra»)
        YtmBrowse,        // POST /youtubei/v1/browse  (letra con tiempos)
        LrclibGet,        // GET /api/get
        LrclibSearch,     // GET /api/search
        NeteaseSearch,    // GET music.163.com/api/search/get
        NeteaseLyric      // GET music.163.com/api/song/lyric
    };

    void request(const QUrl &url, Stage stage, const QString &key);
    // Like request() but sending a JSON body (YouTube Music).
    void postJson(const QUrl &url, const QJsonObject &body, Stage stage,
                  const QString &key);
    void onGetReply(QNetworkReply *reply, const QString &key);
    void onSearchReply(QNetworkReply *reply, const QString &key);
    void onNeteaseSearchReply(QNetworkReply *reply, const QString &key);
    void onNeteaseLyricReply(QNetworkReply *reply, const QString &key);

    // ---- YouTube Music cascade -------------------------------------
    void startYtm();
    // Classic plan (LRCLIB -> NetEase), used when YouTube Music has no
    // lyrics for the track.
    void startLrclib();
    // Asks for /next for the candidate video number `index` of m_ytmIds.
    void ytmNextFor(int index);
    // Asks for /browse with the browseId of the lyrics found in /next.
    void ytmBrowseFor(const QString &browseId);
    // No video works: it carries on with LRCLIB.
    void ytmGiveUp(const QString &why);
    void onYtmSearchReply(QNetworkReply *reply, const QString &key);
    void onYtmNextReply(QNetworkReply *reply, const QString &key);
    void onYtmBrowseReply(QNetworkReply *reply, const QString &key);

    void startSearch();
    void startNetease();
    // Closes the search and emits `changed` with the accumulated result.
    void finish();
    void fail(const QString &message);
    // No synced lyrics in any source: it keeps the plain one if there is
    void settleOrFail();

    // Dumps a LRCLIB JSON object (get or search) into the state. A result
    // with "syncedLyrics" always wins; the plain one is only stored if
    // there is none yet.
    void applyPayload(const QJsonObject &obj);
    void rememberPlain(const QString &plain, const char *source);
    // Adopts an LRC as synced lyrics. `filterCredits` removes the credit
    // lines (typical in NetEase: 作词/作曲/...). It returns false if the LRC
    // is not usable (e.g. only credits), leaving the state untouched.
    bool adoptSynced(const QString &lrc, const QString &source,
                     bool filterCredits);
    // Scores the NetEase search results and picks the best one.
    int scoreNetease(const QJsonObject &song) const;

    static QVector<LrcLine> parseLrc(const QString &text, bool filterCredits);
    static bool looksLikeCredit(const QString &line);

    // ---- local Sonora cache (lyrics with WORD level timings) ------------
    // The Sonora desktop player caches in ~/.cache/sonora/cache.sqlite the
    // lyrics it already downloaded, indexed by YouTube video, with the
    // word level timings of Apple Music/Musixmatch. It is the SAME source
    // the desktop widget uses, so reading it gives word level karaoke
    // without asking the network for anything. It is only used if the
    // track has a video and it is in the cache; otherwise the normal
    // cascade carries on.
    bool trySonoraCache();
    // Fallback: the same Sonora cache searched by TITLE and ARTIST (not
    // only by videoId), like the shell widget does. It covers the tracks
    // whose videoId is not the one Sonora cached: without this they were
    // left with line level timings and the word level karaoke did not
    // show up.
    bool trySonoraByTitle();
    // Enriched LRC: besides the line timing it has the timing of every
    // word between angle brackets ("<mm:ss.xx>word"). That is what allows
    // the word level karaoke.
    static QVector<LrcLine> parseLrcWords(const QString &text);
    // Does the current lyrics bring word level timings?
    bool hasWordTimings() const;
    // Adopts already built lines (with words) as synced lyrics.
    bool adoptWorded(QVector<LrcLine> lines, const QString &source);

    // ---- state published for the desktop (inir widgets) ---------------
    // The app dumps its lyrics state in ~/.local/state/lotus-tune/ so the
    // lock screen and desktop widgets paint EXACTLY the same lyrics, with
    // the same clock and the same sync adjustment:
    //   lyrics.json          -> lines (with words), track meta, offset and
    //                          karaoke mode; it is written on a track, lyrics
    //                          or adjustment change.
    //   lyrics-runtime.json  -> engine position/state with a timestamp;
    //                          every ~1 s while playing and on pause or
    //                          seek.
    // The clock travels here and not through MPRIS because mpv's position
    // is real (microseconds) while the bus one arrives rounded for other
    // cases.
private:
    void publishTrack();          // pista nueva: reescribir ambos ficheros
    void publishLines();          // letra resuelta (o descartada): letras + meta
    void publishRuntime();        // posición/offset/playing al vuelo (ligero)
    void removePublished();       // sin letra o app fuera: borrar los ficheros
    // The engine and the publishing beat (position every ~1 s while playing).
    Player *m_engine = nullptr;
    QTimer *m_runtimeBeat = nullptr;
    double m_offset = 0.0;
    bool m_karaoke = true;

    QNetworkAccessManager *m_net = nullptr;
    QString m_trackKey;
    QString m_artist;
    QString m_title;
    int m_duration = 0;         // segundos redondeados
    // Number of fetch() in flight. Together with m_trackKey it drops any
    // reply from an old request even if the key repeats (e.g. two
    // fetch() in a row for the same track while the duration loaded).
    int m_gen = 0;
    QStringList m_ytmIds;       // vídeos candidatos de YouTube Music
    int m_ytmIdx = 0;           // candidato en curso
    QString m_ytmBrowseId;      // browseId «MPLYt_*» de la letra actual
    // True when the exact video m_videoId has already been tried and had
    // no lyrics: the title search then works as a fallback (once).
    bool m_exactTried = false;
    // Has NetEase already been asked for the word level timings? (it
    // avoids the loop: NetEase without "klyric" lands here again).
    bool m_neteaseTried = false;
    bool m_loading = false;
    bool m_hasLyrics = false;
    bool m_hasSynced = false;
    QString m_plain;
    QString m_synced;
    QString m_error;
    QString m_syncSource;       // "ytmusic" | "lrclib" | "netease"
    QString m_plainSource;      // "ytmusic" | "lrclib"
    QVector<LrcLine> m_lines;   // LRC cacheado y ordenado
    // Exact video being played (if the track came from YouTube): it is
    // tried first, before searching again by title.
    QString m_videoId;
};
