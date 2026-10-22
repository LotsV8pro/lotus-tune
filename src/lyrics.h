#pragma once

#include <QDateTime>
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
    Q_PROPERTY(QString synced READ synced NOTIFY changed)   // raw LRC
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
        double time;    // seconds from the start
        QString text;
        // WORD level timings (only if the source brings them): [{t,e,text}].
        // Empty in the line level sources (YTM/LRCLIB/NetEase).
        QVariantList words;
        bool instrumental = false;   // stretch without voice (only Sonora marks it)
    };

    // How well a word level source fits the song, once it is aligned with
    // the timeline of the video being played. The sources are compared
    // with this: the one that matches more lines is the same take of the
    // song, and the one with more word level timings has the richer
    // karaoke.
    struct WordedScore {
        int matched = 0;      // lines that matched the timeline of the video
        int total = 0;        // lines of the source
        int worded = 0;       // lines with word level timings
        double shift = 0.0;   // how much the source had to be moved
        bool usable = false;  // it is the same take of the song

        // True when this source fits the song better than `o`.
        bool betterThan(const WordedScore &o) const {
            if (!usable)
                return false;
            if (!o.usable)
                return true;
            // The ratio of matched lines (the sources have different
            // amounts of lines, so the counts are not comparable).
            const int lhs = matched * o.total;
            const int rhs = o.matched * total;
            if (lhs != rhs)
                return lhs > rhs;
            if (worded != o.worded)
                return worded > o.worded;
            return qAbs(shift) < qAbs(o.shift);
        }
    };

    // A word level source that can be shown: the lines as they came (not
    // moved yet) and where they came from.
    struct WordedCandidate {
        QVector<LrcLine> lines;
        QString source;
        bool local = false;   // it comes from the local Sonora cache
    };

    // Stage of the sources cascade; it travels attached to the reply to
    // know which handler has to process the answer.
    enum class Stage {
        YtmSearch,        // POST /youtubei/v1/search  (candidates)
        YtmNext,          // POST /youtubei/v1/next    («Lyrics» tab)
        YtmBrowse,        // POST /youtubei/v1/browse  (lyrics with timings)
        LrclibGet,        // GET /api/get
        LrclibSearch,     // GET /api/search
        NeteaseSearch,    // GET music.163.com/api/search/get
        NeteaseLyric,     // GET music.163.com/api/song/lyric
        MxmToken,         // GET apic.musixmatch.com/ws/1.1/token.get
        MxmRichsync       // GET apic.musixmatch.com/ws/1.1/macro.subtitles.get
    };

    void request(const QUrl &url, Stage stage, const QString &key);
    // The word level timings come from the ALBUM while the reference
    // timeline is the video being played: the text of the reference wins
    // (it is the version that is being sung) and the offset is the median
    // of the difference between the lines that match by text.
    bool alignWords(QVector<LrcLine> &lines,
                    const QVector<LrcLine> &reference,
                    WordedScore *score = nullptr);
    // The last word of a line usually inherits the end of the line: the
    // sources mark the end of the phrase, not the end of the word. When
    // the line is long the karaoke front stays on that word for seconds
    // and the phrase looks like it is still being sung. The word is cut
    // to what the other words of the line take.
    static void clampStretchedWords(QVector<LrcLine> &lines);
    // The lines that are not sung (the title of the song with the artist,
    // a line of credits...) are removed: their words are not real timings
    // (they cover half of the song) and they spoil the karaoke.
    static void dropJunkLines(QVector<LrcLine> &lines, const QString &title,
                              const QString &artist);
    // Prepares the lines that are going to be shown: the instrumental
    // markers of the video are added, the long gaps are marked, the
    // stretched words are cut and the lines that are not sung are
    // removed.
    void prepareWordedLines(QVector<LrcLine> &lines) const;
    // Picks the word level source that fits the song best and shows it.
    // The sources are compared with the timeline of the video being
    // played; without it they cannot be compared and the first one (the
    // local cache, which is instant) is used.
    void pickWorded();
    // An instrumental stretch is marked with as many "♪" as it lasts.
    static void expandInstrumentals(QVector<LrcLine> &lines);
    // Musixmatch: the word level timings ("richsync") of the very same
    // catalogue YouTube Music uses, but with the timing of every word.
    void startMusixmatch();
    void requestMusixmatchRichsync();
    void onMxmTokenReply(QNetworkReply *reply, const QString &key);
    void onMxmRichsyncReply(QNetworkReply *reply, const QString &key);
    // The richsync body: one entry per line, with the words and their
    // offsets inside the line.
    static QVector<LrcLine> parseRichsync(const QJsonArray &arr);
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
    // Adopts already built lines (with words) as synced lyrics. The
    // source is kept as a candidate: the ones that arrive later are
    // compared with it and the best aligned one is shown.
    bool adoptWorded(QVector<LrcLine> lines, const QString &source,
                     bool local = false);
    // True when the current lyrics carry word level timings.
    bool m_worded = false;
    // The word level sources that are on the table (the local cache, the
    // network...) and the one that is being shown.
    QVector<WordedCandidate> m_candidates;
    int m_current = -1;
    // The source that is on screen, as it came (before the alignment
    // moved it) and where it came from.
    QVector<LrcLine> m_wordedRaw;
    QString m_wordedSource;
    bool m_localWorded = false;   // the one on screen is the local cache
    WordedScore m_wordedScore;

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
    void publishTrack();          // new track: rewrite both files
    void publishLines();          // resolved lyrics (or discarded): lyrics + meta
    void publishRuntime();        // position/offset/playing on the fly (light)
    void removePublished();       // no lyrics or app gone: delete the files
    // The engine and the publishing beat (position every ~1 s while playing).
    Player *m_engine = nullptr;
    QTimer *m_runtimeBeat = nullptr;
    double m_offset = 0.0;
    bool m_karaoke = true;

    QNetworkAccessManager *m_net = nullptr;
    QString m_trackKey;
    QString m_artist;
    QString m_title;
    int m_duration = 0;         // rounded seconds
    // Number of fetch() in flight. Together with m_trackKey it drops any
    // reply from an old request even if the key repeats (e.g. two
    // fetch() in a row for the same track while the duration loaded).
    int m_gen = 0;
    QStringList m_ytmIds;       // candidate videos from YouTube Music
    int m_ytmIdx = 0;           // candidate in progress
    QString m_ytmBrowseId;      // browseId «MPLYt_*» of the current lyrics
    // True when the exact video m_videoId has already been tried and had
    // no lyrics: the title search then works as a fallback (once).
    bool m_exactTried = false;
    // Has NetEase already been asked for the word level timings? (it
    // avoids the loop: NetEase without "klyric" lands here again).
    bool m_neteaseTried = false;
    // Musixmatch: the token lasts ten minutes and it is kept on disk.
    bool m_mxmTried = false;
    // Which variant of the query is being tried: Musixmatch matches a
    // different song depending on how the artist is written.
    int m_mxmVariant = 0;
    QString m_mxmToken;
    QDateTime m_mxmTokenAt;
    bool m_loading = false;
    bool m_hasLyrics = false;
    bool m_hasSynced = false;
    QString m_plain;
    QString m_synced;
    QString m_error;
    QString m_syncSource;       // "ytmusic" | "lrclib" | "netease"
    QString m_plainSource;      // "ytmusic" | "lrclib"
    QVector<LrcLine> m_lines;   // cached and sorted LRC
    // The timed lines of the video being played: the reference the word
    // level timings are aligned with.
    QVector<LrcLine> m_refLines;
    // Sonora lyrics without word level timings: they are only used when
    // the network has nothing better (the network may bring the real
    // karaoke, the local cache usually does not).
    QVector<LrcLine> m_cacheLines;
    QString m_cacheSource;
    // Exact video being played (if the track came from YouTube): it is
    // tried first, before searching again by title.
    QString m_videoId;
};
