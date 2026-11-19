#include <QtTest/QtTest>
#include <QDateTime>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QStandardPaths>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QUrl>
#include <QVector>

#include "downloads.h"
#include "player.h"
#include "audiocache.h"
#include "errortext.h"
#include "appconfig.h"
#include "catalog.h"
#include "sources.h"
#include "lyrics.h"
#include "updates.h"
#include "theme.h"
#include "appconfig.h"
#include "paths.h"

class TestLotusTune : public QObject
{
    Q_OBJECT

    // Temporary HOME: Catalog writes its state in
    // ~/.local/state/lotus-tune through QDir::homePath(), so the whole suite
    // runs with the HOME pointing here to avoid touching the user's library.
    QTemporaryDir *m_homeDir = nullptr;

    // A line with the timing of every word. The times are the ones the
    // sources give: the last word of a line inherits the end of the line.
    static Lyrics::LrcLine wordLine(double time, const QString &text,
                                    const QVector<double> &starts,
                                    double lastEnd);
    static double durationOf(const QVariantMap &word);

private slots:
    void initTestCase();
    void cleanupTestCase();
    void testSafeSegment();
    void testFriendlyError();
    void testPartialFilesCleanup();
    void testCountAudioFiles();
    void testUniqueListFolder();
    void testNormalizeUrl();
    void testAppConfig();
    void testSourceManager();
    void testVideoIdOf();
    void testPlayCountArtist();
    void testLabelChannelArtist();
    void testLikes();
    void testLyricsState();
    void testPublishedArt();
    void testSearchCandidatesAndQueryText();
    void testLyricsTitleLines();
    void testParseLrc();
    void testParseLyricsfile();
    void testLrclibWordSyncPayload();
    void testLooksLikeCredit();
    void testLineIndexAt();
    void testWordTimings();
    void testParseTtml();
    void testInstrumentalMarkers();
    void testConsecutiveInstrumentalMarkers();
    void testNotesOnlyLineIsInstrumental();
    void testRichsyncPhraseEnd();
    void testLrcSilenceBoundary();
    void testSungCreditLine();
    void testVideoEndWins();
    void testBestLrcRecordWins();
    void testMusicalEndKept();
    void testReferenceVersion();
    void testWrongSongDiscardedByPlain();
    void testRestoreSpacesFromPlain();
    void testGluedShortWordsAtLineEnd();
    void testGluedApostrophesAndTypos();
    void testJoinGluedProviderWords();
    void testCollapseDuplicateLines();
    void testLrcExportImport();
    void testInstrumentalSweep();
    void testSanitizeWordStamps();
    void testAccentFromSettings();
    void testLotusAccentOnLightBg();
    void testSettingsExportImport();
    void testSearchLibraryTracks();
    void testUpdateHelpers();
    void testInstallerHash();
    void testAudioCachePrune();
    void testAudioCacheClear();
    void testFriendlyNetError();
};

void TestLotusTune::initTestCase()
{
    qDebug() << "Iniciando suite de pruebas de Lotus Tune...";

    m_homeDir = new QTemporaryDir;
    QVERIFY(m_homeDir->isValid());
    qputenv("HOME", QFile::encodeName(m_homeDir->path()));
    QCOMPARE(QDir::homePath(), m_homeDir->path());
}

void TestLotusTune::cleanupTestCase()
{
    delete m_homeDir;
    m_homeDir = nullptr;
}

void TestLotusTune::testSafeSegment()
{
    // Basic segments
    QCOMPARE(Downloads::safeSegment("Coldplay - Yellow"), QString("Coldplay - Yellow"));

    // Segments with characters forbidden in file systems
    QString invalid = "Track: Title / With \\ Slashes * And ? Quotes \" < > |";
    QString safe = Downloads::safeSegment(invalid);
    QVERIFY(!safe.contains('/'));
    QVERIFY(!safe.contains('\\'));
    QVERIFY(!safe.contains(':'));
    QVERIFY(!safe.contains('*'));
    QVERIFY(!safe.contains('?'));
    QVERIFY(!safe.contains('"'));
    QVERIFY(!safe.contains('<'));
    QVERIFY(!safe.contains('>'));
    QVERIFY(!safe.contains('|'));

    // Dots and spaces at the beginning/end
    QCOMPARE(Downloads::safeSegment("...test..."), QString("test"));
    QCOMPARE(Downloads::safeSegment("   test   "), QString("test"));

    // Empty text falls back to "download"
    QCOMPARE(Downloads::safeSegment(""), QString("descarga"));
    QCOMPARE(Downloads::safeSegment("   "), QString("descarga"));
    QCOMPARE(Downloads::safeSegment(":::"), QString("descarga"));

    // Unicode characters with accents
    QString unicodeText = "Canción Épica (Año 2026)";
    QCOMPARE(Downloads::safeSegment(unicodeText), unicodeText);

    // Length limit (truncated to <= 180 bytes)
    QString veryLong(200, 'A');
    QString safeLong = Downloads::safeSegment(veryLong);
    QVERIFY(safeLong.toUtf8().size() <= 180);
}

void TestLotusTune::testFriendlyError()
{
    // 404 / does not exist
    QString err404 = Downloads::friendlyError("ERROR: [youtube] Video does not exist or was removed");
    QVERIFY(err404.contains("no existe") || err404.contains("privada"));

    // Private content / login
    QString errPrivate = Downloads::friendlyError("ERROR: Sign in to confirm you’re not a bot / private video");
    QVERIFY(errPrivate.contains("privado") || errPrivate.contains("sesión"));

    // Network failure
    QString errNet = Downloads::friendlyError("ERROR: unable to download webpage: <urlopen error timed out>");
    QVERIFY(errNet.contains("red") || errNet.contains("conexión"));

    // Not enough space
    QString errDisk = Downloads::friendlyError("ERROR: [Errno 28] No space left on device");
    QVERIFY(errDisk.contains("espacio"));

    // ffmpeg missing
    QString errFfmpeg = Downloads::friendlyError("ERROR: ffprobe or avprobe not found. Please install ffmpeg.");
    QVERIFY(errFfmpeg.contains("ffmpeg"));

    // Empty message
    QCOMPARE(Downloads::friendlyError(""), QString("La descarga falló."));
}

void TestLotusTune::testPartialFilesCleanup()
{
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString dirPath = tempDir.path();

    // Create temporary and partial files
    QStringList partials = {
        dirPath + "/song.mp3.part",
        dirPath + "/song.mp3.ytdl",
        dirPath + "/audio.opus.temp",
        dirPath + "/track.m4a.tmp",
        dirPath + "/stream.temp-frag1"
    };

    for (const QString &p : partials) {
        QFile f(p);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("partial data");
        f.close();
        QVERIFY(QFile::exists(p));
    }

    // Create a legitimate audio file
    QString audioFile = dirPath + "/final_song.mp3";
    {
        QFile f(audioFile);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("audio data");
        f.close();
    }
    QVERIFY(QFile::exists(audioFile));

    // Clean the partials
    Downloads::removePartials(dirPath);

    // Check that the partials were removed
    for (const QString &p : partials) {
        QVERIFY2(!QFile::exists(p), qPrintable(p + " no fue eliminado"));
    }

    // The legitimate file must still exist
    QVERIFY(QFile::exists(audioFile));
}

void TestLotusTune::testCountAudioFiles()
{
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString dirPath = tempDir.path();

    QCOMPARE(Downloads::countAudioFiles(dirPath), 0);

    // Create files of several types
    QStringList audios = {"track1.mp3", "track2.m4a", "track3.opus", "track4.flac"};
    for (const QString &a : audios) {
        QFile f(dirPath + "/" + a);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();
    }

    // Create non audio files
    QStringList others = {"cover.jpg", "info.json", "notes.txt"};
    for (const QString &o : others) {
        QFile f(dirPath + "/" + o);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();
    }

    QCOMPARE(Downloads::countAudioFiles(dirPath), 4);
}

void TestLotusTune::testUniqueListFolder()
{
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());

    Downloads dl;
    dl.setFolder(tempDir.path());

    // First time: original name
    QString f1 = dl.uniqueListFolder("Rock Clásico", "https://music.youtube.com/playlist?list=123");
    QCOMPARE(f1, QString("Rock Clásico"));

    // Simulate that the folder is created with metadata
    QString fullPath = tempDir.path() + "/Rock Clásico";
    QDir().mkpath(fullPath);
    QFile metaFile(fullPath + "/.lotus-list.json");
    QVERIFY(metaFile.open(QIODevice::WriteOnly));
    metaFile.write("{\"url\":\"https://music.youtube.com/playlist?list=123\"}");
    metaFile.close();

    // Same list (same URL): it must reuse the same folder to resume
    QString fSame = dl.uniqueListFolder("Rock Clásico", "https://music.youtube.com/playlist?list=123");
    QCOMPARE(fSame, QString("Rock Clásico"));

    // Another different list with the same name (other URL): it must assign the (2) suffix
    QString fDifferent = dl.uniqueListFolder("Rock Clásico", "https://music.youtube.com/playlist?list=999");
    QCOMPARE(fDifferent, QString("Rock Clásico (2)"));
}

void TestLotusTune::testNormalizeUrl()
{
    // music.youtube.com to www.youtube.com
    QString musicUrl = "https://music.youtube.com/watch?v=dQw4w9WgXcQ";
    QCOMPARE(Player::normalizeUrl(musicUrl), QString("https://www.youtube.com/watch?v=dQw4w9WgXcQ"));

    // www.youtube.com untouched
    QString wwwUrl = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
    QCOMPARE(Player::normalizeUrl(wwwUrl), wwwUrl);

    // Local file untouched
    QString fileUrl = "file:///home/lots/music/song.opus";
    QCOMPARE(Player::normalizeUrl(fileUrl), fileUrl);

    // Empty untouched
    QCOMPARE(Player::normalizeUrl(""), QString(""));
}

void TestLotusTune::testAppConfig()
{
    AppConfig cfg;
    cfg.set("test_key_1.0", "lotus_tune_ready");
    QCOMPARE(cfg.get("test_key_1.0"), QString("lotus_tune_ready"));
    QCOMPARE(cfg.get("non_existent_key_xyz"), QString(""));
}

void TestLotusTune::testSourceManager()
{
    SourceManager sm;
    // YouTube Music is the default active source and it is ready.
    QCOMPARE(sm.activeId(), QString("ytm"));
    QVERIFY(sm.isReady("ytm"));
    QVERIFY(sm.isReady("soundcloud"));
    // The not implemented backends come "locked" (spotify, tidal).
    QVERIFY(!sm.isReady("spotify"));
    QVERIFY(!sm.isReady("tidal"));
    QVERIFY(sm.entry("no-existe").isEmpty());

    // Search prefixes that are passed to yt-dlp.
    QCOMPARE(sm.searchPrefix("ytm"), QString("ytsearch15:"));
    QCOMPARE(sm.searchPrefix("soundcloud"), QString("scsearch15:"));
    QCOMPARE(sm.list().size(), 2);

    // Change the source; an unknown source is ignored and re-selecting
    // the same one does not emit again.
    QSignalSpy changed(&sm, &SourceManager::activeChanged);
    sm.select("soundcloud");
    QCOMPARE(sm.activeId(), QString("soundcloud"));
    sm.setActiveId("no-existe");
    QCOMPARE(sm.activeId(), QString("soundcloud"));
    const int emitted = changed.count();
    sm.setActiveId("soundcloud");
    QCOMPARE(changed.count(), emitted);
}

void TestLotusTune::testVideoIdOf()
{
    SourceManager sources;
    Catalog catalog(&sources);

    // The normal shapes of a YouTube URL.
    QCOMPARE(catalog.videoIdOf("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
             QString("dQw4w9WgXcQ"));
    QCOMPARE(catalog.videoIdOf("https://music.youtube.com/watch?v=dQw4w9WgXcQ&t=42"),
             QString("dQw4w9WgXcQ"));
    QCOMPARE(catalog.videoIdOf("https://youtu.be/dQw4w9WgXcQ?si=abcDEF"),
             QString("dQw4w9WgXcQ"));
    QCOMPARE(catalog.videoIdOf("https://www.youtube.com/shorts/dQw4w9WgXcQ"),
             QString("dQw4w9WgXcQ"));

    // A raw videoId of 11 characters passes as it is.
    QCOMPARE(catalog.videoIdOf("dQw4w9WgXcQ"), QString("dQw4w9WgXcQ"));

    // What does not carry a videoId stays empty (playlists, rubbish, empty).
    QCOMPARE(catalog.videoIdOf(""), QString(""));
    QCOMPARE(catalog.videoIdOf("   "), QString(""));
    QCOMPARE(catalog.videoIdOf("https://music.youtube.com/playlist?list=RDCLAK5uy_l"),
             QString(""));
    QCOMPARE(catalog.videoIdOf("no es una url"), QString(""));

    // Downloaded local file: the real id comes from the sibling .info.json.
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString audio = dir.path() + QStringLiteral("/Canci\u00f3n.opus");
    {
        QFile f(audio);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("opus");
    }
    {
        QFile info(dir.path() + QStringLiteral("/Canci\u00f3n.info.json"));
        QVERIFY(info.open(QIODevice::WriteOnly));
        info.write("{\"id\": \"dQw4w9WgXcQ\"}");
    }
    QCOMPARE(catalog.videoIdOf(QUrl::fromLocalFile(audio).toString()),
             QString("dQw4w9WgXcQ"));
}

void TestLotusTune::testPlayCountArtist()
{
    // YouTube writes the play count in the artist column of some lists,
    // with a non-breaking space between the number and the unit.
    const QString counts[] = {
        QString::fromUtf8("19 M reproducciones"),
        QString::fromUtf8("3,3\u00a0M reproducciones"),
        QString::fromUtf8("262\u202fK reproducciones"),
        QStringLiteral("2.1M views"),
    };
    for (const QString &count : counts)
        QVERIFY2(Catalog::looksLikePlayCount(count),
                 count.toUtf8().constData());

    // Real artists, including one with a non-breaking space, survive.
    QVERIFY(!Catalog::looksLikePlayCount(QStringLiteral("Skrillex")));
    QVERIFY(!Catalog::looksLikePlayCount(
        QString::fromUtf8("Porter\u00a0Robinson")));
}

void TestLotusTune::testLabelChannelArtist()
{
    // Known label/channel columns must not become the name of a home radio.
    QCOMPARE(Catalog::realArtistFromTitle(
                 QStringLiteral("SUMERIAN"),
                 QStringLiteral("Bring Me The Horizon - Can You Feel My Heart")),
             QStringLiteral("Bring Me The Horizon"));
    QCOMPARE(Catalog::realArtistFromTitle(
                 QStringLiteral("Fearless Records"),
                 QStringLiteral("Pierce The Veil - King For A Day")),
             QStringLiteral("Pierce The Veil"));
    QCOMPARE(Catalog::realArtistFromTitle(
                 QStringLiteral("riserecords and 2 more"),
                 QStringLiteral("The Ghost Inside - Move Myself")),
             QStringLiteral("The Ghost Inside"));
    QCOMPARE(Catalog::realArtistFromTitle(
                 QStringLiteral("Epitaph Records"),
                 QStringLiteral("Bad Religion - American Jesus")),
             QStringLiteral("Bad Religion"));
    // Real artist columns and titles without the dash pattern are untouched.
    QCOMPARE(Catalog::realArtistFromTitle(
                 QStringLiteral("Skrillex"), QStringLiteral("Purpose - A Key")),
             QStringLiteral("Skrillex"));
    QCOMPARE(Catalog::realArtistFromTitle(
                 QStringLiteral("SUMERIAN"), QStringLiteral("No Dash Here")),
             QStringLiteral("SUMERIAN"));
}

void TestLotusTune::testLikes()
{
    SourceManager sources;
    Catalog catalog(&sources);

    // Local vote: turn on and turn off; by URL the videoId is resolved first.
    QVERIFY(!catalog.isLiked("dQw4w9WgXcQ"));
    QSignalSpy liked(&catalog, &Catalog::likedChanged);
    catalog.setLiked("dQw4w9WgXcQ", true);
    QVERIFY(catalog.isLiked("dQw4w9WgXcQ"));
    QVERIFY(catalog.isLiked("https://youtu.be/dQw4w9WgXcQ"));
    QCOMPARE(liked.count(), 1);

    // Empty id: it does nothing and does not emit.
    catalog.setLiked(QString(), true);
    QCOMPARE(liked.count(), 1);

    catalog.setLiked("dQw4w9WgXcQ", false);
    QVERIFY(!catalog.isLiked("dQw4w9WgXcQ"));

    // Persistence: the vote is stored in liked.json under the test HOME
    // (never under the real user's library).
    catalog.setLiked("abc123DEF45", true);
    QFile f(QDir::homePath() + QStringLiteral("/.local/state/lotus-tune/liked.json"));
    QVERIFY(f.open(QIODevice::ReadOnly));
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    const QJsonArray idsArr = o.value(QStringLiteral("ids")).toArray();
    QStringList ids;
    for (const QJsonValue &v : idsArr)
        ids << v.toString();
    QVERIFY(ids.contains(QStringLiteral("abc123DEF45")));
}

void TestLotusTune::testLyricsState()
{
    Lyrics lyrics;
    // Initial state: nothing loaded and nothing to highlight.
    QVERIFY(!lyrics.loading());
    QVERIFY(!lyrics.hasLyrics());
    QVERIFY(!lyrics.hasSynced());
    QVERIFY(lyrics.lines().isEmpty());
    QVERIFY(lyrics.trackKey().isEmpty());
    QCOMPARE(lyrics.lineIndexAt(0), -1);
    QCOMPARE(lyrics.lineIndexAt(120.5), -1);
    QCOMPARE(lyrics.lineIndexAt(-5), -1);

    // clear() over an empty one leaves the state empty but warns the UI.
    QSignalSpy changed(&lyrics, &Lyrics::changed);
    lyrics.clear();
    QCOMPARE(changed.count(), 1);
    QVERIFY(!lyrics.hasLyrics());
    QVERIFY(lyrics.lines().isEmpty());
}

void TestLotusTune::testPublishedArt()
{
    Lyrics lyrics;
    lyrics.m_trackKey = QStringLiteral("Artist - Title");
    lyrics.m_title = QStringLiteral("Title");
    lyrics.m_artist = QStringLiteral("Artist");
    lyrics.m_videoId = QStringLiteral("abc123");
    const QString art = QStringLiteral("https://i.ytimg.com/vi/abc123/hqdefault.jpg");
    lyrics.setPublishedArt(art);

    QFile f(AppPaths::stateDir() + QStringLiteral("/lyrics.json"));
    QVERIFY(f.open(QIODevice::ReadOnly));
    const QJsonObject obj = QJsonDocument::fromJson(f.readAll()).object();
    QCOMPARE(obj.value(QStringLiteral("art")).toString(), art);
    QCOMPARE(obj.value(QStringLiteral("title")).toString(), QStringLiteral("Title"));
    QCOMPARE(obj.value(QStringLiteral("artist")).toString(), QStringLiteral("Artist"));
    QCOMPARE(obj.value(QStringLiteral("videoId")).toString(), QStringLiteral("abc123"));

    QFile rt(AppPaths::stateDir() + QStringLiteral("/lyrics-runtime.json"));
    QVERIFY(rt.open(QIODevice::ReadOnly));
    const QJsonObject runtime = QJsonDocument::fromJson(rt.readAll()).object();
    QCOMPARE(runtime.value(QStringLiteral("art")).toString(), art);
}

void TestLotusTune::testSearchCandidatesAndQueryText()
{
    // Un titulo raro genera varias variantes distintas (sin parentesis,
    // guion partido, sin palabras de ruido) y sin duplicados.
    const QVector<Lyrics::SearchCandidate> cs =
        Lyrics::buildSearchCandidates(QStringLiteral("MK"),
            QStringLiteral("17 - Eternal rest in time (Official Video)"));
    QVERIFY(cs.size() >= 3);
    QSet<QString> seen;
    for (const Lyrics::SearchCandidate &c : cs)
        seen.insert(c.title + QStringLiteral("|") + c.artist);
    QCOMPARE(seen.size(), cs.size());

    bool noParen = false, split = false, noNoise = false;
    for (const Lyrics::SearchCandidate &c : cs) {
        if (!c.title.contains(QLatin1Char('(')))
            noParen = true;
        if (c.title == QStringLiteral("Eternal rest in time"))
            split = true;
        if (!c.title.contains(QStringLiteral("Official"), Qt::CaseInsensitive))
            noNoise = true;
    }
    QVERIFY(noParen);
    QVERIFY(split);
    QVERIFY(noNoise);

    // queryText quita signos que los catalogos no indexan.
    QCOMPARE(Lyrics::queryText(QStringLiteral("Nosebleed!")),
             QStringLiteral("Nosebleed"));
    QCOMPARE(Lyrics::queryText(QStringLiteral("Let us cry / lloremos")),
             QStringLiteral("Let us cry lloremos"));
    QCOMPARE(Lyrics::queryText(QStringLiteral("Nose Bleed (Live)")),
             QStringLiteral("Nose Bleed Live"));

    // Sufijos de video: con artista se quita el prefijo "Artist - " y el sufijo.
    QCOMPARE(Lyrics::cleanTitleForSearch(
                 QStringLiteral("Spiritbox - Perfect Soul (Official Video)"),
                 QStringLiteral("Spiritbox")),
             QStringLiteral("Perfect Soul"));
    QCOMPARE(Lyrics::cleanTitleForSearch(
                 QStringLiteral("Bad Omens - Just Pretend (Official Music Video)"),
                 QStringLiteral("Bad Omens")),
             QStringLiteral("Just Pretend"));
    QCOMPARE(Lyrics::cleanTitleForSearch(
                 QStringLiteral("Poppy - New Way Out (Official Visualizer)"),
                 QStringLiteral("Poppy")),
             QStringLiteral("New Way Out"));
    QCOMPARE(Lyrics::cleanTitleForSearch(
                 QStringLiteral("Avoid - Instrumental [Lyric Video]"),
                 QStringLiteral("Avoid")),
             QStringLiteral("Instrumental"));
    QCOMPARE(Lyrics::cleanTitleForSearch(
                 QStringLiteral("MK - 17 Official Audio"),
                 QStringLiteral("MK")),
             QStringLiteral("17"));
}

void TestLotusTune::testLyricsTitleLines()
{
    // The header (title + artist) is not sung: it is removed. The lines of
    // the song that repeat the title ARE sung: they must survive, or the
    // chorus disappears from the lyrics ("faltan frases").
    QVector<Lyrics::LrcLine> lines;
    auto add = [&lines](double t, const QString &text) {
        Lyrics::LrcLine l;
        l.time = t;
        l.text = text;
        lines.append(l);
    };
    add(0.0, "Three Days Grace - I Hate Everything About You");
    add(12.0, "Every time we lie awake");
    add(20.0, "I Hate Everything About You");
    add(30.0, "Why can't I see?");
    add(45.0, "I Hate Everything About You");

    Lyrics::dropJunkLines(lines, "I Hate Everything About You",
                          "Three Days Grace");

    QCOMPARE(lines.size(), 4);
    QCOMPARE(lines.at(0).text, QString("Every time we lie awake"));
    // The chorus is kept, with its timings.
    QCOMPARE(lines.at(1).time, 20.0);
    QCOMPARE(lines.at(1).text, QString("I Hate Everything About You"));
    QCOMPARE(lines.at(3).time, 45.0);
}

// LRCLIB's word-synced records arrive as a small YAML document. The app
// used to ignore it and fell back to the line-only LRC.
void TestLotusTune::testParseLyricsfile()
{
    const QString yaml = QStringLiteral(
        "version: '1.0'\n"
        "metadata:\n"
        "  title: Song\n"
        "lines:\n"
        "- text: Hello, it's me\n"
        "  start_ms: 6320\n"
        "  end_ms: 9500\n"
        "  words:\n"
        "  - text: 'Hello, '\n"
        "    start_ms: 6320\n"
        "  - text: 'it''s '\n"
        "    start_ms: 9000\n"
        "  - text: me\n"
        "    start_ms: 9340\n"
        "plain: |\n"
        "  The club is mine\n");
    const QVector<Lyrics::LrcLine> lines = Lyrics::parseLyricsfile(yaml);
    QCOMPARE(lines.size(), 1);
    QCOMPARE(lines.at(0).text, QStringLiteral("Hello, it's me"));
    QCOMPARE(lines.at(0).time, 6.32);
    QCOMPARE(lines.at(0).words.size(), 3);
    const QVariantMap w = lines.at(0).words.at(1).toMap();
    QCOMPARE(w.value(QStringLiteral("text")).toString(), QStringLiteral("it's "));
    QCOMPARE(w.value(QStringLiteral("t")).toDouble(), 9.0);
    // No end_ms in the source: the word ends where the next one starts.
    QCOMPARE(w.value(QStringLiteral("e")).toDouble(), 9.34);
    const QVariantMap last = lines.at(0).words.at(2).toMap();
    QCOMPARE(last.value(QStringLiteral("e")).toDouble(), 9.5);
    // Plain-only records (lines: []) yield nothing and are left alone.
    QVERIFY(Lyrics::parseLyricsfile(QStringLiteral("version: '1.0'\nlines: []\nplain: |\n  hi\n")).isEmpty());
}

// A real LRCLIB payload with word-level lyricsfile must end as karaoke,
// not as a line-only track.
void TestLotusTune::testLrclibWordSyncPayload()
{
    Lyrics lyrics;
    lyrics.m_title = QStringLiteral("Hello");
    lyrics.m_artist = QStringLiteral("Adele");
    lyrics.m_duration = 300;
    const QString yaml = QStringLiteral(
        "version: '1.0'\n"
        "lines:\n"
        "- text: Hello, it's me\n"
        "  start_ms: 6320\n"
        "  end_ms: 9500\n"
        "  words:\n"
        "  - text: 'Hello, '\n"
        "    start_ms: 6320\n"
        "  - text: 'it''s '\n"
        "    start_ms: 9000\n"
        "  - text: me\n"
        "    start_ms: 9340\n"
        "- text: I was wondering\n"
        "  start_ms: 11920\n"
        "  end_ms: 14000\n"
        "  words:\n"
        "  - text: 'I '\n"
        "    start_ms: 11920\n"
        "  - text: 'was wondering'\n"
        "    start_ms: 12180\n");
    QJsonObject obj;
    obj.insert(QStringLiteral("trackName"), QStringLiteral("Hello"));
    obj.insert(QStringLiteral("artistName"), QStringLiteral("Adele"));
    obj.insert(QStringLiteral("plainLyrics"), QStringLiteral("Hello, it's me"));
    obj.insert(QStringLiteral("syncedLyrics"), QStringLiteral("[00:06.32]Hello, it's me"));
    obj.insert(QStringLiteral("lyricsfile"), yaml);
    lyrics.applyPayload(obj);
    QVERIFY(lyrics.m_worded);
    QCOMPARE(lyrics.m_lines.size(), 2);
    QCOMPARE(lyrics.m_lines.at(0).words.size(), 3);
}

void TestLotusTune::testParseLrc()
{
    // Basic LRC: exact timings and trimmed text.
    const QVector<Lyrics::LrcLine> basic = Lyrics::parseLrc(
        "[00:12.50]  Primer verso \n[01:05.00]Segundo verso\n", true);
    QCOMPARE(basic.size(), 2);
    QCOMPARE(basic[0].time, 12.5);
    QCOMPARE(basic[0].text, QString("Primer verso"));
    QCOMPARE(basic[1].time, 65.0);
    QCOMPARE(basic[1].text, QString("Segundo verso"));

    // Several timestamps share the text of the line (repeated chorus).
    const QVector<Lyrics::LrcLine> chorus = Lyrics::parseLrc(
        "[00:10.00][00:50.00]estribillo\n", true);
    QCOMPARE(chorus.size(), 2);
    QCOMPARE(chorus[0].time, 10.0);
    QCOMPARE(chorus[1].time, 50.0);
    QCOMPARE(chorus[0].text, chorus[1].text);

    // The colon also works as a tenths separator: 12:50 = 12.5 s.
    const QVector<Lyrics::LrcLine> colon = Lyrics::parseLrc("[00:12:50]x\n", true);
    QCOMPARE(colon.size(), 1);
    QCOMPARE(colon[0].time, 12.5);

    // Three digit minutes: 100:01.50 = 6001.5 s.
    const QVector<Lyrics::LrcLine> long_ = Lyrics::parseLrc("[100:01.50]larga\n", true);
    QCOMPARE(long_.size(), 1);
    QCOMPARE(long_[0].time, 6001.5);

    // Metadata ([ar:...], [ti:...]) and lines without time are discarded.
    QVERIFY(Lyrics::parseLrc("[ar:Radiohead]\n[ti:Creep]\n", true).isEmpty());
    QVERIFY(Lyrics::parseLrc("", true).isEmpty());

    // A timestamp with no text behind it does not generate a line.
    QVERIFY(Lyrics::parseLrc("[00:10.00]\n", true).isEmpty());

    // The output comes sorted by time even if the input is not.
    const QVector<Lyrics::LrcLine> sorted = Lyrics::parseLrc(
        "[01:00.00]tercero\n[00:30.00]primero\n[00:45.00]segundo\n", true);
    QCOMPARE(sorted.size(), 3);
    QCOMPARE(sorted[0].text, QString("primero"));
    QCOMPARE(sorted[1].text, QString("segundo"));
    QCOMPARE(sorted[2].text, QString("tercero"));

    // Credits: out with the filter, in without it.
    const QString mixed = QStringLiteral(
        "[00:01.00]作词 : 张三\n[00:02.00]Written by Max Martin\n"
        "[00:03.00]verso normal\n[00:04.00]otro verso\n");
    const QVector<Lyrics::LrcLine> kept = Lyrics::parseLrc(mixed, true);
    QCOMPARE(kept.size(), 2);
    QCOMPARE(kept[0].text, QString("verso normal"));
    QCOMPARE(kept[1].text, QString("otro verso"));
    QCOMPARE(Lyrics::parseLrc(mixed, false).size(), 4);
}

void TestLotusTune::testLooksLikeCredit()
{
    // Credits in the NetEase style (CJK).
    QVERIFY(Lyrics::looksLikeCredit(QString::fromUtf8("\u8bcd\u66f2 : \u5f20\u4e09")));
    QVERIFY(Lyrics::looksLikeCredit(QString::fromUtf8("\u7279\u522b\u9e23\u8c22 : \u67d0\u4eba")));

    // Credits in English.
    QVERIFY(Lyrics::looksLikeCredit("Written by Max Martin"));
    QVERIFY(Lyrics::looksLikeCredit("produced by shellback"));
    QVERIFY(Lyrics::looksLikeCredit("  Recorded by Someone"));

    // Normal verses that must not disappear: the list only counts at
    // the beginning of the line.
    QVERIFY(!Lyrics::looksLikeCredit("Shut up and dance with me"));
    QVERIFY(!Lyrics::looksLikeCredit("By your side tonight"));
    QVERIFY(!Lyrics::looksLikeCredit("I am written in the stars"));
    QVERIFY(!Lyrics::looksLikeCredit("Composer: Someone"));
}

void TestLotusTune::testLineIndexAt()
{
    Lyrics lyrics;
    // adoptSynced requires at least 2 usable lines.
    QVERIFY(!lyrics.adoptSynced("[00:12.50]una línea sola", "test", true));
    QVERIFY(!lyrics.hasSynced());

    // Filtered credits leave less than 2 lines: the whole LRC is rejected.
    QVERIFY(!lyrics.adoptSynced(
        "[00:01.00]作词 : X\n[00:02.00]Written by Y\n", "test", true));

    // With the filter off, those same lines are accepted.
    QVERIFY(lyrics.adoptSynced(
        "[00:01.00]作词 : X\n[00:02.00]Written by Y\n", "test", false));
    QVERIFY(lyrics.hasSynced());
    QCOMPARE(lyrics.lines().size(), 2);

    // Bisection: -1 before the first line, the index at every exact time,
    // the previous one between lines and the last one past the end.
    QCOMPARE(lyrics.lineIndexAt(0.5), -1);
    QCOMPARE(lyrics.lineIndexAt(-1.0), -1);
    QCOMPARE(lyrics.lineIndexAt(1.0), 0);
    QCOMPARE(lyrics.lineIndexAt(1.5), 0);
    QCOMPARE(lyrics.lineIndexAt(2.0), 1);
    QCOMPARE(lyrics.lineIndexAt(999.0), 1);

    // clear() leaves the bisection without data again.
    lyrics.clear();
    QVERIFY(!lyrics.hasSynced());
    QCOMPARE(lyrics.lines().size(), 0);
    QCOMPARE(lyrics.lineIndexAt(1.0), -1);
}

// A line with the timing of every word. The times are the ones the
// sources give: the last word of a line inherits the end of the line.
Lyrics::LrcLine TestLotusTune::wordLine(double time, const QString &text,
                                         const QVector<double> &starts,
                                         double lastEnd)
{
    Lyrics::LrcLine line;
    line.time = time;
    line.text = text;
    for (int i = 0; i < starts.size(); ++i) {
        const double begin = starts.at(i);
        const double end = (i + 1 < starts.size()) ? starts.at(i + 1) : lastEnd;
        QVariantMap word;
        word.insert(QStringLiteral("t"), begin);
        word.insert(QStringLiteral("e"), end);
        word.insert(QStringLiteral("text"), QStringLiteral("w"));
        line.words.append(word);
    }
    return line;
}

double TestLotusTune::durationOf(const QVariantMap &word)
{
    return word.value(QStringLiteral("e")).toDouble()
         - word.value(QStringLiteral("t")).toDouble();
}

void TestLotusTune::testWordTimings()
{
    // The last word of a line inherits the end of the line: when the line
    // is long the karaoke front stays on it for seconds. It is cut to
    // what the other words of the line take.
    QVector<Lyrics::LrcLine> lines;
    lines.append(wordLine(10.0, QStringLiteral("For me to take what's mine"),
                           {10.0, 10.3, 10.6, 10.9}, 14.0));
    Lyrics::clampStretchedWords(lines);
    QCOMPARE(lines.size(), 1);
    const QVariantMap last = lines.at(0).words.last().toMap();
    // The other words last 0.3 s: the last one may not last more than
    // twice that.
    QVERIFY(durationOf(last) <= 0.61);
    // The word still lasts something and it is not before the others.
    QVERIFY(durationOf(last) > 0.0);
    QCOMPARE(last.value(QStringLiteral("t")).toDouble(), 10.9);

    // A line whose words are in order is not touched.
    QVector<Lyrics::LrcLine> ok;
    ok.append(wordLine(20.0, QStringLiteral("Is it such a sin"),
                       {20.0, 20.2, 20.4}, 20.6));
    Lyrics::clampStretchedWords(ok);
    QCOMPARE(durationOf(ok.at(0).words.last().toMap()), 0.2);

    // The header of the lyrics (the title with the artist) is not a line
    // of the song: it is removed.
    QVector<Lyrics::LrcLine> junk;
    junk.append(wordLine(5.0, QStringLiteral("A Little Piece Of Heaven-Avenged"),
                          {5.0, 6.0}, 20.0));
    junk.append(wordLine(30.0, QStringLiteral("Before the story begins"),
                          {30.0, 30.4}, 32.0));
    Lyrics::dropJunkLines(junk, QStringLiteral("A Little Piece of Heaven"),
                          QStringLiteral("Avenged Sevenfold"));
    QCOMPARE(junk.size(), 1);
    QCOMPARE(junk.at(0).text, QStringLiteral("Before the story begins"));

    // A line whose words cover half of the song keeps its text but loses
    // the timings: they are not real.
    QVector<Lyrics::LrcLine> wide;
    wide.append(wordLine(100.0, QStringLiteral("Do you take this man to death"),
                          {100.0, 110.0}, 130.0));
    Lyrics::dropJunkLines(wide, QStringLiteral("Nothing"),
                          QStringLiteral("Nobody"));
    QCOMPARE(wide.size(), 1);
    QVERIFY(wide.at(0).words.isEmpty());
    QCOMPARE(wide.at(0).text, QStringLiteral("Do you take this man to death"));
}

// A reference timeline that runs past the real end of the track is
// another version of the song (the studio take of an acoustic video):
// it must not be used, or the karaoke of the take being played moves.
void TestLotusTune::testReferenceVersion()
{
    Lyrics lyrics;
    auto line = [](double t) {
        Lyrics::LrcLine l;
        l.time = t;
        l.text = QStringLiteral("line");
        return l;
    };
    lyrics.m_duration = 184;
    QVector<Lyrics::LrcLine> acoustic{line(17.3), line(80.0), line(177.6)};
    QVERIFY(lyrics.referenceFitsDuration(acoustic));

    // The studio take of "Prettyboy!" ends at 4:00 for a 3:04 video.
    QVector<Lyrics::LrcLine> studio{line(1.1), line(120.0), line(238.8)};
    QVERIFY(!lyrics.referenceFitsDuration(studio));

    // Without the real length there is nothing to compare.
    lyrics.m_duration = 0;
    QVERIFY(lyrics.referenceFitsDuration(studio));

    // The end may be rounded: a few seconds past the end are tolerated.
    lyrics.m_duration = 184;
    QVector<Lyrics::LrcLine> edge{line(188.5)};
    QVERIFY(lyrics.referenceFitsDuration(edge));
}

// A word-level source of another song must not be shown just because the
// video gave no reference timeline: the plain lyric of this track is
// enough to reject it.
void TestLotusTune::testWrongSongDiscardedByPlain()
{
    Lyrics lyrics;
    lyrics.m_plain = QStringLiteral(
        "In the life of the wrong a love lingered on "
        "till your rapture falls to pieces "
        "find in me the room to breathe simple things like suffering");
    auto line = [](double t, const QString &s) {
        Lyrics::LrcLine l;
        l.time = t;
        l.text = s;
        return l;
    };
    QVector<Lyrics::LrcLine> wrong{
        line(1, QStringLiteral("I set my self on fire")),
        line(5, QStringLiteral("To get away from you")),
        line(9, QStringLiteral("Of all your hearts desires")),
        line(13, QStringLiteral("I was never who")),
        line(17, QStringLiteral("Youd talk to late at night")),
        line(21, QStringLiteral("In that dark ened room")),
        line(25, QStringLiteral("I thought he said hes shy")),
        line(29, QStringLiteral("I guess hes not with you")),
    };
    QVERIFY(!lyrics.adoptWorded(wrong, QStringLiteral("bad"), false, false));

    QVector<Lyrics::LrcLine> good{
        line(1, QStringLiteral("till your rapture falls to pieces")),
        line(5, QStringLiteral("find in me the room to breathe")),
        line(9, QStringLiteral("simple things like suffering")),
        line(13, QStringLiteral("life had gone this way")),
        line(17, QStringLiteral("until your rapture falls to pieces")),
        line(21, QStringLiteral("find in me the room to breathe")),
        line(25, QStringLiteral("simple things like suffering")),
        line(29, QStringLiteral("till your rapture falls to pieces")),
    };
    QVERIFY(lyrics.adoptWorded(good, QStringLiteral("good"), false, false));
}

// The updater picks a release by comparing versions and matching the
// artifact of this platform. A wrong choice downloads the wrong binary.
void TestLotusTune::testUpdateHelpers()
{
    QCOMPARE(versionOf(QStringLiteral("v2.1.2")), QStringLiteral("2.1.2"));
    QCOMPARE(versionOf(QStringLiteral("  v2.1.2-beta.3 ")), QStringLiteral("2.1.2"));
    QCOMPARE(versionOf(QStringLiteral("2.1.2")), QStringLiteral("2.1.2"));

    QVERIFY(isNewer(QStringLiteral("v2.1.2"), QStringLiteral("2.1.1")));
    QVERIFY(isNewer(QStringLiteral("1.10.0"), QStringLiteral("1.9.0")));
    QVERIFY(isNewer(QStringLiteral("2.1.2"), QStringLiteral("2.1.2-rc1")));
    QVERIFY(!isNewer(QStringLiteral("2.1.1"), QStringLiteral("2.1.1")));
    QVERIFY(!isNewer(QStringLiteral("2.1.1"), QStringLiteral("2.1.2")));

    // Linux: a Windows installer or a phone APK is never an update.
    QVERIFY(assetMatches(QStringLiteral("lotus-tune-2.1.2-Linux.tar.gz")));
    QVERIFY(assetMatches(QStringLiteral("lotus-tune_2.1.2_amd64.deb")));
    QVERIFY(assetMatches(QStringLiteral("lotus-tune-2.1.2-1.x86_64.rpm")));
    QVERIFY(!assetMatches(QStringLiteral("lotus-tune-android.apk")));
    QVERIFY(!assetMatches(QStringLiteral("LotusTune-Setup-2.1.2.exe")));
    QVERIFY(!assetMatches(QString()));
}

// The updater refuses to run tools/install.sh when its hash does not match
// the one compiled in. CMake derives that hash from the file itself, so a
// change to the script can never leave a stale value in the app.
void TestLotusTune::testInstallerHash()
{
    QFile f(QStringLiteral(LOTUS_INSTALL_PATH));
    QVERIFY2(f.open(QIODevice::ReadOnly), "no se encontro tools/install.sh");
    const QByteArray sha = QCryptographicHash::hash(
        f.readAll(), QCryptographicHash::Sha256).toHex();
    QCOMPARE(QString::fromLatin1(sha), QStringLiteral(LOTUS_INSTALL_SHA));
}

// Some providers drop the spaces inside a line ("esnada", "tuvoz").
// The clean text of the track must restore them, with the word stamps
// rebuilt so the karaoke still agrees with the text.
void TestLotusTune::testRestoreSpacesFromPlain()
{
    const QString plain = QStringLiteral(
        "Verte ya no es nada\n"
        "Escuchar tu voz en las campeadas\n"
        "La noche de colores\n"
        "That fear is only fatal 'til it's alchemized\n"
        "I've been gone for far too long\n"
        "So don't be too concerned, you've got a lot to learn\n");
    Lyrics lyrics;
    auto line = [](const QString &text) {
        Lyrics::LrcLine l;
        l.time = 1.0;
        l.text = text;
        l.end = 4.0;
        return l;
    };
    QVector<Lyrics::LrcLine> lines{
        line(QStringLiteral("Verte ya no esnada")),
        line(QStringLiteral("Escuchar tuvoz enlas campeadas")),
        line(QStringLiteral("Lanoche decolores")),
        line(QStringLiteral("That fear is on lyfa tal till it's alchemized")),
        line(QStringLiteral("I've been gone forfar too long")),
        line(QStringLiteral("So don't betoo concerned, you've got a lot to learn")),
    };
    Lyrics::restoreSpacesFromPlain(lines, plain);
    QCOMPARE(lines.at(0).text, QStringLiteral("Verte ya no es nada"));
    QCOMPARE(lines.at(1).text, QStringLiteral("Escuchar tu voz en las campeadas"));
    QCOMPARE(lines.at(2).text, QStringLiteral("La noche de colores"));
    // A word split in three still finds its clean line by similarity.
    QCOMPARE(lines.at(3).text,
             QStringLiteral("That fear is only fatal 'til it's alchemized"));
    QCOMPARE(lines.at(4).text, QStringLiteral("I've been gone for far too long"));
    QCOMPARE(lines.at(5).text,
             QStringLiteral("So don't be too concerned, you've got a lot to learn"));
    // Lines not present in the plain text are left alone.
    QVector<Lyrics::LrcLine> other{line(QStringLiteral("otra cosa distinta"))};
    Lyrics::restoreSpacesFromPlain(other, plain);
    QCOMPARE(other.at(0).text, QStringLiteral("otra cosa distinta"));
}

// A provider glued short words at the end of a line ("Let uscry"). The
// clean text must not be glued back by the generic fragment rule, and the
// single glued word stamp must be split to keep karaoke in sync.
void TestLotusTune::testGluedShortWordsAtLineEnd()
{
    auto line = [](const QString &text, const QStringList &words) {
        Lyrics::LrcLine l;
        l.time = 1.0;
        l.text = text;
        l.end = 4.0;
        for (int i = 0; i < words.size(); ++i) {
            QVariantMap w;
            w.insert(QStringLiteral("t"), 1.0 + i * 1.0);
            w.insert(QStringLiteral("e"), 2.0 + i * 1.0);
            w.insert(QStringLiteral("text"), words.at(i));
            l.words.append(w);
        }
        return l;
    };
    const QString plain = QStringLiteral(
        "Let us cry\n"
        "Eternal rest in time\n"
        "I've been gone for far too long\n"
        "La noche de colores\n"
        "They have tampered with the locks\n");
    QVector<Lyrics::LrcLine> lines{
        line(QStringLiteral("Let uscry"),
             {QStringLiteral("Let "), QStringLiteral("uscry")}),
        line(QStringLiteral("Eternal rest intime"),
             {QStringLiteral("Eternal "), QStringLiteral("rest "),
              QStringLiteral("intime")}),
        line(QStringLiteral("I've been gone forfar too long"),
             {QStringLiteral("I've "), QStringLiteral("been "),
              QStringLiteral("gone "), QStringLiteral("forfar "),
              QStringLiteral("too "), QStringLiteral("long")}),
        line(QStringLiteral("Lanoche decolores"),
             {QStringLiteral("Lanoche "), QStringLiteral("decolores")}),
        line(QStringLiteral("They have tampered with the locks"),
             {QStringLiteral("They "), QStringLiteral("have "),
              QStringLiteral("tampered "), QStringLiteral("with "),
              QStringLiteral("the "), QStringLiteral("locks")}),
    };
    Lyrics::joinSplitWords(lines, plain);
    QCOMPARE(lines.at(0).text, QStringLiteral("Let us cry"));
    QCOMPARE(lines.at(1).text, QStringLiteral("Eternal rest in time"));
    QCOMPARE(lines.at(2).text, QStringLiteral("I've been gone for far too long"));
    QCOMPARE(lines.at(3).text, QStringLiteral("La noche de colores"));
    QCOMPARE(lines.at(4).text, QStringLiteral("They have tampered with the locks"));
    QCOMPARE(lines.at(0).words.size(), 3);
    QCOMPARE(lines.at(0).words.at(0).toMap().value(QStringLiteral("text")).toString(),
             QStringLiteral("Let"));
    QCOMPARE(lines.at(0).words.at(2).toMap().value(QStringLiteral("text")).toString(),
             QStringLiteral("cry"));
    QCOMPARE(lines.at(0).words.at(1).toMap().value(QStringLiteral("text")).toString(),
             QStringLiteral("us"));
}

// Providers glue a few common word pairs ("Eternal rest intime"). The fix
// must reach both the line text and the word stamps, or karaoke still
// highlights the glued token as one word.
void TestLotusTune::testJoinGluedProviderWords()
{
    auto makeLine = [](const QString &text, const QStringList &words) {
        Lyrics::LrcLine l;
        l.time = 1.0;
        l.text = text;
        l.end = 4.0;
        for (int i = 0; i < words.size(); ++i) {
            QVariantMap w;
            w.insert(QStringLiteral("t"), 1.0 + i * 0.5);
            w.insert(QStringLiteral("e"), 1.5 + i * 0.5);
            w.insert(QStringLiteral("text"), words.at(i));
            l.words.append(w);
        }
        return l;
    };
    QVector<Lyrics::LrcLine> lines{
        makeLine(QStringLiteral("Eternal rest intime"),
                 {QStringLiteral("Eternal"), QStringLiteral("rest"),
                  QStringLiteral("intime")}),
        makeLine(QStringLiteral("I've been gone forfar too long"),
                 {QStringLiteral("I've"), QStringLiteral("gone"),
                  QStringLiteral("forfar"), QStringLiteral("too"),
                  QStringLiteral("long")}),
        makeLine(QStringLiteral("Verte ya no esnada"),
                 {QStringLiteral("Verte"), QStringLiteral("esnada")}),
    };
    Lyrics::joinSplitWords(lines, QString());
    QCOMPARE(lines.at(0).text, QStringLiteral("Eternal rest in time"));
    QCOMPARE(lines.at(1).text, QStringLiteral("I've been gone for far too long"));
    QCOMPARE(lines.at(2).text, QStringLiteral("Verte ya no es nada"));
    QCOMPARE(lines.at(0).words.at(2).toMap().value(QStringLiteral("text")).toString(),
             QStringLiteral("in time"));
    QCOMPARE(lines.at(1).words.at(2).toMap().value(QStringLiteral("text")).toString(),
             QStringLiteral("for far"));
    QCOMPARE(lines.at(2).words.at(1).toMap().value(QStringLiteral("text")).toString(),
             QStringLiteral("es nada"));
}

// Apostrophised tokens and words split with a wrong letter. The plain line
// restores the spaces, and the glued table handles the case where the plain
// line for that exact sentence is missing.
void TestLotusTune::testGluedApostrophesAndTypos()
{
    auto line = [](const QString &text, const QStringList &words) {
        Lyrics::LrcLine l;
        l.time = 1.0;
        l.text = text;
        l.end = 4.0;
        for (int i = 0; i < words.size(); ++i) {
            QVariantMap w;
            w.insert(QStringLiteral("t"), 1.0 + i * 0.5);
            w.insert(QStringLiteral("e"), 1.5 + i * 0.5);
            w.insert(QStringLiteral("text"), words.at(i));
            l.words.append(w);
        }
        return l;
    };
    const QString plain = QStringLiteral(
        "And a pretty little smile\n"
        "You're so pretty, baby\n"
        "Let 'em breathe, watch 'em burn in the fire\n");
    QVector<Lyrics::LrcLine> lines{
        line(QStringLiteral("And a pret tylittle smile (you're so pret ty,ba by)"),
             {QStringLiteral("And"), QStringLiteral(" a"), QStringLiteral(" pret"),
              QStringLiteral("tylittle"), QStringLiteral(" smile"),
              QStringLiteral(" (you're"), QStringLiteral(" so"),
              QStringLiteral(" pret"), QStringLiteral("ty,ba"),
              QStringLiteral(" by)")}),
        line(QStringLiteral("Let'em breathe watch'em burn in the fire"),
             {QStringLiteral("Let'em"), QStringLiteral(" breathe"),
              QStringLiteral("watch'em"), QStringLiteral(" burn"),
              QStringLiteral(" in"), QStringLiteral(" the"),
              QStringLiteral(" fire")}),
    };
    Lyrics::joinSplitWords(lines, plain);
    QCOMPARE(lines.at(0).text,
             QStringLiteral("And a pretty little smile (you're so pretty, baby)"));
    QCOMPARE(lines.at(1).text,
             QStringLiteral("Let 'em breathe, watch 'em burn in the fire"));
    // Neither pair gets glued back by the generic fragment joins.
    const QString w0 = lines.at(1).words.at(0).toMap()
                           .value(QStringLiteral("text")).toString();
    const QString w1 = lines.at(1).words.at(2).toMap()
                           .value(QStringLiteral("text")).toString();
    QVERIFY(!w0.contains(QLatin1String("Let'em")));
    QVERIFY(!w1.contains(QLatin1String("watch'em")));

    // No plain line at all: the glued table is the only source.
    QVector<Lyrics::LrcLine> fallback{
        line(QStringLiteral("You'll bedoin' that soon, 'cause di a monds are forever"),
             {QStringLiteral("You'll"), QStringLiteral("bedoin'"),
              QStringLiteral(" that"), QStringLiteral(" soon,"),
              QStringLiteral(" 'cause"), QStringLiteral(" di"),
              QStringLiteral(" a"), QStringLiteral(" monds"),
              QStringLiteral(" are"), QStringLiteral("forever")}),
    };
    Lyrics::joinSplitWords(fallback, QString());
    QCOMPARE(fallback.at(0).text,
             QStringLiteral("You'll be doin' that soon, 'cause diamonds are forever"));
}

// Instrumental stretches get a real end and three evenly spaced dots,
// so the artificial sweep walks through them instead of jumping.
void TestLotusTune::testInstrumentalSweep()
{
    QVector<Lyrics::LrcLine> lines;
    Lyrics::LrcLine a; a.time = 10.0; a.text = QStringLiteral("♪ ♪ ♪"); a.instrumental = true;
    Lyrics::LrcLine b; b.time = 18.0; b.text = QStringLiteral("sung line");
    lines << a << b;
    Lyrics::distributeWordTimes(lines);
    QCOMPARE(lines.at(0).end, 18.0);
    QCOMPARE(lines.at(0).words.size(), 3);
    QCOMPARE(lines.at(0).words.at(0).toMap().value(QStringLiteral("t")).toDouble(), 10.0);
    QCOMPARE(lines.at(0).words.at(2).toMap().value(QStringLiteral("e")).toDouble(), 18.0);
    QVERIFY(lines.at(0).instrumental);
}

// Corrupt cached stamps (inverted, overlapping, out of order) must become a
// clean monotonic sequence with a real end on the last word.
void TestLotusTune::testSanitizeWordStamps()
{
    QVector<Lyrics::LrcLine> lines;
    Lyrics::LrcLine l;
    l.time = 10.0;
    l.end = 14.0;
    l.text = QStringLiteral("one two three four");
    auto add = [&l](double t, double e, const QString &text) {
        QVariantMap w;
        w.insert(QStringLiteral("t"), t);
        w.insert(QStringLiteral("e"), e);
        w.insert(QStringLiteral("text"), text);
        l.words.append(w);
    };
    add(12.0, 11.0, QStringLiteral("bad"));   // inverted, dropped
    add(10.0, 13.0, QStringLiteral("one"));   // overlaps the next one
    add(11.0, 10.5, QStringLiteral("two"));   // inverted, dropped
    add(11.5, 12.0, QStringLiteral("three"));
    add(12.5, 99.0, QStringLiteral("four"));  // goes past end, last = end
    lines << l;

    Lyrics::sanitizeWordStamps(lines);
    const QVariantList ws = lines.at(0).words;
    QCOMPARE(ws.size(), 3);
    const QVariantMap a = ws.at(0).toMap();
    const QVariantMap b = ws.at(1).toMap();
    const QVariantMap c = ws.at(2).toMap();
    const double at = a.value(QStringLiteral("t")).toDouble();
    const double ae = a.value(QStringLiteral("e")).toDouble();
    const double bt = b.value(QStringLiteral("t")).toDouble();
    const double be = b.value(QStringLiteral("e")).toDouble();
    const double ct = c.value(QStringLiteral("t")).toDouble();
    const double ce = c.value(QStringLiteral("e")).toDouble();
    QVERIFY(at < ae && ae <= bt);
    QVERIFY(bt < be && be <= ct);
    QVERIFY(ct < ce);                          // last end > start
    QVERIFY(ce <= lines.at(0).end);
}

// A song inside ANY saved list is found without opening that list.
void TestLotusTune::testSearchLibraryTracks()
{
    QVariantList tracks;
    QVariantMap t;
    t.insert(QStringLiteral("title"), QStringLiteral("Nosebleed!"));
    t.insert(QStringLiteral("artist"), QStringLiteral("Vana"));
    t.insert(QStringLiteral("url"), QStringLiteral("https://youtu.be/abc"));
    tracks.append(t);
    QVariantMap pl;
    pl.insert(QStringLiteral("name"), QStringLiteral("Favoritas"));
    pl.insert(QStringLiteral("tracks"), tracks);
    QVariantList pls; pls.append(pl);

    QCOMPARE(Catalog::searchInLists(pls, QVariantList(), QStringLiteral("nose")).size(), 1);
    QCOMPARE(Catalog::searchInLists(pls, QVariantList(), QStringLiteral("zzz")).size(), 0);
    // A one-character query is ignored (too many results).
    QCOMPARE(Catalog::searchInLists(pls, QVariantList(), QStringLiteral("n")).size(), 0);
}

// Lyrics can be saved as LRC and read back, keeping the word stamps.
void TestLotusTune::testLrcExportImport()
{
    const QString src = QStringLiteral(
        "[ar:Test]\n[ti:Song]\n"
        "[00:01.00]<00:01.00>Hello <00:01.50>world\n"
        "[00:03.00]Second line\n");
    const QString path = m_homeDir->path() + QStringLiteral("/test.lrc");
    QFile f(path);
    QVERIFY(f.open(QIODevice::WriteOnly));
    f.write(src.toUtf8());
    f.close();

    Lyrics lyrics;
    lyrics.m_title = QStringLiteral("Song");
    lyrics.m_artist = QStringLiteral("Test");
    lyrics.m_duration = 200;
    QVERIFY(lyrics.importLrc(path));
    QCOMPARE(lyrics.m_lines.size(), 2);
    const QString lrc = lyrics.toLrc();
    QVERIFY(lrc.contains(QStringLiteral("[ar:Test]")));
    QVERIFY(lrc.contains(QStringLiteral("<00:01.00>Hello")));
    QVERIFY(lrc.contains(QStringLiteral("[00:01.00]<00:01.00>Hello")));
    QVERIFY(lrc.contains(QStringLiteral("[00:03.00]Second line")));

    // A track flagged instrumental produces a single marker line and
    // does not keep other candidates from being searched away.
    QJsonObject inst;
    inst.insert(QStringLiteral("instrumental"), true);
    Lyrics only;
    only.m_duration = 120;
    only.applyPayload(inst);
    QCOMPARE(only.m_lines.size(), 1);
    QVERIFY(only.m_lines.at(0).instrumental);
    QVERIFY(only.m_hasLyrics);

    // Copying includes the translation under each original line.
    Lyrics withTr;
    Lyrics::LrcLine a; a.text = "Hello"; a.translation = "Hola";
    Lyrics::LrcLine b; b.text = "Bye";
    withTr.m_lines = {a, b};
    QCOMPARE(withTr.translatedText(), QStringLiteral("Hello\nHola\nBye"));
}

// The accent typed in Settings must actually reach the palette: it is
// written through QSettings, while the theme used to read only config.ini.
void TestLotusTune::testAccentFromSettings()
{
    // QSettings caches its path, and this suite repoints HOME to a temp
    // dir, so write the .conf the theme actually reads.
    const QString conf = QDir::homePath() + "/.config/lotus-tune/lotus-tune.conf";
    QVERIFY(QDir().mkpath(QFileInfo(conf).absolutePath()));
    QFile f(conf);
    QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write("[General]\naccent=#123456\n");
    f.close();
    AppTheme theme;   // the constructor reloads the palette
    QCOMPARE(theme.accent().name(QColor::HexRgb), QStringLiteral("#123456"));
}

// On a light system background the Lotus accent darkens to stay readable.
void TestLotusTune::testLotusAccentOnLightBg()
{
    const QString dir = QDir::homePath()
        + "/.local/state/quickshell/user/generated";
    QVERIFY(QDir().mkpath(dir));
    QFile pal(dir + "/app-palette.json");
    QVERIFY(pal.open(QIODevice::WriteOnly | QIODevice::Truncate));
    pal.write("{\"app_window_bg\":\"#f5f5f7\",\"app_accent\":\"#aaaaaa\"}");
    pal.close();

    // A manual accent from an earlier test would win: remove it.
    QFile::remove(QDir::homePath() + "/.config/lotus-tune/lotus-tune.conf");

    AppTheme theme;
    theme.setInterfaceStyle(QStringLiteral("lotus"));
    theme.reload();
    QCOMPARE(theme.accent().name(QColor::HexRgb), QStringLiteral("#6d28d9"));
}

// All settings round-trip through one JSON document.
void TestLotusTune::testSettingsExportImport()
{
    AppConfig a;
    a.set(QStringLiteral("lyricsEnabled"), QStringLiteral("false"));
    const QString json = a.exportAll();
    QVERIFY(json.contains(QStringLiteral("lyricsEnabled")));
    AppConfig b;
    QVERIFY(b.importAll(json));
    QCOMPARE(b.get(QStringLiteral("lyricsEnabled")), QStringLiteral("false"));
}

// The TTML of Apple Music: one <p> per line (with the voice that sings
// it) and one <span> per word (with its own instant).
void TestLotusTune::testParseTtml()
{
    const QString xml = QStringLiteral(
        "<tt xmlns=\"http://www.w3.org/ns/ttml\" "
        "xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\">"
        "<head><metadata>"
        "<ttm:agent type=\"person\" xml:id=\"v1\">"
        "<ttm:name type=\"full\">Avenged Sevenfold</ttm:name></ttm:agent>"
        "<ttm:agent type=\"person\" xml:id=\"v2\"/>"
        "</metadata></head><body>"
        "<p begin=\"1:01.008\" end=\"1:05.645\" ttm:agent=\"v1\">"
        "<span begin=\"1:01.008\" end=\"1:01.382\">I</span> "
        "<span begin=\"1:01.382\" end=\"1:01.782\">took</span> "
        "<span begin=\"1:01.782\" end=\"1:02.233\">all</span></p>"
        "<p begin=\"1:05.600\" end=\"1:07.000\" ttm:agent=\"v2\">"
        "<span begin=\"1:05.600\" end=\"1:06.000\">What</span> "
        "<span begin=\"1:06.000\" end=\"1:07.000\">will you do</span></p>"
        "<p begin=\"1:08.000\" end=\"1:09.000\" ttm:agent=\"v1\">"
        "without words</p>"
        "</body></tt>");

    const QVector<Lyrics::LrcLine> lines = Lyrics::parseTtml(xml);
    QCOMPARE(lines.size(), 3);

    // The first line: the words with their own instants and the text
    // rebuilt with the spaces that go with them.
    QCOMPARE(lines.at(0).time, 61.008);
    QCOMPARE(lines.at(0).text, QStringLiteral("I took all"));
    QCOMPARE(lines.at(0).words.size(), 3);
    QCOMPARE(lines.at(0).words.at(0).toMap().value(QStringLiteral("t")).toDouble(),
             61.008);
    QCOMPARE(lines.at(0).words.at(0).toMap().value(QStringLiteral("e")).toDouble(),
             61.382);
    QCOMPARE(lines.at(0).words.at(1).toMap().value(QStringLiteral("t")).toDouble(),
             61.382);
    // The main voice is not the second one.
    QVERIFY(!lines.at(0).secondary);

    // The second line is the other voice: it is the one that goes to the
    // other side.
    QCOMPARE(lines.at(1).time, 65.6);
    QCOMPARE(lines.at(1).text, QStringLiteral("What will you do"));
    QVERIFY(lines.at(1).secondary);

    // A line without word timings keeps its text and has no words.
    QCOMPARE(lines.at(2).text, QStringLiteral("without words"));
    QVERIFY(lines.at(2).words.isEmpty());
    QVERIFY(!lines.at(2).secondary);
}

void TestLotusTune::testInstrumentalMarkers()
{
    // The notes of an instrumental stretch cannot start while the previous
    // phrase is still being sung: the old marker (`time + 0.5`) cut the
    // last words of the line and the view jumped to the instrumental in the
    // middle of the phrase ("empieza a medias").
    Lyrics lyrics;
    lyrics.m_title = QStringLiteral("Test");
    lyrics.m_artist = QStringLiteral("Test");
    QVector<Lyrics::LrcLine> lines;
    lines.append(wordLine(10.0, QStringLiteral("But don't call us the liars"),
                          {10.0, 10.5, 11.0, 11.5, 12.0}, 14.5));
    lines.append(wordLine(15.0, QStringLiteral("We've walked these alleys"),
                          {15.0, 15.5, 16.0, 16.5}, 19.0));
    lines.append(wordLine(20.0, QStringLiteral("And scattered around"),
                          {20.0, 20.5, 21.0, 21.5}, 24.0));
    lines.append(wordLine(60.0, QStringLiteral("Your life maybe hard"),
                          {60.0, 60.5, 61.0, 61.5}, 64.0));
    // A marker of the video that lands in the middle of the first phrase:
    // it is not a stretch without voice.
    {
        Lyrics::LrcLine mark;
        mark.time = 12.0;
        mark.text = QStringLiteral("♪");
        lyrics.m_refLines.append(mark);
    }
    lyrics.prepareWordedLines(lines);

    // No marker inside any phrase.
    for (const Lyrics::LrcLine &l : lines) {
        if (!l.instrumental)
            continue;
        QVERIFY2(!(l.time > 10.0 && l.time < 14.5),
                 qPrintable(QStringLiteral("marker inside the phrase: %1")
                                .arg(l.time)));
        QVERIFY(!(l.time > 20.0 && l.time < 24.0));
    }
    // The gap between 20 and 60 does have its marker, after the last word
    // of the previous phrase.
    bool gap = false;
    for (const Lyrics::LrcLine &l : lines) {
        if (l.instrumental && l.time > 24.0 && l.time < 60.0) {
            gap = true;
            QVERIFY(l.time >= 24.0);
        }
    }
    QVERIFY(gap);
}

void TestLotusTune::testConsecutiveInstrumentalMarkers()
{
    // The video marks one silence twice (two markers in a row): the view
    // drew two rows of dots for the same stretch. Two instrumental lines
    // that follow each other are one stretch, never two.
    Lyrics lyrics;
    lyrics.m_title = QStringLiteral("Test");
    lyrics.m_artist = QStringLiteral("Test");
    QVector<Lyrics::LrcLine> lines;
    lines.append(wordLine(10.0, QStringLiteral("For this is love"),
                          {10.0, 10.4, 11.2}, 18.4));
    lines.append(wordLine(31.6, QStringLiteral("I wanna be a celebrity martyr"),
                          {31.6, 32.1, 32.8, 33.6}, 35.5));
    for (const double at : {18.4, 26.6}) {
        Lyrics::LrcLine mark;
        mark.time = at;
        mark.text = QStringLiteral("♪");
        lyrics.m_refLines.append(mark);
    }
    lyrics.prepareWordedLines(lines);

    int stretches = 0;
    double start = -1.0;
    for (const Lyrics::LrcLine &l : lines) {
        if (!l.instrumental)
            continue;
        ++stretches;
        start = l.time;
    }
    QCOMPARE(stretches, 1);
    QVERIFY(qAbs(start - 18.4) < 0.001);
    // One notes line for it (not one per marker), and it is not sung.
    for (const Lyrics::LrcLine &l : lines) {
        if (!l.instrumental)
            continue;
        QVERIFY(l.text.contains(QChar(0x266a)));
    }
}

void TestLotusTune::testNotesOnlyLineIsInstrumental()
{
    // Some sources write the stretch as a line of notes and do not flag it.
    // It reached the view as a lyric and a lone "♪" was drawn where the
    // three dots belong.
    Lyrics lyrics;
    lyrics.m_title = QStringLiteral("Test");
    lyrics.m_artist = QStringLiteral("Test");
    QVector<Lyrics::LrcLine> lines;
    lines.append(wordLine(5.0, QStringLiteral("Under the stars"),
                          {5.0, 5.4, 6.2, 7.0}, 12.0));
    Lyrics::LrcLine note;
    note.time = 20.0;
    note.text = QStringLiteral("♪");
    lines.append(note);
    lines.append(wordLine(40.0, QStringLiteral("Torment and sadness"),
                          {40.0, 40.5, 41.2, 42.0}, 45.0));
    lyrics.prepareWordedLines(lines);

    int stretches = 0;
    for (const Lyrics::LrcLine &l : lines) {
        if (l.instrumental) {
            ++stretches;
            continue;
        }
        QVERIFY2(!l.text.contains(QChar(0x266a)),
                 "a line of notes was left as a lyric");
    }
    QCOMPARE(stretches, 1);
}

void TestLotusTune::testRichsyncPhraseEnd()
{
    // A richsync line carries its own end (`te`): the phrase stops there,
    // NOT where the next line starts. The old code stretched the words of
    // the phrase until the next lyric, so a 4 s phrase followed by a 10 s
    // instrumental filled the whole stretch and the karaoke front crawled
    // ("muchísimos errores de sync") while the ♪ marker never appeared.
    const QByteArray json = R"([
        {"ts":79.37,"te":83.273,"l":[
            {"c":"I","o":0.0},{"c":" need","o":0.186},
            {"c":" a","o":0.557},{"c":" new","o":0.681},
            {"c":" way","o":0.929},{"c":" out","o":3.855}]},
        {"ts":92.88,"te":96.83,"l":[
            {"c":"The","o":0.0},{"c":" pain","o":0.5}]}
    ])";
    const QJsonArray arr = QJsonDocument::fromJson(json).array();
    QVector<Lyrics::LrcLine> lines = Lyrics::parseRichsync(arr);
    QCOMPARE(lines.size(), 2);

    // The end of the phrase is the `te` of the source.
    QVERIFY(qAbs(lines.at(0).end - 83.273) < 0.001);
    const QVariantMap last = lines.at(0).words.last().toMap();
    QVERIFY(qAbs(last.value(QStringLiteral("e")).toDouble() - 83.273) < 0.001);
    // The word instants are the real ones (offset + ts), not redistributed
    // by the length of the text over the gap until the next line.
    const QVariantMap need = lines.at(0).words.at(1).toMap();
    QVERIFY(qAbs(need.value(QStringLiteral("t")).toDouble() - 79.556) < 0.001);
    QVERIFY(qAbs(need.value(QStringLiteral("e")).toDouble() - 79.927) < 0.001);
    QVERIFY(lines.at(0).end < 90.0);

    // The instrumental stretch between the two phrases gets its marker,
    // right after the phrase stops.
    Lyrics lyrics;
    lyrics.m_title = QStringLiteral("Test");
    lyrics.m_artist = QStringLiteral("Test");
    lyrics.prepareWordedLines(lines);
    bool gap = false;
    for (const Lyrics::LrcLine &l : lines) {
        if (l.instrumental && l.time >= 83.273 && l.time < 92.88) {
            gap = true;
            QVERIFY(l.time >= 83.273);
            QVERIFY(l.time < 86.0);
        }
    }
    QVERIFY(gap);

    // A phrase of one word is a real lyric line ("Ah", "Yeah", "Go!"):
    // it is kept without word timings instead of being thrown away.
    const QByteArray oneWordJson = R"([
        {"ts":16.87,"te":16.87,"l":[{"c":"Ah","o":0.0}]},
        {"ts":26.8,"te":30.56,"l":[
            {"c":"I'm","o":0.0},{"c":" in","o":0.3}]}
    ])";
    QVector<Lyrics::LrcLine> oneWord =
        Lyrics::parseRichsync(QJsonDocument::fromJson(oneWordJson).array());
    QCOMPARE(oneWord.size(), 2);
    QCOMPARE(oneWord.at(0).text, QStringLiteral("Ah"));
    QVERIFY(oneWord.at(0).words.isEmpty());
    QCOMPARE(oneWord.at(0).end, 0.0);

    // The video marks where that phrase stops (an empty timed line) and the
    // karaoke source does not: the boundary is copied when the lines are
    // aligned, so the interjection does not stay lit until the next lyric.
    Lyrics::LrcLine ref0;
    ref0.time = 16.87;
    ref0.text = QStringLiteral("Ah");
    ref0.end = 19.03;
    Lyrics::LrcLine ref1;
    ref1.time = 26.8;
    ref1.text = QStringLiteral("I'm in");
    QVector<Lyrics::LrcLine> reference{ref0, ref1};
    Lyrics::WordedScore score;
    QVERIFY(lyrics.alignWords(oneWord, reference, &score));
    QVERIFY(qAbs(oneWord.at(0).end - 19.03) < 0.001);
}

void TestLotusTune::testLrcSilenceBoundary()
{
    // A plain LRC marks the end of the phrase with a timed line without
    // text: it has to be kept as the end of the previous line (it is where
    // the instrumental starts), not discarded as an empty lyric.
    const QString lrc = QStringLiteral("[00:10.00]Hello world\n"
                                       "[00:14.50]\n"
                                       "[00:20.00]Next line");
    const QVector<Lyrics::LrcLine> lines = Lyrics::parseLrc(lrc, true);
    QCOMPARE(lines.size(), 2);
    QVERIFY(qAbs(lines.at(0).time - 10.0) < 0.001);
    QVERIFY(qAbs(lines.at(0).end - 14.5) < 0.001);
    QVERIFY(qAbs(lines.at(1).time - 20.0) < 0.001);
    // The last line has no silence marker after it: no invented end.
    QCOMPARE(lines.at(1).end, 0.0);
}

void TestLotusTune::testSungCreditLine()
{
    // The richsync of a song whose intro whispers the artist name ("Poppy"
    // before the first verse) carries a line with the artist as its text.
    // It is sung: the "Artist - Title" filter must not throw it away.
    const QByteArray json = R"([
        {"ts":8.25,"te":8.76,"l":[{"c":"Poppy","o":0.0}]},
        {"ts":16.87,"te":16.9,"l":[{"c":"Ah","o":0.0}]}
    ])";
    QVector<Lyrics::LrcLine> lines =
        Lyrics::parseRichsync(QJsonDocument::fromJson(json).array());
    QCOMPARE(lines.size(), 2);
    QVERIFY(lines.at(0).sung);

    Lyrics lyrics;
    lyrics.dropJunkLines(lines, QStringLiteral("New Way Out"),
                         QStringLiteral("Poppy"));
    // Both stay: the first one is sung, not a credit.
    QCOMPARE(lines.size(), 2);
    QCOMPARE(lines.at(0).text, QStringLiteral("Poppy"));

    // A header line that is NOT sung is still removed.
    QVector<Lyrics::LrcLine> header;
    Lyrics::LrcLine h;
    h.time = 0.0;
    h.text = QStringLiteral("Poppy - New Way Out");
    header.append(h);
    Lyrics::LrcLine real;
    real.time = 8.0;
    real.text = QStringLiteral("I'm in too deep");
    header.append(real);
    lyrics.dropJunkLines(header, QStringLiteral("New Way Out"),
                         QStringLiteral("Poppy"));
    QCOMPARE(header.size(), 1);
    QCOMPARE(header.at(0).text, QStringLiteral("I'm in too deep"));
}

void TestLotusTune::testVideoEndWins()
{
    // The richsync stops counting at the onset of the last word: "out" was
    // still sounding when the view had already jumped to the ♪ marker. The
    // video's own LRC marks where the phrase really stops (a timed line
    // without text), and that mark wins.
    QVector<Lyrics::LrcLine> worded;
    Lyrics::LrcLine line;
    line.time = 79.37;
    line.end = 83.273;   // the `te` of the richsync
    line.text = QStringLiteral("I need a new way, give me a new way out");
    line.sung = true;
    QVariantMap w1;
    w1.insert(QStringLiteral("t"), 82.0);
    w1.insert(QStringLiteral("e"), 83.0);
    w1.insert(QStringLiteral("text"), QStringLiteral("way "));
    QVariantMap w2;
    w2.insert(QStringLiteral("t"), 83.225);
    w2.insert(QStringLiteral("e"), 83.273);
    w2.insert(QStringLiteral("text"), QStringLiteral("out"));
    line.words.append(w1);
    line.words.append(w2);
    worded.append(line);
    Lyrics::LrcLine next;
    next.time = 92.88;
    next.text = QStringLiteral("The pain and all the pretty things");
    worded.append(next);

    QVector<Lyrics::LrcLine> reference;
    Lyrics::LrcLine ref;
    ref.time = 79.32;
    ref.text = QStringLiteral("I need a new way, give me a new way out");
    ref.end = 86.42;   // the timed line without text of the video
    reference.append(ref);
    Lyrics::LrcLine refNext;
    refNext.time = 92.82;
    refNext.text = QStringLiteral("The pain and all the pretty things");
    reference.append(refNext);

    Lyrics lyrics;
    lyrics.m_duration = 203.0;
    Lyrics::WordedScore score;
    QVERIFY(lyrics.alignWords(worded, reference, &score));
    // The end of the phrase is the one of the video, not the `te`...
    QVERIFY(worded.at(0).end > 86.0);
    // ...and the last word is held until that moment.
    const QVariantMap last = worded.at(0).words.last().toMap();
    QVERIFY(qAbs(last.value(QStringLiteral("e")).toDouble() - worded.at(0).end)
            < 0.001);
}

void TestLotusTune::testMusicalEndKept()
{
    // A musical source (Apple Music) gives the real end of the last word:
    // the held note is already there. The silence mark of the video comes
    // after the voice and must not stretch it ("Get up" stayed lit two
    // seconds longer over the instrumental).
    QVector<Lyrics::LrcLine> worded;
    Lyrics::LrcLine line;
    line.time = 157.87;
    line.end = 158.50;
    line.text = QStringLiteral("Get up");
    QVariantMap w1;
    w1.insert(QStringLiteral("t"), 157.87);
    w1.insert(QStringLiteral("e"), 158.06);
    w1.insert(QStringLiteral("text"), QStringLiteral("Get "));
    QVariantMap w2;
    w2.insert(QStringLiteral("t"), 158.06);
    w2.insert(QStringLiteral("e"), 158.50);
    w2.insert(QStringLiteral("text"), QStringLiteral("up"));
    line.words.append(w1);
    line.words.append(w2);
    worded.append(line);
    Lyrics::LrcLine next;
    next.time = 166.75;
    next.text = QStringLiteral("'Cause they push and pull me down");
    worded.append(next);

    QVector<Lyrics::LrcLine> reference;
    Lyrics::LrcLine ref;
    ref.time = 157.86;
    ref.text = QStringLiteral("Get up");
    ref.end = 160.37;   // the video's silence mark
    reference.append(ref);
    reference.append(next);

    Lyrics lyrics;
    lyrics.m_duration = 203.0;
    QVERIFY(lyrics.alignWords(worded, reference, nullptr, /*musical=*/true));
    QCOMPARE(worded.at(0).end, 158.50);
    QCOMPARE(worded.at(0).words.last().toMap()
                 .value(QStringLiteral("e")).toDouble(), 158.50);
}

void TestLotusTune::testBestLrcRecordWins()
{
    // The search brings several records of the same song. The first one may
    // not mark where the phrases stop; another one does, and that is the
    // one that must be adopted (it cuts the karaoke when the voice ends).
    Lyrics lyrics;
    lyrics.m_title = QStringLiteral("new way out");
    lyrics.m_artist = QStringLiteral("Poppy");
    lyrics.m_duration = 203.0;

    QJsonObject withoutStops;
    withoutStops.insert(QStringLiteral("id"), 30258756);
    withoutStops.insert(QStringLiteral("trackName"),
                        QStringLiteral("new way out"));
    withoutStops.insert(QStringLiteral("artistName"), QStringLiteral("Poppy"));
    withoutStops.insert(QStringLiteral("duration"), 203.0);
    withoutStops.insert(QStringLiteral("syncedLyrics"),
                        QStringLiteral("[01:19.59] I need a new way\n"
                                       "[01:32.88] The pain and all\n"
                                       "[03:19.80] "));

    QJsonObject withStops = withoutStops;
    withStops.insert(QStringLiteral("id"), 18424346);
    withStops.insert(QStringLiteral("syncedLyrics"),
                     QStringLiteral("[01:19.32] I need a new way\n"
                                    "[01:26.42] \n"
                                    "[01:32.82] The pain and all\n"
                                    "[03:20.21] "));

    QVERIFY(lyrics.scoreLrcRecord(withStops) > lyrics.scoreLrcRecord(withoutStops));

    // A record of another take (its length is far off) loses.
    QJsonObject otherTake = withStops;
    otherTake.insert(QStringLiteral("id"), 13387270);
    otherTake.insert(QStringLiteral("duration"), 260.0);
    QVERIFY(lyrics.scoreLrcRecord(withStops) > lyrics.scoreLrcRecord(otherTake));
}

// ---------------------------------------------------------------------------
// Cache de audio: tope de tamano y borrado LRU.
// ---------------------------------------------------------------------------
static QString makeAudioFile(const QString &dir, const QString &id,
                             qint64 size, int hoursAgo)
{
    const QString path = dir + QStringLiteral("/audio_") + id
                         + QStringLiteral(".bin");
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return QString();
    f.resize(size);
    f.close();
    QFile tf(path);
    if (!tf.open(QIODevice::ReadOnly))
        return QString();
    tf.setFileTime(QDateTime::currentDateTime().addSecs(-hoursAgo * 3600),
                   QFileDevice::FileModificationTime);
    tf.close();
    return path;
}

void TestLotusTune::testAudioCachePrune()
{
    AudioCache *cache = AudioCache::instance();
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const int oldLimit = cache->limitMB();
    cache->setDirectoryForTest(dir.path());

    const qint64 mb = 1024 * 1024;
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("a"), mb, 40).isEmpty());
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("b"), mb, 30).isEmpty());
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("c"), mb, 20).isEmpty());
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("d"), mb, 10).isEmpty());
    QCOMPARE(cache->files(), 4);
    QCOMPARE(cache->bytes(), 4 * mb);

    // Tope de 2 MB: se borran las mas antiguas hasta quedar por debajo.
    cache->setLimitMB(2);
    QCOMPARE(cache->prune(), 3);
    QCOMPARE(cache->files(), 1);
    QCOMPARE(cache->bytes(), mb);
    QVERIFY(QFile::exists(dir.path() + QStringLiteral("/audio_d.bin")));

    // La pista que suena no se borra aunque sea la mas antigua.
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("a"), mb, 40).isEmpty());
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("b"), mb, 30).isEmpty());
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("c"), mb, 20).isEmpty());
    QCOMPARE(cache->prune(QStringLiteral("a")), 3);
    QVERIFY(QFile::exists(dir.path() + QStringLiteral("/audio_a.bin")));

    // Restos de descargas: los .part viejos se borran, los recientes no.
    const QString oldPart = dir.path() + QStringLiteral("/audio_x.bin.part");
    const QString newPart = dir.path() + QStringLiteral("/audio_y.bin.part");
    QFile op(oldPart);
    QVERIFY(op.open(QIODevice::WriteOnly));
    op.write("x");
    op.close();
    QFile otf(oldPart);
    (void)otf.open(QIODevice::ReadOnly);
    otf.setFileTime(QDateTime::currentDateTime().addSecs(-7200),
                    QFileDevice::FileModificationTime);
    otf.close();
    QFile np(newPart);
    QVERIFY(np.open(QIODevice::WriteOnly));
    np.write("y");
    np.close();
    QCOMPARE(cache->prunePartials(), 1);
    QVERIFY(!QFile::exists(oldPart));
    QVERIFY(QFile::exists(newPart));

    QVERIFY(!cache->summary().isEmpty());
    cache->setLimitMB(oldLimit);
    cache->setDirectoryForTest(QString());
}

void TestLotusTune::testAudioCacheClear()
{
    AudioCache *cache = AudioCache::instance();
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    cache->setDirectoryForTest(dir.path());
    const qint64 mb = 1024 * 1024;
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("e"), mb, 1).isEmpty());
    QVERIFY(!makeAudioFile(dir.path(), QStringLiteral("f"), mb, 1).isEmpty());
    QCOMPARE(cache->clear(), 2);
    QCOMPARE(cache->files(), 0);
    QCOMPARE(cache->clear(), 0);
    cache->setDirectoryForTest(QString());
}

// El usuario no debe ver "error:http403": cada fallo se traduce a algo que
// pueda entender y accionar.
void TestLotusTune::testFriendlyNetError()
{
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("error:http403"))
            .contains(QStringLiteral("403")));
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("error:http403"))
            .contains(QStringLiteral("operador")));
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("video unavailable"))
            .contains(QStringLiteral("disponible")));
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("Timed out"))
            .contains(QStringLiteral("tardado")));
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("UnknownHost"))
            .contains(QStringLiteral("conexion")));
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("HTTP 429"))
            .contains(QStringLiteral("limitando")));
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("No space left"))
            .contains(QStringLiteral("espacio")));
    // Cancelar no es un error: no se le enseña nada al usuario.
    QVERIFY(LotusText::friendlyNetError(QStringLiteral("cancelled")).isEmpty());

    // Lo que no se reconoce se deja tal cual (mejor eso que un mensaje falso).
    const QString other = QStringLiteral("algo raro del motor");
    QCOMPARE(LotusText::friendlyNetError(other), other);
}

// El mismo frase de dos fuentes se colapsa; un estribillo repetido
// segundos despues se conserva.
void TestLotusTune::testCollapseDuplicateLines()
{
    QVector<Lyrics::LrcLine> lines;
    auto add = [&lines](double t, const QString &text, int words,
                        const QString &tr = QString()) {
        Lyrics::LrcLine l;
        l.time = t;
        l.text = text;
        l.translation = tr;
        for (int i = 0; i < words; ++i) {
            QVariantMap w;
            w.insert(QStringLiteral("t"), t + i * 0.2);
            w.insert(QStringLiteral("e"), t + i * 0.2 + 0.2);
            w.insert(QStringLiteral("text"), QStringLiteral("w%1").arg(i));
            l.words.append(w);
        }
        lines.append(l);
    };
    add(10.0, QStringLiteral("Eternal rest in time"), 2,
        QStringLiteral("Descanso eterno en el tiempo"));
    add(10.1, QStringLiteral("Eternal rest in time"), 0);
    add(20.0, QStringLiteral("Eternal rest in time"), 2);
    Lyrics::collapseDuplicateLines(lines);
    QCOMPARE(lines.size(), 2);
    QCOMPARE(lines.at(0).time, 10.0);
    QCOMPARE(lines.at(0).translation,
             QStringLiteral("Descanso eterno en el tiempo"));
    QCOMPARE(lines.at(1).time, 20.0);
}

QTEST_MAIN(TestLotusTune)
#include "test_all.moc"

