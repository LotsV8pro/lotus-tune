#include <QtTest/QtTest>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QStandardPaths>
#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QUrl>
#include <QVector>

#include "downloads.h"
#include "player.h"
#include "appconfig.h"
#include "catalog.h"
#include "sources.h"
#include "lyrics.h"

class TestLotusTune : public QObject
{
    Q_OBJECT

    // Temporary HOME: Catalog writes its state in
    // ~/.local/state/lotus-tune through QDir::homePath(), so the whole suite
    // runs with the HOME pointing here to avoid touching the user's library.
    QTemporaryDir *m_homeDir = nullptr;

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
    void testLikes();
    void testLyricsState();
    void testParseLrc();
    void testLooksLikeCredit();
    void testLineIndexAt();
};

void TestLotusTune::initTestCase()
{
    qDebug() << "Iniciando suite de pruebas de Lotus Tune 1.0...";

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
    QCOMPARE(sm.searchPrefix("spotify"), QString(""));
    QCOMPARE(sm.list().size(), 4);

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

QTEST_MAIN(TestLotusTune)
#include "test_all.moc"
